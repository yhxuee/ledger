import Foundation
import CryptoKit

/// Canonical SQLite invariant:
/// - the manifest, each book header, entity blobs, transaction catalog, derived index and its
///   completeness certificate change in one SQLite transaction;
/// - `Header.transactionIDs` names the complete canonical transaction set for the book;
/// - the transaction index is derived and may be rebuilt, but is never trusted without a matching
///   count + ID digest certificate and an actual row-count check;
/// - `library.json` is a legacy import source, not a synchronized recovery replica.
struct IncrementalLedgerRepository: Sendable {
    let database: LedgerDiskDatabase
    private static let indexFormatVersion = 1
    private static let postingFormatVersion = 1
    private struct RateInput: Encodable {
        var currency: CurrencyCode
        var value: Double
    }
    private struct ProjectionAccountInput: Encodable {
        var id: UUID
        var currency: CurrencyCode
        var pockets: [CurrencyCode]
    }
    private struct ProjectionInputs: Encodable {
        var accounts: [ProjectionAccountInput]
        var rates: [RateInput]
    }
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

    /// Loads structural book metadata without decoding transaction payloads. A damaged derived
    /// index may still require a one-time rebuild that explicitly decodes canonical blobs.
    func loadMetadata() throws -> LedgerLibraryMetadata? {
        let metadata: LedgerLibraryMetadata? = try database.transaction(write: false) {
            guard let data = try database.data("library", "manifest") else {
                guard try !database.hasLedgerContent() else { throw PersistenceIntegrityError.missingManifest }
                return nil
            }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.schemaVersion <= BackupCodec.currentSchemaVersion else { throw BackupError.futureSchema(manifest.schemaVersion) }
            try requireUnique(manifest.bookIDs, label: "book")
            guard manifest.bookIDs.contains(manifest.activeBookID) else {
                throw PersistenceIntegrityError.identifierMismatch("active book")
            }
            let books = try manifest.bookIDs.map { id -> LedgerBookMetadata in
                let namespace = id.uuidString
                let header: Header = try read(namespace, "header")
                guard header.book.id == id else { throw PersistenceIntegrityError.identifierMismatch("book") }
                try validateCatalog(header, namespace: namespace)
                let book = header.book
                return LedgerBookMetadata(
                    id: id,
                    name: book.name,
                    createdAt: book.createdAt,
                    updatedAt: book.updatedAt,
                    storageKind: book.effectiveStorageKind,
                    cloudZoneName: book.cloudZoneName,
                    cloudZoneOwnerName: book.cloudZoneOwnerName,
                    isEncrypted: book.isEncrypted == true,
                    encryptionVersion: book.encryptionVersion,
                    keyFingerprint: book.keyFingerprint,
                    encryptionState: book.effectiveEncryptionState,
                    encryptionUpdatedAt: book.encryptionUpdatedAt,
                    accounts: try readIdentified(namespace, ids: header.accountIDs, prefix: "account", label: "account"),
                    categories: book.state.categories,
                    settings: book.state.settings,
                    recurringRules: try readIdentified(namespace, ids: header.recurringIDs ?? [], prefix: "recurring", label: "recurring rule"),
                    purchaseSessions: try readIdentified(namespace, ids: header.purchaseIDs ?? [], prefix: "purchase", label: "purchase session"),
                    transactionCatalog: try LedgerTransactionCatalog(bookID: id, ids: header.transactionIDs)
                )
            }
            return LedgerLibraryMetadata(schemaVersion: manifest.schemaVersion, activeBookID: manifest.activeBookID, books: books)
        }
        if let metadata {
            for book in metadata.books { try ensureIndexPopulated(for: book.id) }
        }
        return metadata
    }

    func load() throws -> LedgerLibrary? {
        let started = Date.now
        var totalTxs = 0
        var totalBooks = 0
        var manifestDuration: TimeInterval = 0
        var headerDuration: TimeInterval = 0
        var transactionHydrationDuration: TimeInterval = 0
        var supportingHydrationDuration: TimeInterval = 0
        let library: LedgerLibrary? = try database.transaction(write: false) {
            let manifestStart = Date.now
            guard let data = try database.data("library", "manifest") else {
                guard try !database.hasLedgerContent() else { throw PersistenceIntegrityError.missingManifest }
                return nil
            }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.schemaVersion <= BackupCodec.currentSchemaVersion else { throw BackupError.futureSchema(manifest.schemaVersion) }
            try requireUnique(manifest.bookIDs, label: "book")
            guard manifest.bookIDs.contains(manifest.activeBookID) else {
                throw PersistenceIntegrityError.identifierMismatch("active book")
            }
            manifestDuration = Date.now.timeIntervalSince(manifestStart)
            let books = try manifest.bookIDs.map { id -> LedgerBook in
                let headerStart = Date.now
                let namespace = id.uuidString
                let header: Header = try read(namespace, "header")
                guard header.book.id == id else { throw PersistenceIntegrityError.identifierMismatch("book") }
                try validateCatalog(header, namespace: namespace)
                headerDuration += Date.now.timeIntervalSince(headerStart)
                var book = header.book
                let supportingStart = Date.now
                book.state.accounts = try readIdentified(namespace, ids: header.accountIDs, prefix: "account", label: "account")
                supportingHydrationDuration += Date.now.timeIntervalSince(supportingStart)
                let transactionsStart = Date.now
                book.state.transactions = try readIdentified(namespace, ids: header.transactionIDs, prefix: "transaction", label: "transaction")
                transactionHydrationDuration += Date.now.timeIntervalSince(transactionsStart)
                let trailingStart = Date.now
                book.state.recurringRules = try header.recurringIDs.map { try readIdentified(namespace, ids: $0, prefix: "recurring", label: "recurring rule") }
                book.state.purchaseSessions = try header.purchaseIDs.map { try readIdentified(namespace, ids: $0, prefix: "purchase", label: "purchase session") }
                supportingHydrationDuration += Date.now.timeIntervalSince(trailingStart)
                return book
            }
            totalBooks = books.count
            totalTxs = books.reduce(0) { $0 + $1.state.transactions.count }
            return LedgerLibrary(schemaVersion: manifest.schemaVersion, activeBookID: manifest.activeBookID, books: books)
        }
        if let library {
            let duration = Date.now.timeIntervalSince(started)
            LedgerDiagnostics.recordStartupPhase("manifest", duration: manifestDuration, books: totalBooks)
            LedgerDiagnostics.recordStartupPhase("headers-catalogs", duration: headerDuration, books: totalBooks)
            LedgerDiagnostics.recordStartupPhase("hydrate-transactions", duration: transactionHydrationDuration, books: totalBooks, transactions: totalTxs)
            LedgerDiagnostics.recordStartupPhase("hydrate-supporting-entities", duration: supportingHydrationDuration, books: totalBooks)
            LedgerDiagnostics.recordStartupPhase("load-library", duration: duration, books: totalBooks, transactions: totalTxs)
            LedgerDiagnostics.persistence.info("Loaded library books=\(library.books.count) transactions=\(totalTxs) elapsed=\(duration)")
        }
        return library
    }

    func materializeFullBook(id: UUID) throws -> LedgerBook {
        let namespace = id.uuidString
        let header: Header = try read(namespace, "header")
        guard header.book.id == id else { throw PersistenceIntegrityError.identifierMismatch("book") }
        try validateCatalog(header, namespace: namespace)
        var book = header.book
        book.state.accounts = try readIdentified(namespace, ids: header.accountIDs, prefix: "account", label: "account")
        book.state.transactions = try readIdentified(namespace, ids: header.transactionIDs, prefix: "transaction", label: "transaction")
        book.state.recurringRules = try header.recurringIDs.map { try readIdentified(namespace, ids: $0, prefix: "recurring", label: "recurring rule") }
        book.state.purchaseSessions = try header.purchaseIDs.map { try readIdentified(namespace, ids: $0, prefix: "purchase", label: "purchase session") }
        return book
    }

    func materializeFullLibrary() throws -> LedgerLibrary {
        guard let data = try database.data("library", "manifest") else { throw BackupError.invalidFormat }
        let manifest = try decoder.decode(Manifest.self, from: data)
        try requireUnique(manifest.bookIDs, label: "book")
        guard manifest.bookIDs.contains(manifest.activeBookID) else {
            throw PersistenceIntegrityError.identifierMismatch("active book")
        }
        let books = try manifest.bookIDs.map { try materializeFullBook(id: $0) }
        return LedgerLibrary(schemaVersion: manifest.schemaVersion, activeBookID: manifest.activeBookID, books: books)
    }

    /// Reads only book headers when CloudKit needs to restore migration barriers.
    /// Transaction payloads can dominate startup memory and are irrelevant to this decision.
    func cloudMigrationBlocks() throws -> [(zoneName: String, ownerName: String?)] {
        try database.transaction(write: false) {
            guard let data = try database.data("library", "manifest") else { return [] }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.schemaVersion <= BackupCodec.currentSchemaVersion else {
                throw BackupError.futureSchema(manifest.schemaVersion)
            }
            return try manifest.bookIDs.compactMap { id in
                let header: Header = try read(id.uuidString, "header")
                let book = header.book
                guard book.effectiveEncryptionState == .enabling || book.effectiveEncryptionState == .migrationFailed,
                      let zoneName = book.cloudZoneName else { return nil }
                return (zoneName: zoneName, ownerName: book.cloudZoneOwnerName)
            }
        }
    }

    private func read<T: Decodable>(_ namespace: String, ids: [UUID], prefix: String) throws -> [T] {
        try database.values(namespace, keys: ids.lazy.map { "\(prefix)-\($0)" }) {
            try decoder.decode(T.self, from: $0)
        }
    }

    private func readIdentified<T: Decodable & Identifiable>(
        _ namespace: String,
        ids: [UUID],
        prefix: String,
        label: String
    ) throws -> [T] where T.ID == UUID {
        try requireUnique(ids, label: label)
        let values: [T] = try read(namespace, ids: ids, prefix: prefix)
        guard zip(ids, values).allSatisfy({ pair in pair.0 == pair.1.id }) else {
            throw PersistenceIntegrityError.identifierMismatch(label)
        }
        return values
    }

    private func read<T: Decodable>(_ namespace: String, _ key: String) throws -> T {
        guard let data = try database.data(namespace, key) else { throw BackupError.invalidFormat }
        return try decoder.decode(T.self, from: data)
    }

    func save(_ library: LedgerLibrary, previous: LedgerLibrary?) throws {
        let start = Date.now
        try database.transaction {
            try requireUnique(library.books.map(\.id), label: "book")
            guard library.books.contains(where: { $0.id == library.activeBookID }) else {
                throw PersistenceIntegrityError.identifierMismatch("active book")
            }
            let oldBooks = try uniqueDictionary(previous?.books ?? [], label: "previous book")
            for book in library.books {
                try requireUnique(book.state.accounts.map(\.id), label: "account")
                try requireUnique(book.state.transactions.map(\.id), label: "transaction")
                try requireUnique((book.state.recurringRules ?? []).map(\.id), label: "recurring rule")
                try requireUnique((book.state.purchaseSessions ?? []).map(\.id), label: "purchase session")
                let old = oldBooks[book.id]
                guard book != old else { continue }
                let namespace = book.id.uuidString
                try update(book.state.accounts, previous: old?.state.accounts, namespace: namespace, prefix: "account")
                try updateTransactions(book.state.transactions, previous: old?.state.transactions,
                                       book: book, previousBook: old, namespace: namespace)
                try update(book.state.recurringRules ?? [], previous: old?.state.recurringRules, namespace: namespace, prefix: "recurring")
                try update(book.state.purchaseSessions ?? [], previous: old?.state.purchaseSessions, namespace: namespace, prefix: "purchase")

                try database.put(namespace, "header", encoder.encode(Header(book, allTransactionIDs: book.state.transactions.map(\.id))))
            }
            let manifest = Manifest(schemaVersion: library.schemaVersion, activeBookID: library.activeBookID, bookIDs: library.books.map(\.id))
            if let oldData = try database.data("library", "manifest") {
                let old = try decoder.decode(Manifest.self, from: oldData)
                try requireUnique(old.bookIDs, label: "stored book")
                for id in Set(old.bookIDs).subtracting(manifest.bookIDs) {
                    for key in try database.keys(id.uuidString) { try database.remove(id.uuidString, key) }
                    try database.removeAllIndexedTransactions(bookID: id.uuidString)
                    try database.removeTransactionIndexState(bookID: id.uuidString)
                    try database.removeAllPostings(bookID: id.uuidString)
                    try database.removePostingIndexState(bookID: id.uuidString)
                }
            }
            try database.put("library", "manifest", encoder.encode(manifest))
        }
        LedgerDiagnostics.persistence.info("Saved library books=\(library.books.count) elapsed=\(Date.now.timeIntervalSince(start))")
    }

    private func updateTransactions(_ transactions: [LedgerTransaction], previous: [LedgerTransaction]?,
                                    book: LedgerBook, previousBook: LedgerBook?, namespace: String) throws {
        let old = try uniqueDictionary(previous ?? [], label: "previous transaction")
        try requireUnique(transactions.map(\.id), label: "transaction")
        let previousIDs = (previous ?? []).map(\.id)
        let accountsByID = try uniqueDictionary(book.state.accounts, label: "account")
        let rates = book.state.settings.rates
        let inputDigest = try projectionInputDigest(accounts: book.state.accounts, rates: rates)
        let canUpdateProjection: Bool
        if let previousBook, previous != nil,
           try projectionInputDigest(accounts: previousBook.state.accounts,
                                     rates: previousBook.state.settings.rates) == inputDigest {
            canUpdateProjection = try postingIndexIsComplete(
                namespace: namespace, ids: previousIDs, inputDigest: inputDigest
            )
        } else {
            canUpdateProjection = false
        }
        let previousCertificate = LedgerDiskDatabase.TransactionIndexState(
            transactionCount: previousIDs.count,
            idDigest: Self.idDigest(previousIDs),
            formatVersion: Self.indexFormatVersion
        )
        let previousIndexWasComplete: Bool
        if previous != nil {
            let storedCertificate = try database.transactionIndexState(bookID: namespace)
            let storedCount = try database.transactionCount(bookID: namespace, includeDeleted: true)
            let storedIDs = try database.allIndexedTransactionIDs(bookID: namespace).compactMap(UUID.init(uuidString:))
            previousIndexWasComplete = storedCertificate == previousCertificate
                && storedCount == previousIDs.count
                && storedIDs.count == storedCount
                && Self.idDigest(storedIDs) == previousCertificate.idDigest
        } else {
            previousIndexWasComplete = false
        }
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
            if canUpdateProjection {
                try database.replacePostings(bookID: namespace, transactionID: tx.id.uuidString,
                    postings: LedgerPostingProjection.postings(for: tx, accountsByID: accountsByID, rates: rates))
            }
        }
        if previous != nil {
            for id in Set(old.keys).subtracting(currentIDs) {
                try database.remove(namespace, "transaction-\(id)")
                try database.removeIndexedTransaction(bookID: namespace, transactionID: id.uuidString)
                if canUpdateProjection { try database.removePostings(bookID: namespace, transactionID: id.uuidString) }
            }
        } else {
            let expectedKeys = Set(currentIDs.map { "transaction-\($0)" })
            for key in try database.keys(namespace, prefix: "transaction-") where !expectedKeys.contains(key) {
                try database.remove(namespace, key)
            }
            for indexedID in try database.allIndexedTransactionIDs(bookID: namespace) {
                guard let id = UUID(uuidString: indexedID), currentIDs.contains(id) else {
                    try database.removeIndexedTransaction(bookID: namespace, transactionID: indexedID)
                    continue
                }
            }
        }
        if previous != nil, !previousIndexWasComplete {
            // Never publish a new certificate on top of an inherited partial/uncertified index.
            // The enclosing save transaction makes the rebuild and certificate atomic.
            try database.removeAllIndexedTransactions(bookID: namespace)
            for transaction in transactions { try index(transaction, namespace: namespace) }
        }
        if !canUpdateProjection {
            try database.removeAllPostings(bookID: namespace)
            for tx in transactions {
                try database.replacePostings(bookID: namespace, transactionID: tx.id.uuidString,
                    postings: LedgerPostingProjection.postings(for: tx, accountsByID: accountsByID, rates: rates))
            }
        }
        try certifyPostings(namespace: namespace, ids: transactions.map(\.id), inputDigest: inputDigest)
        try database.setTransactionIndexState(
            bookID: namespace,
            transactionCount: transactions.count,
            idDigest: Self.idDigest(transactions.map(\.id)),
            formatVersion: Self.indexFormatVersion
        )
    }

    /// Atomically applies named changes against the durable catalog. In particular, an ID absent
    /// from `upserts` is left untouched even if no UI page currently contains that record.
    func applyTransactionDelta(_ delta: LedgerTransactionDelta, bookID: UUID) throws {
        guard !delta.upserts.isEmpty || !delta.removedIDs.isEmpty else { return }
        try ensureIndexPopulated(for: bookID)
        try ensurePostingIndexPopulated(for: bookID)
        let namespace = bookID.uuidString
        try database.transaction {
            var header: Header = try read(namespace, "header")
            guard header.book.id == bookID else { throw PersistenceIntegrityError.identifierMismatch("book") }
            try validateCatalog(header, namespace: namespace)
            let accounts: [LedgerAccount] = try readIdentified(namespace, ids: header.accountIDs,
                                                                 prefix: "account", label: "account")
            let accountsByID = try uniqueDictionary(accounts, label: "account")
            let rates = header.book.state.settings.rates
            var known = Set(header.transactionIDs)
            guard delta.removedIDs.isSubset(of: known) else { throw PersistenceIntegrityError.identifierMismatch("removed transaction") }

            for id in delta.removedIDs {
                try database.remove(namespace, "transaction-\(id)")
                try database.removeIndexedTransaction(bookID: namespace, transactionID: id.uuidString)
                try database.removePostings(bookID: namespace, transactionID: id.uuidString)
                known.remove(id)
            }
            header.transactionIDs.removeAll { delta.removedIDs.contains($0) }

            for transaction in delta.upserts {
                if known.insert(transaction.id).inserted { header.transactionIDs.append(transaction.id) }
                try database.put(namespace, "transaction-\(transaction.id)", encoder.encode(transaction))
                try index(transaction, namespace: namespace)
                try database.replacePostings(bookID: namespace, transactionID: transaction.id.uuidString,
                    postings: LedgerPostingProjection.postings(for: transaction,
                                                                accountsByID: accountsByID, rates: rates))
            }
            header.validatedPocketBalances = nil
            header.book.updatedAt = .now
            try database.put(namespace, "header", encoder.encode(header))
            try database.setTransactionIndexState(
                bookID: namespace,
                transactionCount: header.transactionIDs.count,
                idDigest: Self.idDigest(header.transactionIDs),
                formatVersion: Self.indexFormatVersion
            )
            try certifyPostings(namespace: namespace, ids: header.transactionIDs,
                                inputDigest: projectionInputDigest(accounts: accounts, rates: rates))
        }
    }

    private func update<T: Codable & Equatable & Identifiable>(_ values: [T], previous: [T]?, namespace: String, prefix: String) throws where T.ID == UUID {
        let old = try uniqueDictionary(previous ?? [], label: prefix)
        try requireUnique(values.map(\.id), label: prefix)
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

    private func validateCatalog(_ header: Header, namespace: String) throws {
        try requireUnique(header.accountIDs, label: "account")
        try requireUnique(header.transactionIDs, label: "transaction")
        try requireUnique(header.recurringIDs ?? [], label: "recurring rule")
        try requireUnique(header.purchaseIDs ?? [], label: "purchase session")
        try validateCatalogIDs(header.accountIDs, namespace: namespace, prefix: "account")
        try validateCatalogIDs(header.transactionIDs, namespace: namespace, prefix: "transaction")
        try validateCatalogIDs(header.recurringIDs ?? [], namespace: namespace, prefix: "recurring")
        try validateCatalogIDs(header.purchaseIDs ?? [], namespace: namespace, prefix: "purchase")
    }

    private func validateCatalogIDs(_ ids: [UUID], namespace: String, prefix: String) throws {
        let expected = Set(ids.map { "\(prefix)-\($0)" })
        let stored = Set(try database.keys(namespace, prefix: prefix + "-"))
        guard expected == stored else {
            throw PersistenceIntegrityError.catalogMismatch(kind: prefix, expected: expected.count, stored: stored.count)
        }
    }

    private func requireUnique<ID: Hashable>(_ ids: [ID], label: String) throws {
        guard Set(ids).count == ids.count else { throw PersistenceIntegrityError.duplicateID(label) }
    }

    private func uniqueDictionary<T: Identifiable>(_ values: [T], label: String) throws -> [T.ID: T] where T.ID: Hashable {
        try requireUnique(values.map(\.id), label: label)
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func idDigest(_ ids: [UUID]) -> String {
        let canonical = ids.map(\.uuidString).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension IncrementalLedgerRepository: LedgerTransactionRepository {
    func transaction(id: UUID, bookID: UUID) throws -> LedgerTransaction? {
        let key = "transaction-\(id)"
        guard let data = try database.data(bookID.uuidString, key) else { return nil }
        let transaction = try decoder.decode(LedgerTransaction.self, from: data)
        guard transaction.id == id else { throw PersistenceIntegrityError.identifierMismatch("transaction") }
        return transaction
    }

    func transactions(bookID: UUID, from: Date?, to: Date?, limit: Int?, offset: Int?) throws -> [LedgerTransaction] {
        guard limit.map({ $0 >= 0 }) ?? true, offset.map({ $0 >= 0 }) ?? true else {
            throw PersistenceIntegrityError.invalidPagination
        }
        try ensureIndexPopulated(for: bookID)
        let ids = try database.transactionIDs(bookID: bookID.uuidString, from: from, to: to, limit: limit, offset: offset)
        return try readIndexedTransactions(ids, bookID: bookID)
    }

    func recentTransactions(bookID: UUID, before: Date?, beforeID: UUID?, limit: Int) throws -> [LedgerTransaction] {
        guard limit > 0, (before == nil) == (beforeID == nil) else {
            throw PersistenceIntegrityError.invalidPagination
        }
        try ensureIndexPopulated(for: bookID)
        let ids = try database.recentTransactionIDs(bookID: bookID.uuidString, before: before, beforeID: beforeID?.uuidString, limit: limit)
        return try readIndexedTransactions(ids, bookID: bookID)
    }

    private func readIndexedTransactions(_ ids: [String], bookID: UUID) throws -> [LedgerTransaction] {
        let values = try database.values(bookID.uuidString, keys: ids.map { "transaction-\($0)" }) {
            try decoder.decode(LedgerTransaction.self, from: $0)
        }
        guard zip(ids, values).allSatisfy({ pair in UUID(uuidString: pair.0) == pair.1.id }) else {
            throw PersistenceIntegrityError.identifierMismatch("transaction")
        }
        return values
    }

    func transactionCount(bookID: UUID) throws -> Int {
        try ensureIndexPopulated(for: bookID)
        return try database.transactionCount(bookID: bookID.uuidString)
    }

    func allTransactionIDs(bookID: UUID) throws -> [UUID] {
        try transactionCatalog(bookID: bookID).ids
    }

    func transactionCatalog(bookID: UUID) throws -> LedgerTransactionCatalog {
        let header: Header = try read(bookID.uuidString, "header")
        guard header.book.id == bookID else { throw PersistenceIntegrityError.identifierMismatch("book") }
        try validateCatalog(header, namespace: bookID.uuidString)
        return try LedgerTransactionCatalog(bookID: bookID, ids: header.transactionIDs)
    }

    func transactionPage(bookID: UUID, after: LedgerTransactionCursor?, limit: Int) throws -> LedgerTransactionPage {
        guard (1...500).contains(limit) else { throw PersistenceIntegrityError.invalidPagination }
        let fetched = try recentTransactions(
            bookID: bookID,
            before: after?.occurredAt,
            beforeID: after?.id,
            limit: limit + 1
        )
        let hasMore = fetched.count > limit
        let transactions = hasMore ? Array(fetched.prefix(limit)) : fetched
        let nextCursor = hasMore ? transactions.last.map { LedgerTransactionCursor(occurredAt: $0.occurredAt, id: $0.id) } : nil
        return LedgerTransactionPage(bookID: bookID, transactions: transactions, nextCursor: nextCursor, hasMore: hasMore)
    }

    func transactionPage(bookID: UUID, filter: LedgerTransactionFilter,
                         after: LedgerTransactionCursor?, limit: Int) throws -> LedgerTransactionPage {
        guard (1...500).contains(limit) else { throw PersistenceIntegrityError.invalidPagination }
        try ensureIndexPopulated(for: bookID)
        let ids = try database.filteredRecentTransactionIDs(bookID: bookID.uuidString, filter: filter,
                                                            after: after, limit: limit + 1)
        let fetched = try readIndexedTransactions(ids, bookID: bookID)
        let hasMore = fetched.count > limit
        let transactions = hasMore ? Array(fetched.prefix(limit)) : fetched
        let nextCursor = hasMore ? transactions.last.map { LedgerTransactionCursor(occurredAt: $0.occurredAt, id: $0.id) } : nil
        return LedgerTransactionPage(bookID: bookID, transactions: transactions,
                                     nextCursor: nextCursor, hasMore: hasMore)
    }

    func pocketBalances(for account: LedgerAccount, bookID: UUID) throws -> [(currency: CurrencyCode, balance: Double)] {
        try ensureIndexPopulated(for: bookID)
        try ensurePostingIndexPopulated(for: bookID)
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

    func accountViews(bookID: UUID) throws -> [AccountViewModel] {
        try ensureIndexPopulated(for: bookID)
        try ensurePostingIndexPopulated(for: bookID)
        let namespace = bookID.uuidString
        let header: Header = try read(namespace, "header")
        guard header.book.id == bookID else { throw PersistenceIntegrityError.identifierMismatch("book") }
        let accounts: [LedgerAccount] = try readIdentified(namespace, ids: header.accountIDs,
                                                            prefix: "account", label: "account")
        let sums = try database.accountPocketPostingsSums(bookID: namespace)
        let rates = header.book.state.settings.rates
        return accounts.filter { $0.deletedAt == nil }.map { account in
            if account.type == .stocks, let stock = account.stockMetadata {
                return AccountViewModel(account: account, balance: stock.value)
            }
            let balance = account.normalizedPockets.reduce(0.0) { total, pocket in
                let pocketBalance = pocket.openingBalance
                    + (sums[account.id.uuidString]?[pocket.currency.rawValue] ?? 0)
                return total + LedgerCalculations.convert(pocketBalance, from: pocket.currency,
                                                          to: account.currency, rates: rates)
            }
            return AccountViewModel(account: account, balance: balance)
        }
    }

    private func ensureIndexPopulated(for bookID: UUID) throws {
        let namespace = bookID.uuidString
        guard let headerData = try database.data(namespace, "header") else { return }
        let header = try decoder.decode(Header.self, from: headerData)
        try requireUnique(header.transactionIDs, label: "transaction")
        let expected = LedgerDiskDatabase.TransactionIndexState(
            transactionCount: header.transactionIDs.count,
            idDigest: Self.idDigest(header.transactionIDs),
            formatVersion: Self.indexFormatVersion
        )
        let actualCount = try database.transactionCount(bookID: namespace, includeDeleted: true)
        let actualIDStrings = try database.allIndexedTransactionIDs(bookID: namespace)
        let actualIDs = actualIDStrings.compactMap(UUID.init(uuidString:))
        let actualIDsAreValid = actualIDs.count == actualIDStrings.count
            && Set(actualIDs).count == actualIDs.count
            && Self.idDigest(actualIDs) == expected.idDigest
        if try database.transactionIndexState(bookID: namespace) == expected,
           actualCount == expected.transactionCount,
           actualIDsAreValid { return }

        let rebuildStart = Date.now
        try database.transaction {
            try database.removeAllIndexedTransactions(bookID: namespace)
            let transactions: [LedgerTransaction] = try readIdentified(
                namespace,
                ids: header.transactionIDs,
                prefix: "transaction",
                label: "transaction"
            )
            for tx in transactions { try index(tx, namespace: namespace) }
            try database.setTransactionIndexState(
                bookID: namespace,
                transactionCount: expected.transactionCount,
                idDigest: expected.idDigest,
                formatVersion: expected.formatVersion
            )
        }
        LedgerDiagnostics.recordLazyMetrics(
            operation: "index-rebuild",
            duration: Date.now.timeIntervalSince(rebuildStart),
            count: expected.transactionCount
        )
    }

    private func projectionInputDigest(accounts: [LedgerAccount], rates: [CurrencyCode: Double]) throws -> String {
        let inputs = ProjectionInputs(
            accounts: accounts.map { ProjectionAccountInput(id: $0.id, currency: $0.currency,
                                                            pockets: $0.normalizedPockets.map(\.currency)) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            rates: rates.map { RateInput(currency: $0.key, value: $0.value) }
                .sorted { $0.currency.rawValue < $1.currency.rawValue }
        )
        return SHA256.hash(data: try encoder.encode(inputs)).map { String(format: "%02x", $0) }.joined()
    }

    private func postingIndexIsComplete(namespace: String, ids: [UUID], inputDigest: String) throws -> Bool {
        guard let state = try database.postingIndexState(bookID: namespace),
              state.transactionCount == ids.count,
              state.idDigest == Self.idDigest(ids),
              state.inputDigest == inputDigest,
              state.formatVersion == Self.postingFormatVersion else { return false }
        let actual = try database.postingIntegrity(bookID: namespace)
        return actual.count == state.postingCount && actual.digest == state.postingDigest
    }

    private func certifyPostings(namespace: String, ids: [UUID], inputDigest: String) throws {
        let integrity = try database.postingIntegrity(bookID: namespace)
        try database.setPostingIndexState(bookID: namespace, state: .init(
            transactionCount: ids.count,
            idDigest: Self.idDigest(ids),
            inputDigest: inputDigest,
            postingCount: integrity.count,
            postingDigest: integrity.digest,
            formatVersion: Self.postingFormatVersion
        ))
    }

    private func ensurePostingIndexPopulated(for bookID: UUID) throws {
        let namespace = bookID.uuidString
        let header: Header = try read(namespace, "header")
        guard header.book.id == bookID else { throw PersistenceIntegrityError.identifierMismatch("book") }
        try validateCatalog(header, namespace: namespace)
        let accounts: [LedgerAccount] = try readIdentified(namespace, ids: header.accountIDs,
                                                            prefix: "account", label: "account")
        let rates = header.book.state.settings.rates
        let inputDigest = try projectionInputDigest(accounts: accounts, rates: rates)
        if try postingIndexIsComplete(namespace: namespace, ids: header.transactionIDs, inputDigest: inputDigest) { return }
        let started = Date.now
        try database.transaction {
            let accountsByID = try uniqueDictionary(accounts, label: "account")
            try database.removeAllPostings(bookID: namespace)
            let transactions: [LedgerTransaction] = try readIdentified(
                namespace, ids: header.transactionIDs, prefix: "transaction", label: "transaction"
            )
            for transaction in transactions {
                try database.replacePostings(bookID: namespace, transactionID: transaction.id.uuidString,
                    postings: LedgerPostingProjection.postings(for: transaction,
                                                                accountsByID: accountsByID, rates: rates))
            }
            try certifyPostings(namespace: namespace, ids: header.transactionIDs, inputDigest: inputDigest)
        }
        LedgerDiagnostics.recordLazyMetrics(operation: "posting-index-rebuild",
                                            duration: Date.now.timeIntervalSince(started),
                                            count: header.transactionIDs.count)
    }

    private func index(_ tx: LedgerTransaction, namespace: String) throws {
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

enum PersistenceIntegrityError: LocalizedError, Equatable {
    case duplicateID(String)
    case identifierMismatch(String)
    case catalogMismatch(kind: String, expected: Int, stored: Int)
    case invalidPagination
    case missingManifest
    case conflictingTransactionDelta

    var errorDescription: String? {
        switch self {
        case .duplicateID(let label): return "Local storage contains a duplicate \(label) ID."
        case .identifierMismatch(let label): return "Local storage contains a mismatched \(label) record."
        case .catalogMismatch(let kind, let expected, let stored):
            return "Local \(kind) storage is incomplete (catalog \(expected), records \(stored))."
        case .invalidPagination: return "The transaction page request is invalid."
        case .missingManifest: return "Local storage contains ledger data but its library manifest is missing."
        case .conflictingTransactionDelta: return "A transaction cannot be updated and removed in the same save."
        }
    }
}
