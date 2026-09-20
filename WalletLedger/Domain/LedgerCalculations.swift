import Foundation

enum LedgerCalculations {
    static func activeAccounts(_ state: LedgerState) -> [LedgerAccount] { state.accounts.filter { $0.deletedAt == nil } }
    static func activeTransactions(_ state: LedgerState) -> [LedgerTransaction] { state.transactions.filter { $0.deletedAt == nil } }

    static func convert(_ amount: Double, from: CurrencyCode, to: CurrencyCode, rates: [CurrencyCode: Double]) -> Double {
        guard amount.isFinite else { return 0 }
        let fromRate = validRate(CurrencyRates.reference(from, in: rates))
        let toRate = validRate(CurrencyRates.reference(to, in: rates))
        let result = amount * fromRate / toRate
        return result.isFinite ? result : 0
    }

    static func historical(_ transaction: LedgerTransaction, to target: CurrencyCode, rates: [CurrencyCode: Double]) -> Double {
        guard transaction.amount.isFinite else { return 0 }
        let snapshotRate = validRate(transaction.exchangeRateAtTransaction)
        let result = transaction.amount * snapshotRate / validRate(CurrencyRates.reference(target, in: rates))
        return result.isFinite ? result : 0
    }

    static func convertHistorical(_ amount: Double, rate: Double, to target: CurrencyCode, rates: [CurrencyCode: Double]) -> Double {
        guard amount.isFinite else { return 0 }
        let snapshotRate = validRate(rate)
        let result = amount * snapshotRate / validRate(CurrencyRates.reference(target, in: rates))
        return result.isFinite ? result : 0
    }

    private static func validRate(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 1 }
        return value
    }

    static func transactionEffect(_ transaction: LedgerTransaction, in state: LedgerState, to target: CurrencyCode, type: LedgerTransactionType, now: Date = .now) -> Double? {
        switch type {
        case .expense:
            return TransactionSemantics.expenseEffect(transaction, in: state, to: target, now: now)
        case .income:
            return TransactionSemantics.incomeEffect(transaction, in: state, to: target, now: now)
        case .transfer:
            return nil
        }
    }

    static func expenseEffect(_ transaction: LedgerTransaction, in state: LedgerState, to target: CurrencyCode, now: Date = .now) -> Double? {
        TransactionSemantics.expenseEffect(transaction, in: state, to: target, now: now)
    }

    /// Pocket a source posting lands in. Single-currency accounts always use their primary currency.
    static func sourcePocket(_ transaction: LedgerTransaction, for account: LedgerAccount) -> CurrencyCode {
        guard account.usesCurrencyPockets else { return account.currency }
        return transaction.accountCurrency ?? account.currency
    }

    /// Pocket a destination posting lands in. Single-currency accounts always use their primary currency.
    static func destinationPocket(_ transaction: LedgerTransaction, for account: LedgerAccount) -> CurrencyCode {
        guard account.usesCurrencyPockets else { return account.currency }
        return transaction.destinationAccountCurrency ?? account.currency
    }

    /// Actual amount posted to the source account pocket, in that pocket's currency.
    /// `accountAmount` is authoritative; the FX estimate is only a fallback for legacy rows.
    static func sourcePosting(_ transaction: LedgerTransaction, for account: LedgerAccount, in state: LedgerState) -> Double {
        if let accountAmount = transaction.accountAmount, accountAmount.isFinite { return accountAmount }
        return convert(transaction.amount, from: transaction.currency, to: sourcePocket(transaction, for: account), rates: state.settings.rates)
    }

    /// Actual amount posted to the destination account pocket, in that pocket's currency.
    static func destinationPosting(_ transaction: LedgerTransaction, for account: LedgerAccount, in state: LedgerState) -> Double {
        if let destinationAmount = transaction.destinationAmount, destinationAmount.isFinite { return destinationAmount }
        return convert(transaction.amount, from: transaction.currency, to: destinationPocket(transaction, for: account), rates: state.settings.rates)
    }

    /// Balance of one pocket: its own opening balance plus only the postings routed to it.
    static func pocketBalance(_ currency: CurrencyCode, for account: LedgerAccount, in state: LedgerState) -> Double {
        let opening = account.normalizedPockets.first(where: { $0.currency == currency })?.openingBalance ?? 0
        return activeTransactions(state).reduce(opening) { balance, transaction in
            guard TransactionSemantics.posts(transaction) else { return balance }
            if transaction.accountID == account.id, sourcePocket(transaction, for: account) == currency {
                let posted = sourcePosting(transaction, for: account, in: state)
                switch transaction.type {
                case .expense, .transfer: return balance - posted
                case .income: return balance + posted
                }
            }
            if transaction.type == .transfer, transaction.destinationAccountID == account.id, destinationPocket(transaction, for: account) == currency {
                return balance + destinationPosting(transaction, for: account, in: state)
            }
            return balance
        }
    }

    /// Every pocket of an account, in declaration order.
    static func pocketBalances(for account: LedgerAccount, in state: LedgerState) -> [(currency: CurrencyCode, balance: Double)] {
        account.normalizedPockets.map { ($0.currency, pocketBalance($0.currency, for: account, in: state)) }
    }

    /// Account total: each pocket converted into the account's primary currency and summed.
    /// Single-currency accounts reduce to exactly their previous value.
    static func balance(for account: LedgerAccount, in state: LedgerState) -> Double {
        if account.type == .stocks, let stock = account.stockMetadata { return stock.value }
        return account.normalizedPockets.reduce(0) { total, pocket in
            total + convert(pocketBalance(pocket.currency, for: account, in: state), from: pocket.currency, to: account.currency, rates: state.settings.rates)
        }
    }

    /// Account-side expense effect, expressed in the account's primary currency.
    static func accountExpenseEffect(_ transaction: LedgerTransaction, for account: LedgerAccount, in state: LedgerState, now: Date = .now) -> Double? {
        guard transaction.accountID == account.id else { return nil }
        return TransactionSemantics.expenseEffect(transaction, in: state, to: account.currency, now: now)
    }

    static func accountViews(_ state: LedgerState) -> [AccountViewModel] {
        activeAccounts(state).map { .init(account: $0, balance: balance(for: $0, in: state)) }
    }

    static func portfolioAccounts(_ state: LedgerState) -> [LedgerAccount] {
        activeAccounts(state).filter { !$0.effectiveIsFrozen }
    }

    static func portfolioBalance(_ state: LedgerState, target: CurrencyCode? = nil) -> Double {
        let currency = target ?? state.settings.baseCurrency
        return accountViews(state)
            .filter { !$0.account.effectiveIsFrozen }
            .reduce(0) { $0 + convert($1.balance, from: $1.account.currency, to: currency, rates: state.settings.rates) }
    }

    static func portfolioSummary(_ state: LedgerState, target: CurrencyCode? = nil) -> (netWorth: Double, assets: Double, liabilities: Double) {
        let currency = target ?? state.settings.baseCurrency
        return accountViews(state)
            .filter { !$0.account.effectiveIsFrozen }
            .reduce(into: (netWorth: 0.0, assets: 0.0, liabilities: 0.0)) { result, item in
                let value = convert(item.balance, from: item.account.currency, to: currency, rates: state.settings.rates)
                result.netWorth += value
                if value >= 0 { result.assets += value }
                else { result.liabilities += abs(value) }
            }
    }

    static func budgetUsage(_ state: LedgerState, now: Date = .now) -> (budget: Double, spent: Double, ratio: Double) {
        let detail = budgetBreakdown(state, now: now)
        return (detail.budget, detail.spent, detail.ratio)
    }

    static func budgetBreakdown(_ state: LedgerState, now: Date = .now) -> BudgetBreakdown {
        let target = state.settings.baseCurrency
        let plan = state.settings.budgetPlan
        let calendar = Calendar.current
        let monthly = activeTransactions(state).filter { calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month) }
        let accountMap = Dictionary(uniqueKeysWithValues: activeAccounts(state).map { ($0.id, $0) })
        let lines: [BudgetBreakdownLine]
        switch plan.mode {
        case .category:
            let categoryMap = Dictionary(uniqueKeysWithValues: state.categories.map { ($0.id, $0) })
            lines = plan.categoryAllocations.filter { $0.value > 0 }.map { categoryID, allocation in
                let spent = monthly.reduce(0) { partial, transaction in
                    guard transaction.categoryID == categoryID, let value = expenseEffect(transaction, in: state, to: target, now: now) else { return partial }
                    return partial + value
                }
                return .init(id: "category:\(categoryID.rawValue)", title: categoryMap[categoryID]?.name ?? categoryID.rawValue, currency: target, budget: allocation, spent: spent)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .account:
            lines = plan.accountAllocations.compactMap { accountID, allocation in
                guard allocation > 0, let account = accountMap[accountID] else { return nil }
                let spent = monthly.reduce(0) { partial, transaction in
                    guard transaction.accountID == accountID, let value = accountExpenseEffect(transaction, for: account, in: state, now: now) else { return partial }
                    return partial + value
                }
                return .init(id: "account:\(accountID.uuidString)", title: account.name, currency: account.currency, budget: allocation, spent: spent)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        let budget = lines.reduce(0) { $0 + convert($1.budget, from: $1.currency, to: target, rates: state.settings.rates) }
        let spent = lines.reduce(0) { $0 + convert($1.spent, from: $1.currency, to: target, rates: state.settings.rates) }
        return .init(currency: target, budget: budget, spent: spent, lines: lines)
    }

    static func budgetUsage(_ state: LedgerState, account: LedgerAccount, now: Date = .now) -> (budget: Double, spent: Double, ratio: Double) {
        let plan = state.settings.budgetPlan
        let budget: Double
        let includedCategories: Set<LedgerCategoryID>?
        switch plan.mode {
        case .account:
            budget = plan.accountAllocations[account.id] ?? 0
            includedCategories = nil
        case .category:
            budget = convert(plan.categoryAllocations.values.reduce(0, +), from: state.settings.baseCurrency, to: account.currency, rates: state.settings.rates)
            includedCategories = Set(plan.categoryAllocations.filter { $0.value > 0 }.keys)
        }
        guard budget > 0 else { return (0, 0, 0) }
        let calendar = Calendar.current
        let spent = activeTransactions(state).reduce(0) { partial, transaction in
            guard transaction.accountID == account.id, (includedCategories == nil || includedCategories!.contains(transaction.categoryID)), calendar.isDate(transaction.occurredAt, equalTo: now, toGranularity: .month), let value = accountExpenseEffect(transaction, for: account, in: state, now: now) else { return partial }
            return partial + value
        }
        return (budget, spent, spent / budget)
    }

    static func transactions(_ state: LedgerState, accountID: UUID?) -> [LedgerTransaction] {
        activeTransactions(state).filter { accountID == nil || $0.accountID == accountID || $0.destinationAccountID == accountID }.sorted { $0.occurredAt > $1.occurredAt }
    }

    static func analytics(_ state: LedgerState, range: AnalyticsRange, type: LedgerTransactionType = .expense, categories: Set<LedgerCategoryID> = [], accountID: UUID? = nil, accountIDs: Set<UUID> = [], customRange: ClosedRange<Date>? = nil, now: Date = .now) -> AnalyticsSummary {
        let calendar = Calendar.current
        let target = state.settings.baseCurrency
        let startOfToday = calendar.startOfDay(for: now)
        var buckets: [AnalyticsBucket] = []
        var start = startOfToday
        var end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        var bucketMode: AnalyticsBucketMode = .day

        if let customRange {
            start = calendar.startOfDay(for: customRange.lowerBound)
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customRange.upperBound)) ?? customRange.upperBound
            let days = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 1))
            if days <= 14 {
                bucketMode = .day
                buckets = (0..<days).map { offset in
                    let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    return .init(id: dayKey(date), label: date.formatted(.dateTime.month(.defaultDigits).day()), value: 0)
                }
            } else if days <= 120 {
                bucketMode = .customWeek
                let count = (days + 6) / 7
                buckets = (0..<count).map { offset in
                    let date = calendar.date(byAdding: .day, value: offset * 7, to: start) ?? start
                    return .init(id: "C\(offset)", label: date.formatted(.dateTime.month(.defaultDigits).day()), value: 0)
                }
            } else {
                bucketMode = .month
                let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
                let lastMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: customRange.upperBound)) ?? customRange.upperBound
                let count = max(1, (calendar.dateComponents([.month], from: firstMonth, to: lastMonth).month ?? 0) + 1)
                buckets = (0..<count).map { offset in
                    let date = calendar.date(byAdding: .month, value: offset, to: firstMonth) ?? firstMonth
                    return .init(id: monthKey(date), label: date.formatted(.dateTime.month(.abbreviated).year(.twoDigits)), value: 0)
                }
            }
        } else {
            switch range {
            case .week:
                bucketMode = .day
                let weekday = calendar.component(.weekday, from: startOfToday)
                start = calendar.date(byAdding: .day, value: -(weekday - 1), to: startOfToday) ?? startOfToday
                buckets = (0..<7).map { offset in
                    let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    let label = date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
                    return .init(id: dayKey(date), label: label, value: 0)
                }
            case .month:
                bucketMode = .weekOfMonth
                start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
                buckets = (0..<4).map { .init(id: "\($0)", label: "W\($0 + 1)", value: 0) }
            case .sixMonths, .year:
                bucketMode = .month
                let count = range == .sixMonths ? 6 : 12
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
                start = calendar.date(byAdding: .month, value: -(count - 1), to: monthStart) ?? monthStart
                buckets = (0..<count).map { offset in
                    let date = calendar.date(byAdding: .month, value: offset, to: start) ?? start
                    return .init(id: monthKey(date), label: date.formatted(.dateTime.month(.abbreviated)), value: 0)
                }
            }
        }

        let relevantCategories = state.categories.filter { $0.kind == (type == .income ? .income : .expense) && !$0.id.isSystemLinked }
        var totals = Dictionary(uniqueKeysWithValues: relevantCategories.map { ($0.id, 0.0) })
        for transaction in activeTransactions(state) where transaction.occurredAt >= start && transaction.occurredAt < end && (accountID == nil || transaction.accountID == accountID) && (accountIDs.isEmpty || accountIDs.contains(transaction.accountID)) {
            guard categories.isEmpty || categories.contains(transaction.categoryID) else { continue }
            guard let value = transactionEffect(transaction, in: state, to: target, type: type, now: now) else { continue }
            let key: String
            switch bucketMode {
            case .day: key = dayKey(transaction.occurredAt)
            case .weekOfMonth: key = String(min(3, max(0, (calendar.component(.day, from: transaction.occurredAt) - 1) / 7)))
            case .month: key = monthKey(transaction.occurredAt)
            case .customWeek:
                let days = calendar.dateComponents([.day], from: start, to: transaction.occurredAt).day ?? 0
                key = "C\(max(0, days / 7))"
            }
            if let index = buckets.firstIndex(where: { $0.id == key }) { buckets[index].value += value }
            totals[transaction.categoryID, default: 0] += value
        }
        let values = buckets.map(\.value)
        let total = values.reduce(0, +)
        let subtitle: String
        if let customRange {
            subtitle = "\(customRange.lowerBound.formatted(date: .abbreviated, time: .omitted))–\(customRange.upperBound.formatted(date: .abbreviated, time: .omitted))"
        } else {
            switch range {
            case .week: subtitle = "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(now.formatted(.dateTime.month(.abbreviated).day().year()))"
            case .month: subtitle = now.formatted(.dateTime.month(.wide).year())
            case .sixMonths, .year: subtitle = "\(start.formatted(.dateTime.month(.abbreviated).year()))–\(now.formatted(.dateTime.month(.abbreviated).year()))"
            }
        }
        return .init(buckets: buckets, categoryTotals: totals, subtitle: subtitle, total: total, average: values.isEmpty ? 0 : total / Double(values.count), minimum: values.min() ?? 0, maximum: values.max() ?? 0)
    }

    private static func dayKey(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
    private static func monthKey(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", values.year ?? 0, values.month ?? 0)
    }

    private enum AnalyticsBucketMode { case day, weekOfMonth, month, customWeek }
}
