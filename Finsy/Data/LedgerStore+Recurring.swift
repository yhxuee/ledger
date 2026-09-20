import Foundation

extension LedgerStore {
    func saveRecurringRule(_ rule: RecurringRule) {
        var activeRule = rule
        activeRule.deletedAt = nil
        mutateState { state in
            var rules = state.recurringRules ?? []
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = activeRule }
            else { rules.append(activeRule) }
            state.recurringRules = rules
        }
        scheduleSave()
    }

    func deleteRecurringRule(_ rule: RecurringRule) {
        guard (state.recurringRules ?? []).contains(where: { $0.id == rule.id }) else { return }
        activeUndoOperation = LedgerUndoOperation(
            message: "Recurring transaction deleted",
            recurringRuleSnapshots: [rule.id: rule]
        )
        mutateState { state in
            guard var rules = state.recurringRules, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index].deletedAt = .now
            rules[index].isEnabled = false
            rules[index].updatedAt = .now
            state.recurringRules = rules
        }
        undoMessage = "Recurring transaction deleted"
        scheduleSave()
    }

    func setRecurringRule(_ rule: RecurringRule, enabled: Bool) {
        guard (state.recurringRules ?? []).contains(where: { $0.id == rule.id }) else { return }
        mutateState { state in
            guard var rules = state.recurringRules, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index].isEnabled = enabled
            rules[index].updatedAt = .now
            state.recurringRules = rules
        }
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
                if amount > 0 { addTransaction(type: rule.type, accountID: rule.accountID, destinationAccountID: rule.destinationAccountID, amount: amount, currency: rule.currency, categoryID: rule.categoryID, occurredAt: rule.nextRunAt, note: rule.note, recurringRuleID: rule.id, accountCurrency: rule.accountCurrency, destinationAccountCurrency: rule.destinationAccountCurrency, origin: .recurring) }
                rules[index].nextRunAt = nextDate(after: rule.nextRunAt, interval: rule.interval, customDays: rule.customIntervalDays)
                rules[index].updatedAt = now
                executions += 1
                changed = true
            }
        }
        if changed {
            mutateState { state in
                state.recurringRules = rules
            }
            scheduleSave()
        }
    }

    func recurringAmount(for rule: RecurringRule) -> Double {
        guard rule.effectiveAmountKind == .loanInterest else { return rule.amount }
        guard let accountID = rule.linkedLoanAccountID,
              let account = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }),
              let loan = account.loanMetadata, loan.annualPercentageRate > 0 else { return 0 }
        let principal = abs(LedgerCalculations.balance(for: account, in: state))
        let periods: Double
        switch rule.interval { case .weekly: periods = 52; case .monthly: periods = 12; case .yearly: periods = 1; case .customDays: periods = 365 / Double(max(1, rule.customIntervalDays)) }
        return principal * (loan.annualPercentageRate / 100) / max(1, periods)
    }

    func nextDate(after date: Date, interval: RecurringInterval, customDays: Int) -> Date {
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
