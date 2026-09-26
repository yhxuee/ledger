import Foundation

/// Limits presentation only. Financial calculations, backup, sync and export use the full ledger.
struct LedgerListWindow: Sendable {
    static let maximumTransactions = 3_600
    static let maximumMonths = 12
    var transactions: [LedgerTransaction]
    var excludedByMonths: Int
    var excludedByCount: Int

    static func select(_ transactions: [LedgerTransaction], now: Date, calendar: Calendar = .current) -> Self {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let start = calendar.date(byAdding: .month, value: -maximumMonths, to: calendar.startOfDay(for: now)) ?? .distantPast
        var visible: [LedgerTransaction] = []
        visible.reserveCapacity(min(transactions.count, maximumTransactions))
        var excludedByMonths = 0
        var excludedByCount = 0
        // Callers provide the index's stable descending chronology.
        for transaction in transactions {
            if transaction.occurredAt < start || transaction.occurredAt >= end {
                excludedByMonths += 1
            } else if visible.count == maximumTransactions {
                excludedByCount += 1
            } else {
                visible.append(transaction)
            }
        }
        return Self(transactions: visible, excludedByMonths: excludedByMonths, excludedByCount: excludedByCount)
    }
}
