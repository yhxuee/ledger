import Foundation

protocol LedgerRepository: Sendable {
    func loadLibrary() throws -> LedgerLibrary?
    func saveLibrary(_ library: LedgerLibrary) throws
}

enum LedgerLibraryLoadSource: Sendable, Equatable {
    case sqlite
    case legacyJSONImport
    case legacyJSONReadOnlyRecovery
}

struct LedgerLibraryLoadResult: Sendable {
    var library: LedgerLibrary
    var source: LedgerLibraryLoadSource
    var sqliteFailureDescription: String?
    /// Exact on-disk snapshot, available only when normalization did not alter it.
    var writerBaseline: LedgerLibrary?
}

struct LocalLedgerRepository: LedgerRepository {
    static var storageFolder: URL { FinsyStorage.folder }

    var folder: URL = Self.storageFolder

    func loadLibrary() throws -> LedgerLibrary? {
        try loadResult()?.library
    }

    func loadResult() throws -> LedgerLibraryLoadResult? {
        try FinsyStorage.prepare()
        let databaseURL = folder.appending(path: "ledger.sqlite")
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                if let library = try IncrementalLedgerRepository(database: LedgerDiskDatabase(url: databaseURL)).load() {
                    return LedgerLibraryLoadResult(library: library, source: .sqlite, sqliteFailureDescription: nil, writerBaseline: nil)
                }
            } catch {
                guard let legacy = try loadLegacyJSON() else { throw error }
                LedgerDiagnostics.failure(error, operation: "sqlite-read-only-recovery", logger: LedgerDiagnostics.persistence)
                return LedgerLibraryLoadResult(
                    library: legacy,
                    source: .legacyJSONReadOnlyRecovery,
                    sqliteFailureDescription: error.localizedDescription,
                    writerBaseline: nil
                )
            }
        }
        guard let legacy = try loadLegacyJSON() else { return nil }
        return LedgerLibraryLoadResult(library: legacy, source: .legacyJSONImport, sqliteFailureDescription: nil, writerBaseline: nil)
    }

    /// `library.json` is a one-way legacy import and an emergency read-only snapshot. SQLite saves
    /// do not update it, so it must never be treated as a current replica or overwrite failed SQLite.
    func loadLegacyJSON() throws -> LedgerLibrary? {
        let url = folder.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if let encrypted = try? BackupCodec.decoder().decode(ICloudLibraryBackup.self, from: data),
           encrypted.format == ICloudLibraryBackup.currentFormat { return try encrypted.library() }
        if var current = try? BackupCodec.decoder().decode(LedgerLibrary.self, from: data), current.schemaVersion >= 2 {
            for index in current.books.indices { PurchaseRules.migrateDevelopmentSessions(in: &current.books[index].state) }
            return current
        }
        if let old = try? BackupCodec.decoder().decode(LedgerLibraryV1.self, from: data), old.schemaVersion <= 1 { return SchemaMigration.migrate(old) }
        throw BackupError.invalidFormat
    }

    func saveLibrary(_ library: LedgerLibrary) throws {
        try saveLibrary(library, previous: nil)
    }

    func saveLibrary(_ library: LedgerLibrary, previous: LedgerLibrary?) throws {
        try FinsyStorage.prepare()
        let database = try LedgerDiskDatabase(url: folder.appending(path: "ledger.sqlite"))
        for book in library.books { try AttachmentStore.encryptLocalAttachments(for: book) }
        try IncrementalLedgerRepository(database: database).save(library, previous: previous)
    }

    func encryptLegacyRecoverySnapshot() throws {
        let url = folder.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        if let current = try? BackupCodec.decoder().decode(ICloudLibraryBackup.self, from: data),
           current.format == ICloudLibraryBackup.currentFormat { return }
        guard var legacy = try loadLegacyJSON() else { return }
        for index in legacy.books.indices {
            let id = legacy.books[index].id
            let key = try LedgerKeyStore.loadKey(for: id) ?? LedgerKeyStore.generateAndSaveKey(for: id).key
            legacy.books[index].isEncrypted = true
            legacy.books[index].encryptionState = .enabled
            legacy.books[index].keyFingerprint = LedgerKeyStore.fingerprint(for: key, ledgerID: id)
            legacy.books[index].encryptionVersion = LedgerCryptoService.currentEncryptionVersion
        }
        try ICloudLibraryBackup.encode(legacy).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func resetLocalData() throws {
        let target = Self.storageFolder.standardizedFileURL
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL
        guard target.deletingLastPathComponent() == applicationSupport else { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    func transactionRepository() throws -> IncrementalLedgerRepository {
        try FinsyStorage.prepare()
        let database = try LedgerDiskDatabase(url: folder.appending(path: "ledger.sqlite"))
        return IncrementalLedgerRepository(database: database)
    }

    func cloudMigrationBlocks() throws -> [(zoneName: String, ownerName: String?)] {
        try FinsyStorage.prepare()
        let databaseURL = folder.appending(path: "ledger.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        return try IncrementalLedgerRepository(database: LedgerDiskDatabase(url: databaseURL)).cloudMigrationBlocks()
    }
}
