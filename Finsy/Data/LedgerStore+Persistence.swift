import Foundation
import CloudKit

extension LedgerStore {
    func refreshCurrencyCatalogIfNeeded(force: Bool = false) async throws {
        if !force, let updated = currencyCatalogUpdatedAt, Date.now.timeIntervalSince(updated) < 7 * 86_400 { return }
        let currencies = CurrencyDescriptor.appCatalog(try await FrankfurterRateService.shared.currencyCatalog())
        let snapshot = CurrencyCatalogSnapshot(fetchedAt: .now, currencies: currencies)
        currencyCatalog = currencies
        currencyCatalogUpdatedAt = snapshot.fetchedAt
        try CurrencyCatalogCache.write(snapshot)
    }

    func switchBook(to id: UUID) {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        guard id != activeBookID else { return }
        commitActiveBook()
        guard let book = books.first(where: { $0.id == id }) else { return }
        activeBookID = book.id
        let targetState = book.state
        mutateState { state in state = targetState }
        undoTransactions = []
        activeUndoOperation = nil
        undoMessage = nil
        processDueRecurring()
        scheduleSave()
    }

    func createBook(named rawName: String) {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Ledger \(books.count + 1)" : trimmed
        commitActiveBook()
        let book = LedgerBook(id: UUID(), name: name, state: SeedData.makeEmpty(), createdAt: .now, updatedAt: .now)
        books.append(book)
        activeBookID = book.id
        mutateState { state in state = book.state }
        undoTransactions = []
        activeUndoOperation = nil
        undoMessage = nil
        scheduleSave()
    }

    func markActiveBookCloudOwner(zoneName: String) {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].storageKind = .cloudOwner
        books[index].cloudZoneName = zoneName
        books[index].cloudZoneOwnerName = CKCurrentUserDefaultName
        books[index].state = state
        scheduleSave()
    }

    func markActiveBookEncrypted(fingerprint: String) {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].isEncrypted = true
        books[index].encryptionVersion = LedgerCryptoService.currentEncryptionVersion
        books[index].keyFingerprint = fingerprint
        books[index].encryptionState = .enabled
        books[index].encryptionUpdatedAt = .now
        books[index].updatedAt = .now
        scheduleSave()
    }

    func markActiveBookUnencrypted() {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].isEncrypted = false
        books[index].encryptionState = .disabled
        books[index].encryptionUpdatedAt = .now
        books[index].updatedAt = .now
        scheduleSave()
    }

    func detachCloudZone(_ zone: CKRecordZone.ID) {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        commitActiveBook()
        for index in books.indices where books[index].cloudZoneName == zone.zoneName && books[index].cloudZoneOwnerName == zone.ownerName {
            // Preserve the last local copy and unsent edits when a share is removed.
            books[index].storageKind = .local
            books[index].cloudZoneName = nil
            books[index].cloudZoneOwnerName = nil
        }
        scheduleSave()
    }

    @discardableResult
    func addOrMergeCloudBook(_ book: LedgerBook, deletedRecordNames: Set<String> = [], selectNewBook: Bool = true) -> Bool {
        guard canMutateLedger else { rejectRecoveryMutation(); return false }
        commitActiveBook()
        do {
            if let index = books.firstIndex(where: { $0.id == book.id }) {
                let merged = try CloudBookMerge.merge(local: books[index], remote: book, deletedRecordNames: deletedRecordNames)
                guard books[index] != merged else { return true }
                books[index] = merged
                if activeBookID == book.id { mutateState { $0 = merged.state } }
            } else {
                books.append(book)
                // Keep the existing share-acceptance behavior for a newly joined ledger.
                if selectNewBook {
                    activeBookID = book.id
                    mutateState { $0 = book.state }
                }
            }
            scheduleSave()
            return true
        } catch {
            lastSyncError = error.localizedDescription
            LedgerDiagnostics.failure(error, operation: "cloud-merge", logger: LedgerDiagnostics.cloud)
            return false
        }
    }

    func persistDurableAsync() async throws {
        #if DEBUG
        if let hook = persistenceTestHook {
            try await hook()
        }
        #endif
        guard persistenceEnabled else { return }
        commitActiveBook()
        saveTask?.cancel()
        saveRevision &+= 1
        let revision = saveRevision
        let snapshot = librarySnapshot()
        let saved = try await LedgerPersistence.shared.save(snapshot, revision: revision, previousHint: persistenceBaseline)
        guard saved, persistenceEnabled else { return }
        persistenceBaseline = nil
        OverviewWidgetRelay.updateSnapshot(store: self)
        for active in snapshot.books where active.effectiveStorageKind != .local {
            Task {
                do { try await CloudLedgerService.shared.synchronize(book: active, revision: revision) }
                catch { self.lastSyncError = error.localizedDescription }
            }
        }
    }

    func scheduleSave() {
        guard persistenceEnabled else {
            if !canMutateLedger { rejectRecoveryMutation() }
            return
        }
        commitActiveBook()
        saveTask?.cancel()
        saveRevision &+= 1
        let revision = saveRevision
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let snapshot = self.librarySnapshot()
            do {
                let saved = try await LedgerPersistence.shared.save(snapshot, revision: revision, previousHint: self.persistenceBaseline)
                guard saved else { return }
                self.persistenceBaseline = nil
                OverviewWidgetRelay.updateSnapshot(store: self)
            }
            catch {
                self.presentedError = String(format: String(localized: "Local save failed: %@"), error.localizedDescription)
                LedgerDiagnostics.failure(error, operation: "local-save", logger: LedgerDiagnostics.persistence)
                return
            }
            guard !Task.isCancelled, self.persistenceEnabled else { return }
            for active in snapshot.books where active.effectiveStorageKind != .local {
                do { try await CloudLedgerService.shared.synchronize(book: active, revision: revision) }
                catch { self.lastSyncError = error.localizedDescription }
            }
        }
    }

    func commitActiveBook() {
        guard canMutateLedger else { return }
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        if books[index].state != state {
            books[index].state = state
            books[index].updatedAt = .now
        }
    }

    func librarySnapshot() -> LedgerLibrary {
        var snapshotBooks = books
        if let index = snapshotBooks.firstIndex(where: { $0.id == activeBookID }) {
            if snapshotBooks[index].state != state {
                snapshotBooks[index].state = state
                snapshotBooks[index].updatedAt = .now
            }
        }
        return LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: activeBookID, books: snapshotBooks)
    }

    nonisolated static var storageFolder: URL { LocalLedgerRepository.storageFolder }

    static func loadLibraryResult() throws -> LedgerLibraryLoadResult? {
        guard var result = try localRepository.loadResult() else { return nil }
        do {
            let diskSnapshot = result.library
            try normalizeAndValidate(&result.library)
            if result.source == .sqlite, result.library == diskSnapshot {
                result.writerBaseline = diskSnapshot
            }
            return result
        } catch {
            guard result.source == .sqlite, var legacy = try localRepository.loadLegacyJSON() else { throw error }
            try normalizeAndValidate(&legacy)
            LedgerDiagnostics.failure(error, operation: "sqlite-semantic-recovery", logger: LedgerDiagnostics.persistence)
            return LedgerLibraryLoadResult(
                library: legacy,
                source: .legacyJSONReadOnlyRecovery,
                sqliteFailureDescription: error.localizedDescription,
                writerBaseline: nil
            )
        }
    }

    static func loadLibrary() throws -> LedgerLibrary? {
        try loadLibraryResult()?.library
    }

    private static func normalizeAndValidate(_ library: inout LedgerLibrary) throws {
        guard !library.books.isEmpty else { throw BackupError.invalidFormat }
        let normalizeStart = Date.now
        SchemaMigration.normalize(&library)
        LedgerDiagnostics.recordStartupPhase("normalize", duration: Date.now.timeIntervalSince(normalizeStart), books: library.books.count)
        let validateStart = Date.now
        // Invariant: BackupCodec.validate() requires fully materialized LedgerState
        for book in library.books { try BackupCodec.validate(book.state) }
        LedgerDiagnostics.recordStartupPhase("validate", duration: Date.now.timeIntervalSince(validateStart), books: library.books.count)
    }

    static func loadLegacyState() throws -> LedgerState? {
        let url = storageFolder.appending(path: "ledger.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        var state: LedgerState
        if let current = try? BackupCodec.decoder().decode(LedgerState.self, from: data), current.schemaVersion >= 2 { state = current }
        else if let old = try? BackupCodec.decoder().decode(LedgerStateV1.self, from: data), old.schemaVersion <= 1 { state = SchemaMigration.migrate(old) }
        else { throw BackupError.invalidFormat }
        PurchaseRules.migrateDevelopmentSessions(in: &state)
        SchemaMigration.normalize(&state)
        try BackupCodec.validate(state)
        return state
    }

    nonisolated static func writeLibrary(_ library: LedgerLibrary) throws {
        try localRepository.saveLibrary(library)
    }

}
