import Foundation

enum ForecastRiskSeverity: String, Codable, CaseIterable, Sendable {
    case yellow
    case red
}

struct BudgetForecastRisk: Identifiable, Sendable {
    var id: String { lineID }
    var lineID: String
    var title: String
    var currency: CurrencyCode
    var budget: Double
    var actualSpent: Double
    var scheduledSpent: Double
    var flexibleSpent: Double
    var projectedSpend: Double
    var exceedance: Double
    var severity: ForecastRiskSeverity
}

struct CashFlowForecast: Sendable {
    var generatedAt: Date
    var historyStart: Date
    var historyEnd: Date
    var historyDays: Int
    var availableHistorySpan: Int
    var eligible: Bool

    var projectedExpenses: Double
    var projectedIncome: Double
    var projectedNetCashFlow: Double

    var budgetRisks: [BudgetForecastRisk]

    var highestSeverity: ForecastRiskSeverity? {
        if budgetRisks.contains(where: { $0.severity == .red }) {
            return .red
        }
        if budgetRisks.contains(where: { $0.severity == .yellow }) {
            return .yellow
        }
        return nil
    }

    static var empty: CashFlowForecast {
        .init(
            generatedAt: .now,
            historyStart: .now,
            historyEnd: .now,
            historyDays: 0,
            availableHistorySpan: 0,
            eligible: false,
            projectedExpenses: 0,
            projectedIncome: 0,
            projectedNetCashFlow: 0,
            budgetRisks: []
        )
    }
}

enum CashFlowForecastEngine {
    static let minEligibilityDays = 90
    static let maxHistoryDays = 90
    static let holtAlpha: Double = 0.20
    static let holtBeta: Double = 0.10

    struct ForecastConfiguration: Sendable {
        var enabled: Bool = true
        var yellowThreshold: Double = 0.10
        var redThreshold: Double = 0.20
    }

    static func evaluate(
        state: LedgerState,
        preferences: AppPreferences,
        now: Date = .now
    ) -> CashFlowForecast {
        let config = ForecastConfiguration(
            enabled: preferences.cashFlowForecastEnabled,
            yellowThreshold: preferences.forecastYellowThreshold,
            redThreshold: preferences.forecastRedThreshold
        )
        return evaluate(state: state, config: config, now: now)
    }

    static func evaluate(
        state: LedgerState,
        config: ForecastConfiguration,
        now: Date = .now
    ) -> CashFlowForecast {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let rates = state.settings.rates

        // 1. Check history span eligibility
        let active = state.transactions.filter { $0.deletedAt == nil }
        let eligibleExpenses = active.filter { $0.occurredAt <= now && $0.isCompleted(asOf: now) }

        guard let earliestDate = eligibleExpenses.map(\.occurredAt).min() else {
            return CashFlowForecast(
                generatedAt: now,
                historyStart: now,
                historyEnd: now,
                historyDays: 0,
                availableHistorySpan: 0,
                eligible: false,
                projectedExpenses: 0,
                projectedIncome: 0,
                projectedNetCashFlow: 0,
                budgetRisks: []
            )
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfEarliest = calendar.startOfDay(for: earliestDate)
        let availableDays = max(0, calendar.dateComponents([.day], from: startOfEarliest, to: startOfToday).day ?? 0)

        guard availableDays >= minEligibilityDays else {
            return CashFlowForecast(
                generatedAt: now,
                historyStart: startOfEarliest,
                historyEnd: startOfToday,
                historyDays: availableDays,
                availableHistorySpan: availableDays,
                eligible: false,
                projectedExpenses: 0,
                projectedIncome: 0,
                projectedNetCashFlow: 0,
                budgetRisks: []
            )
        }

        let historyDays = min(maxHistoryDays, availableDays)
        guard let historyStart = calendar.date(byAdding: .day, value: -historyDays, to: startOfToday) else {
            return .empty
        }

        // 2. Build calendar days in history window
        var historyDates: [Date] = []
        for i in 0..<historyDays {
            if let d = calendar.date(byAdding: .day, value: i, to: historyStart) {
                historyDates.append(d)
            }
        }

        // 3. Define forecast horizon through end of current month
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth),
              let endOfMonth = calendar.date(byAdding: .second, value: -1, to: nextMonth) else {
            return .empty
        }

        // Future days from tomorrow to end of month
        var futureDates: [Date] = []
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        var runner = tomorrow
        while runner <= endOfMonth {
            futureDates.append(runner)
            guard let next = calendar.date(byAdding: .day, value: 1, to: runner) else { break }
            runner = next
        }

        // 4. Deterministic future events (Recurring Rules + Pending Installments)
        let scheduledExpenses = collectDeterministicExpenses(state: state, from: now, to: endOfMonth)
        let scheduledIncome = collectDeterministicIncome(state: state, from: now, to: endOfMonth)

        // 5. Global flexible series for fallback weekday seasonality
        let flexibleByDay = Dictionary(grouping: active.filter {
            $0.recurringRuleID == nil && $0.linkedTransactionKind != .installment &&
            $0.occurredAt >= historyStart && $0.occurredAt < startOfToday
        }, by: { calendar.startOfDay(for: $0.occurredAt) })
        let globalFlexibleDaily = historyDates.map { date in
            sumFlexibleExpense(transactions: flexibleByDay[date, default: []], in: state, to: baseCurrency, filter: nil, now: now, calendar: calendar)
        }
        let globalRobust = winsorize(globalFlexibleDaily)
        let globalWeekdayFactors = calculateWeekdayFactors(dailyValues: globalRobust, dates: historyDates, calendar: calendar)

        // 6. Per-budget-line forecast
        let plan = state.settings.budgetPlan
        var risks: [BudgetForecastRisk] = []
        var totalProjectedExpenses: Double = 0
        let accountMap = Dictionary(uniqueKeysWithValues: state.accounts.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        let categoryMap = Dictionary(uniqueKeysWithValues: state.categories.map { ($0.id, $0) })
        let monthlyTransactions = active.filter { calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month) }

        switch plan.mode {
        case .category:
            for (categoryID, allocation) in plan.categoryAllocations where allocation > 0 {
                let actualSpent = monthlyTransactions.reduce(0.0) { sum, t in
                    guard t.categoryID == categoryID,
                          let val = TransactionSemantics.expenseEffect(t, in: state, to: baseCurrency, now: now) else { return sum }
                    return sum + val
                }

                // Deterministic future spend for category
                let scheduledForCategory = scheduledExpenses.filter { $0.categoryID == categoryID }.reduce(0.0) { sum, item in
                    sum + LedgerCalculations.convert(item.amount, from: item.currency, to: baseCurrency, rates: rates)
                }

                // Flexible future spend for category
                let catDaily = historyDates.map { date in
                    sumFlexibleExpense(transactions: flexibleByDay[date, default: []], in: state, to: baseCurrency, filter: { $0.categoryID == categoryID }, now: now, calendar: calendar)
                }
                let flexibleForCategory = forecastFlexibleExpense(
                    dailySeries: catDaily,
                    dates: historyDates,
                    futureDates: futureDates,
                    fallbackWeekdayFactors: globalWeekdayFactors,
                    calendar: calendar
                )

                let projected = actualSpent + scheduledForCategory + flexibleForCategory
                totalProjectedExpenses += projected

                let exceedance = (projected / allocation) - 1.0
                if exceedance >= config.yellowThreshold && config.enabled {
                    let severity: ForecastRiskSeverity = exceedance >= config.redThreshold ? .red : .yellow
                    risks.append(
                        BudgetForecastRisk(
                            lineID: "category:\(categoryID.rawValue)",
                            title: categoryMap[categoryID]?.displayName ?? categoryID.rawValue,
                            currency: baseCurrency,
                            budget: allocation,
                            actualSpent: actualSpent,
                            scheduledSpent: scheduledForCategory,
                            flexibleSpent: flexibleForCategory,
                            projectedSpend: projected,
                            exceedance: exceedance,
                            severity: severity
                        )
                    )
                }
            }

        case .account:
            for (accountID, allocation) in plan.accountAllocations where allocation > 0 {
                guard let account = accountMap[accountID] else { continue }
                let accountCurrency = account.currency

                let actualSpent = monthlyTransactions.reduce(0.0) { sum, t in
                    guard t.accountID == accountID,
                          let val = LedgerCalculations.accountExpenseEffect(t, for: account, in: state, now: now) else { return sum }
                    return sum + val
                }

                // Deterministic future spend for account
                let scheduledForAccount = scheduledExpenses.filter { $0.accountID == accountID }.reduce(0.0) { sum, item in
                    sum + LedgerCalculations.convert(item.amount, from: item.currency, to: accountCurrency, rates: rates)
                }

                // Flexible future spend for account
                let accDaily = historyDates.map { date in
                    sumFlexibleExpense(transactions: flexibleByDay[date, default: []], in: state, to: accountCurrency, filter: { $0.accountID == accountID }, now: now, calendar: calendar)
                }
                let flexibleForAccount = forecastFlexibleExpense(
                    dailySeries: accDaily,
                    dates: historyDates,
                    futureDates: futureDates,
                    fallbackWeekdayFactors: globalWeekdayFactors,
                    calendar: calendar
                )

                let projected = actualSpent + scheduledForAccount + flexibleForAccount
                let projectedInBase = LedgerCalculations.convert(projected, from: accountCurrency, to: baseCurrency, rates: rates)
                totalProjectedExpenses += projectedInBase

                let exceedance = (projected / allocation) - 1.0
                if exceedance >= config.yellowThreshold && config.enabled {
                    let severity: ForecastRiskSeverity = exceedance >= config.redThreshold ? .red : .yellow
                    risks.append(
                        BudgetForecastRisk(
                            lineID: "account:\(accountID.uuidString)",
                            title: account.name,
                            currency: accountCurrency,
                            budget: allocation,
                            actualSpent: actualSpent,
                            scheduledSpent: scheduledForAccount,
                            flexibleSpent: flexibleForAccount,
                            projectedSpend: projected,
                            exceedance: exceedance,
                            severity: severity
                        )
                    )
                }
            }
        }

        risks.sort { $0.exceedance > $1.exceedance }

        let projectedIncomeTotal = scheduledIncome.reduce(0.0) { sum, item in
            sum + LedgerCalculations.convert(item.amount, from: item.currency, to: baseCurrency, rates: rates)
        }

        return CashFlowForecast(
            generatedAt: now,
            historyStart: historyStart,
            historyEnd: startOfToday,
            historyDays: historyDays,
            availableHistorySpan: availableDays,
            eligible: true,
            projectedExpenses: totalProjectedExpenses,
            projectedIncome: projectedIncomeTotal,
            projectedNetCashFlow: projectedIncomeTotal - totalProjectedExpenses,
            budgetRisks: risks
        )
    }

    // MARK: - Flexible Spending Summation

    private static func sumFlexibleExpense(
        transactions: [LedgerTransaction],
        in state: LedgerState,
        to target: CurrencyCode,
        filter: ((LedgerTransaction) -> Bool)?,
        now: Date,
        calendar: Calendar
    ) -> Double {
        return transactions.reduce(0.0) { sum, t in
            guard filter?(t) ?? true, let eff = TransactionSemantics.expenseEffect(t, in: state, to: target, now: now), eff > 0 else { return sum }
            return sum + eff
        }
    }

    // MARK: - Winsorization & Baseline

    static func winsorize(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        let count = sorted.count
        let p90Index = min(count - 1, Int((Double(count - 1) * 0.90).rounded()))
        let p90 = sorted[p90Index]
        return values.map { min($0, p90) }
    }

    // MARK: - Weekday Seasonality

    static func calculateWeekdayFactors(
        dailyValues: [Double],
        dates: [Date],
        calendar: Calendar
    ) -> [Int: Double] {
        guard dailyValues.count == dates.count, !dailyValues.isEmpty else {
            return Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 1.0) })
        }

        let overallMean = dailyValues.reduce(0.0, +) / Double(dailyValues.count)
        guard overallMean > 0 else {
            return Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 1.0) })
        }

        var weekdayBuckets: [Int: [Double]] = [:]
        for (v, d) in zip(dailyValues, dates) {
            let weekday = calendar.component(.weekday, from: d)
            weekdayBuckets[weekday, default: []].append(v)
        }

        var rawFactors: [Int: Double] = [:]
        for w in 1...7 {
            let vals = weekdayBuckets[w] ?? []
            let count = vals.count
            if count == 0 {
                rawFactors[w] = 1.0
            } else {
                let mean_w = vals.reduce(0.0, +) / Double(count)
                let raw = mean_w / overallMean
                // Sparse weekday shrinkage towards 1.0
                let reliability = min(1.0, Double(count) / 6.0)
                let shrunk = 1.0 + reliability * (raw - 1.0)
                rawFactors[w] = min(1.75, max(0.5, shrunk))
            }
        }

        // Normalize so mean of factors is 1.0
        let meanFactor = (1...7).reduce(0.0) { $0 + (rawFactors[$1] ?? 1.0) } / 7.0
        guard meanFactor > 0 else {
            return Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 1.0) })
        }

        var normalized: [Int: Double] = [:]
        for w in 1...7 {
            normalized[w] = (rawFactors[w] ?? 1.0) / meanFactor
        }
        return normalized
    }

    // MARK: - Bounded Holt Smoothing & Forecast

    static func forecastFlexibleExpense(
        dailySeries: [Double],
        dates: [Date],
        futureDates: [Date],
        fallbackWeekdayFactors: [Int: Double],
        calendar: Calendar
    ) -> Double {
        guard !dailySeries.isEmpty, !futureDates.isEmpty else { return 0.0 }
        let totalSpend = dailySeries.reduce(0.0, +)
        guard totalSpend > 0 else { return 0.0 }

        let robustSeries = winsorize(dailySeries)
        let robustMean = robustSeries.reduce(0.0, +) / Double(robustSeries.count)
        guard robustMean > 0 else { return 0.0 }

        // Choose weekday factors: if category has sparse history (< 7 active days), use fallback
        let activeDays = dailySeries.filter { $0 > 0 }.count
        let weekdayFactors = activeDays >= 7
            ? calculateWeekdayFactors(dailyValues: robustSeries, dates: dates, calendar: calendar)
            : fallbackWeekdayFactors

        // Holt linear recurrence
        var level = robustSeries[0]
        var trend = robustSeries.count >= 2 ? (robustSeries[1] - robustSeries[0]) : 0.0

        for t in 1..<robustSeries.count {
            let y_t = robustSeries[t]
            let newLevel = holtAlpha * y_t + (1.0 - holtAlpha) * (level + trend)
            let newTrend = holtBeta * (newLevel - level) + (1.0 - holtBeta) * trend
            level = newLevel
            trend = newTrend
        }

        // Bound trend so total adjustment over horizon does not exceed 25% of baseline
        let horizon = futureDates.count
        let maxDailyTrend = (0.25 * robustMean) / Double(max(1, horizon))
        let clampedTrend = min(maxDailyTrend, max(-maxDailyTrend, trend))

        var totalForecast: Double = 0.0
        for (index, futureDate) in futureDates.enumerated() {
            let h = Double(index + 1)
            let rawBaseline = level + h * clampedTrend
            var boundedBaseline = max(0.0, min(rawBaseline, 1.25 * robustMean))
            if clampedTrend < 0 {
                boundedBaseline = max(0.75 * robustMean, boundedBaseline)
            }
            boundedBaseline = max(0.0, boundedBaseline)

            let weekday = calendar.component(.weekday, from: futureDate)
            let factor = weekdayFactors[weekday] ?? 1.0
            let dailyForecast = max(0.0, boundedBaseline * factor)
            totalForecast += dailyForecast
        }

        return totalForecast
    }

    // MARK: - Deterministic Scheduled Event Collection

    struct ScheduledItem {
        var date: Date
        var amount: Double
        var currency: CurrencyCode
        var categoryID: LedgerCategoryID
        var accountID: UUID
    }

    struct ScheduledIncomeItem {
        var date: Date
        var amount: Double
        var currency: CurrencyCode
    }

    private static func collectDeterministicExpenses(
        state: LedgerState,
        from now: Date,
        to endOfMonth: Date
    ) -> [ScheduledItem] {
        var items: [ScheduledItem] = []
        let calendar = Calendar.current

        // 1. Recurring Expense Rules
        if let rules = state.recurringRules {
            for rule in rules where rule.isEnabled && rule.deletedAt == nil && rule.type == .expense {
                var occurrence = rule.nextRunAt
                var count = 0
                while occurrence <= endOfMonth && count < 100 {
                    if occurrence > now {
                        items.append(
                            ScheduledItem(
                                date: occurrence,
                                amount: rule.amount,
                                currency: rule.currency,
                                categoryID: rule.categoryID,
                                accountID: rule.accountID
                            )
                        )
                    }
                    occurrence = nextDate(after: occurrence, interval: rule.interval, customDays: rule.customIntervalDays, calendar: calendar)
                    count += 1
                }
            }
        }

        // 2. Pending Installment Children
        for t in state.transactions where t.deletedAt == nil && t.linkedTransactionKind == .installment && !t.isCompleted(asOf: now) {
            if t.occurredAt > now && t.occurredAt <= endOfMonth {
                items.append(
                    ScheduledItem(
                        date: t.occurredAt,
                        amount: t.amount,
                        currency: t.currency,
                        categoryID: t.categoryID,
                        accountID: t.accountID
                    )
                )
            }
        }

        return items
    }

    private static func collectDeterministicIncome(
        state: LedgerState,
        from now: Date,
        to endOfMonth: Date
    ) -> [ScheduledIncomeItem] {
        var items: [ScheduledIncomeItem] = []
        let calendar = Calendar.current

        if let rules = state.recurringRules {
            for rule in rules where rule.isEnabled && rule.deletedAt == nil && rule.type == .income {
                var occurrence = rule.nextRunAt
                var count = 0
                while occurrence <= endOfMonth && count < 100 {
                    if occurrence > now {
                        items.append(
                            ScheduledIncomeItem(
                                date: occurrence,
                                amount: rule.amount,
                                currency: rule.currency
                            )
                        )
                    }
                    occurrence = nextDate(after: occurrence, interval: rule.interval, customDays: rule.customIntervalDays, calendar: calendar)
                    count += 1
                }
            }
        }

        return items
    }

    private static func nextDate(after date: Date, interval: RecurringInterval, customDays: Int, calendar: Calendar) -> Date {
        let component: Calendar.Component
        let value: Int
        switch interval {
        case .weekly: component = .weekOfYear; value = 1
        case .monthly: component = .month; value = 1
        case .yearly: component = .year; value = 1
        case .customDays: component = .day; value = max(1, customDays)
        }
        return calendar.date(byAdding: component, value: value, to: date) ?? date.addingTimeInterval(86_400)
    }
}
