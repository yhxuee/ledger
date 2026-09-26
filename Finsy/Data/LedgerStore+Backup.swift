import Foundation

extension LedgerStore {
    func restoreLibrary(_ library: LedgerLibrary) async throws {
        guard canMutateLedger else { throw BackupError.invalidFormat }
        guard !library.books.isEmpty, Set(library.books.map(\.id)).count == library.books.count else { throw BackupError.invalidFormat }
        for book in library.books { try BackupCodec.validate(book.state) }
        commitActiveBook()
        var restored = books
        var restoredActiveID = library.activeBookID
        for var book in library.books {
            if let index = restored.firstIndex(where: { $0.id == book.id }) {
                // A snapshot must never overwrite another owner's shared ledger.
                if restored[index].effectiveStorageKind != .cloudParticipant {
                    restored[index] = try CloudBookMerge.merge(local: restored[index], remote: book)
                }
            } else {
                let oldID = book.id
                book.id = UUID()
                if oldID == library.activeBookID { restoredActiveID = book.id }
                if book.effectiveStorageKind == .cloudParticipant { book.name += " (Restored)" }
                if let key = try LedgerKeyStore.loadKey(for: oldID, expectedFingerprint: book.keyFingerprint), book.isEncrypted == true {
                    try LedgerKeyStore.saveKey(key, for: book.id)
                    book.keyFingerprint = LedgerKeyStore.fingerprint(for: key, ledgerID: book.id)
                }
                book.storageKind = .local
                book.cloudZoneName = nil
                book.cloudZoneOwnerName = nil
                restored.append(book)
            }
        }
        if restored.count > 1 { restored.removeAll { $0.isImplicitPlaceholder == true && $0.state.accounts.isEmpty && $0.state.transactions.isEmpty } }
        books = restored
        if let active = books.first(where: { $0.id == restoredActiveID }) {
            activeBookID = active.id
            mutateState { $0 = active.state }
        } else if let active = books.first(where: { $0.id == activeBookID }) {
            mutateState { $0 = active.state }
        }
        try await persistDurableAsync()
    }

    func replace(with envelope: LedgerBackupEnvelope) {
        guard canMutateLedger else { rejectRecoveryMutation(); return }
        do {
            var importedState = envelope.data
            SchemaMigration.normalize(&importedState)
            try BackupCodec.validate(importedState)
            if activeBook.effectiveStorageKind == .local {
                mutateState { state in state = importedState }
            } else {
                commitActiveBook()
                let now = Date.now
                let imported = LedgerBook(id: UUID(), name: "Imported Ledger", state: importedState, createdAt: now, updatedAt: now, storageKind: .local, cloudZoneName: nil, cloudZoneOwnerName: nil)
                books.append(imported)
                activeBookID = imported.id
                mutateState { state in state = imported.state }
            }
            scheduleSave()
        } catch { presentedError = error.localizedDescription }
    }

    func resetLocalData() async throws {
        saveTask?.cancel()
        persistenceEnabled = false
        defer { persistenceEnabled = persistenceRecoveryMode == nil }
        saveRevision &+= 1
        await LedgerPersistence.shared.invalidate(revision: saveRevision)
        await CloudLedgerService.shared.resetLocalState()
        try Self.localRepository.resetLocalData()
        try PurchaseSharedStateStore.resetLocalSnapshots()
        IncrementalLedgerRepository.clearDecryptedCache()
        try LedgerKeyStore.reset()
        leaveRecoveryModeAfterReset()
        Task { await PurchaseLiveActivityController.shared.endAll() }
        let initial = SeedData.makeProductionEmpty()
        let book = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now, isImplicitPlaceholder: true)
        books = [book]
        activeBookID = book.id
        mutateState { state in state = initial }
        currencyCatalog = CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = nil
        undoTransactions = []
        activeUndoOperation = nil
        undoMessage = nil
        persistenceEnabled = true
        scheduleSave()
    }

    func backupEnvelope() -> LedgerBackupEnvelope { BackupCodec.envelope(for: materializeFullState()) }


}
