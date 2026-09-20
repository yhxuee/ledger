import Foundation

struct CurrencyCatalogSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var currencies: [CurrencyDescriptor]
}

enum CurrencyCatalogCache {
    nonisolated private static var fileURL: URL {
        FinsyStorage.folder
            .appending(path: "currency-catalog.json")
    }

    nonisolated static func load() -> CurrencyCatalogSnapshot? {
        guard (try? FinsyStorage.prepare()) != nil else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? BackupCodec.decoder().decode(CurrencyCatalogSnapshot.self, from: data)
    }

    nonisolated static func write(_ snapshot: CurrencyCatalogSnapshot) throws {
        try FinsyStorage.prepare()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try BackupCodec.encoder().encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
