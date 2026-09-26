import Foundation
import Combine
import BackgroundTasks

enum ICloudLibraryError: LocalizedError {
    case disabled, busy
    var errorDescription: String? {
        switch self {
        case .disabled: "Enable iCloud Backup first."
        case .busy: "An iCloud operation is already in progress. Try again when it finishes."
        }
    }
}

@MainActor
final class ICloudLibraryCoordinator: ObservableObject {
    static let shared = ICloudLibraryCoordinator()
    @Published private(set) var working = false
    @Published private(set) var lastError: String?

    func maintenance(store: LedgerStore, preferences: AppPreferencesStore) async {
        guard preferences.value.iCloudBackupEnabled, store.persistenceEnabled, !working else { return }
        working = true
        defer { working = false; ICloudBackupBackground.schedule(preferences: preferences.value) }
        do {
            try await synchronizeAll(store: store)
            guard preferences.value.iCloudBackupEnabled, store.persistenceEnabled else { return }
            let value = preferences.value
            let due = value.iCloudLastBackupAt.map { value.iCloudBackupInterval.nextDate(after: $0) <= .now } ?? true
            let library = store.librarySnapshot()
            // A newly installed empty device must not overwrite an existing full backup.
            let hasData = library.books.contains { !$0.state.accounts.isEmpty || !$0.state.transactions.isEmpty }
            if due && hasData {
                let date = try await ICloudBackupService.shared.backupLibrary(library)
                preferences.update { $0.iCloudLastBackupAt = date }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            store.lastSyncError = lastError
        }
    }

    func backupNow(store: LedgerStore, preferences: AppPreferencesStore) async throws {
        guard preferences.value.iCloudBackupEnabled else { throw ICloudLibraryError.disabled }
        guard !working else { throw ICloudLibraryError.busy }
        working = true
        defer { working = false; ICloudBackupBackground.schedule(preferences: preferences.value) }
        try await synchronizeAll(store: store)
        guard preferences.value.iCloudBackupEnabled, store.persistenceEnabled else { throw ICloudLibraryError.disabled }
        let date = try await ICloudBackupService.shared.backupLibrary(store.librarySnapshot())
        preferences.update { $0.iCloudLastBackupAt = date }
        lastError = nil
    }

    func restorePreview(store: LedgerStore, preferences: AppPreferencesStore) async throws -> ICloudLibraryRestorePreview {
        guard preferences.value.iCloudBackupEnabled else { throw ICloudLibraryError.disabled }
        guard !working else { throw ICloudLibraryError.busy }
        working = true
        defer { working = false }
        return try await ICloudBackupService.shared.restoreLibrary(existingState: store.state)
    }

    func synchronizeAll(store: LedgerStore) async throws {
        guard store.persistenceEnabled else { throw BackupError.invalidFormat }
        // Fetch deletions first, before creating zones or sending a stale local snapshot.
        try await CloudLedgerService.shared.fetchAllLedgers()
        for id in store.books.filter({ $0.effectiveEncryptionState == .authorizationRequired }).map(\.id) {
            await store.restoreAuthorizedLedger(bookID: id)
        }
        store.prepareBooksForICloudSync()
        try await store.persistDurableAsync()
        for book in store.librarySnapshot().books where book.isImplicitPlaceholder != true {
            if book.effectiveEncryptionState == .authorizationRequired || book.effectiveEncryptionState == .migrationFailed || book.effectiveEncryptionState == .enabling {
                throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: book.keyFingerprint)
            }
            if book.isEncrypted == true {
                try LedgerKeyStore.publishKeyToICloud(for: book.id, expectedFingerprint: book.keyFingerprint)
            }
            try await CloudLedgerService.shared.synchronize(book: book)
        }
        try await CloudLedgerService.shared.flushAllLedgers()
    }
}

@MainActor
enum ICloudBackupBackground {
    static let identifier = "com.finsy.app.icloud-backup"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                await ICloudLibraryCoordinator.shared.maintenance(store: .shared, preferences: .shared)
                refresh.setTaskCompleted(success: !Task.isCancelled && ICloudLibraryCoordinator.shared.lastError == nil)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    static func schedule(preferences: AppPreferences) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard preferences.iCloudBackupEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = preferences.iCloudLastBackupAt.map {
            max(preferences.iCloudBackupInterval.nextDate(after: $0), .now.addingTimeInterval(15 * 60))
        } ?? .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
