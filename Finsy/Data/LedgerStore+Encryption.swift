import Foundation
import CryptoKit

extension LedgerStore {
    func enableEncryption(bookID: UUID) async throws {
        guard canMutateLedger else { rejectRecoveryMutation(); throw CocoaError(.fileWriteNoPermission) }
        guard encryptionMigrations.insert(bookID).inserted else { throw CloudLedgerError.migrationInProgress }
        defer { encryptionMigrations.remove(bookID) }
        guard let index = books.firstIndex(where: { $0.id == bookID }), books[index].effectiveStorageKind != .cloudParticipant else { return }
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
                books[currentIndex].encryptionState = .migrationFailed
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
