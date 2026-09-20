import Foundation

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum TransactionCreationOrigin: Sendable {
    case user
    case purchase
    case recurring
    case system
}

extension LedgerStore {
    /// Resolves a requested currency pocket against an account.
    /// Single-currency accounts only ever post to their primary currency; a multi-currency
    /// account rejects an unknown pocket rather than silently redirecting the money.
    private func resolvedPocket(_ requested: CurrencyCode?, for account: LedgerAccount) -> CurrencyCode? {
        guard let requested else { return account.currency }
        guard account.usesCurrencyPockets else { return account.currency }
        return account.pocketCurrencies.contains(requested) ? requested : nil
    }

    func buildTransaction(
        type: LedgerTransactionType,
        accountID: UUID,
        destinationAccountID: UUID?,
        amount: Double,
        currency: CurrencyCode,
        categoryID: LedgerCategoryID,
        occurredAt: Date,
        note: String?,
        noteAttachmentID: String? = nil,
        purchaseSessionID: UUID? = nil,
        purchaseItemID: UUID? = nil,
        recurringRuleID: UUID? = nil,
        accountCurrency: CurrencyCode? = nil,
        accountAmount: Double? = nil,
        destinationAccountCurrency: CurrencyCode? = nil,
        destinationAmount: Double? = nil,
        taxSnapshot: TaxSnapshot? = nil,
        couponSnapshot: CouponTransactionSnapshot? = nil,
        linkedRecovery: Bool = false,
        in snapshot: LedgerState
    ) throws -> LedgerTransaction {
        guard !categoryID.isSystemLinked || linkedRecovery else { throw PurchaseFinalizationError.invalidItem }
        guard amount.isFinite, amount > 0, CurrencyRates.reference(currency, in: snapshot.settings.rates) != nil, let source = snapshot.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }) else { throw PurchaseFinalizationError.invalidItem }
        let destination = destinationAccountID.flatMap { id in snapshot.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) }
        guard type != .transfer || (destination != nil && TransactionSemantics.validTransfer(source: source, destinationID: destinationAccountID, sourceCurrency: accountCurrency, destinationCurrency: destinationAccountCurrency)) else { throw PurchaseFinalizationError.invalidItem }
        let rates = snapshot.settings.rates
        guard CurrencyRates.reference(source.currency, in: rates) != nil,
              destination.map({ CurrencyRates.reference($0.currency, in: rates) != nil }) ?? true else { throw PurchaseFinalizationError.missingRate }
        guard let sourcePocket = resolvedPocket(accountCurrency, for: source) else { throw PurchaseFinalizationError.invalidItem }
        let resolvedAccountAmount = accountAmount ?? LedgerCalculations.convert(amount, from: currency, to: sourcePocket, rates: rates)
        guard resolvedAccountAmount.isFinite else { throw PurchaseFinalizationError.invalidItem }
        var resolvedDestinationPocket: CurrencyCode?
        var resolvedDestinationAmount: Double?
        if type == .transfer, let destination {
            guard let destinationPocket = resolvedPocket(destinationAccountCurrency, for: destination) else { throw PurchaseFinalizationError.invalidItem }
            resolvedDestinationPocket = destination.usesCurrencyPockets ? destinationPocket : nil
            let value = destinationAmount ?? LedgerCalculations.convert(amount, from: currency, to: destinationPocket, rates: rates)
            guard value.isFinite else { throw PurchaseFinalizationError.invalidItem }
            resolvedDestinationAmount = value
        }
        var item = LedgerTransaction(id: UUID(), userID: snapshot.settings.userID, type: type, accountID: source.id, destinationAccountID: type == .transfer ? destination?.id : nil, amount: amount, currency: currency, accountAmount: resolvedAccountAmount, destinationAmount: resolvedDestinationAmount, accountCurrency: source.usesCurrencyPockets ? sourcePocket : nil, destinationAccountCurrency: resolvedDestinationPocket, categoryID: type == .transfer ? .other : categoryID, occurredAt: occurredAt, note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, noteAttachmentID: noteAttachmentID, exchangeRateAtTransaction: CurrencyRates.reference(currency, in: rates) ?? 1, purchaseSessionID: purchaseSessionID, purchaseItemID: purchaseItemID, recurringRuleID: recurringRuleID, couponSnapshot: couponSnapshot, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
        item.applyTax(taxSnapshot)
        return item
    }

    @discardableResult
    func addTransaction(
        type: LedgerTransactionType,
        accountID: UUID,
        destinationAccountID: UUID?,
        amount: Double,
        currency: CurrencyCode,
        categoryID: LedgerCategoryID,
        occurredAt: Date,
        note: String?,
        noteAttachmentID: String? = nil,
        purchaseSessionID: UUID? = nil,
        purchaseItemID: UUID? = nil,
        recurringRuleID: UUID? = nil,
        accountCurrency: CurrencyCode? = nil,
        accountAmount: Double? = nil,
        destinationAccountCurrency: CurrencyCode? = nil,
        destinationAmount: Double? = nil,
        taxSnapshot: TaxSnapshot? = nil,
        couponSnapshot: CouponTransactionSnapshot? = nil,
        linkedRecovery: Bool = false,
        origin: TransactionCreationOrigin = .user
    ) -> LedgerTransaction? {
        guard let item = try? buildTransaction(type: type, accountID: accountID, destinationAccountID: destinationAccountID, amount: amount, currency: currency, categoryID: categoryID, occurredAt: occurredAt, note: note, noteAttachmentID: noteAttachmentID, purchaseSessionID: purchaseSessionID, purchaseItemID: purchaseItemID, recurringRuleID: recurringRuleID, accountCurrency: accountCurrency, accountAmount: accountAmount, destinationAccountCurrency: destinationAccountCurrency, destinationAmount: destinationAmount, taxSnapshot: taxSnapshot, couponSnapshot: couponSnapshot, linkedRecovery: linkedRecovery, in: state) else { return nil }
        mutateState { state in
            state.transactions.insert(item, at: 0)

            // Mark coupon as used if applied
            if let snapshot = couponSnapshot,
               let accIdx = state.accounts.firstIndex(where: { $0.id == item.accountID }),
               var coupons = state.accounts[accIdx].coupons,
               let cIdx = coupons.firstIndex(where: { $0.id == snapshot.couponID }) {
                coupons[cIdx].usedAt = occurredAt
                coupons[cIdx].linkedTransactionID = item.id
                coupons[cIdx].updatedAt = .now
                state.accounts[accIdx].coupons = coupons
                state.accounts[accIdx].updatedAt = .now
                state.accounts[accIdx].version += 1
                state.accounts[accIdx].syncStatus = .pending
            }
        }

        scheduleSave()
        let recordedItem = item
        let acc = state.accounts.first(where: { $0.id == recordedItem.accountID })
        let cat = state.categories.first(where: { $0.id == recordedItem.categoryID })

        if origin == .user {
            Task {
                do {
                    _ = try await self.persistDurableAsync()
                    let outcome = await RecentTransactionActivityCoordinator.shared.didRecordTransaction(
                        recordedItem,
                        account: acc,
                        category: cat,
                        ledgerBookID: self.activeBookID
                    )
                    switch outcome {
                    case .requestFailed(_, let code, let message):
                        self.recentActivityWarning = "The transaction was saved, but its Live Activity could not start (\(code): \(message))."
                    case .activitiesDisabled:
                        self.recentActivityWarning = "Live Activities are disabled for Finsy."
                    case .started, .skippedPurchaseTransaction:
                        break
                    }
                } catch {
                    // Persistence failed; do not start activity
                }
            }
        }
        return item
    }

    func updateTransaction(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }), !state.transactions[index].isLockedByReversal, let source = state.accounts.first(where: { $0.id == item.accountID }) else { return }
        guard item.amount.isFinite, item.amount > 0, source.deletedAt == nil else { return }
        guard let sourcePocket = resolvedPocket(item.accountCurrency, for: source) else { return }
        let original = state.transactions[index]
        guard item.type != .transfer || TransactionSemantics.validTransfer(source: source, destinationID: item.destinationAccountID, sourceCurrency: item.accountCurrency, destinationCurrency: item.destinationAccountCurrency) else { return }
        guard original.groupMode == nil else { return }
        guard original.parentTransactionID == nil || (item.type == original.type && item.categoryID == original.categoryID) else { return }
        guard original.linkedTransactionKind != .installment || (source.type == .credit && item.currency == original.currency) else { return }
        let keepsFX = item.currency == original.currency && item.accountID == original.accountID &&
            item.destinationAccountID == original.destinationAccountID && item.type == original.type &&
            item.accountCurrency == original.accountCurrency && item.destinationAccountCurrency == original.destinationAccountCurrency
        let scale = original.amount > 0 ? item.amount / original.amount : 1
        var updated = item
        updated.parentTransactionID = original.parentTransactionID
        updated.linkedTransactionKind = original.linkedTransactionKind
        updated.linkedTransactionIndex = original.linkedTransactionIndex
        updated.groupMode = original.groupMode
        updated.splitMetadata = original.splitMetadata
        updated.installmentMetadata = original.installmentMetadata
        updated.linkedStatus = original.linkedStatus
        updated.completedAt = original.completedAt
        updated.couponSnapshot = item.couponSnapshot

        // Automatic completion on edit/save for pending child records:
        if original.linkedTransactionKind == .splitSettlement && original.linkedStatus == .pending {
            updated.linkedStatus = .completed
            updated.completedAt = .now
        } else if original.linkedTransactionKind == .reimbursementIncome && original.linkedStatus == .pending {
            updated.linkedStatus = .completed
            updated.completedAt = .now
        } else if original.linkedTransactionKind == .installment && !original.isEffectivelyCompleted {
            updated.linkedStatus = .completed
            updated.completedAt = .now
        }

        // Split child tax proportion recalculation
        if original.linkedTransactionKind == .splitSelfExpense,
           let parentID = original.parentTransactionID,
           let parent = state.transactions.first(where: { $0.id == parentID }),
           parent.amount > 0 {
            let originalTax = parent.taxAmount ?? 0
            let ratio = min(1.0, max(0.0, item.amount / parent.amount))
            updated.taxAmount = TaxCalculations.rounded(originalTax * ratio)
            if let originalBase = parent.taxBaseAmount {
                updated.taxBaseAmount = TaxCalculations.rounded(originalBase * ratio)
            }
        } else if original.linkedTransactionKind == .splitSettlement || original.linkedTransactionKind == .reimbursementIncome || original.linkedTransactionKind == .refundIncome {
            updated.applyTax(TaxCalculations.resolve(entered: item.amount, type: .income, rate: 0, mode: .finalAmount, exempt: true))
        } else if original.linkedTransactionKind == .installment {
            updated.taxRate = original.taxRate; updated.taxAmount = original.taxAmount
            updated.taxBaseAmount = original.taxBaseAmount; updated.taxInputMode = original.taxInputMode; updated.isTaxExempt = original.isTaxExempt
        } else if updated.type == .transfer {
            updated.applyTax(nil)
        }

        updated.accountCurrency = source.usesCurrencyPockets ? sourcePocket : nil
        if keepsFX, item.accountAmount == original.accountAmount, let existing = original.accountAmount {
            updated.accountAmount = existing * scale
        } else if let supplied = item.accountAmount, supplied.isFinite {
            updated.accountAmount = supplied
        } else {
            updated.accountAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: sourcePocket, rates: state.settings.rates)
        }
        if item.type == .transfer, let destinationID = item.destinationAccountID, let destination = state.accounts.first(where: { $0.id == destinationID }) {
            guard destination.deletedAt == nil, let destinationPocket = resolvedPocket(item.destinationAccountCurrency, for: destination) else { return }
            updated.destinationAccountCurrency = destination.usesCurrencyPockets ? destinationPocket : nil
            if keepsFX, item.destinationAmount == original.destinationAmount, let existing = original.destinationAmount {
                updated.destinationAmount = existing * scale
            } else if let supplied = item.destinationAmount, supplied.isFinite {
                updated.destinationAmount = supplied
            } else {
                updated.destinationAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: destinationPocket, rates: state.settings.rates)
            }
            updated.categoryID = .other
        } else {
            updated.destinationAccountID = nil
            updated.destinationAmount = nil
            updated.destinationAccountCurrency = nil
        }
        updated.exchangeRateAtTransaction = item.currency == original.currency ? original.exchangeRateAtTransaction : (CurrencyRates.reference(item.currency, in: state.settings.rates) ?? 1)
        updated.updatedAt = .now
        updated.version += 1
        updated.syncStatus = .pending

        mutateState { state in
            // Handle coupon release / consumption on change
            if original.couponSnapshot?.couponID != item.couponSnapshot?.couponID {
                if let oldCouponID = original.couponSnapshot?.couponID,
                   let accIdx = state.accounts.firstIndex(where: { $0.id == original.accountID }),
                   var coupons = state.accounts[accIdx].coupons,
                   let cIdx = coupons.firstIndex(where: { $0.id == oldCouponID }) {
                    coupons[cIdx].usedAt = nil
                    coupons[cIdx].linkedTransactionID = nil
                    coupons[cIdx].updatedAt = .now
                    state.accounts[accIdx].coupons = coupons
                    state.accounts[accIdx].updatedAt = .now
                    state.accounts[accIdx].version += 1
                    state.accounts[accIdx].syncStatus = .pending
                }
                if let newSnapshot = item.couponSnapshot,
                   let accIdx = state.accounts.firstIndex(where: { $0.id == item.accountID }),
                   var coupons = state.accounts[accIdx].coupons,
                   let cIdx = coupons.firstIndex(where: { $0.id == newSnapshot.couponID }) {
                    coupons[cIdx].usedAt = item.occurredAt
                    coupons[cIdx].linkedTransactionID = item.id
                    coupons[cIdx].updatedAt = .now
                    state.accounts[accIdx].coupons = coupons
                    state.accounts[accIdx].updatedAt = .now
                    state.accounts[accIdx].version += 1
                    state.accounts[accIdx].syncStatus = .pending
                }
            }

            state.transactions[index] = updated

            // If this child belongs to a Combined Payment group, update the parent's aggregate amount
            if let parentID = updated.parentTransactionID,
               let parentIndex = state.transactions.firstIndex(where: { $0.id == parentID && $0.groupMode == .combinedPayment && $0.deletedAt == nil }) {
                let allChildren = state.transactions.filter {
                    $0.parentTransactionID == parentID && $0.linkedTransactionKind == .combinedPaymentItem && $0.deletedAt == nil
                }
                let parentCurrency = state.transactions[parentIndex].currency
                let newAmount = allChildren.reduce(0.0) { sum, child in
                    sum + LedgerCalculations.convert(child.recognizedExpenseAmount, from: child.currency, to: parentCurrency, rates: state.settings.rates)
                }
                state.transactions[parentIndex].amount = newAmount
                state.transactions[parentIndex].updatedAt = .now
                state.transactions[parentIndex].version += 1
                state.transactions[parentIndex].syncStatus = .pending
            }
        }

        scheduleSave()
    }

    func deleteTransaction(_ item: LedgerTransaction) {
        // Combined Payment child deletion
        if item.linkedTransactionKind == .combinedPaymentItem, item.parentTransactionID != nil {
            deleteCombinedPaymentChild(item)
            return
        }

        // Group children never support Delete, except Purchase children
        guard item.parentTransactionID == nil || item.purchaseSessionID != nil else { return }
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }) else { return }
        let now = Date.now

        var txSnapshots: [UUID: LedgerTransaction] = [item.id: state.transactions[index]]
        var expectedTxVersions: [UUID: Int] = [item.id: state.transactions[index].version + 1]
        var accountSnapshots: [UUID: LedgerAccount] = [:]
        var expectedAccVersions: [UUID: Int] = [:]

        // Capture accounts modified if coupon is present
        if let couponID = state.transactions[index].couponSnapshot?.couponID,
           let accIdx = state.accounts.firstIndex(where: { $0.id == state.transactions[index].accountID }),
           state.accounts[accIdx].coupons?.contains(where: { $0.id == couponID }) == true {
            let acc = state.accounts[accIdx]
            accountSnapshots[acc.id] = acc
            expectedAccVersions[acc.id] = acc.version + 1
        }

        var deletedSnapshot = [state.transactions[index]]

        mutateState { state in
            // Soft-delete entire group if this is a group parent
            if item.groupMode != nil {
                for childIndex in state.transactions.indices where state.transactions[childIndex].parentTransactionID == item.id && state.transactions[childIndex].deletedAt == nil {
                    let child = state.transactions[childIndex]
                    deletedSnapshot.append(child)
                    txSnapshots[child.id] = child
                    expectedTxVersions[child.id] = child.version + 1
                    if let cID = child.couponSnapshot?.couponID,
                       let accIdx = state.accounts.firstIndex(where: { $0.id == child.accountID }),
                       accountSnapshots[child.accountID] == nil {
                        let acc = state.accounts[accIdx]
                        accountSnapshots[acc.id] = acc
                        expectedAccVersions[acc.id] = acc.version + 1
                    }
                    releaseCouponIfPresent(in: &state, on: state.transactions[childIndex])
                    markDeleted(in: &state, at: childIndex, date: now)
                }
            }

            releaseCouponIfPresent(in: &state, on: state.transactions[index])

            if let originalID = state.transactions[index].reversalOfTransactionID,
               let originalIndex = state.transactions.firstIndex(where: { $0.id == originalID }) {
                let orig = state.transactions[originalIndex]
                deletedSnapshot.append(orig)
                txSnapshots[orig.id] = orig
                expectedTxVersions[orig.id] = orig.version + 1
                state.transactions[originalIndex].reversalTransactionID = nil
                state.transactions[originalIndex].updatedAt = now
                state.transactions[originalIndex].version += 1
                state.transactions[originalIndex].syncStatus = .pending
            } else if let reversalID = state.transactions[index].reversalTransactionID,
                      let reversalIndex = state.transactions.firstIndex(where: { $0.id == reversalID && $0.deletedAt == nil }) {
                let rev = state.transactions[reversalIndex]
                deletedSnapshot.append(rev)
                txSnapshots[rev.id] = rev
                expectedTxVersions[rev.id] = rev.version + 1
                markDeleted(in: &state, at: reversalIndex, date: now)
            }
            markDeleted(in: &state, at: index, date: now)
        }

        activeUndoOperation = LedgerUndoOperation(
            message: "Transaction deleted",
            transactionSnapshots: txSnapshots,
            accountSnapshots: accountSnapshots,
            expectedTransactionVersions: expectedTxVersions,
            expectedAccountVersions: expectedAccVersions
        )
        undoTransactions = deletedSnapshot
        undoMessage = "Transaction deleted"
        scheduleSave()
    }

    private func releaseCouponIfPresent(in state: inout LedgerState, on transaction: LedgerTransaction) {
        guard let couponID = transaction.couponSnapshot?.couponID,
              let accIdx = state.accounts.firstIndex(where: { $0.id == transaction.accountID }),
              var coupons = state.accounts[accIdx].coupons,
              let cIdx = coupons.firstIndex(where: { $0.id == couponID }) else { return }
        coupons[cIdx].usedAt = nil
        coupons[cIdx].linkedTransactionID = nil
        coupons[cIdx].updatedAt = .now
        state.accounts[accIdx].coupons = coupons
        state.accounts[accIdx].updatedAt = .now
        state.accounts[accIdx].version += 1
        state.accounts[accIdx].syncStatus = .pending
    }

    private func deleteCombinedPaymentChild(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id && $0.deletedAt == nil }) else { return }
        guard let parentID = item.parentTransactionID,
              let parentIndex = state.transactions.firstIndex(where: { $0.id == parentID && $0.deletedAt == nil }) else { return }
        let now = Date.now

        var txSnapshots: [UUID: LedgerTransaction] = [:]
        var expectedTxVersions: [UUID: Int] = [:]
        var accountSnapshots: [UUID: LedgerAccount] = [:]
        var expectedAccVersions: [UUID: Int] = [:]

        txSnapshots[item.id] = state.transactions[index]
        expectedTxVersions[item.id] = state.transactions[index].version + 1

        txSnapshots[parentID] = state.transactions[parentIndex]
        expectedTxVersions[parentID] = state.transactions[parentIndex].version + 1

        if let couponID = item.couponSnapshot?.couponID,
           let accIdx = state.accounts.firstIndex(where: { $0.id == item.accountID }) {
            let acc = state.accounts[accIdx]
            accountSnapshots[acc.id] = acc
            expectedAccVersions[acc.id] = acc.version + 1
        }

        let remainingChildren = state.transactions.filter {
            $0.parentTransactionID == parentID && $0.linkedTransactionKind == .combinedPaymentItem && $0.deletedAt == nil
        }
        for child in remainingChildren {
            txSnapshots[child.id] = child
            expectedTxVersions[child.id] = child.version + 1
        }

        var message = "Payment removed from Combined Payment"

        mutateState { state in
            releaseCouponIfPresent(in: &state, on: state.transactions[index])
            markDeleted(in: &state, at: index, date: now)

            let rem = state.transactions.filter {
                $0.parentTransactionID == parentID && $0.linkedTransactionKind == .combinedPaymentItem && $0.deletedAt == nil
            }

            if rem.count >= 2 {
                let parentCurrency = state.transactions[parentIndex].currency
                let newAmount = rem.reduce(0.0) { sum, child in
                    sum + LedgerCalculations.convert(child.recognizedExpenseAmount, from: child.currency, to: parentCurrency, rates: state.settings.rates)
                }
                state.transactions[parentIndex].amount = newAmount
                state.transactions[parentIndex].updatedAt = now
                state.transactions[parentIndex].version += 1
                state.transactions[parentIndex].syncStatus = .pending
                message = "Payment removed from Combined Payment"
            } else if rem.count == 1 {
                if let lastChildIndex = state.transactions.firstIndex(where: { $0.id == rem[0].id }) {
                    state.transactions[lastChildIndex].parentTransactionID = nil
                    state.transactions[lastChildIndex].linkedTransactionKind = nil
                    state.transactions[lastChildIndex].updatedAt = now
                    state.transactions[lastChildIndex].version += 1
                    state.transactions[lastChildIndex].syncStatus = .pending
                }
                markDeleted(in: &state, at: parentIndex, date: now)
                for idx in state.transactions.indices where state.transactions[idx].parentTransactionID == parentID && state.transactions[idx].deletedAt == nil {
                    markDeleted(in: &state, at: idx, date: now)
                }
                message = "Combined Payment dissolved"
            } else {
                markDeleted(in: &state, at: parentIndex, date: now)
                message = "Combined Payment deleted"
            }
        }

        activeUndoOperation = LedgerUndoOperation(
            message: message,
            transactionSnapshots: txSnapshots,
            accountSnapshots: accountSnapshots,
            expectedTransactionVersions: expectedTxVersions,
            expectedAccountVersions: expectedAccVersions
        )
        undoTransactions = Array(txSnapshots.values)
        undoMessage = message
        scheduleSave()
    }

    @discardableResult
    func applyUndo(_ operation: LedgerUndoOperation) -> Bool {
        // Version guards: ensure none of the captured entities were subsequently modified incompatibly
        for (id, expectedVersion) in operation.expectedTransactionVersions {
            guard let current = state.transactions.first(where: { $0.id == id }) else { return false }
            if current.version != expectedVersion { return false }
        }
        for (id, expectedVersion) in operation.expectedAccountVersions {
            guard let current = state.accounts.first(where: { $0.id == id }) else { return false }
            if current.version != expectedVersion { return false }
        }

        let now = Date.now
        mutateState { state in
            for (id, snapshot) in operation.transactionSnapshots {
                if let index = state.transactions.firstIndex(where: { $0.id == id }) {
                    var restored = snapshot
                    restored.updatedAt = now
                    restored.version = state.transactions[index].version + 1
                    restored.syncStatus = .pending
                    state.transactions[index] = restored
                } else {
                    var restored = snapshot
                    restored.updatedAt = now
                    restored.version = 1
                    restored.syncStatus = .pending
                    state.transactions.append(restored)
                }
            }

            for id in operation.createdTransactionIDs {
                if let index = state.transactions.firstIndex(where: { $0.id == id }) {
                    markDeleted(in: &state, at: index, date: now)
                }
            }

            for (id, snapshot) in operation.accountSnapshots {
                if let index = state.accounts.firstIndex(where: { $0.id == id }) {
                    var restored = snapshot
                    restored.updatedAt = now
                    restored.version = state.accounts[index].version + 1
                    restored.syncStatus = .pending
                    state.accounts[index] = restored
                }
            }

            for (id, snapshot) in operation.recurringRuleSnapshots {
                var rules = state.recurringRules ?? []
                if let index = rules.firstIndex(where: { $0.id == id }) {
                    rules[index] = snapshot
                } else {
                    rules.append(snapshot)
                }
                state.recurringRules = rules
            }

            for (id, snapshot) in operation.purchaseSessionSnapshots {
                if var sessions = state.purchaseSessions, let index = sessions.firstIndex(where: { $0.id == id }) {
                    sessions[index] = snapshot
                    state.purchaseSessions = sessions
                }
            }
        }
        scheduleSave()
        return true
    }

    func undoDelete() {
        if let op = activeUndoOperation {
            if applyUndo(op) {
                activeUndoOperation = nil
                undoTransactions = []
                undoMessage = nil
            } else {
                presentedError = "Cannot undo: item was subsequently modified."
            }
            return
        }
        guard !undoTransactions.isEmpty else { return }
        let items = undoTransactions
        let now = Date.now
        mutateState { state in
            for item in items {
                if let index = state.transactions.firstIndex(where: { $0.id == item.id }) {
                    var restored = item
                    restored.updatedAt = now
                    restored.version = state.transactions[index].version + 1
                    restored.syncStatus = .pending
                    state.transactions[index] = restored
                }
            }
        }
        undoTransactions = []
        undoMessage = nil
        scheduleSave()
    }

    @discardableResult
    func refundTransaction(_ original: LedgerTransaction) -> LedgerTransaction? {
        guard original.deletedAt == nil, !original.isReversal, original.reversalTransactionID == nil else { return nil }

        // Combined Payment parent refund
        if original.groupMode == .combinedPayment {
            _ = refundCombinedPayment(parentID: original.id)
            return nil
        }

        // Purchase child refund exception: hidden reversal, no refund group
        if original.purchaseSessionID != nil {
            return refundPurchaseChild(original)
        }

        // Installment parent refund: refunds only posted amount so far
        if original.groupMode == .installment {
            return refundInstallmentParent(original)
        }

        // Standalone expense, income or transfer: reversal workflow
        let now = Date.now
        guard let originalIndex = state.transactions.firstIndex(where: { $0.id == original.id && $0.deletedAt == nil }),
              !state.transactions.contains(where: { $0.reversalOfTransactionID == original.id && $0.deletedAt == nil }) else { return nil }
        guard let reversal = RefundEngine.makeReversal(of: original, in: state, now: now) else { return nil }
        mutateState { state in
            state.transactions[originalIndex].reversalTransactionID = reversal.id
            state.transactions[originalIndex].updatedAt = now
            state.transactions[originalIndex].version += 1
            state.transactions[originalIndex].syncStatus = .pending
            state.transactions.insert(reversal, at: 0)
        }
        scheduleSave()
        return reversal
    }


}
