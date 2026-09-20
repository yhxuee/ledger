import Foundation

extension LedgerStore {
    func saveRecurringRule(_ rule: RecurringRule) {
        var rules = state.recurringRules ?? []
        var activeRule = rule
        activeRule.deletedAt = nil
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = activeRule }
        else { rules.append(activeRule) }
        state.recurringRules = rules
        scheduleSave()
    }

    func deleteRecurringRule(_ rule: RecurringRule) {
        guard var rules = state.recurringRules, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        undoState = state
        rules[index].deletedAt = .now
        rules[index].isEnabled = false
        rules[index].updatedAt = .now
        state.recurringRules = rules
        undoMessage = "Recurring transaction deleted"
        scheduleSave()
    }

    func setRecurringRule(_ rule: RecurringRule, enabled: Bool) {
        guard var rules = state.recurringRules, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled = enabled
        rules[index].updatedAt = .now
        state.recurringRules = rules
        scheduleSave()
    }

    func processDueRecurring(now: Date = .now) {
        guard var rules = state.recurringRules, !rules.isEmpty else { return }
        var changed = false
        for index in rules.indices where rules[index].isEnabled && rules[index].deletedAt == nil {
            var executions = 0
            while rules[index].nextRunAt <= now && executions < 100 {
                let rule = rules[index]
                let amount = recurringAmount(for: rule)
                if amount > 0 { addTransaction(type: rule.type, accountID: rule.accountID, destinationAccountID: rule.destinationAccountID, amount: amount, currency: rule.currency, categoryID: rule.categoryID, occurredAt: rule.nextRunAt, note: rule.note, recurringRuleID: rule.id, accountCurrency: rule.accountCurrency, destinationAccountCurrency: rule.destinationAccountCurrency) }
                rules[index].nextRunAt = nextDate(after: rule.nextRunAt, interval: rule.interval, customDays: rule.customIntervalDays)
                rules[index].updatedAt = now
                executions += 1
                changed = true
            }
        }
        if changed { state.recurringRules = rules; scheduleSave() }
    }

    private func recurringAmount(for rule: RecurringRule) -> Double {
        guard rule.effectiveAmountKind == .loanInterest else { return rule.amount }
        guard let accountID = rule.linkedLoanAccountID,
              let account = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }),
              let loan = account.loanMetadata, loan.annualPercentageRate > 0 else { return 0 }
        let principal = abs(LedgerCalculations.balance(for: account, in: state))
        let periods: Double
        switch rule.interval { case .weekly: periods = 52; case .monthly: periods = 12; case .yearly: periods = 1; case .customDays: periods = 365 / Double(max(1, rule.customIntervalDays)) }
        return principal * (loan.annualPercentageRate / 100) / max(1, periods)
    }

    private func nextDate(after date: Date, interval: RecurringInterval, customDays: Int) -> Date {
        let component: Calendar.Component
        let value: Int
        switch interval {
        case .weekly: component = .weekOfYear; value = 1
        case .monthly: component = .month; value = 1
        case .yearly: component = .year; value = 1
        case .customDays: component = .day; value = max(1, customDays)
        }
        return Calendar.current.date(byAdding: component, value: value, to: date) ?? date.addingTimeInterval(86_400)
    }


}
