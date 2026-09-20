import Foundation

extension LedgerStore {
    /// A pocket that still holds money cannot be removed until it is cleared or transferred out.
    func pocketRemovalMessage(for draft: LedgerAccount) -> String? {
        guard let existing = state.accounts.first(where: { $0.id == draft.id }), existing.usesCurrencyPockets else { return nil }
        let kept = Set(draft.normalizedPockets.map(\.currency))
        for pocket in existing.normalizedPockets where !kept.contains(pocket.currency) {
            let balance = LedgerCalculations.pocketBalance(pocket.currency, for: existing, in: state)
            guard balance.isFinite, abs(balance) > 0.005 else { continue }
            return "\(pocket.currency.rawValue) pocket still holds \(LedgerFormat.money(balance, currency: pocket.currency)). Clear or transfer it first."
        }
        return nil
    }

    /// Saves an account. `desiredPocketBalances` holds one entry per pocket; pockets that are not
    /// listed keep their stored opening balance, and a pocket's opening balance absorbs its own
    /// ledger delta so the requested balance is what the user sees.
    func saveAccount(_ draft: LedgerAccount, desiredBalance: Double, desiredPocketBalances: [CurrencyCode: Double] = [:]) {
        var account = draft
        account.logo = AccountTag.sanitize(account.logo.isEmpty ? account.name : account.logo)
        // Stocks settle in the market currency, so normalise before any balance arithmetic.
        if account.type == .stocks {
            let market = account.stockMetadata?.market ?? .US
            if account.stockMetadata == nil { account.stockMetadata = .init(market: market, symbol: "") }
            if let current = state.accounts.first(where: { $0.id == account.id })?.stockMetadata,
               current.market == account.stockMetadata?.market,
               current.symbol == account.stockMetadata?.symbol,
               current.providerSymbol == account.stockMetadata?.providerSymbol,
               let date = current.latestPriceAt,
               date >= (account.stockMetadata?.latestPriceAt ?? .distantPast) {
                account.stockMetadata?.latestPrice = current.latestPrice
                account.stockMetadata?.latestPriceAt = date
            }
            guard let stock = account.stockMetadata, stock.costBasis.isFinite, stock.value.isFinite,
                  stock.averageCost >= 0, stock.quantity >= 0 else {
                presentedError = "Enter a valid cost price and quantity."
                return
            }
            account.currency = market.settlementCurrency
            account.isMultiCurrency = false
            account.currencyPockets = []
        }
        account.isMultiCurrency = account.usesCurrencyPockets
        var pockets = account.normalizedPockets
        let previousRuleID = state.accounts.first(where: { $0.id == draft.id })?.loanMetadata?.linkedRecurringRuleID

        if account.usesCurrencyPockets {
            for index in pockets.indices {
                let currency = pockets[index].currency
                var zeroOpening = account
                zeroOpening.openingBalance = 0
                zeroOpening.currencyPockets = [.init(currency: currency, openingBalance: 0)]
                let ledgerDelta = LedgerCalculations.pocketBalance(currency, for: zeroOpening, in: state)
                let desired = desiredPocketBalances[currency] ?? (pockets[index].openingBalance + ledgerDelta)
                pockets[index].openingBalance = desired - ledgerDelta
            }
            account.currencyPockets = pockets
            // The primary currency stays mirrored for readers that only understand `openingBalance`.
            if let primary = pockets.first(where: { $0.currency == account.currency }) { account.openingBalance = primary.openingBalance }
        } else if account.type == .stocks {
            // Holdings valuation is independent of cash postings and never creates a P/L transaction.
            account.openingBalance = 0
            account.currencyPockets = []
        } else {
            var zeroOpening = draft
            zeroOpening.openingBalance = 0
            zeroOpening.isMultiCurrency = false
            zeroOpening.currencyPockets = []
            let ledgerDelta = LedgerCalculations.balance(for: zeroOpening, in: state)
            account.openingBalance = desiredBalance - ledgerDelta
            account.currencyPockets = [.init(currency: account.currency, openingBalance: account.openingBalance)]
        }

        if let current = state.accounts.first(where: { $0.id == draft.id }) {
            account.version = current.version + 1
            account.createdAt = current.createdAt
        } else {
            account.version = 1
        }
        account.updatedAt = .now
        account.deletedAt = nil
        account.syncStatus = .pending
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) { state.accounts[index] = account }
        else { state.accounts.append(account) }
        syncLoanInterestRule(accountID: account.id, previousRuleID: previousRuleID)
        scheduleSave()
    }

    private func syncLoanInterestRule(accountID: UUID, previousRuleID: UUID?) {
        guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let account = state.accounts[accountIndex]
        guard account.type == .loan, var metadata = account.loanMetadata, metadata.annualPercentageRate > 0, let interval = metadata.interestInterval else {
            if let previousRuleID, let ruleIndex = state.recurringRules?.firstIndex(where: { $0.id == previousRuleID }) { state.recurringRules?[ruleIndex].isEnabled = false; state.recurringRules?[ruleIndex].updatedAt = .now }
            return
        }
        var rules = state.recurringRules ?? []
        let ruleID = metadata.linkedRecurringRuleID ?? previousRuleID ?? UUID()
        let now = Date.now
        let existing = rules.first(where: { $0.id == ruleID })
        let rule = RecurringRule(id: ruleID, userID: state.settings.userID, type: .expense, accountID: account.id, destinationAccountID: nil, amount: 0, amountKind: .loanInterest, linkedLoanAccountID: account.id, currency: account.currency, categoryID: .other, note: "\(account.name) Interest", interval: interval, customIntervalDays: max(1, metadata.customIntervalDays), nextRunAt: existing?.nextRunAt ?? nextDate(after: now, interval: interval, customDays: metadata.customIntervalDays), isEnabled: true, createdAt: existing?.createdAt ?? now, updatedAt: now)
        if let index = rules.firstIndex(where: { $0.id == ruleID }) { rules[index] = rule } else { rules.append(rule) }
        metadata.linkedRecurringRuleID = ruleID
        state.accounts[accountIndex].loanMetadata = metadata
        state.recurringRules = rules
    }

    func deleteAccount(_ account: LedgerAccount) {
        undoState = state
        let deletedAt = Date.now
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
            state.accounts[index].deletedAt = deletedAt
            state.accounts[index].updatedAt = deletedAt
            state.accounts[index].version += 1
        }
        for index in state.transactions.indices where state.transactions[index].accountID == account.id || state.transactions[index].destinationAccountID == account.id {
            state.transactions[index].deletedAt = deletedAt
            state.transactions[index].updatedAt = deletedAt
            state.transactions[index].version += 1
        }
        if var rules = state.recurringRules {
            for index in rules.indices where rules[index].accountID == account.id || rules[index].destinationAccountID == account.id { rules[index].isEnabled = false; rules[index].updatedAt = deletedAt }
            state.recurringRules = rules
        }
        state.settings.defaultExpenseAccountByCategory = state.settings.defaultExpenseAccountByCategory.filter { $0.value != account.id }
        state.settings.budgetPlan.accountAllocations[account.id] = nil
        if var sessions = state.purchaseSessions {
            for sessionIndex in sessions.indices {
                for itemIndex in sessions[sessionIndex].items.indices where sessions[sessionIndex].items[itemIndex].resolvedAccountID == account.id { sessions[sessionIndex].items[itemIndex].resolvedAccountID = nil }
            }
            for index in sessions.indices where sessions[index].accountID == account.id && (sessions[index].status == .active || sessions[index].status == .awaitingSummary) {
                sessions[index].status = .draft
                sessions[index].updatedAt = deletedAt
                let stopped = sessions[index]
                if persistenceEnabled {
                    try? PurchaseSharedStateStore.write(session: stopped)
                    Task { await PurchaseLiveActivityController.shared.end(sessionID: stopped.id) }
                }
            }
            state.purchaseSessions = sessions
        }
        undoMessage = "Account deleted"
        scheduleSave()
    }

    func freezeAccount(_ id: UUID) {
        guard let index = state.accounts.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        var account = state.accounts[index]
        guard !account.effectiveIsFrozen else { return }
        undoState = state
        let now = Date.now
        account.isFrozen = true
        account.updatedAt = now
        account.version += 1
        account.syncStatus = .pending

        state.accounts.remove(at: index)

        // Move to the end of accounts (or end of frozen accounts, before soft-deleted)
        let lastNonDeletedIndex = state.accounts.lastIndex(where: { $0.deletedAt == nil }) ?? state.accounts.count - 1
        let insertIndex = min(lastNonDeletedIndex + 1, state.accounts.count)
        state.accounts.insert(account, at: insertIndex)

        scheduleSave()
    }

    func unfreezeAccount(_ id: UUID) {
        guard let index = state.accounts.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        var account = state.accounts[index]
        guard account.effectiveIsFrozen else { return }
        undoState = state
        let now = Date.now
        account.isFrozen = false
        account.updatedAt = now
        account.version += 1
        account.syncStatus = .pending

        state.accounts.remove(at: index)

        // Place at the end of the ACTIVE section (immediately before the first frozen account, or before deleted)
        if let firstFrozenIndex = state.accounts.firstIndex(where: { $0.deletedAt == nil && $0.effectiveIsFrozen }) {
            state.accounts.insert(account, at: firstFrozenIndex)
        } else {
            let lastNonDeletedIndex = state.accounts.lastIndex(where: { $0.deletedAt == nil }) ?? state.accounts.count - 1
            let insertIndex = min(lastNonDeletedIndex + 1, state.accounts.count)
            state.accounts.insert(account, at: insertIndex)
        }

        scheduleSave()
    }

    func moveAccounts(from offsets: IndexSet, to destination: Int) {
        var nonDeleted = state.accounts.filter { $0.deletedAt == nil }
        guard destination >= 0, destination <= nonDeleted.count else { return }
        nonDeleted.move(fromOffsets: offsets, toOffset: destination)

        // Enforce active accounts first, then frozen accounts, preserving relative order in each partition
        let active = nonDeleted.filter { !$0.effectiveIsFrozen }
        let frozen = nonDeleted.filter { $0.effectiveIsFrozen }
        var newAccounts = active + frozen
        newAccounts.append(contentsOf: state.accounts.filter { $0.deletedAt != nil })
        state.accounts = newAccounts
        scheduleSave()
    }

    func setAccountOrder(_ orderedIDs: [UUID]) {
        let active = state.accounts.filter { $0.deletedAt == nil }
        let map = Dictionary(grouping: active, by: \.id)
        var newActive: [LedgerAccount] = []
        for id in orderedIDs {
            if let account = map[id]?.first {
                newActive.append(account)
            }
        }
        let orderedSet = Set(orderedIDs)
        for account in active where !orderedSet.contains(account.id) {
            newActive.append(account)
        }
        newActive.append(contentsOf: state.accounts.filter { $0.deletedAt != nil })
        state.accounts = newActive
        scheduleSave()
    }

    func moveAccount(from sourceID: UUID, to destinationID: UUID) {
        guard sourceID != destinationID else { return }
        guard let sourceIndex = state.accounts.firstIndex(where: { $0.id == sourceID }),
              let destIndex = state.accounts.firstIndex(where: { $0.id == destinationID }) else { return }
        let account = state.accounts.remove(at: sourceIndex)
        state.accounts.insert(account, at: destIndex)
        scheduleSave()
    }

}
