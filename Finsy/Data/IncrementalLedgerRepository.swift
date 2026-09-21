import Foundation

/// The manifest and changed entities commit together. Original JSON is retained for recovery.
struct IncrementalLedgerRepository: Sendable {
    let database: LedgerDiskDatabase
    private struct Manifest: Codable {
        var schemaVersion: Int
        var activeBookID: UUID
        var bookIDs: [UUID]
    }
    struct Header: Codable {
        var book: LedgerBook
        var accountIDs: [UUID]
        var transactionIDs: [UUID]
        var recurringIDs: [UUID]?
        var purchaseIDs: [UUID]?
        var validatedPocketBalances: [UUID: [String: Double]]?

        init(_ value: LedgerBook, allTransactionIDs: [UUID]? = nil, validatedBalances: [UUID: [String: Double]]? = nil) {
            book = value
            accountIDs = value.state.accounts.map(\.id)
            transactionIDs = allTransactionIDs ?? value.state.transactions.map(\.id)
            recurringIDs = value.state.recurringRules?.map(\.id)
            purchaseIDs = value.state.purchaseSessions?.map(\.id)
            validatedPocketBalances = validatedBalances
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

    func load(pageSize: Int = 300) throws -> LedgerLibrary? {
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
                book.state.recurringRules = try header.recurringIDs.map { try read(namespace, ids: $0, prefix: "recurring") }
                book.state.purchaseSessions = try header.purchaseIDs.map { try read(namespace, ids: $0, prefix: "purchase") }

                if id == manifest.activeBookID {
                    // Active book: hydrate bounded recent transactions
                    try ensureIndexPopulated(for: id)
                    let recentIDs: [UUID]
                    if try database.hasIndexedTransactions(bookID: namespace) {
                        let ids = try database.recentTransactionIDs(bookID: namespace, limit: pageSize)
                        recentIDs = ids.compactMap(UUID.init)
                    } else if header.transactionIDs.count <= pageSize {
                        recentIDs = header.transactionIDs
                    } else {
                        recentIDs = Array(header.transactionIDs.prefix(pageSize))
                    }
                    book.state.transactions = try read(namespace, ids: recentIDs, prefix: "transaction")
                } else {
                    // Inactive books: do not hydrate transactions at startup (empty array)
                    book.state.transactions = []
                }
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

    func materializeFullBook(id: UUID) throws -> LedgerBook {
        let namespace = id.uuidString
        let header: Header = try read(namespace, "header")
        var book = header.book
        book.state.accounts = try read(namespace, ids: header.accountIDs, prefix: "account")
        book.state.transactions = try read(namespace, ids: header.transactionIDs, prefix: "transaction")
        book.state.recurringRules = try header.recurringIDs.map { try read(namespace, ids: $0, prefix: "recurring") }
        book.state.purchaseSessions = try header.purchaseIDs.map { try read(namespace, ids: $0, prefix: "purchase") }
        return book
    }

    func materializeFullLibrary() throws -> LedgerLibrary {
        guard let data = try database.data("library", "manifest") else { throw BackupError.invalidFormat }
        let manifest = try decoder.decode(Manifest.self, from: data)
        let books = try manifest.bookIDs.map { try materializeFullBook(id: $0) }
        return LedgerLibrary(schemaVersion: manifest.schemaVersion, activeBookID: manifest.activeBookID, books: books)
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
                try updateTransactions(book.state.transactions, previous: old?.state.transactions, namespace: namespace)
                try update(book.state.recurringRules ?? [], previous: old?.state.recurringRules, namespace: namespace, prefix: "recurring")
                try update(book.state.purchaseSessions ?? [], previous: old?.state.purchaseSessions, namespace: namespace, prefix: "purchase")

                var pocketBalances: [UUID: [String: Double]] = [:]
                for account in book.state.accounts {
                    var balances: [String: Double] = [:]
                    for pocket in account.normalizedPockets {
                        let sum = try database.accountPocketPostingsSum(
                            bookID: namespace,
                            accountID: account.id.uuidString,
                            currency: pocket.currency.rawValue
                        )
                        balances[pocket.currency.rawValue] = pocket.openingBalance + sum
                    }
                    pocketBalances[account.id] = balances
                }

                let allIDs = try database.allIndexedTransactionIDs(bookID: namespace).compactMap(UUID.init)
                let headerTxIDs = allIDs.isEmpty ? book.state.transactions.map(\.id) : allIDs
                try database.put(namespace, "header", encoder.encode(Header(book, allTransactionIDs: headerTxIDs, validatedBalances: pocketBalances)))
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

    private func updateTransactions(_ transactions: [LedgerTransaction], previous: [LedgerTransaction]?, namespace: String) throws {
        let old = Dictionary(uniqueKeysWithValues: (previous ?? []).map { ($0.id, $0) })
        let currentIDs = Set(transactions.map(\.id))
        for tx in transactions where old[tx.id] != tx {
            try database.put(namespace, "transaction-\(tx.id)", encoder.encode(tx))
            try database.indexTransaction(
                bookID: namespace,
                transactionID: tx.id.uuidString,
                occurredAt: tx.occurredAt.timeIntervalSince1970,
                accountID: tx.accountID.uuidString,
                destinationAccountID: tx.destinationAccountID?.uuidString,
                categoryID: tx.categoryID.rawValue,
                type: tx.type.rawValue,
                amount: tx.amount,
                currency: tx.currency.rawValue,
                accountCurrency: tx.accountCurrency?.rawValue,
                accountAmount: tx.accountAmount,
                destinationAmount: tx.destinationAmount,
                destinationCurrency: tx.destinationAccountCurrency?.rawValue,
                isDeleted: tx.deletedAt != nil,
                isReversal: tx.isReversal,
                parentID: tx.parentTransactionID?.uuidString,
                purchaseSessionID: tx.purchaseSessionID?.uuidString,
                version: tx.version,
                updatedAt: tx.updatedAt.timeIntervalSince1970
            )
        }
        if previous != nil {
            for id in Set(old.keys).subtracting(currentIDs) {
                try database.remove(namespace, "transaction-\(id)")
                try database.removeIndexedTransaction(bookID: namespace, transactionID: id.uuidString)
            }
        }
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

extension IncrementalLedgerRepository: LedgerTransactionRepository {
    func transaction(id: UUID, bookID: UUID) throws -> LedgerTransaction? {
        let key = "transaction-\(id)"
        guard let data = try database.data(bookID.uuidString, key) else { return nil }
        return try decoder.decode(LedgerTransaction.self, from: data)
    }

    func transactions(bookID: UUID, from: Date?, to: Date?, limit: Int?, offset: Int?) throws -> [LedgerTransaction] {
        try ensureIndexPopulated(for: bookID)
        let ids = try database.transactionIDs(bookID: bookID.uuidString, from: from, to: to, limit: limit, offset: offset)
        return try database.values(bookID.uuidString, keys: ids.map { "transaction-\($0)" }) {
            try decoder.decode(LedgerTransaction.self, from: $0)
        }
    }

    func recentTransactions(bookID: UUID, before: Date?, beforeID: UUID?, limit: Int) throws -> [LedgerTransaction] {
        try ensureIndexPopulated(for: bookID)
        let ids = try database.recentTransactionIDs(bookID: bookID.uuidString, before: before, beforeID: beforeID?.uuidString, limit: limit)
        return try database.values(bookID.uuidString, keys: ids.map { "transaction-\($0)" }) {
            try decoder.decode(LedgerTransaction.self, from: $0)
        }
    }

    func transactionCount(bookID: UUID) throws -> Int {
        try ensureIndexPopulated(for: bookID)
        return try database.transactionCount(bookID: bookID.uuidString)
    }

    func allTransactionIDs(bookID: UUID) throws -> [UUID] {
        try ensureIndexPopulated(for: bookID)
        let strings = try database.allIndexedTransactionIDs(bookID: bookID.uuidString)
        return strings.compactMap(UUID.init)
    }

    func pocketBalances(for account: LedgerAccount, bookID: UUID) throws -> [(currency: CurrencyCode, balance: Double)] {
        try ensureIndexPopulated(for: bookID)
        let pockets = account.normalizedPockets
        var result: [(currency: CurrencyCode, balance: Double)] = []
        for pocket in pockets {
            let sum = try database.accountPocketPostingsSum(
                bookID: bookID.uuidString,
                accountID: account.id.uuidString,
                currency: pocket.currency.rawValue
            )
            result.append((pocket.currency, pocket.openingBalance + sum))
        }
        return result
    }

    func accountBalance(for account: LedgerAccount, bookID: UUID, rates: [CurrencyCode: Double]) throws -> Double {
        if account.type == .stocks, let stock = account.stockMetadata { return stock.value }
        let balances = try pocketBalances(for: account, bookID: bookID)
        return balances.reduce(0) { total, pocket in
            total + LedgerCalculations.convert(pocket.balance, from: pocket.currency, to: account.currency, rates: rates)
        }
    }

    private func ensureIndexPopulated(for bookID: UUID) throws {
        let namespace = bookID.uuidString
        guard try !database.hasIndexedTransactions(bookID: namespace) else { return }
        guard let headerData = try database.data(namespace, "header") else { return }
        let header = try decoder.decode(Header.self, from: headerData)
        guard !header.transactionIDs.isEmpty else { return }
        let transactions: [LedgerTransaction] = try read(namespace, ids: header.transactionIDs, prefix: "transaction")
        for tx in transactions {
            try database.indexTransaction(
                bookID: namespace,
                transactionID: tx.id.uuidString,
                occurredAt: tx.occurredAt.timeIntervalSince1970,
                accountID: tx.accountID.uuidString,
                destinationAccountID: tx.destinationAccountID?.uuidString,
                categoryID: tx.categoryID.rawValue,
                type: tx.type.rawValue,
                amount: tx.amount,
                currency: tx.currency.rawValue,
                accountCurrency: tx.accountCurrency?.rawValue,
                accountAmount: tx.accountAmount,
                destinationAmount: tx.destinationAmount,
                destinationCurrency: tx.destinationAccountCurrency?.rawValue,
                isDeleted: tx.deletedAt != nil,
                isReversal: tx.isReversal,
                parentID: tx.parentTransactionID?.uuidString,
                purchaseSessionID: tx.purchaseSessionID?.uuidString,
                version: tx.version,
                updatedAt: tx.updatedAt.timeIntervalSince1970
            )
        }
    }
}
