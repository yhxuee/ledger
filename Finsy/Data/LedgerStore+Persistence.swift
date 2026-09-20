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
        guard id != activeBookID else { return }
        commitActiveBook()
        guard let book = books.first(where: { $0.id == id }) else { return }
        activeBookID = book.id
        mutateState { state in state = book.state }
        undoTransactions = []
        undoState = nil
        undoMessage = nil
        processDueRecurring()
        scheduleSave()
    }

    func createBook(named rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Ledger \(books.count + 1)" : trimmed
        commitActiveBook()
        let book = LedgerBook(id: UUID(), name: name, state: SeedData.makeEmpty(), createdAt: .now, updatedAt: .now)
        books.append(book)
        activeBookID = book.id
        mutateState { state in state = book.state }
        undoTransactions = []
        undoState = nil
        undoMessage = nil
        scheduleSave()
    }

    func markActiveBookCloudOwner(zoneName: String) {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].storageKind = .cloudOwner
        books[index].cloudZoneName = zoneName
        books[index].cloudZoneOwnerName = CKCurrentUserDefaultName
        books[index].state = state
        scheduleSave()
    }

    func markActiveBookEncrypted(fingerprint: String) {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].isEncrypted = true
        books[index].encryptionVersion = LedgerCryptoService.currentEncryptionVersion
        books[index].keyFingerprint = fingerprint
        books[index].encryptionState = .enabled
        books[index].updatedAt = .now
        scheduleSave()
    }

    func markActiveBookUnencrypted() {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].isEncrypted = false
        books[index].encryptionState = .disabled
        books[index].updatedAt = .now
        scheduleSave()
    }

    func addOrMergeCloudBook(_ book: LedgerBook) {
        commitActiveBook()
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            guard book.updatedAt >= books[index].updatedAt else { return }
            books[index] = book
        } else { books.append(book) }
        activeBookID = book.id
        mutateState { state in state = book.state }
        scheduleSave()
    }


    func persistDurableAsync() async throws {
        guard persistenceEnabled else { return }
        commitActiveBook()
        saveTask?.cancel()
        saveRevision &+= 1
        let revision = saveRevision
        let snapshot = librarySnapshot()
        try persistenceFailureHook?()
        try await LedgerPersistence.shared.save(snapshot, revision: revision)
        OverviewWidgetRelay.updateSnapshot(store: self)
        if let active = snapshot.books.first(where: { $0.id == snapshot.activeBookID }), active.effectiveStorageKind != .local {
            Task {
                do { try await CloudLedgerService.shared.synchronize(book: active); self.lastSyncError = nil }
                catch { self.lastSyncError = error.localizedDescription }
            }
        }
    }

    func scheduleSave() {
        guard persistenceEnabled else { return }
        commitActiveBook()
        saveTask?.cancel()
        saveRevision &+= 1
        let revision = saveRevision
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let snapshot = self.librarySnapshot()
            OverviewWidgetRelay.updateSnapshot(store: self)
            do { try await LedgerPersistence.shared.save(snapshot, revision: revision) }
            catch { self.presentedError = "Local save failed: \(error.localizedDescription)" }
            if let active = snapshot.books.first(where: { $0.id == snapshot.activeBookID }), active.effectiveStorageKind != .local {
                do { try await CloudLedgerService.shared.synchronize(book: active); self.lastSyncError = nil }
                catch { self.lastSyncError = error.localizedDescription }
            }
        }
    }

    func commitActiveBook() {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].state = state
        books[index].updatedAt = .now
    }

    func librarySnapshot() -> LedgerLibrary {
        var snapshotBooks = books
        if let index = snapshotBooks.firstIndex(where: { $0.id == activeBookID }) {
            snapshotBooks[index].state = state
            snapshotBooks[index].updatedAt = .now
        }
        return LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: activeBookID, books: snapshotBooks)
    }

    nonisolated static var storageFolder: URL { LocalLedgerRepository.storageFolder }

    static func loadLibrary() throws -> LedgerLibrary? {
        guard var library = try localRepository.loadLibrary() else { return nil }
        guard !library.books.isEmpty else { throw BackupError.invalidFormat }
        SchemaMigration.normalize(&library)
        for book in library.books { try BackupCodec.validate(book.state) }
        return library
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
