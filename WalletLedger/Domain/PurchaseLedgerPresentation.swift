import Foundation

enum PurchaseLedgerEntry: Identifiable, Hashable, Sendable {
    case transaction(LedgerTransaction)
    case purchase(PurchaseSession, [LedgerTransaction])

    var id: String {
        switch self {
        case .transaction(let transaction): "transaction-\(transaction.id.uuidString)"
        case .purchase(let session, _): "purchase-\(session.id.uuidString)"
        }
    }

    var occurredAt: Date {
        switch self {
        case .transaction(let transaction): transaction.occurredAt
        case .purchase(_, let transactions): transactions.map(\.occurredAt).max() ?? .distantPast
        }
    }
}

enum PurchaseLedgerPresentation {
    /// Show original purchase units; current base-currency settings do not redenominate a purchase.
    static func displayedTotal(_ transactions: [LedgerTransaction], session: PurchaseSession, rates: [CurrencyCode: Double]) -> Double {
        transactions.filter { $0.deletedAt == nil && !$0.isRefunded && !$0.isReversal }.reduce(0) { total, transaction in
            total + (transaction.currency == session.currency
                ? transaction.amount
                : LedgerCalculations.historical(transaction, to: session.currency, rates: rates))
        }
    }

    /// Aggregation is presentation-only. Calculations continue to consume the underlying transactions.
    static func entries(
        transactions: [LedgerTransaction],
        sessions: [PurchaseSession],
        collapsePurchases: Bool
    ) -> [PurchaseLedgerEntry] {
        guard collapsePurchases else {
            return transactions.filter { !$0.isReversal }.map(PurchaseLedgerEntry.transaction)
        }
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: transactions.compactMap { transaction -> LedgerTransaction? in
            guard transaction.purchaseSessionID != nil, !transaction.isReversal else { return nil }
            return transaction
        }) { $0.purchaseSessionID! }
        var emitted = Set<UUID>()
        var result: [PurchaseLedgerEntry] = []
        for transaction in transactions.sorted(by: { $0.occurredAt > $1.occurredAt }) {
            guard !transaction.isReversal else { continue }
            guard let sessionID = transaction.purchaseSessionID,
                  let session = sessionsByID[sessionID],
                  let children = grouped[sessionID] else {
                result.append(.transaction(transaction))
                continue
            }
            if emitted.insert(sessionID).inserted {
                result.append(.purchase(session, children.sorted { $0.occurredAt > $1.occurredAt }))
            }
        }
        return result.sorted { $0.occurredAt > $1.occurredAt }
    }
}
