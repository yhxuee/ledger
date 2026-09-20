import Foundation

protocol LedgerRepository: Sendable {
    func loadLibrary() throws -> LedgerLibrary?
    func saveLibrary(_ library: LedgerLibrary) throws
}

struct LocalLedgerRepository: LedgerRepository {
    static var storageFolder: URL { FinsyStorage.folder }

    func loadLibrary() throws -> LedgerLibrary? {
        try FinsyStorage.prepare()
        let url = Self.storageFolder.appending(path: "library.json")
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
        try FinsyStorage.prepare()
        let url = Self.storageFolder.appending(path: "library.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try BackupCodec.encoder().encode(library).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func resetLocalData() throws {
        let target = Self.storageFolder.standardizedFileURL
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL
        guard target.deletingLastPathComponent() == applicationSupport else { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}
