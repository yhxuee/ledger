import Foundation

enum LedgerCalculations {
    static func activeAccounts(_ state: LedgerState) -> [LedgerAccount] { state.accounts.filter { $0.deletedAt == nil } }
    static func activeTransactions(_ state: LedgerState) -> [LedgerTransaction] { state.transactions.filter { $0.deletedAt == nil } }

    static func convert(_ amount: Double, from: CurrencyCode, to: CurrencyCode, rates: [CurrencyCode: Double]) -> Double {
        amount * (rates[from] ?? 1) / (rates[to] ?? 1)
    }

    static func historical(_ transaction: LedgerTransaction, to target: CurrencyCode, rates: [CurrencyCode: Double]) -> Double {
        transaction.amount * transaction.exchangeRateAtTransaction / (rates[target] ?? 1)
    }

    static func balance(for account: LedgerAccount, in state: LedgerState) -> Double {
        activeTransactions(state).reduce(account.openingBalance) { balance, transaction in
            guard transaction.accountID == account.id || transaction.destinationAccountID == account.id else { return balance }
            let sourceAmount = transaction.accountAmount ?? convert(transaction.amount, from: transaction.currency, to: account.currency, rates: state.settings.rates)
            switch transaction.type {
            case .expense where transaction.accountID == account.id: return balance - sourceAmount
            case .income where transaction.accountID == account.id: return balance + sourceAmount
            case .transfer where transaction.accountID == account.id: return balance - sourceAmount
            case .transfer where transaction.destinationAccountID == account.id:
                return balance + (transaction.destinationAmount ?? convert(transaction.amount, from: transaction.currency, to: account.currency, rates: state.settings.rates))
            default: return balance
            }
        }
    }

    static func accountViews(_ state: LedgerState) -> [AccountViewModel] {
        activeAccounts(state).map { .init(account: $0, balance: balance(for: $0, in: state)) }
    }

    static func portfolioBalance(_ state: LedgerState, target: CurrencyCode? = nil) -> Double {
        let currency = target ?? state.settings.baseCurrency
        return accountViews(state).reduce(0) { $0 + convert($1.balance, from: $1.account.currency, to: currency, rates: state.settings.rates) }
    }

    static func budgetUsage(_ state: LedgerState, now: Date = .now) -> (budget: Double, spent: Double, ratio: Double) {
        let target = state.settings.baseCurrency
        let accounts = activeAccounts(state).filter(\.includeInBudget)
        let accountIDs = Set(accounts.map(\.id))
        let budget = accounts.reduce(0) { $0 + convert($1.budget, from: $1.currency, to: target, rates: state.settings.rates) }
        let calendar = Calendar.current
        let spent = activeTransactions(state).filter {
            $0.type == .expense && accountIDs.contains($0.accountID) && calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month)
        }.reduce(0) { $0 + historical($1, to: target, rates: state.settings.rates) }
        return (budget, spent, budget > 0 ? spent / budget : 0)
    }

    static func budgetUsage(_ state: LedgerState, account: LedgerAccount, now: Date = .now) -> (budget: Double, spent: Double, ratio: Double) {
        guard account.includeInBudget else { return (0, 0, 0) }
        let calendar = Calendar.current
        let spent = activeTransactions(state).filter {
            $0.type == .expense && $0.accountID == account.id && calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month)
        }.reduce(0) { partial, transaction in
            partial + (transaction.accountAmount ?? convert(transaction.amount, from: transaction.currency, to: account.currency, rates: state.settings.rates))
        }
        return (account.budget, spent, account.budget > 0 ? spent / account.budget : 0)
    }

    static func transactions(_ state: LedgerState, accountID: UUID?) -> [LedgerTransaction] {
        activeTransactions(state).filter { accountID == nil || $0.accountID == accountID || $0.destinationAccountID == accountID }.sorted { $0.occurredAt > $1.occurredAt }
    }

    static func analytics(_ state: LedgerState, range: AnalyticsRange, categories: Set<LedgerCategoryID> = [], accountID: UUID? = nil, accountIDs: Set<UUID> = [], customRange: ClosedRange<Date>? = nil, now: Date = .now) -> AnalyticsSummary {
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
                let weekdayLabels = ["U", "M", "T", "W", "R", "F", "S"]
                buckets = (0..<7).map { offset in
                    let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    return .init(id: dayKey(date), label: weekdayLabels[offset], value: 0)
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

        var totals = Dictionary(uniqueKeysWithValues: state.categories.map { ($0.id, 0.0) })
        for transaction in activeTransactions(state) where transaction.type == .expense && transaction.occurredAt >= start && transaction.occurredAt < end && (accountID == nil || transaction.accountID == accountID) && (accountIDs.isEmpty || accountIDs.contains(transaction.accountID)) {
            guard categories.isEmpty || categories.contains(transaction.categoryID) else { continue }
            let value = historical(transaction, to: target, rates: state.settings.rates)
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
