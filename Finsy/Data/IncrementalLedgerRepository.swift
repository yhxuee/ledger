import Foundation

/// The manifest and changed entities commit together. Original JSON is retained for recovery.
struct IncrementalLedgerRepository {
    let database: LedgerDiskDatabase
    private struct Manifest: Codable {
        var schemaVersion: Int
        var activeBookID: UUID
        var bookIDs: [UUID]
    }
    private struct Header: Codable {
        var book: LedgerBook
        var accountIDs: [UUID]
        var transactionIDs: [UUID]
        var recurringIDs: [UUID]?
        var purchaseIDs: [UUID]?

        init(_ value: LedgerBook) {
            book = value
            accountIDs = value.state.accounts.map(\.id)
            transactionIDs = value.state.transactions.map(\.id)
            recurringIDs = value.state.recurringRules?.map(\.id)
            purchaseIDs = value.state.purchaseSessions?.map(\.id)
            book.state.accounts = []; book.state.transactions = []
            book.state.recurringRules = nil; book.state.purchaseSessions = nil
        }
    }

    // Internal storage uses full precision dates; portable backups retain their existing codec.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(database: LedgerDiskDatabase) {
        self.database = database
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> LedgerLibrary? {
        let started = Date.now
        let library: LedgerLibrary? = try database.transaction(write: false) {
            guard let data = try database.data("library", "manifest") else { return nil }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.schemaVersion <= BackupCodec.currentSchemaVersion else { throw BackupError.futureSchema(manifest.schemaVersion) }
            let books = try manifest.bookIDs.map { id -> LedgerBook in
                let namespace = id.uuidString
                let header: Header = try read(namespace, "header")
                var book = header.book
                book.state.accounts = try read(namespace, ids: header.accountIDs, prefix: "account")
                book.state.transactions = try read(namespace, ids: header.transactionIDs, prefix: "transaction")
                book.state.recurringRules = try header.recurringIDs.map { try read(namespace, ids: $0, prefix: "recurring") }
                book.state.purchaseSessions = try header.purchaseIDs.map { try read(namespace, ids: $0, prefix: "purchase") }
                return book
            }
            return LedgerLibrary(schemaVersion: manifest.schemaVersion, activeBookID: manifest.activeBookID, books: books)
        }
        if let library {
            let count = library.books.reduce(0) { $0 + $1.state.transactions.count }
            LedgerDiagnostics.persistence.info("Loaded library books=\(library.books.count) transactions=\(count) elapsed=\(Date.now.timeIntervalSince(started))")
        }
        return library
    }

    private func read<T: Decodable>(_ namespace: String, ids: [UUID], prefix: String) throws -> [T] {
        try database.values(namespace, keys: ids.lazy.map { "\(prefix)-\($0)" }) {
            try decoder.decode(T.self, from: $0)
        }
    }

    private func read<T: Decodable>(_ namespace: String, _ key: String) throws -> T {
        guard let data = try database.data(namespace, key) else { throw BackupError.invalidFormat }
        return try decoder.decode(T.self, from: data)
    }

    func save(_ library: LedgerLibrary, previous: LedgerLibrary?) throws {
        let start = Date.now
        try database.transaction {
            let oldBooks = Dictionary(uniqueKeysWithValues: (previous?.books ?? []).map { ($0.id, $0) })
            for book in library.books {
                let old = oldBooks[book.id]
                guard book != old else { continue }
                let namespace = book.id.uuidString
                try update(book.state.accounts, previous: old?.state.accounts, namespace: namespace, prefix: "account")
                try update(book.state.transactions, previous: old?.state.transactions, namespace: namespace, prefix: "transaction")
                try update(book.state.recurringRules ?? [], previous: old?.state.recurringRules, namespace: namespace, prefix: "recurring")
                try update(book.state.purchaseSessions ?? [], previous: old?.state.purchaseSessions, namespace: namespace, prefix: "purchase")
                try database.put(namespace, "header", encoder.encode(Header(book)))
            }
            let manifest = Manifest(schemaVersion: library.schemaVersion, activeBookID: library.activeBookID, bookIDs: library.books.map(\.id))
            if let oldData = try database.data("library", "manifest") {
                let old = try decoder.decode(Manifest.self, from: oldData)
                for id in Set(old.bookIDs).subtracting(manifest.bookIDs) {
                    for key in try database.keys(id.uuidString) { try database.remove(id.uuidString, key) }
                }
            }
            try database.put("library", "manifest", encoder.encode(manifest))
        }
        LedgerDiagnostics.persistence.info("Saved library books=\(library.books.count) elapsed=\(Date.now.timeIntervalSince(start))")
    }

    private func update<T: Codable & Equatable & Identifiable>(_ values: [T], previous: [T]?, namespace: String, prefix: String) throws where T.ID == UUID {
        let old = Dictionary(uniqueKeysWithValues: (previous ?? []).map { ($0.id, $0) })
        let currentIDs = Set(values.map(\.id))
        for value in values where old[value.id] != value {
            try database.put(namespace, "\(prefix)-\(value.id)", encoder.encode(value))
        }
        if previous != nil {
            for id in Set(old.keys).subtracting(currentIDs) { try database.remove(namespace, "\(prefix)-\(id)") }
        } else {
            let expected = Set(values.map { "\(prefix)-\($0.id)" })
            for key in try database.keys(namespace) where key.hasPrefix(prefix + "-") && !expected.contains(key) {
                try database.remove(namespace, key)
            }
        }
    }
}
