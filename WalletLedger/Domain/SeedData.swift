import Foundation

/// Production configuration and empty-state initialization.
/// Financial demo datasets are strictly separated into test fixtures (`DemoDataFactory`).
enum SeedData {
    static let localUserID = "local-user"
    static let rates: [CurrencyCode: Double] = [
        .HKD: 1, .USD: 7.8, .CNY: 1.08, .MYR: 1.67,
        .EUR: 9.22, .GBP: 10.61, .JPY: 0.052
    ]

    static let expenseCategories: [LedgerCategory] = [
        .init(id: .food, name: "Food", detail: "Meals & drinks", symbol: "fork.knife", colorHex: "F05E4F", kind: .expense),
        .init(id: .transport, name: "Transport", detail: "Travel & transit", symbol: "car.fill", colorHex: "36A7C9", kind: .expense),
        .init(id: .shopping, name: "Shopping", detail: "Retail & purchases", symbol: "bag.fill", colorHex: "F3A11F", kind: .expense),
        .init(id: .utilities, name: "Utilities", detail: "Bills & services", symbol: "lightbulb.fill", colorHex: "B54AC6", kind: .expense),
        .init(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F", kind: .expense)
    ]

    static let incomeCategories: [LedgerCategory] = [
        .init(id: .salary, name: "Salary", detail: "Wages & earnings", symbol: "banknote.fill", colorHex: "2E7D32", kind: .income),
        .init(id: .dividends, name: "Dividends", detail: "Stock & fund payouts", symbol: "chart.line.uptrend.xyaxis", colorHex: "1976D2", kind: .income),
        .init(id: .interest, name: "Interest", detail: "Savings & deposits", symbol: "percent", colorHex: "7B1FA2", kind: .income),
        .init(id: .bonus, name: "Bonus", detail: "Incentives & rewards", symbol: "gift.fill", colorHex: "F57C00", kind: .income),
        .init(id: .otherIncome, name: "Other Income", detail: "Miscellaneous incoming", symbol: "arrow.down.left.circle.fill", colorHex: "00897B", kind: .income)
    ]

    static var categories: [LedgerCategory] {
        expenseCategories + incomeCategories
    }

    /// Production empty state with zero accounts and zero transactions,
    /// retaining built-in categories, default tax settings, base currency, and exchange rates.
    static func makeProductionEmpty() -> LedgerState {
        let now = Date()
        return LedgerState(
            schemaVersion: 2,
            accounts: [],
            transactions: [],
            categories: categories,
            settings: .init(userID: localUserID, baseCurrency: .HKD,
                            exchangeRates: .init(rates: rates, automatic: false, updatedAt: nil),
                            defaultExpenseAccountByCategory: [:], budgetPlan: .empty(now: now),
                            backupReminders: true, lastBackupAt: nil, updatedAt: now)
        )
    }

    /// Alias for production empty state.
    static func makeEmpty() -> LedgerState {
        makeProductionEmpty()
    }
}
