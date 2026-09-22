import Foundation

/// The complete durable ID catalog is separate from any decoded UI page. Its IDs include
/// tombstoned records; a record absent from a page remains present in this catalog.
struct LedgerTransactionCatalog: Sendable, Equatable {
    let bookID: UUID
    let ids: [UUID]
    private let knownIDs: Set<UUID>

    init(bookID: UUID, ids: [UUID]) throws {
        let knownIDs = Set(ids)
        guard knownIDs.count == ids.count else { throw PersistenceIntegrityError.duplicateID("transaction") }
        self.bookID = bookID
        self.ids = ids
        self.knownIDs = knownIDs
    }

    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { knownIDs.contains(id) }
}

struct LedgerTransactionCursor: Sendable, Equatable {
    let occurredAt: Date
    let id: UUID
}

/// A bounded query result. It is deliberately not a LedgerState or a saveable snapshot.
struct LedgerTransactionPage: Sendable {
    let bookID: UUID
    let transactions: [LedgerTransaction]
    let nextCursor: LedgerTransactionCursor?
    let hasMore: Bool
}

/// Persistence changes are named explicitly. A missing record in a page is never a removal.
/// Normal user deletion is an upsert of a tombstoned LedgerTransaction; removals are reserved
/// for explicit hard removal of a known canonical ID.
struct LedgerTransactionDelta: Sendable {
    let upserts: [LedgerTransaction]
    let removedIDs: Set<UUID>

    init(upserts: [LedgerTransaction] = [], removedIDs: Set<UUID> = []) throws {
        let upsertIDs = upserts.map(\.id)
        guard Set(upsertIDs).count == upsertIDs.count else { throw PersistenceIntegrityError.duplicateID("transaction delta") }
        guard Set(upsertIDs).isDisjoint(with: removedIDs) else { throw PersistenceIntegrityError.conflictingTransactionDelta }
        self.upserts = upserts
        self.removedIDs = removedIDs
    }
}

/// Nontransaction book data plus a complete ID catalog. This type cannot be used where a
/// fully materialized LedgerBook or LedgerState is required by calculations or CloudKit.
struct LedgerBookMetadata: Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let storageKind: LedgerStorageKind
    let cloudZoneName: String?
    let cloudZoneOwnerName: String?
    let encryptionState: LedgerEncryptionState
    let accounts: [LedgerAccount]
    let categories: [LedgerCategory]
    let settings: LedgerSettings
    let recurringRules: [RecurringRule]
    let purchaseSessions: [PurchaseSession]
    let transactionCatalog: LedgerTransactionCatalog
}

struct LedgerLibraryMetadata: Sendable {
    let schemaVersion: Int
    let activeBookID: UUID
    let books: [LedgerBookMetadata]
}

protocol LedgerTransactionRepository: Sendable {
    func transaction(id: UUID, bookID: UUID) throws -> LedgerTransaction?
    func transactions(
        bookID: UUID,
        from: Date?,
        to: Date?,
        limit: Int?,
        offset: Int?
    ) throws -> [LedgerTransaction]
    func recentTransactions(
        bookID: UUID,
        before: Date?,
        beforeID: UUID?,
        limit: Int
    ) throws -> [LedgerTransaction]
    func transactionCount(bookID: UUID) throws -> Int
    func transactionCatalog(bookID: UUID) throws -> LedgerTransactionCatalog
    func transactionPage(bookID: UUID, after: LedgerTransactionCursor?, limit: Int) throws -> LedgerTransactionPage
    func allTransactionIDs(bookID: UUID) throws -> [UUID]
    func pocketBalances(for account: LedgerAccount, bookID: UUID) throws -> [(currency: CurrencyCode, balance: Double)]
    func accountBalance(for account: LedgerAccount, bookID: UUID, rates: [CurrencyCode: Double]) throws -> Double
}
