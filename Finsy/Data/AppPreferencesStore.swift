import Foundation
import SwiftUI

@MainActor
final class AppPreferencesStore: ObservableObject {
    static let shared = AppPreferencesStore()
    @Published private(set) var value: AppPreferences
    private var saveTask: Task<Void, Never>?

    init() { value = Self.load() ?? AppPreferences() }

    func update(_ change: (inout AppPreferences) -> Void) {
        let previous = value
        let oldLock = value.biometricLockEnabled
        change(&value)
        let snapshot = value
        if oldLock != snapshot.biometricLockEnabled {
            OverviewWidgetRelay.updatePrivacyMask(isPrivacyMasked: snapshot.biometricLockEnabled)
        }
        saveTask?.cancel()
        if previous.endToEndEncryptionEnabled != snapshot.endToEndEncryptionEnabled || previous.iCloudSyncEnabled != snapshot.iCloudSyncEnabled || previous.iCloudBackupEnabled != snapshot.iCloudBackupEnabled || previous.iCloudBackupInterval != snapshot.iCloudBackupInterval || previous.iCloudLastBackupAt != snapshot.iCloudLastBackupAt {
            do { try Self.write(snapshot) }
            catch {
                value = previous
                LedgerStore.shared.presentedError = error.localizedDescription
            }
            return
        }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do { try Self.write(snapshot) }
            catch { assertionFailure("App preferences could not be saved: \(error)") }
        }
    }

    func reset() {
        value = AppPreferences()
        try? Self.write(value)
    }

    nonisolated private static var fileURL: URL {
        FinsyStorage.folder
            .appending(path: "app-preferences.json")
    }

    nonisolated static func load() -> AppPreferences? {
        guard (try? FinsyStorage.prepare()) != nil else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AppPreferences.self, from: data)
    }

    nonisolated private static func write(_ preferences: AppPreferences) throws {
        try FinsyStorage.prepare()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try JSONEncoder().encode(preferences).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
