import Foundation

enum SeedData {
    static let localUserID = "local-user"
    static let rates: [CurrencyCode: Double] = [
        .HKD: 1, .USD: 7.8, .CNY: 1.08, .MYR: 1.67,
        .EUR: 9.22, .GBP: 10.61, .JPY: 0.052
    ]

    static let categories: [LedgerCategory] = [
        .init(id: .food, name: "Food", detail: "Meals & drinks", symbol: "fork.knife", colorHex: "F05E4F"),
        .init(id: .transport, name: "Transport", detail: "Travel & transit", symbol: "car.fill", colorHex: "36A7C9"),
        .init(id: .shopping, name: "Shopping", detail: "Retail & purchases", symbol: "bag.fill", colorHex: "F3A11F"),
        .init(id: .utilities, name: "Utilities", detail: "Bills & services", symbol: "lightbulb.fill", colorHex: "B54AC6"),
        .init(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F")
    ]

    static func make() -> LedgerState {
        let now = Date()
        let calendar = Calendar.current
        let checking = LedgerAccount(id: UUID(), userID: localUserID, name: "Daily Checking", type: .checking, currency: .HKD, openingBalance: 12_741.40, budget: 6_500, includeInBudget: true, logo: "DC", cardStyle: .init(startHex: "F6C3D8", endHex: "F4CC67"), createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .synced)
        let savings = LedgerAccount(id: UUID(), userID: localUserID, name: "Emergency Savings", type: .savings, currency: .HKD, openingBalance: 30_000, budget: 0, includeInBudget: false, logo: "ES", cardStyle: .init(startHex: "86C5DA", endHex: "C6E7CF"), createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .synced)
        let card = LedgerAccount(id: UUID(), userID: localUserID, name: "Apple Card", type: .credit, currency: .USD, openingBalance: -3.33, budget: 1_200, includeInBudget: true, logo: "AC", cardStyle: .init(startHex: "D4B8F4", endHex: "F8A58C"), createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .synced)
        let investments = LedgerAccount(id: UUID(), userID: localUserID, name: "Investments", type: .investment, currency: .USD, openingBalance: 5_148.56, budget: 0, includeInBudget: false, logo: "INV", cardStyle: .init(startHex: "203E59", endHex: "6A7D89"), createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .synced)

        func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func expense(_ account: LedgerAccount, category: LedgerCategoryID, note: String, daysAgo: Int, currency: CurrencyCode, amount: Double, hour: Int) -> LedgerTransaction {
            let sourceAmount = amount * (rates[currency] ?? 1) / (rates[account.currency] ?? 1)
            let occurredAt = date(daysAgo: daysAgo, hour: hour, minute: 0)
            return .init(id: UUID(), userID: localUserID, type: .expense, accountID: account.id, destinationAccountID: nil, amount: amount, currency: currency, accountAmount: sourceAmount, destinationAmount: nil, categoryID: category, occurredAt: occurredAt, note: note, exchangeRateAtTransaction: rates[currency] ?? 1, createdAt: occurredAt, updatedAt: occurredAt, deletedAt: nil, version: 1, syncStatus: .synced)
        }
        let transactions = [
            expense(checking, category: .food, note: "Chocolicious — Gurney 2", daysAgo: 0, currency: .MYR, amount: 111, hour: 17),
            expense(checking, category: .transport, note: "Rapid Penang", daysAgo: 0, currency: .MYR, amount: 20, hour: 16),
            expense(card, category: .shopping, note: "Decathlon", daysAgo: 0, currency: .MYR, amount: 98, hour: 15),
            expense(checking, category: .shopping, note: "Lotus's", daysAgo: 1, currency: .MYR, amount: 44.8, hour: 17),
            expense(checking, category: .utilities, note: "Mobile plan", daysAgo: 1, currency: .MYR, amount: 30, hour: 9),
            expense(checking, category: .food, note: "Wufoo Sdn Bhd", daysAgo: 2, currency: .MYR, amount: 45.7, hour: 15),
            expense(checking, category: .transport, note: "MTR", daysAgo: 2, currency: .HKD, amount: 12.4, hour: 13),
            expense(card, category: .other, note: "Coffee subscription", daysAgo: 3, currency: .HKD, amount: 32, hour: 9),
            expense(checking, category: .food, note: "Lunch", daysAgo: 6, currency: .HKD, amount: 58, hour: 12),
            expense(checking, category: .transport, note: "Taxi", daysAgo: 9, currency: .HKD, amount: 86, hour: 21),
            expense(investments, category: .shopping, note: "Household", daysAgo: 13, currency: .HKD, amount: 123, hour: 14)
        ]
        let budgetPlan = BudgetPlan(mode: .account, categoryAllocations: [:], accountAllocations: [checking.id: checking.budget, card.id: card.budget], updatedAt: now)
        return LedgerState(schemaVersion: 2, accounts: [checking, savings, card, investments], transactions: transactions, categories: categories, settings: .init(userID: localUserID, baseCurrency: .HKD, exchangeRates: .init(rates: rates, automatic: false, updatedAt: nil), defaultExpenseAccountByCategory: [:], budgetPlan: budgetPlan, backupReminders: true, lastBackupAt: nil, updatedAt: now))
    }

    static func makeEmpty() -> LedgerState {
        let now = Date()
        let account = LedgerAccount(
            id: UUID(), userID: localUserID, name: "Main Account", type: .checking,
            currency: .HKD, openingBalance: 0, budget: 0, includeInBudget: true,
            logo: "MAIN", cardStyle: .init(startHex: "86C5DA", endHex: "C6E7CF"),
            createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        return LedgerState(
            schemaVersion: 2,
            accounts: [account],
            transactions: [],
            categories: categories,
            settings: .init(userID: localUserID, baseCurrency: .HKD, exchangeRates: .init(rates: rates, automatic: false, updatedAt: nil), defaultExpenseAccountByCategory: [:], budgetPlan: .empty(now: now), backupReminders: true, lastBackupAt: nil, updatedAt: now)
        )
    }
}
