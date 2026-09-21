import Foundation

/// Legacy identifiers are confined to compatibility boundaries; new writes use Finsy.
enum FinsyCompatibility {
    static let storageDirectory = "WalletLedger"
    static let backupApps = ["finsy", "wallet-ledger-ios", "wallet-ledger-overview"]
    static let webBackupApp = "wallet-ledger-overview"
    static let backupType = "org.medx.walletledger.backup"
    static let backupFile = "WalletLedger-latest.walletledger"
    static let urlScheme = "walletledger"
}

enum FinsyStorage {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "finsy", directoryHint: .isDirectory)
    }

    // Static initialization serializes migration for stores initialized concurrently.
    private static let preparation: Result<Void, Error> = Result { try migrate() }
    static func prepare() throws { try preparation.get() }

    private static func migrate() throws {
        let manager = FileManager.default
        let destination = folder
        let parentFolder = destination.deletingLastPathComponent()
        let legacy = parentFolder.appending(path: FinsyCompatibility.storageDirectory)
        guard !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: legacy.path) else { return }

        // Clean up any stale migration folders from previous aborted attempts
        if let existingStaging = try? manager.contentsOfDirectory(at: parentFolder, includingPropertiesForKeys: nil) {
            for item in existingStaging where item.lastPathComponent.hasPrefix("finsy-migration-") {
                try? manager.removeItem(at: item)
            }
        }

        let staging = parentFolder.appending(path: "finsy-migration-\(UUID().uuidString)")
        try manager.copyItem(at: legacy, to: staging)
        do {
            guard let files = manager.enumerator(at: legacy, includingPropertiesForKeys: [.isRegularFileKey]) else { throw CocoaError(.fileReadUnknown) }
            let legacyStandard = legacy.standardizedFileURL.path
            for case let file as URL in files {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let fileStandard = file.standardizedFileURL.path
                guard fileStandard.hasPrefix(legacyStandard) else { continue }
                let relative = String(fileStandard.dropFirst(legacyStandard.count).drop(while: { $0 == "/" }))
                let targetURL = staging.appending(path: relative).standardizedFileURL
                guard manager.contentsEqual(atPath: fileStandard, andPath: targetURL.path) else { throw CocoaError(.fileReadCorruptFile) }
            }
            let libraryURL = staging.appending(path: "library.json")
            if manager.fileExists(atPath: libraryURL.path) {
                let data = try Data(contentsOf: libraryURL)
                var library: LedgerLibrary
                if let current = try? BackupCodec.decoder().decode(LedgerLibrary.self, from: data) { library = current }
                else { library = SchemaMigration.migrate(try BackupCodec.decoder().decode(LedgerLibraryV1.self, from: data)) }
                guard library.schemaVersion <= BackupCodec.currentSchemaVersion, !library.books.isEmpty else { throw BackupError.invalidFormat }
                SchemaMigration.normalize(&library)
                for book in library.books { try BackupCodec.validate(book.state) }
            }
            let preferencesURL = staging.appending(path: "app-preferences.json")
            if manager.fileExists(atPath: preferencesURL.path) {
                _ = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: preferencesURL))
            }
            // A directory rename publishes the verified copy atomically. The original is retained.
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
}

/// Serial background writes prevent main-thread JSON/disk work and stale save ordering.
actor LedgerPersistence {
    static let shared = LedgerPersistence()
    private var latestRevision: UInt64 = 0
    private var previous: LedgerLibrary?

    func invalidate(revision: UInt64) {
        latestRevision = max(latestRevision, revision)
        previous = nil
    }

    @discardableResult
    func save(_ library: LedgerLibrary, revision: UInt64, previousHint: LedgerLibrary? = nil) throws -> Bool {
        guard revision >= latestRevision else { return false }
        try FinsyStorage.prepare()
        if !FileManager.default.fileExists(atPath: FinsyStorage.folder.appending(path: "ledger.sqlite").path) {
            previous = nil
        } else if previous == nil {
            // The store already paid startup materialization cost. Reuse that exact validated
            // snapshot so the first mutation after launch remains an incremental save.
            previous = previousHint
        }
        try LocalLedgerRepository().saveLibrary(library, previous: previous)
        previous = library
        latestRevision = revision
        return true
    }
}
