import Foundation

protocol LedgerRepository: Sendable {
    func loadLibrary() throws -> LedgerLibrary?
    func saveLibrary(_ library: LedgerLibrary) throws
}

struct LocalLedgerRepository: LedgerRepository {
    static var storageFolder: URL { FinsyStorage.folder }

    var folder: URL = Self.storageFolder

    func loadLibrary() throws -> LedgerLibrary? {
        try FinsyStorage.prepare()
        let databaseURL = folder.appending(path: "ledger.sqlite")
        if FileManager.default.fileExists(atPath: databaseURL.path),
           let library = try IncrementalLedgerRepository(database: LedgerDiskDatabase(url: databaseURL)).load() {
            return library
        }
        let url = folder.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
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
        try IncrementalLedgerRepository(database: database).save(library, previous: previous)
    }

    func resetLocalData() throws {
        let target = Self.storageFolder.standardizedFileURL
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL
        guard target.deletingLastPathComponent() == applicationSupport else { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}
