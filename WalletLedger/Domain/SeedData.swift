import Foundation

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

    /// Only initial demo creation/full reset uses this history. A supplied end date
    /// also makes previews and manual audits reproducible without touching persistence.
    static func make(now: Date = .now) -> LedgerState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startDate = calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!
        func account(_ index: Int, _ name: String, _ type: AccountType, _ currency: CurrencyCode,
                     _ opening: Double, _ budget: Double, _ tag: String, _ colors: (String, String)) -> LedgerAccount {
            LedgerAccount(id: demoID(index), userID: localUserID, name: name, type: type,
                          currency: currency, openingBalance: opening, budget: budget,
                          includeInBudget: budget > 0, logo: tag,
                          cardStyle: .init(startHex: colors.0, endHex: colors.1),
                          createdAt: startDate, updatedAt: startDate, deletedAt: nil, version: 1, syncStatus: .synced)
        }
        var checking = account(1, "HSBC Everyday", .checking, .HKD, 25_000, 7_500, "HSBC", ("D75A62", "F4C4AC"))
        checking.isMultiCurrency = true
        checking.currencyPockets = [
            .init(currency: .HKD, openingBalance: 25_000),
            .init(currency: .USD, openingBalance: 1_500),
            .init(currency: .CNY, openingBalance: 5_000),
            .init(currency: .EUR, openingBalance: 600),
            .init(currency: .JPY, openingBalance: 40_000)
        ]
        let savings = account(2, "Emergency Savings", .savings, .HKD, 30_000, 0, "SAVE", ("86C5DA", "C6E7CF"))
        let card = account(3, "Apple Card", .credit, .USD, -180, 800, "AC", ("D4B8F4", "F8A58C"))
        let mainland = account(4, "Mainland Wallet", .checking, .CNY, 6_000, 0, "CNY", ("E8BE67", "F2DEB0"))
        let cash = account(5, "Cash", .cash, .HKD, 3_000, 0, "CASH", ("99BE90", "D4E4B7"))
        let investments = account(6, "Investments", .investment, .USD, 5_200, 0, "INV", ("6C9EBB", "B3C5DB"))
        let accounts = [checking, savings, card, mainland, cash, investments]
        var transactions: [LedgerTransaction] = []

        func rounded(_ amount: Double) -> Double { (amount * 100).rounded() / 100 }
        func posting(_ amount: Double, _ currency: CurrencyCode, _ pocket: CurrencyCode) -> Double {
            rounded(LedgerCalculations.convert(amount, from: currency, to: pocket, rates: rates))
        }
        func append(_ id: Int, _ type: LedgerTransactionType, _ source: LedgerAccount,
                    _ category: LedgerCategoryID, _ note: String, _ date: Date,
                    _ currency: CurrencyCode, _ amount: Double,
                    destination: LedgerAccount? = nil, destinationPocket: CurrencyCode? = nil) {
            guard date >= startDate, date <= now else { return }
            let categoryValue = categories.first { $0.id == category }
            let demoSettings = LedgerSettings(userID: localUserID, baseCurrency: .HKD,
                                              exchangeRates: .init(rates: rates, automatic: false, updatedAt: nil),
                                              defaultExpenseAccountByCategory: [:], budgetPlan: .empty(now: now),
                                              backupReminders: true, lastBackupAt: nil, updatedAt: now)
            let mode: TaxInputMode = id.isMultiple(of: 2) ? .beforeTax : .finalAmount
            let tax = categoryValue.flatMap {
                TaxCalculations.resolve(entered: amount, type: type, rate: demoSettings.taxRate(for: $0),
                                        mode: mode, exempt: id.isMultiple(of: 17))
            }
            let finalAmount = rounded(tax?.finalAmount ?? amount)
            let sourceCurrency = source.defaultPocket(for: currency)
            let targetCurrency = destination.map { destinationPocket ?? $0.defaultPocket(for: currency) }
            var transaction = LedgerTransaction(
                id: demoID(id), userID: localUserID, type: type, accountID: source.id,
                destinationAccountID: destination?.id, amount: finalAmount, currency: currency,
                accountAmount: posting(finalAmount, currency, sourceCurrency),
                destinationAmount: targetCurrency.map { posting(finalAmount, currency, $0) },
                accountCurrency: sourceCurrency, destinationAccountCurrency: targetCurrency,
                categoryID: category, occurredAt: date, note: note,
                exchangeRateAtTransaction: rates[currency] ?? 1,
                createdAt: date, updatedAt: date, deletedAt: nil, version: 1, syncStatus: .synced)
            transaction.applyTax(tax)
            transactions.append(transaction)
        }
        // Account indexes refer to the stable declaration order above. Amounts stay
        // denominated in their original currencies; append handles pocket postings.
        let expenses: [DemoExpense] = [
            .init(1, 0, .food, .HKD, 68, 8, ["Cafe de Coral", "Breakfast cafe", "McDonald's"]),
            .init(3, 0, .transport, .HKD, 160, 9, ["Octopus top-up", "MTR journeys", "Rail ticket"]),
            .init(5, 2, .shopping, .USD, 55, 15, ["Amazon", "Uniqlo", "Books and stationery"]),
            .init(7, 0, .utilities, .HKD, 480, 10, ["Electricity bill", "Internet and mobile", "Home utilities"]),
            .init(9, 3, .food, .CNY, 65, 12, ["Shenzhen lunch", "Noodle restaurant", "Dim sum"]),
            .init(11, 0, .other, .HKD, 190, 18, ["Cinema", "Haircut", "Pharmacy"]),
            .init(13, 0, .food, .USD, 28, 19, ["Restaurant", "Dinner with friends", "Weekend brunch"]),
            .init(15, 0, .transport, .JPY, 950, 9, ["JR ticket", "Metro ticket", "Airport rail"]),
            .init(17, 0, .shopping, .CNY, 180, 16, ["Taobao", "Muji", "Household supplies"]),
            .init(19, 0, .food, .HKD, 310, 19, ["ParknShop", "Deliveroo dinner", "Family dinner"]),
            .init(21, 2, .utilities, .USD, 32, 10, ["Cloud storage and mobile", "Annual app installment", "Subscriptions"]),
            .init(23, 0, .other, .EUR, 24, 14, ["Museum tickets", "Exhibition", "Travel service"]),
            .init(24, 0, .food, .MYR, 48, 12, ["Penang lunch", "Food court", "Cafe lunch"]),
            .init(26, 4, .transport, .HKD, 85, 20, ["Taxi", "Minibus and taxi", "Evening transport"]),
            .init(27, 0, .shopping, .HKD, 620, 15, ["Uniqlo", "Home electronics", "Department store"]),
            .init(28, 0, .other, .HKD, 260, 17, ["Dental check-up", "Gym membership", "Travel insurance"])
        ]
        let seasonal = [0.94, 1.12, 0.88, 1.03, 1.27, 0.91, 1.06, 1.22, 0.85, 1.08, 1.31, 0.96]
        var month = startDate
        var monthIndex = 0
        while month <= now {
            func date(_ day: Int, _ hour: Int = 12) -> Date {
                let dayStart = calendar.date(byAdding: .day, value: day - 1, to: month)!
                return calendar.date(bySettingHour: hour, minute: (monthIndex * 7 + day * 3) % 60, second: 0, of: dayStart)!
            }
            let baseID = 1_000 + monthIndex * 100
            for (index, expense) in expenses.enumerated() {
                let variation = seasonal[monthIndex % seasonal.count] * (0.94 + Double((monthIndex * 3 + index * 7) % 13) / 100)
                append(baseID + index, .expense, accounts[expense.account], expense.category,
                       expense.notes[monthIndex % expense.notes.count], date(expense.day, expense.hour),
                       expense.currency, rounded(expense.amount * variation))
            }
            if monthIndex % 3 == 1 {
                let notes = ["Flight to visit family", "Hotel weekend", "Laptop accessories"]
                append(baseID + 20, .expense, checking, .shopping, notes[(monthIndex / 3) % 3], date(18, 15), .HKD, 1_650 + Double(monthIndex % 4) * 250)
            }
            append(baseID + 30, .income, checking, .salary, "Monthly salary", date(25, 10), .HKD, 22_000 + Double(monthIndex % 3) * 500)
            append(baseID + 31, .income, savings, .interest, "Savings interest", date(28, 9), .HKD, 24 + Double(monthIndex % 7) * 3)
            append(baseID + 32, .income, investments, .interest, "USD cash interest", date(28, 9), .USD, 2 + Double(monthIndex % 4))
            if monthIndex % 2 == 0 {
                append(baseID + 33, .income, investments, .dividends, "Index fund distribution", date(16, 11), .USD, 35 + Double(monthIndex % 5) * 12)
            }
            if monthIndex % 3 == 0 {
                let notes = ["Travel reimbursement", "Sold used books", "Cashback credit"]
                append(baseID + 34, .income, mainland, .otherIncome, notes[(monthIndex / 3) % 3], date(12, 14), .CNY, 300)
            }
            let monthNumber = calendar.component(.month, from: month)
            if monthNumber == 12 || monthNumber == 6 {
                append(baseID + 35, .income, checking, .bonus, monthNumber == 12 ? "Year-end bonus" : "Project bonus", date(20, 11), .HKD, monthNumber == 12 ? 12_000 : 6_000)
            }
            append(baseID + 40, .transfer, checking, .other, "Monthly savings", date(26, 10), .HKD, 8_000, destination: savings)
            // Pay only actual outstanding postings already incurred by the payment date.
            let paymentDate = date(28, 18)
            let liability = transactions.filter { $0.accountID == card.id && $0.type == .expense && $0.occurredAt <= paymentDate }
                .reduce(-card.openingBalance) { $0 + ($1.accountAmount ?? 0) }
            let paid = transactions.filter { $0.destinationAccountID == card.id && $0.type == .transfer }
                .reduce(0.0) { $0 + ($1.destinationAmount ?? 0) }
            if liability > paid {
                append(baseID + 42, .transfer, checking, .other, "Apple Card payment", paymentDate, .HKD,
                       posting(liability - paid, .USD, .HKD), destination: card)
            }
            // A rotating third transfer funds travel pockets, investments or cash.
            // Keep each month to at most three transfers, without intra-account transfers.
            let funding: [(account: Int, currency: CurrencyCode, amount: Double, note: String)] = [
                (0, .USD, 900, "USD travel pocket funding"),
                (4, .HKD, 600, "Cash withdrawal"),
                (5, .USD, 300, "Investment contribution"),
                (0, .CNY, 1_200, "CNY travel pocket funding"),
                (0, .EUR, 400, "EUR travel pocket funding"),
                (5, .USD, 300, "Investment contribution"),
                (0, .USD, 900, "USD travel pocket funding"),
                (4, .HKD, 600, "Cash withdrawal"),
                (5, .USD, 300, "Investment contribution"),
                (0, .JPY, 20_000, "JPY travel pocket funding"),
                (0, .CNY, 1_200, "CNY travel pocket funding"),
                (5, .USD, 300, "Investment contribution")
            ]
            let fundingPlan = funding[monthIndex % funding.count]
            append(baseID + 43, .transfer, fundingPlan.account == 0 ? savings : checking, .other,
                   fundingPlan.note, date(4, 10), .HKD,
                   posting(fundingPlan.amount, fundingPlan.currency, .HKD),
                   destination: accounts[fundingPlan.account], destinationPocket: fundingPlan.currency)
            month = calendar.date(byAdding: .month, value: 1, to: month)!
            monthIndex += 1
        }
        // Eight extra small expenses over the latest seven days keep the default
        // weekly pie useful. Include today's entries even when opened before lunch.
        for index in 0..<8 {
            let expense = expenses[index]
            let day = calendar.date(byAdding: .day, value: -(index % 7), to: calendar.startOfDay(for: now))!
            let scheduled = calendar.date(bySettingHour: expense.hour, minute: 15 + index, second: 0, of: day)!
            let occurredAt = min(scheduled, now)
            let dayIndex = calendar.dateComponents([.day], from: startDate, to: day).day ?? 0
            append(10_000_000 + dayIndex * 10 + index, .expense, accounts[expense.account], expense.category,
                   expense.notes[(index + 1) % expense.notes.count], occurredAt, expense.currency, rounded(expense.amount * 0.45))
        }
        transactions.sort {
            $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt > $1.occurredAt
        }
        let budgetPlan = BudgetPlan(mode: .account, categoryAllocations: [:],
                                    accountAllocations: [checking.id: checking.budget, card.id: card.budget], updatedAt: now)
        return LedgerState(schemaVersion: 2, accounts: accounts, transactions: transactions, categories: categories,
                           settings: .init(userID: localUserID, baseCurrency: .HKD,
                                           exchangeRates: .init(rates: rates, automatic: false, updatedAt: nil),
                                           defaultExpenseAccountByCategory: [:], budgetPlan: budgetPlan,
                                           backupReminders: true, lastBackupAt: nil, updatedAt: now))
    }

    private struct DemoExpense {
        let day: Int
        let account: Int
        let category: LedgerCategoryID
        let currency: CurrencyCode
        let amount: Double
        let hour: Int
        let notes: [String]

        init(_ day: Int, _ account: Int, _ category: LedgerCategoryID, _ currency: CurrencyCode,
             _ amount: Double, _ hour: Int, _ notes: [String]) {
            self.day = day; self.account = account; self.category = category
            self.currency = currency; self.amount = amount; self.hour = hour; self.notes = notes
        }
    }

    private static func demoID(_ index: Int) -> UUID {
        UUID(uuidString: "F1750000-0000-4000-8000-" + String(format: "%012llX", Int64(index)))!
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
