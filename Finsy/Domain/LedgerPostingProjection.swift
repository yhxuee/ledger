import Foundation

/// A derived account-side posting. Canonical transaction blobs remain the source of truth.
struct LedgerPosting: Equatable, Sendable {
    let transactionID: UUID
    let accountID: UUID
    let currency: CurrencyCode
    let amount: Double
    let effectiveAt: Date
}

enum LedgerPostingProjection {
    /// Uses the same posting, pocket, and FX rules as LedgerCalculations. `effectiveAt` retains
    /// installment/settlement timing without consulting the wall clock while building the index.
    static func postings(
        for transaction: LedgerTransaction,
        accountsByID: [UUID: LedgerAccount],
        rates: [CurrencyCode: Double]
    ) -> [LedgerPosting] {
        guard let effectiveAt = TransactionSemantics.postingStartsAt(transaction) else { return [] }
        var result: [LedgerPosting] = []

        if let source = accountsByID[transaction.accountID] {
            let currency = LedgerCalculations.sourcePocket(transaction, for: source)
            if source.normalizedPockets.contains(where: { $0.currency == currency }) {
                let value = LedgerCalculations.sourcePosting(transaction, for: source, rates: rates)
                result.append(LedgerPosting(
                    transactionID: transaction.id,
                    accountID: source.id,
                    currency: currency,
                    amount: transaction.type == .income ? value : -value,
                    effectiveAt: effectiveAt
                ))
            }
        }

        if transaction.type == .transfer,
           let destinationID = transaction.destinationAccountID,
           let destination = accountsByID[destinationID] {
            let currency = LedgerCalculations.destinationPocket(transaction, for: destination)
            if destination.normalizedPockets.contains(where: { $0.currency == currency }) {
                result.append(LedgerPosting(
                    transactionID: transaction.id,
                    accountID: destination.id,
                    currency: currency,
                    amount: LedgerCalculations.destinationPosting(transaction, for: destination, rates: rates),
                    effectiveAt: effectiveAt
                ))
            }
        }
        return result
    }
}
