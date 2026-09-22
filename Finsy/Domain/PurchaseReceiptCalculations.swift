import Foundation

enum PurchaseReceiptCalculations {
    /// Computes the historical tax sum for items linked to recorded transactions.
    /// Returns `nil` if no linked transactions or session transactions are found.
    static func historicalTax(for session: PurchaseSession, in transactions: [LedgerTransaction]) -> Double? {
        let txByID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sum: Double = 0
        var foundAny = false
        for item in session.items {
            if let linkedID = item.linkedTransactionID, let tx = txByID[linkedID], let tax = tx.taxAmount {
                sum += tax
                foundAny = true
            }
        }
        if foundAny {
            return sum
        }
        let sessionTxs = transactions.filter { $0.purchaseSessionID == session.id && $0.deletedAt == nil }
        if !sessionTxs.isEmpty {
            return sessionTxs.reduce(0) { $0 + ($1.taxAmount ?? 0) }
        }
        return nil
    }

    /// Computes preview/estimated tax for items based on configured category tax rates.
    static func previewTax(for session: PurchaseSession, categories: [LedgerCategory], settings: LedgerSettings) -> Double {
        let catByID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sum: Double = 0
        for item in session.items {
            if let cat = catByID[item.categoryID] {
                let taxSnapshot = TaxCalculations.resolve(
                    entered: item.amount,
                    type: .expense,
                    rate: settings.taxRate(for: cat),
                    mode: .finalAmount,
                    exempt: false
                )
                sum += taxSnapshot?.tax ?? 0
            }
        }
        return sum
    }

    /// Resolves tax: uses historical tax for completed purchases with linked transactions,
    /// falling back to category-rate preview tax if historical tax records are not present.
    static func resolvedTax(for session: PurchaseSession, in state: LedgerState, isCompleted: Bool) -> Double {
        if isCompleted, let hist = historicalTax(for: session, in: state.transactions) {
            return hist
        }
        return previewTax(for: session, categories: state.categories, settings: state.settings)
    }
}
