import Foundation

extension LedgerStore {
    func replace(with envelope: LedgerBackupEnvelope) {
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
        defer { persistenceEnabled = true }
        saveRevision &+= 1
        await LedgerPersistence.shared.invalidate(revision: saveRevision)
        await CloudLedgerService.shared.resetLocalState()
        try Self.localRepository.resetLocalData()
        try PurchaseSharedStateStore.resetLocalSnapshots()
        Task { await PurchaseLiveActivityController.shared.endAll() }
        let initial = SeedData.makeProductionEmpty()
        let book = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now)
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

    func backupEnvelope() -> LedgerBackupEnvelope { BackupCodec.envelope(for: state) }


}
