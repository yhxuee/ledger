import Foundation
import CryptoKit

extension LedgerStore {
    func prepareBooksForEncryption() {
        guard canMutateLedger, AppPreferencesStore.shared.value.endToEndEncryptionEnabled else { return }
        commitActiveBook()
        for index in books.indices where books[index].isEncrypted != true {
            if books[index].isImplicitPlaceholder == true && books[index].state.accounts.isEmpty && books[index].state.transactions.isEmpty { continue }
            do {
                let id = books[index].id
                let key = try LedgerKeyStore.loadKey(for: id) ?? LedgerKeyStore.generateAndSaveKey(for: id).key
                books[index].isEncrypted = true
                books[index].keyFingerprint = LedgerKeyStore.fingerprint(for: key, ledgerID: id)
                books[index].encryptionVersion = LedgerCryptoService.currentEncryptionVersion
                books[index].encryptionUpdatedAt = .now
                books[index].updatedAt = .now
                books[index].encryptionState = books[index].effectiveStorageKind == .local ? .enabled : .enabling
            } catch {
                lastSyncError = error.localizedDescription
                presentedError = error.localizedDescription
            }
        }
    }

    func enableEncryptionForAllBooks() async throws {
        guard canMutateLedger else { throw CocoaError(.fileWriteNoPermission) }
        AppPreferencesStore.shared.update { $0.endToEndEncryptionEnabled = true }
        guard AppPreferencesStore.shared.value.endToEndEncryptionEnabled else { throw CocoaError(.fileWriteUnknown) }
        prepareBooksForEncryption()
        try await persistDurableAsync()
        try Self.localRepository.encryptLegacyRecoverySnapshot()
        var failures: [String] = []
        for id in books.map(\.id) {
            guard let book = books.first(where: { $0.id == id }) else { continue }
            if book.effectiveEncryptionState == .authorizationRequired {
                failures.append("\(book.name): device authorization required.")
                continue
            }
            if book.effectiveEncryptionState == .enabling || book.effectiveEncryptionState == .migrationFailed || book.isEncrypted != true {
                do { try await enableEncryption(bookID: id) }
                catch { failures.append("\(book.name): \(error.localizedDescription)") }
            }
        }
        if !failures.isEmpty { throw LedgerCryptoError.corruptedContainer(failures.joined(separator: "\n")) }
    }

    func enableEncryption(bookID: UUID) async throws {
        guard canMutateLedger else { rejectRecoveryMutation(); throw CocoaError(.fileWriteNoPermission) }
        guard encryptionMigrations.insert(bookID).inserted else { throw CloudLedgerError.migrationInProgress }
        defer { encryptionMigrations.remove(bookID) }
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        commitActiveBook()
        let existing = books[index]
        guard existing.effectiveEncryptionState != .authorizationRequired else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: existing.keyFingerprint)
        }
        let key: SymmetricKey
        if let saved = try LedgerKeyStore.loadKey(for: bookID) { key = saved }
        else {
            guard existing.isEncrypted != true else { throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: existing.keyFingerprint) }
            key = try LedgerKeyStore.generateAndSaveKey(for: bookID).key
        }
        let fingerprint = LedgerKeyStore.fingerprint(for: key, ledgerID: bookID)
        if existing.isEncrypted == true, let expected = existing.keyFingerprint, expected.lowercased() != fingerprint.lowercased() {
            throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: expected)
        }
        books[index].isEncrypted = true
        books[index].encryptionState = .enabling
        if existing.effectiveEncryptionState == .disabled { books[index].encryptionUpdatedAt = .now }
        books[index].encryptionVersion = LedgerCryptoService.currentEncryptionVersion
        books[index].keyFingerprint = fingerprint
        books[index].updatedAt = .now
        do {
            try await persistDurableAsync()
            guard let snapshot = books.first(where: { $0.id == bookID }) else { return }
            let migrated = try await CloudLedgerService.shared.migrateToEncrypted(book: snapshot, key: key)
            guard let storedKey = try LedgerKeyStore.loadKey(for: bookID),
                  LedgerKeyStore.fingerprint(for: storedKey, ledgerID: bookID) == fingerprint else {
                throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: fingerprint)
            }
            commitActiveBook()
            guard let currentIndex = books.firstIndex(where: { $0.id == bookID }) else { return }
            // Preserve edits and book switches made while network operations were suspended.
            var merged = try CloudBookMerge.merge(local: books[currentIndex], remote: migrated)
            merged.encryptionState = .enabled
            merged.isEncrypted = true
            merged.keyFingerprint = fingerprint
            books[currentIndex] = merged
            if activeBookID == bookID { mutateState { $0 = merged.state } }
            try await persistDurableAsync()
        } catch {
            if let currentIndex = books.firstIndex(where: { $0.id == bookID }) {
                if case LedgerCryptoError.authorizationRequired(_, let fingerprint) = error {
                    books[currentIndex].encryptionState = .authorizationRequired
                    books[currentIndex].keyFingerprint = fingerprint
                } else { books[currentIndex].encryptionState = .migrationFailed }
                do { try await persistDurableAsync() }
                catch {
                    LedgerDiagnostics.failure(error, operation: "Persist encryption recovery state", logger: LedgerDiagnostics.security)
                    scheduleSave()
                }
            }
            throw error
        }
    }

    func restoreAuthorizedLedger(bookID: UUID) async {
        guard canMutateLedger else { return }
        guard let book = books.first(where: { $0.id == bookID }), book.effectiveEncryptionState == .authorizationRequired else { return }
        do {
            guard try LedgerKeyStore.loadKey(for: bookID) != nil else { return }
            let restored = try await CloudLedgerService.shared.authorizedBook(book)
            addOrMergeCloudBook(restored)
        } catch { lastSyncError = error.localizedDescription }
    }

    func resumeEncryptionMigrations() async {
        guard canMutateLedger else { return }
        do { try LedgerKeyStore.migrateLegacyLocalKeys(); try LedgerKeyStore.migrateLegacyCloudKeys() }
        catch { lastSyncError = error.localizedDescription; return }
        prepareBooksForEncryption()
        for id in books.filter({ $0.effectiveEncryptionState == .authorizationRequired }).map(\.id) {
            await restoreAuthorizedLedger(bookID: id)
        }
        let ids = books.filter { $0.effectiveEncryptionState == .enabling || $0.effectiveEncryptionState == .migrationFailed }.map(\.id)
        for id in ids {
            do { try await enableEncryption(bookID: id) }
            catch {
                lastSyncError = error.localizedDescription
                LedgerDiagnostics.failure(error, operation: "resume-encryption", logger: LedgerDiagnostics.security)
            }
        }
    }
}

extension LedgerStore {
    private static func encryptionAttachmentIDs(_ book: LedgerBook) -> [String] {
        book.state.transactions.compactMap(\.noteAttachmentID)
        + (book.state.purchaseSessions ?? []).compactMap(\.receiptAttachmentID)
    }
    func completeKeyTransfer(_ receipt: FinsyTransferReceipt) async throws {
        guard canMutateLedger else { throw CocoaError(.fileWriteNoPermission) }
        _ = try LedgerDeviceAuthorization.verify(receipt)
        // Stop automatic re-enrollment even if local cleanup is interrupted.
        try LedgerDeviceAuthorization.write(true, account: "revoked-" + receipt.ledgerID.uuidString)
        commitActiveBook()
        if let index = books.firstIndex(where: { $0.id == receipt.ledgerID }) {
            let transferred = books[index]
            // Rewrap attachments referenced by another encrypted ledger before revoking this key.
            for retainedBook in books where retainedBook.id != receipt.ledgerID {
                try AttachmentStore.encryptLocalAttachments(for: retainedBook)
            }
            try await CloudLedgerService.shared.revokeLocalAccess(transferred)
            // Leave attachments still referenced by another ledger untouched.
            let retained = Set(books.filter { $0.id != receipt.ledgerID }.flatMap { Self.encryptionAttachmentIDs($0) })
            for identifier in Set(Self.encryptionAttachmentIDs(transferred)).subtracting(retained) {
                try await AttachmentStore.shared.delete(identifier: identifier)
            }
            books[index].state = SeedData.makeProductionEmpty()
            books[index].encryptionState = .authorizationRequired
            if activeBookID == receipt.ledgerID {
                mutateState { $0 = SeedData.makeProductionEmpty() }
                undoTransactions = []
                activeUndoOperation = nil
                undoMessage = nil
            }
            try await persistDurableAsync()
        }
        IncrementalLedgerRepository.clearDecryptedCache()
        try LedgerDeviceAuthorization.revoke(receipt)
    }
}
