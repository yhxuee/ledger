import Foundation
import Combine

@MainActor
final class ICloudSyncCoordinator: ObservableObject {
    static let shared = ICloudSyncCoordinator()
    @Published private(set) var working = false
    @Published private(set) var phase = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastCompletedAt: Date?
    @Published private(set) var awaitingAuthorizationCount = 0
    private var operation: Task<Void, Error>?
    private var timedOut = false

    func cancel() async {
        guard working else { return }
        phase = "Stopping sync..."
        operation?.cancel()
        await CloudLedgerService.shared.cancelSyncOperations()
    }

    func maintenance(store: LedgerStore, preferences: AppPreferencesStore) async {
        guard preferences.value.iCloudSyncEnabled, store.persistenceEnabled, !working else { return }
        working = true
        startedAt = .now
        timedOut = false
        let work = Task { try await self.synchronizeAll(store: store) }
        operation = work
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            guard !Task.isCancelled, self.working else { return }
            self.timedOut = true
            await self.cancel()
        }
        defer { timeout.cancel(); operation = nil; working = false; startedAt = nil }
        do {
            try await work.value
            try Task.checkCancellation()
            guard !work.isCancelled else { throw CancellationError() }
            lastCompletedAt = .now
            phase = awaitingAuthorizationCount == 0 ? "Up to date" : "Waiting for device authorization"
            store.lastSyncError = nil
        } catch {
            phase = timedOut ? "Sync timed out" : (work.isCancelled ? "Sync stopped" : "Sync failed")
            store.lastSyncError = timedOut
                ? "iCloud did not finish within 3 minutes. Local data is safe; queued changes will retry."
                : (work.isCancelled ? "Sync stopped. Local data and queued changes are preserved." : error.localizedDescription)
            LedgerDiagnostics.failure(error, operation: "icloud-sync", logger: LedgerDiagnostics.cloud)
        }
    }

    func synchronizeAll(store: LedgerStore) async throws {
        guard store.persistenceEnabled, AppPreferencesStore.shared.value.iCloudSyncEnabled else { throw BackupError.invalidFormat }
        // Fetch deletions first, before creating zones or sending a stale local snapshot.
        phase = "Downloading iCloud changes..."
        try await CloudLedgerService.shared.fetchAllLedgers { value in
            await MainActor.run { self.phase = value }
        }
        try Task.checkCancellation()
        phase = "Checking device authorization..."
        awaitingAuthorizationCount = 0
        for id in store.books.filter({ $0.effectiveEncryptionState == .authorizationRequired }).map(\.id) {
            await store.restoreAuthorizedLedger(bookID: id)
        }
        guard AppPreferencesStore.shared.value.iCloudSyncEnabled else { return }
        try Task.checkCancellation()
        phase = "Saving local changes..."
        store.prepareBooksForICloudSync()
        try await store.persistDurableAsync()
        let books = store.librarySnapshot().books.filter { $0.isImplicitPlaceholder != true }
        for (index, book) in books.enumerated() {
            try Task.checkCancellation()
            phase = "Preparing ledger \(index + 1) of \(books.count)..."
            if book.effectiveEncryptionState == .authorizationRequired {
                awaitingAuthorizationCount += 1
                continue // A locked ledger must not block other authorized ledgers.
            }
            if book.effectiveEncryptionState == .migrationFailed || book.effectiveEncryptionState == .enabling {
                continue // Encryption migration owns these ledgers; never send plaintext.
            }
            if book.isEncrypted == true {
                try LedgerKeyStore.validateLocalKey(for: book.id, expectedFingerprint: book.keyFingerprint)
            }
            try await CloudLedgerService.shared.synchronize(book: book)
        }
        try Task.checkCancellation()
        phase = "Uploading changes and checking iCloud..."
        try await CloudLedgerService.shared.flushAllLedgers()
        try Task.checkCancellation()
    }
}
