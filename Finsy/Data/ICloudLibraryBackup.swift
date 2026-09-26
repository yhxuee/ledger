import Foundation

/// Every ledger has its own .fsy payload so an encrypted ledger never falls back to plaintext.
struct ICloudLibraryBackup: Codable, Sendable {
    static let currentFormat = "finsy-library-backup"
    var format: String = Self.currentFormat
    var version = 1
    var createdAt: Date
    var activeBookID: UUID
    var entries: [Entry]

    struct Entry: Codable, Sendable {
        var header: LedgerBook
        var payload: Data
    }

    static func encode(_ library: LedgerLibrary) throws -> Data {
        let entries = try library.books.map { book in
            let key = try CloudRecordMapper.encryptionKey(for: book)
            let payload = try BackupCodec.encodeFsy(envelope: BackupCodec.envelope(for: book.state), ledgerID: book.id, key: key)
            var header = book
            header.state = SeedData.makeProductionEmpty()
            return Entry(header: header, payload: payload)
        }
        return try BackupCodec.encoder().encode(Self(createdAt: .now, activeBookID: library.activeBookID, entries: entries))
    }

    func library() throws -> LedgerLibrary {
        guard format == Self.currentFormat, version == 1, !entries.isEmpty,
              Set(entries.map { $0.header.id }).count == entries.count else { throw BackupError.invalidFormat }
        let books = try entries.map { entry in
            guard let container = try? BackupCodec.decoder().decode(FsyBackupContainer.self, from: entry.payload),
                  container.ledgerID == entry.header.id else { throw BackupError.invalidFormat }
            var book = entry.header
            book.state = try BackupCodec.decode(entry.payload, sourceName: book.name + ".fsy").envelope.data
            return book
        }
        return LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion,
                             activeBookID: books.contains(where: { $0.id == activeBookID }) ? activeBookID : books[0].id,
                             books: books)
    }
}

struct ICloudLibraryRestorePreview: Identifiable, Sendable {
    let id = UUID()
    var library: LedgerLibrary
    var createdAt: Date
    var transactionCount: Int { library.books.reduce(0) { $0 + $1.state.transactions.filter { $0.deletedAt == nil }.count } }
}
