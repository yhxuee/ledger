import Foundation
import Combine

@MainActor
final class ICloudSyncCoordinator: ObservableObject {
    static let shared = ICloudSyncCoordinator()
    @Published private(set) var working = false

    func maintenance(store: LedgerStore, preferences: AppPreferencesStore) async {
        guard preferences.value.iCloudSyncEnabled, store.persistenceEnabled, !working else { return }
        working = true
        defer { working = false }
        do {
            try await synchronizeAll(store: store)
            store.lastSyncError = nil
        } catch {
            store.lastSyncError = error.localizedDescription
            LedgerDiagnostics.failure(error, operation: "icloud-sync", logger: LedgerDiagnostics.cloud)
        }
    }

    func synchronizeAll(store: LedgerStore) async throws {
        guard store.persistenceEnabled, AppPreferencesStore.shared.value.iCloudSyncEnabled else { throw BackupError.invalidFormat }
        // Fetch deletions first, before creating zones or sending a stale local snapshot.
        try await CloudLedgerService.shared.fetchAllLedgers()
        for id in store.books.filter({ $0.effectiveEncryptionState == .authorizationRequired }).map(\.id) {
            await store.restoreAuthorizedLedger(bookID: id)
        }
        guard AppPreferencesStore.shared.value.iCloudSyncEnabled else { return }
        store.prepareBooksForICloudSync()
        try await store.persistDurableAsync()
        for book in store.librarySnapshot().books where book.isImplicitPlaceholder != true {
            if book.effectiveEncryptionState == .authorizationRequired || book.effectiveEncryptionState == .migrationFailed || book.effectiveEncryptionState == .enabling {
                throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: book.keyFingerprint)
            }
            if book.isEncrypted == true {
                try LedgerKeyStore.validateLocalKey(for: book.id, expectedFingerprint: book.keyFingerprint)
            }
            try await CloudLedgerService.shared.synchronize(book: book)
        }
        try await CloudLedgerService.shared.flushAllLedgers()
    }
}
