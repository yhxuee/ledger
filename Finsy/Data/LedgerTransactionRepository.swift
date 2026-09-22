import Foundation

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
    func transactionPage(bookID: UUID, after: LedgerTransactionCursor?, limit: Int) throws -> LedgerTransactionPage
    func allTransactionIDs(bookID: UUID) throws -> [UUID]
    func pocketBalances(for account: LedgerAccount, bookID: UUID) throws -> [(currency: CurrencyCode, balance: Double)]
    func accountBalance(for account: LedgerAccount, bookID: UUID, rates: [CurrencyCode: Double]) throws -> Double
}
