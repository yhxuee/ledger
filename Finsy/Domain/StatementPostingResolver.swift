import Foundation

enum StatementPostingResolver {
    static func resolveUserFacingDescription(
        transaction t: LedgerTransaction,
        isDestinationSide: Bool,
        state: LedgerState,
        index: LedgerIndex? = nil,
        allTransactionsByID: [UUID: LedgerTransaction]? = nil
    ) -> String {
        // 1. Check if note is non-empty and not an internal system note
        if let note = t.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            let lower = note.lowercased()
            if !lower.starts(with: "refund support for") && !lower.contains("combinedpaymentrefundsupport") {
                return note
            }
        }

        // 2. Semantic description
        if t.type == .transfer {
            if let destID = t.destinationAccountID, let destAcc = index?.account(destID) ?? state.accounts.first(where: { $0.id == destID }) {
                if isDestinationSide, let srcAcc = index?.account(t.accountID) ?? state.accounts.first(where: { $0.id == t.accountID }) {
                    return "Transfer from \(srcAcc.name)"
                } else {
                    return "Transfer to \(destAcc.name)"
                }
            }
            return "Transfer"
        }

        if let kind = t.linkedTransactionKind {
            switch kind {
            case .installment:
                if let itemIndex = t.linkedTransactionIndex {
                    let total = t.parentTransactionID.flatMap { pID in
                        (allTransactionsByID?[pID] ?? index?.transaction(pID) ?? state.transactions.first(where: { $0.id == pID }))?.installmentMetadata?.count
                    } ?? 0
                    return total > 0 ? "Installment \(itemIndex) / \(total)" : "Installment \(itemIndex)"
                }
                return "Installment"
            case .splitSelfExpense:
                return "Split Expense"
            case .splitSettlement:
                return "Split Settlement"
            case .reimbursementOriginal:
                return "Reimbursement Pending"
            case .reimbursementIncome:
                return "Reimbursement Settlement"
            case .refundOriginal:
                return "Refunded Purchase"
            case .refundIncome:
                if let pID = t.parentTransactionID, let parent = allTransactionsByID?[pID] ?? index?.transaction(pID) ?? state.transactions.first(where: { $0.id == pID }) {
                    let catName = index?.category(parent.categoryID)?.name ?? state.categories.first(where: { $0.id == parent.categoryID })?.name ?? "Purchase"
                    let pNote = parent.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "Refund · \((pNote != nil && !pNote!.isEmpty) ? pNote! : catName)"
                }
                return "Refund"
            case .combinedPaymentItem:
                return index?.category(t.categoryID)?.name ?? state.categories.first(where: { $0.id == t.categoryID })?.name ?? "General"
            case .combinedPaymentRefund:
                return "Combined Payment Refund"
            case .combinedPaymentRefundSupport:
                if let pID = t.parentTransactionID, let parent = allTransactionsByID?[pID] ?? index?.transaction(pID) ?? state.transactions.first(where: { $0.id == pID }) {
                    let catName = index?.category(parent.categoryID)?.name ?? state.categories.first(where: { $0.id == parent.categoryID })?.name ?? "General"
                    return "Refund · \(catName)"
                }
                return "Refund"
            }
        }

        if t.isReversal {
            if let origID = t.reversalOfTransactionID, let orig = allTransactionsByID?[origID] ?? index?.transaction(origID) ?? state.transactions.first(where: { $0.id == origID }) {
                let catName = index?.category(orig.categoryID)?.name ?? state.categories.first(where: { $0.id == orig.categoryID })?.name ?? "Purchase"
                let oNote = orig.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Refund · \((oNote != nil && !oNote!.isEmpty) ? oNote! : catName)"
            }
            return "Refund"
        }

        // 3. Fallback to Category Name
        return index?.category(t.categoryID)?.name ?? state.categories.first(where: { $0.id == t.categoryID })?.name ?? "General"
    }

    static func resolvePostings(
        transactions: [LedgerTransaction],
        selectedAccountIDs: Set<UUID>,
        baseCurrency: CurrencyCode,
        in state: LedgerState,
        index: LedgerIndex? = nil,
        allTransactionsByID: [UUID: LedgerTransaction]? = nil
    ) -> [MonthlyStatementPosting] {
        var postings: [MonthlyStatementPosting] = []

        for t in transactions {
            guard TransactionSemantics.posts(t) else { continue }

            // 1. Source Account Posting (Debit for Expense / Transfer, Credit for Income)
            if selectedAccountIDs.contains(t.accountID),
               let sourceAccount = index?.account(t.accountID) ?? state.accounts.first(where: { $0.id == t.accountID }) {
                let origCurrency = t.currency
                let origAmount: Double
                switch t.type {
                case .expense:
                    origAmount = t.recognizedExpenseAmount
                case .income, .transfer:
                    origAmount = t.amount
                }

                let sourcePocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
                let nativePosting = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)

                let baseAmount: Double
                let effectiveFX: Double

                if origCurrency == baseCurrency {
                    baseAmount = origAmount
                    effectiveFX = 1.0
                } else if sourcePocket == baseCurrency, let accAmt = t.accountAmount, accAmt.isFinite, accAmt > 0 {
                    baseAmount = accAmt
                    effectiveFX = origAmount > 0.0001 ? baseAmount / origAmount : 1.0
                } else if t.exchangeRateAtTransaction.isFinite, t.exchangeRateAtTransaction > 0 {
                    baseAmount = LedgerCalculations.convertHistorical(origAmount, rate: t.exchangeRateAtTransaction, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = origAmount > 0.0001 ? baseAmount / origAmount : 1.0
                } else {
                    baseAmount = LedgerCalculations.convert(origAmount, from: origCurrency, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = origAmount > 0.0001 ? baseAmount / origAmount : 1.0
                }

                let direction: StatementPostingDirection = (t.type == .income) ? .credit : .debit
                let userDesc = resolveUserFacingDescription(transaction: t, isDestinationSide: false, state: state, index: index, allTransactionsByID: allTransactionsByID)

                postings.append(MonthlyStatementPosting(
                    transactionID: t.id,
                    date: t.occurredAt,
                    accountID: t.accountID,
                    categoryID: t.type == .transfer ? .other : t.categoryID,
                    isTransfer: t.type == .transfer,
                    userDescription: userDesc,
                    originalCurrency: origCurrency,
                    originalAmount: origAmount,
                    baseCurrency: baseCurrency,
                    baseAmount: baseAmount,
                    effectiveFXRate: effectiveFX,
                    direction: direction,
                    pocketCurrency: sourcePocket,
                    nativeAmount: nativePosting
                ))
            }

            // 2. Destination Account Posting (Credit for Transfer)
            if t.type == .transfer,
               let destID = t.destinationAccountID,
               selectedAccountIDs.contains(destID),
               let destAccount = index?.account(destID) ?? state.accounts.first(where: { $0.id == destID }) {
                let destPocket = LedgerCalculations.destinationPocket(t, for: destAccount)
                let nativePosting = LedgerCalculations.destinationPosting(t, for: destAccount, in: state)
                let origCurrency = destPocket
                let origAmount = nativePosting

                let baseAmount: Double
                let effectiveFX: Double

                if destPocket == baseCurrency {
                    baseAmount = nativePosting
                    effectiveFX = 1.0
                } else if let destAmt = t.destinationAmount, destAmt.isFinite, destPocket == baseCurrency {
                    baseAmount = destAmt
                    effectiveFX = 1.0
                } else if t.exchangeRateAtTransaction.isFinite, t.exchangeRateAtTransaction > 0 {
                    let rate = CurrencyRates.reference(destPocket, in: state.settings.rates) ?? t.exchangeRateAtTransaction
                    baseAmount = LedgerCalculations.convertHistorical(nativePosting, rate: rate, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = nativePosting > 0.0001 ? baseAmount / nativePosting : 1.0
                } else {
                    baseAmount = LedgerCalculations.convert(nativePosting, from: destPocket, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = nativePosting > 0.0001 ? baseAmount / nativePosting : 1.0
                }

                let userDesc = resolveUserFacingDescription(transaction: t, isDestinationSide: true, state: state, index: index, allTransactionsByID: allTransactionsByID)

                postings.append(MonthlyStatementPosting(
                    transactionID: t.id,
                    date: t.occurredAt,
                    accountID: destID,
                    categoryID: .other,
                    isTransfer: true,
                    userDescription: userDesc,
                    originalCurrency: destPocket,
                    originalAmount: origAmount,
                    baseCurrency: baseCurrency,
                    baseAmount: baseAmount,
                    effectiveFXRate: effectiveFX,
                    direction: .credit,
                    pocketCurrency: destPocket,
                    nativeAmount: nativePosting
                ))
            }
        }

        return postings.sorted { $0.date < $1.date }
    }
}

