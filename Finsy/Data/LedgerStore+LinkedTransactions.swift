import Foundation

extension LedgerStore {
    func ensureCurrencyPocket(accountID: UUID, currency: CurrencyCode) -> Bool {
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID && $0.deletedAt == nil }),
              state.accounts[index].usesCurrencyPockets,
              CurrencyRates.reference(currency, in: state.settings.rates) != nil else { return false }
        guard !state.accounts[index].pocketCurrencies.contains(currency) else { return true }
        mutateState { state in
            state.accounts[index].currencyPockets = state.accounts[index].normalizedPockets + [.init(currency: currency, openingBalance: 0)]
            state.accounts[index].updatedAt = .now; state.accounts[index].version += 1; state.accounts[index].syncStatus = .pending
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func configureSplit(parentID: UUID, people: Int = 2, now: Date = .now) -> Bool {
        guard (2...50).contains(people) else { return false }
        guard let index = state.transactions.firstIndex(where: { $0.id == parentID && $0.deletedAt == nil }) else { return false }
        let parent = state.transactions[index]
        guard TransactionSemantics.eligible(parent) || (parent.groupMode == .split && !parent.isLockedByReversal) else { return false }
        guard let generated = SplitSchedule.generate(parent: parent, people: people, now: now) else { return false }

        let existingChildren = TransactionSemantics.children(of: parent, in: state)
        let completedSettlements = existingChildren.filter { $0.linkedTransactionKind == .splitSettlement && $0.linkedStatus == .completed }
        guard completedSettlements.count < people else { return false }

        mutateState { state in
            for child in existingChildren {
                if let childIndex = state.transactions.firstIndex(where: { $0.id == child.id }) {
                    markDeleted(in: &state, at: childIndex, date: now)
                }
            }

            state.transactions[index].groupMode = .split
            state.transactions[index].splitMetadata = .init(participantCount: people)
            state.transactions[index].installmentMetadata = nil
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
            state.transactions.append(contentsOf: generated)
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func configureReimbursement(parentID: UUID, now: Date = .now) -> Bool {
        guard let index = state.transactions.firstIndex(where: { $0.id == parentID && $0.deletedAt == nil }) else { return false }
        let parent = state.transactions[index]
        guard TransactionSemantics.eligible(parent) || (parent.groupMode == .reimbursement && !parent.isLockedByReversal) else { return false }
        let generated = ReimbursementSchedule.generate(parent: parent, now: now)

        let existingChildren = TransactionSemantics.children(of: parent, in: state)
        mutateState { state in
            for child in existingChildren {
                if let childIndex = state.transactions.firstIndex(where: { $0.id == child.id }) {
                    markDeleted(in: &state, at: childIndex, date: now)
                }
            }

            state.transactions[index].groupMode = .reimbursement
            state.transactions[index].splitMetadata = nil
            state.transactions[index].installmentMetadata = nil
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
            state.transactions.append(contentsOf: generated)
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func configureInstallment(parentID: UUID, plan: InstallmentPlanMetadata, now: Date = .now) -> Bool {
        guard let index = state.transactions.firstIndex(where: { $0.id == parentID && $0.deletedAt == nil }) else { return false }
        let parent = state.transactions[index]
        guard state.accounts.first(where: { $0.id == parent.accountID && $0.deletedAt == nil })?.type == .credit else { return false }
        guard TransactionSemantics.eligible(parent) || (parent.groupMode == .installment && !parent.isLockedByReversal) else { return false }
        guard let generated = InstallmentSchedule.generate(parent: parent, plan: plan, now: now) else { return false }

        let existingChildren = TransactionSemantics.children(of: parent, in: state)
        mutateState { state in
            for child in existingChildren {
                if let childIndex = state.transactions.firstIndex(where: { $0.id == child.id }) {
                    markDeleted(in: &state, at: childIndex, date: now)
                }
            }

            state.transactions[index].groupMode = .installment
            state.transactions[index].installmentMetadata = plan
            state.transactions[index].splitMetadata = nil
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
            state.transactions.append(contentsOf: generated)
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func convertExpenseToRefundGroup(_ original: LedgerTransaction, now: Date = .now) -> Bool {
        guard let index = state.transactions.firstIndex(where: { $0.id == original.id && $0.deletedAt == nil }) else { return false }
        let parent = state.transactions[index]
        guard TransactionSemantics.eligible(parent) else { return false }
        let generated = RefundSchedule.generate(parent: parent, now: now)

        mutateState { state in
            state.transactions[index].groupMode = .refund
            state.transactions[index].splitMetadata = nil
            state.transactions[index].installmentMetadata = nil
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
            state.transactions.append(contentsOf: generated)
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func completeSettlement(_ childID: UUID, now: Date = .now) -> Bool {
        guard let index = state.transactions.firstIndex(where: { $0.id == childID && $0.deletedAt == nil }),
              state.transactions[index].linkedTransactionKind == .splitSettlement else { return false }
        mutateState { state in
            state.transactions[index].linkedStatus = .completed
            state.transactions[index].completedAt = now
            state.transactions[index].occurredAt = now
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func payInstallmentEarly(_ childID: UUID, now: Date = .now) -> Bool {
        guard let index = state.transactions.firstIndex(where: { $0.id == childID && $0.deletedAt == nil }),
              state.transactions[index].linkedTransactionKind == .installment else { return false }
        mutateState { state in
            state.transactions[index].linkedStatus = .completed
            state.transactions[index].completedAt = now
            state.transactions[index].occurredAt = now
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func completeReimbursement(_ childID: UUID, now: Date = .now) -> Bool {
        guard let index = state.transactions.firstIndex(where: { $0.id == childID && $0.deletedAt == nil }),
              state.transactions[index].linkedTransactionKind == .reimbursementIncome else { return false }
        mutateState { state in
            state.transactions[index].linkedStatus = .completed
            state.transactions[index].completedAt = now
            state.transactions[index].occurredAt = now
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func refundPurchaseChild(_ child: LedgerTransaction, now: Date = .now) -> LedgerTransaction? {
        guard let index = state.transactions.firstIndex(where: { $0.id == child.id && $0.deletedAt == nil }),
              !child.isReversal, child.reversalTransactionID == nil else { return nil }
        guard let reversal = RefundEngine.makeReversal(of: child, in: state, now: now) else { return nil }
        mutateState { state in
            state.transactions[index].reversalTransactionID = reversal.id
            state.transactions[index].updatedAt = now
            state.transactions[index].version += 1
            state.transactions[index].syncStatus = .pending
            state.transactions.insert(reversal, at: 0)
        }
        scheduleSave()
        return reversal
    }

    @discardableResult
    func refundInstallmentParent(_ parent: LedgerTransaction, now: Date = .now) -> LedgerTransaction? {
        guard parent.groupMode == .installment, parent.deletedAt == nil else { return nil }
        let refundable = TransactionSemantics.refundableInstallmentAmount(parent, in: state, now: now)
        guard refundable > 0.001 else { return nil }
        guard let source = state.accounts.first(where: { $0.id == parent.accountID && $0.deletedAt == nil }) else { return nil }
        let sourcePocket = LedgerCalculations.sourcePocket(parent, for: source)
        let exactSourceAmount = LedgerCalculations.convert(refundable, from: parent.currency, to: sourcePocket, rates: state.settings.rates)

        let reversal = LedgerTransaction(
            id: UUID(),
            userID: parent.userID,
            type: .income,
            accountID: parent.accountID,
            destinationAccountID: nil,
            amount: refundable,
            currency: parent.currency,
            accountAmount: exactSourceAmount,
            destinationAmount: nil,
            accountCurrency: parent.accountCurrency,
            destinationAccountCurrency: nil,
            categoryID: .refund,
            occurredAt: now,
            note: "REFUND Installment (\(parent.note ?? "Expense"))",
            exchangeRateAtTransaction: parent.exchangeRateAtTransaction,
            reversalOfTransactionID: parent.id,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil,
            version: 1,
            syncStatus: .pending,
            taxRate: nil,
            taxAmount: 0,
            taxBaseAmount: refundable,
            taxInputMode: .finalAmount,
            isTaxExempt: true
        )
        mutateState { state in
            if let index = state.transactions.firstIndex(where: { $0.id == parent.id }) {
                state.transactions[index].reversalTransactionID = reversal.id
                state.transactions[index].updatedAt = now
                state.transactions[index].version += 1
                state.transactions[index].syncStatus = .pending
            }
            state.transactions.insert(reversal, at: 0)
        }
        scheduleSave()
        return reversal
    }

    @discardableResult
    func configureLinked(_ id: UUID, mode: TransactionGroupMode, people: Int = 2, plan: InstallmentPlanMetadata? = nil) -> Bool {
        switch mode {
        case .split:
            return configureSplit(parentID: id, people: people)
        case .reimbursement:
            return configureReimbursement(parentID: id)
        case .installment:
            guard let plan else { return false }
            return configureInstallment(parentID: id, plan: plan)
        case .refund:
            guard let parent = state.transactions.first(where: { $0.id == id }) else { return false }
            return convertExpenseToRefundGroup(parent)
        case .combinedPayment:
            return false
        }
    }

    // MARK: - Combined Payment Operations

    func canCombine(_ a: LedgerTransaction, _ b: LedgerTransaction) -> Bool {
        guard a.id != b.id, a.deletedAt == nil, b.deletedAt == nil else { return false }
        guard a.type == .expense, b.type == .expense else { return false }
        guard a.parentTransactionID == nil, a.groupMode == nil, a.purchaseSessionID == nil else { return false }
        guard b.parentTransactionID == nil, b.groupMode == nil, b.purchaseSessionID == nil else { return false }
        guard a.reversalOfTransactionID == nil, a.reversalTransactionID == nil else { return false }
        guard b.reversalOfTransactionID == nil, b.reversalTransactionID == nil else { return false }
        guard a.accountID != b.accountID else { return false }
        guard a.categoryID == b.categoryID else { return false }
        return true
    }

    @discardableResult
    func combineTransactions(first: LedgerTransaction, second: LedgerTransaction) -> LedgerTransaction? {
        guard canCombine(first, second) else { return nil }
        guard let idx1 = state.transactions.firstIndex(where: { $0.id == first.id }),
              let idx2 = state.transactions.firstIndex(where: { $0.id == second.id }) else { return nil }
        undoState = state
        let now = Date.now
        let parentCurrency = first.currency == second.currency ? first.currency : state.settings.baseCurrency
        let amount1 = LedgerCalculations.convert(first.recognizedExpenseAmount, from: first.currency, to: parentCurrency, rates: state.settings.rates)
        let amount2 = LedgerCalculations.convert(second.recognizedExpenseAmount, from: second.currency, to: parentCurrency, rates: state.settings.rates)
        let parentID = UUID()

        var parent = LedgerTransaction(
            id: parentID,
            userID: state.settings.userID,
            type: .expense,
            accountID: first.accountID,
            destinationAccountID: nil,
            amount: amount1 + amount2,
            currency: parentCurrency,
            accountAmount: 0,
            destinationAmount: nil,
            accountCurrency: nil,
            destinationAccountCurrency: nil,
            categoryID: first.categoryID,
            occurredAt: max(first.occurredAt, second.occurredAt),
            note: nil,
            exchangeRateAtTransaction: CurrencyRates.reference(parentCurrency, in: state.settings.rates) ?? 1,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil,
            version: 1,
            syncStatus: .pending
        )
        parent.groupMode = .combinedPayment
        parent.isTaxExempt = true
        parent.taxAmount = 0
        parent.taxBaseAmount = 0

        mutateState { state in
            state.transactions[idx1].parentTransactionID = parentID
            state.transactions[idx1].linkedTransactionKind = .combinedPaymentItem
            state.transactions[idx1].updatedAt = now
            state.transactions[idx1].version += 1
            state.transactions[idx1].syncStatus = .pending

            state.transactions[idx2].parentTransactionID = parentID
            state.transactions[idx2].linkedTransactionKind = .combinedPaymentItem
            state.transactions[idx2].updatedAt = now
            state.transactions[idx2].version += 1
            state.transactions[idx2].syncStatus = .pending

            state.transactions.insert(parent, at: 0)
        }
        scheduleSave()
        return parent
    }

    func canAddToCombinedPayment(item: LedgerTransaction, parent: LedgerTransaction) -> Bool {
        guard parent.groupMode == .combinedPayment, parent.deletedAt == nil, !TransactionSemantics.combinedPaymentHasActiveRefund(parent, in: state) else { return false }
        guard item.id != parent.id, item.deletedAt == nil, item.type == .expense else { return false }
        guard item.parentTransactionID == nil, item.groupMode == nil, item.purchaseSessionID == nil else { return false }
        guard item.reversalOfTransactionID == nil, item.reversalTransactionID == nil else { return false }
        guard item.categoryID == parent.categoryID else { return false }
        return true
    }

    @discardableResult
    func addTransactionToCombinedPayment(_ item: LedgerTransaction, into parent: LedgerTransaction) -> Bool {
        guard canAddToCombinedPayment(item: item, parent: parent) else { return false }
        guard let parentIdx = state.transactions.firstIndex(where: { $0.id == parent.id }),
              let itemIdx = state.transactions.firstIndex(where: { $0.id == item.id }) else { return false }
        undoState = state
        let now = Date.now

        mutateState { state in
            state.transactions[itemIdx].parentTransactionID = parent.id
            state.transactions[itemIdx].linkedTransactionKind = .combinedPaymentItem
            state.transactions[itemIdx].updatedAt = now
            state.transactions[itemIdx].version += 1
            state.transactions[itemIdx].syncStatus = .pending

            let allChildren = state.transactions.filter {
                $0.parentTransactionID == parent.id && $0.linkedTransactionKind == .combinedPaymentItem && $0.deletedAt == nil
            }
            let parentCurrency = state.transactions[parentIdx].currency
            let newAmount = allChildren.reduce(0.0) { sum, child in
                sum + LedgerCalculations.convert(child.recognizedExpenseAmount, from: child.currency, to: parentCurrency, rates: state.settings.rates)
            }
            state.transactions[parentIdx].amount = newAmount
            state.transactions[parentIdx].occurredAt = max(state.transactions[parentIdx].occurredAt, item.occurredAt)
            state.transactions[parentIdx].updatedAt = now
            state.transactions[parentIdx].version += 1
            state.transactions[parentIdx].syncStatus = .pending
        }

        scheduleSave()
        return true
    }

    func canDetachCombinedPaymentChild(childID: UUID) -> Bool {
        guard let child = state.transactions.first(where: { $0.id == childID && $0.deletedAt == nil }) else { return false }
        guard child.linkedTransactionKind == .combinedPaymentItem, let parentID = child.parentTransactionID else { return false }
        guard let parent = state.transactions.first(where: { $0.id == parentID && $0.deletedAt == nil && $0.groupMode == .combinedPayment }) else { return false }
        guard !TransactionSemantics.combinedPaymentHasActiveRefund(parent, in: state) else { return false }
        return true
    }

    @discardableResult
    func detachCombinedPaymentChild(childID: UUID, now: Date = .now) -> Bool {
        guard canDetachCombinedPaymentChild(childID: childID) else { return false }
        guard let childIndex = state.transactions.firstIndex(where: { $0.id == childID }) else { return false }
        guard let parentID = state.transactions[childIndex].parentTransactionID,
              let parentIndex = state.transactions.firstIndex(where: { $0.id == parentID }) else { return false }

        undoState = state

        mutateState { state in
            // Detach child: restore to standalone transaction
            state.transactions[childIndex].parentTransactionID = nil
            state.transactions[childIndex].linkedTransactionKind = nil
            state.transactions[childIndex].linkedTransactionIndex = nil
            state.transactions[childIndex].linkedStatus = nil
            state.transactions[childIndex].updatedAt = now
            state.transactions[childIndex].version += 1
            state.transactions[childIndex].syncStatus = .pending

            let remainingChildren = state.transactions.filter {
                $0.parentTransactionID == parentID && $0.linkedTransactionKind == .combinedPaymentItem && $0.deletedAt == nil
            }

            if remainingChildren.count >= 2 {
                let parentCurrency = state.transactions[parentIndex].currency
                let newAmount = remainingChildren.reduce(0.0) { sum, child in
                    sum + LedgerCalculations.convert(child.recognizedExpenseAmount, from: child.currency, to: parentCurrency, rates: state.settings.rates)
                }
                state.transactions[parentIndex].amount = newAmount
                state.transactions[parentIndex].occurredAt = remainingChildren.map(\.occurredAt).max() ?? state.transactions[parentIndex].occurredAt
                state.transactions[parentIndex].updatedAt = now
                state.transactions[parentIndex].version += 1
                state.transactions[parentIndex].syncStatus = .pending
            } else if remainingChildren.count == 1 {
                // Auto-dissolve group: remaining child becomes standalone, synthetic parent soft-deleted
                if let lastChildIndex = state.transactions.firstIndex(where: { $0.id == remainingChildren[0].id }) {
                    state.transactions[lastChildIndex].parentTransactionID = nil
                    state.transactions[lastChildIndex].linkedTransactionKind = nil
                    state.transactions[lastChildIndex].linkedTransactionIndex = nil
                    state.transactions[lastChildIndex].linkedStatus = nil
                    state.transactions[lastChildIndex].updatedAt = now
                    state.transactions[lastChildIndex].version += 1
                    state.transactions[lastChildIndex].syncStatus = .pending
                }
                markDeleted(in: &state, at: parentIndex, date: now)
            } else {
                markDeleted(in: &state, at: parentIndex, date: now)
            }
        }

        scheduleSave()
        return true
    }

    func ungroupCombinedPayment(_ parent: LedgerTransaction) {
        guard parent.groupMode == .combinedPayment, parent.deletedAt == nil, !TransactionSemantics.combinedPaymentHasActiveRefund(parent, in: state) else { return }
        guard let parentIndex = state.transactions.firstIndex(where: { $0.id == parent.id }) else { return }
        undoState = state
        let now = Date.now
        mutateState { state in
            markDeleted(in: &state, at: parentIndex, date: now)

            for idx in state.transactions.indices {
                if state.transactions[idx].parentTransactionID == parent.id && state.transactions[idx].deletedAt == nil {
                    if state.transactions[idx].linkedTransactionKind == .combinedPaymentItem {
                        state.transactions[idx].parentTransactionID = nil
                        state.transactions[idx].linkedTransactionKind = nil
                        state.transactions[idx].updatedAt = now
                        state.transactions[idx].version += 1
                        state.transactions[idx].syncStatus = .pending
                    } else {
                        markDeleted(in: &state, at: idx, date: now)
                    }
                }
            }
        }
        scheduleSave()
    }

    @discardableResult
    func refundCombinedPayment(parentID: UUID, now: Date = .now) -> Bool {
        guard let parentIndex = state.transactions.firstIndex(where: { $0.id == parentID && $0.deletedAt == nil }) else { return false }
        let parent = state.transactions[parentIndex]
        guard TransactionSemantics.combinedPaymentIsRefundable(parent, in: state) else { return false }
        let children = state.transactions.filter {
            $0.parentTransactionID == parent.id && $0.linkedTransactionKind == .combinedPaymentItem && $0.deletedAt == nil
        }
        guard !children.isEmpty else { return false }

        undoState = state

        let totalRefundAmount = children.reduce(0.0) { sum, child in
            sum + LedgerCalculations.convert(child.recognizedExpenseAmount, from: child.currency, to: parent.currency, rates: state.settings.rates)
        }
        var visibleRefund = LedgerTransaction(
            id: UUID(),
            userID: state.settings.userID,
            type: .income,
            accountID: parent.accountID,
            destinationAccountID: nil,
            amount: totalRefundAmount,
            currency: parent.currency,
            accountAmount: 0,
            destinationAmount: nil,
            accountCurrency: nil,
            destinationAccountCurrency: nil,
            categoryID: parent.categoryID,
            occurredAt: now,
            note: "Combined Payment Refund",
            exchangeRateAtTransaction: parent.exchangeRateAtTransaction,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil,
            version: 1,
            syncStatus: .pending
        )
        visibleRefund.parentTransactionID = parent.id
        visibleRefund.linkedTransactionKind = .combinedPaymentRefund
        visibleRefund.linkedStatus = .completed
        visibleRefund.completedAt = now
        visibleRefund.isTaxExempt = true

        var supportReversals: [LedgerTransaction] = []
        for child in children {
            var support = LedgerTransaction(
                id: UUID(),
                userID: state.settings.userID,
                type: .income,
                accountID: child.accountID,
                destinationAccountID: nil,
                amount: child.recognizedExpenseAmount,
                currency: child.currency,
                accountAmount: child.accountAmount ?? child.recognizedExpenseAmount,
                destinationAmount: nil,
                accountCurrency: child.accountCurrency,
                destinationAccountCurrency: nil,
                categoryID: child.categoryID,
                occurredAt: now,
                note: "Refund support for \(child.note ?? "payment")",
                exchangeRateAtTransaction: child.exchangeRateAtTransaction,
                createdAt: now,
                updatedAt: now,
                deletedAt: nil,
                version: 1,
                syncStatus: .pending
            )
            support.parentTransactionID = parent.id
            support.linkedTransactionKind = .combinedPaymentRefundSupport
            support.linkedStatus = .completed
            support.completedAt = now
            support.taxAmount = child.taxAmount
            support.taxRate = child.taxRate
            support.taxBaseAmount = child.taxBaseAmount
            support.taxInputMode = child.taxInputMode
            support.isTaxExempt = child.isTaxExempt
            supportReversals.append(support)
        }

        mutateState { state in
            state.transactions[parentIndex].linkedStatus = .completed
            state.transactions[parentIndex].completedAt = now
            state.transactions[parentIndex].updatedAt = now
            state.transactions[parentIndex].version += 1
            state.transactions[parentIndex].syncStatus = .pending

            state.transactions.insert(visibleRefund, at: 0)
            state.transactions.append(contentsOf: supportReversals)
        }
        undoMessage = "Combined Payment refunded"
        scheduleSave()
        return true
    }
}
