import Foundation

struct MonthPeriod: Sendable, Hashable {
    let monthStart: Date
    let monthEnd: Date
    let label: String
    let isCurrentPartial: Bool
}

struct ThreeMonthFinancialSummary: Sendable, Hashable {
    var averageNetWorth: Double
    var averageIncome: Double
    var averageSpending: Double
    var averageTurnover: Double
}

enum ThreeMonthFinancialEngine {
    static func computeThreeMonthWindows(
        startOfMonth: Date,
        cutoffEnd: Date,
        calendar: Calendar,
        now: Date
    ) -> (m1: MonthPeriod, m2: MonthPeriod, m3: MonthPeriod, rangeString: String, currentPartialNote: String?) {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        let isM3Partial = calendar.isDate(startOfMonth, equalTo: now, toGranularity: .month)
        let m3 = MonthPeriod(monthStart: startOfMonth, monthEnd: cutoffEnd, label: monthFormatter.string(from: startOfMonth), isCurrentPartial: isM3Partial)

        let m2Start = calendar.date(byAdding: .month, value: -1, to: startOfMonth)!
        let m2End = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: m2Start)!
        let m2 = MonthPeriod(monthStart: m2Start, monthEnd: m2End, label: monthFormatter.string(from: m2Start), isCurrentPartial: false)

        let m1Start = calendar.date(byAdding: .month, value: -2, to: startOfMonth)!
        let m1End = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: m1Start)!
        let m1 = MonthPeriod(monthStart: m1Start, monthEnd: m1End, label: monthFormatter.string(from: m1Start), isCurrentPartial: false)

        let rangeString = "\(monthFormatter.string(from: m1Start)) – \(monthFormatter.string(from: startOfMonth))"

        var partialNote: String? = nil
        if isM3Partial {
            let fullDF = DateFormatter()
            fullDF.dateStyle = .long
            partialNote = "Current-month figures are based on records through \(fullDF.string(from: cutoffEnd))."
        }

        return (m1, m2, m3, rangeString, partialNote)
    }

    /// Historical native balances valued using the rates supplied in this state.
    /// No historical FX or account-state history is fabricated for older books.
    static func calculateBalance(
        account: LedgerAccount,
        upTo cutoff: Date,
        in state: LedgerState,
        includeCutoff: Bool = true,
        index: LedgerIndex? = nil
    ) -> Double {
        account.normalizedPockets.reduce(0) { total, pocket in
            let balance = calculatePocketBalance(pocket: pocket.currency, account: account, upTo: cutoff, in: state, includeCutoff: includeCutoff, index: index)
            return total + LedgerCalculations.convert(balance, from: pocket.currency, to: account.currency, rates: state.settings.rates)
        }
    }

    static func calculatePocketBalance(
        pocket: CurrencyCode,
        account: LedgerAccount,
        upTo cutoff: Date,
        in state: LedgerState,
        includeCutoff: Bool = true,
        index: LedgerIndex? = nil
    ) -> Double {
        let opening = account.normalizedPockets.first(where: { $0.currency == pocket })?.openingBalance ?? 0
        let txs = index?.transactions(for: account.id) ?? state.transactions
        return txs.reduce(opening) { balance, transaction in
            guard transaction.deletedAt == nil, (includeCutoff ? transaction.occurredAt <= cutoff : transaction.occurredAt < cutoff), TransactionSemantics.posts(transaction, now: cutoff) else {
                return balance
            }
            var updated = balance
            if transaction.accountID == account.id, LedgerCalculations.sourcePocket(transaction, for: account) == pocket {
                let amount = LedgerCalculations.sourcePosting(transaction, for: account, in: state)
                switch transaction.type {
                case .expense, .transfer: updated -= amount
                case .income: updated += amount
                }
            }
            if transaction.type == .transfer, transaction.destinationAccountID == account.id, LedgerCalculations.destinationPocket(transaction, for: account) == pocket {
                updated += LedgerCalculations.destinationPosting(transaction, for: account, in: state)
            }
            return updated
        }
    }

    /// Net Worth (Assets - Liabilities) across all active, non-frozen accounts at `cutoff`, valued using the supplied current FX rates.
    static func closingNetWorth(
        at cutoff: Date,
        baseCurrency: CurrencyCode,
        in state: LedgerState,
        index: LedgerIndex? = nil
    ) -> Double {
        let activeAccounts = state.accounts.filter { $0.deletedAt == nil && !$0.effectiveIsFrozen }
        var netWorth: Double = 0

        for account in activeAccounts {
            if account.type == .stocks, let stock = account.stockMetadata {
                let val = (stock.latestPriceAt != nil && stock.latestPriceAt! <= cutoff) ? stock.value : stock.costBasis
                let converted = LedgerCalculations.convert(val, from: account.currency, to: baseCurrency, rates: state.settings.rates)
                netWorth += converted
            } else if account.usesCurrencyPockets {
                var accountTotalBase: Double = 0
                for pocket in account.normalizedPockets {
                    let pBal = calculatePocketBalance(pocket: pocket.currency, account: account, upTo: cutoff, in: state, index: index)
                    accountTotalBase += LedgerCalculations.convert(pBal, from: pocket.currency, to: baseCurrency, rates: state.settings.rates)
                }
                netWorth += accountTotalBase
            } else {
                let bal = calculateBalance(account: account, upTo: cutoff, in: state, index: index)
                let converted = LedgerCalculations.convert(bal, from: account.currency, to: baseCurrency, rates: state.settings.rates)
                netWorth += converted
            }
        }

        return netWorth
    }

    static func monthlyRecognizedIncome(from: Date, to: Date, baseCurrency: CurrencyCode, in state: LedgerState, now: Date, index: LedgerIndex? = nil) -> Double {
        let txs = index?.activeTransactions ?? state.transactions.filter { $0.deletedAt == nil }
        return txs.compactMap {
            ($0.occurredAt >= from && $0.occurredAt <= to) ? TransactionSemantics.incomeEffect($0, in: state, to: baseCurrency, now: now) : nil
        }.reduce(0.0, +)
    }

    static func monthlyRecognizedExpense(from: Date, to: Date, baseCurrency: CurrencyCode, in state: LedgerState, now: Date, index: LedgerIndex? = nil) -> Double {
        let txs = index?.activeTransactions ?? state.transactions.filter { $0.deletedAt == nil }
        return txs.compactMap {
            ($0.occurredAt >= from && $0.occurredAt <= to) ? TransactionSemantics.expenseEffect($0, in: state, to: baseCurrency, now: now) : nil
        }.reduce(0.0, +)
    }

    static func externalTurnoverEffect(
        _ t: LedgerTransaction,
        in state: LedgerState,
        to baseCurrency: CurrencyCode,
        ownedAccountIDs: Set<UUID>,
        accountsByID: [UUID: LedgerAccount]
    ) -> Double {
        guard TransactionSemantics.posts(t) else { return 0 }
        if t.type == .transfer {
            let srcOwned = ownedAccountIDs.contains(t.accountID)
            let destOwned = t.destinationAccountID.map { ownedAccountIDs.contains($0) } ?? false
            // Internal transfer between user's own accounts: strictly excluded from turnover
            if srcOwned && destOwned {
                return 0
            } else if srcOwned, let sourceAccount = accountsByID[t.accountID] {
                let posted = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)
                let pocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
                return LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
            } else if destOwned, let destID = t.destinationAccountID, let destAccount = accountsByID[destID] {
                let posted = LedgerCalculations.destinationPosting(t, for: destAccount, in: state)
                let pocket = LedgerCalculations.destinationPocket(t, for: destAccount)
                return LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
            }
        } else if t.type == .expense, let sourceAccount = accountsByID[t.accountID] {
            let posted = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)
            let pocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
            return LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
        } else if t.type == .income, let sourceAccount = accountsByID[t.accountID] {
            let posted = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)
            let pocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
            return LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
        }
        return 0
    }

    static func monthlyExternalTurnover(from: Date, to: Date, baseCurrency: CurrencyCode, in state: LedgerState, index: LedgerIndex? = nil) -> Double {
        let ownedAccountIDs = Set(state.accounts.filter { $0.deletedAt == nil }.map(\.id))
        let accountsByID = index?.accountsByID ?? Dictionary(uniqueKeysWithValues: state.accounts.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        let txs = index?.activeTransactions ?? state.transactions.filter {
            $0.deletedAt == nil && TransactionSemantics.posts($0)
        }

        var turnover: Double = 0
        for t in txs where t.occurredAt >= from && t.occurredAt <= to {
            turnover += externalTurnoverEffect(t, in: state, to: baseCurrency, ownedAccountIDs: ownedAccountIDs, accountsByID: accountsByID)
        }
        return turnover
    }

    private struct MonthAccumulator {
        var income: Double = 0
        var expense: Double = 0
        var turnover: Double = 0
    }

    static func calculate(
        for monthDate: Date,
        in state: LedgerState,
        baseCurrency: CurrencyCode? = nil,
        now: Date = .now,
        index: LedgerIndex? = nil
    ) -> (summary: ThreeMonthFinancialSummary, windows: (m1: MonthPeriod, m2: MonthPeriod, m3: MonthPeriod, rangeString: String, currentPartialNote: String?)) {
        let calendar = Calendar.current
        let targetCurrency = baseCurrency ?? state.settings.baseCurrency
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let endOfMonth: Date
        if let nextMonth = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: startOfMonth) {
            endOfMonth = calendar.isDate(startOfMonth, equalTo: now, toGranularity: .month) ? now : nextMonth
        } else {
            endOfMonth = now
        }

        let windows = computeThreeMonthWindows(startOfMonth: startOfMonth, cutoffEnd: endOfMonth, calendar: calendar, now: now)

        let idx = index ?? LedgerIndex(state: state)

        let m1NW = closingNetWorth(at: windows.m1.monthEnd, baseCurrency: targetCurrency, in: state, index: idx)
        let m2NW = closingNetWorth(at: windows.m2.monthEnd, baseCurrency: targetCurrency, in: state, index: idx)
        let m3NW = closingNetWorth(at: windows.m3.monthEnd, baseCurrency: targetCurrency, in: state, index: idx)
        let avgNetWorth = (m1NW + m2NW + m3NW) / 3.0

        let ownedAccountIDs = Set(state.accounts.filter { $0.deletedAt == nil }.map(\.id))
        let accountsByID = idx.accountsByID

        var m1Acc = MonthAccumulator()
        var m2Acc = MonthAccumulator()
        var m3Acc = MonthAccumulator()

        for t in idx.activeTransactions {
            let date = t.occurredAt
            if date >= windows.m1.monthStart && date <= windows.m1.monthEnd {
                if let inc = TransactionSemantics.incomeEffect(t, in: state, to: targetCurrency, now: now) {
                    m1Acc.income += inc
                }
                if let exp = TransactionSemantics.expenseEffect(t, in: state, to: targetCurrency, now: now) {
                    m1Acc.expense += exp
                }
                m1Acc.turnover += externalTurnoverEffect(t, in: state, to: targetCurrency, ownedAccountIDs: ownedAccountIDs, accountsByID: accountsByID)
            } else if date >= windows.m2.monthStart && date <= windows.m2.monthEnd {
                if let inc = TransactionSemantics.incomeEffect(t, in: state, to: targetCurrency, now: now) {
                    m2Acc.income += inc
                }
                if let exp = TransactionSemantics.expenseEffect(t, in: state, to: targetCurrency, now: now) {
                    m2Acc.expense += exp
                }
                m2Acc.turnover += externalTurnoverEffect(t, in: state, to: targetCurrency, ownedAccountIDs: ownedAccountIDs, accountsByID: accountsByID)
            } else if date >= windows.m3.monthStart && date <= windows.m3.monthEnd {
                if let inc = TransactionSemantics.incomeEffect(t, in: state, to: targetCurrency, now: now) {
                    m3Acc.income += inc
                }
                if let exp = TransactionSemantics.expenseEffect(t, in: state, to: targetCurrency, now: now) {
                    m3Acc.expense += exp
                }
                m3Acc.turnover += externalTurnoverEffect(t, in: state, to: targetCurrency, ownedAccountIDs: ownedAccountIDs, accountsByID: accountsByID)
            }
        }

        let avgIncome = (m1Acc.income + m2Acc.income + m3Acc.income) / 3.0
        let avgExpense = (m1Acc.expense + m2Acc.expense + m3Acc.expense) / 3.0
        let avgTurnover = (m1Acc.turnover + m2Acc.turnover + m3Acc.turnover) / 3.0

        let summary = ThreeMonthFinancialSummary(
            averageNetWorth: avgNetWorth,
            averageIncome: avgIncome,
            averageSpending: avgExpense,
            averageTurnover: avgTurnover
        )

        return (summary, windows)
    }
}
