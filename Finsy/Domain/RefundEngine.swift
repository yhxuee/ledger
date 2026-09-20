import Foundation

enum RefundEngine {
    static func makeReversal(of original: LedgerTransaction, in state: LedgerState, now: Date = .now) -> LedgerTransaction? {
        guard original.deletedAt == nil, !original.isReversal, original.groupMode == nil,
              (original.parentTransactionID == nil || original.linkedTransactionKind == .splitSettlement || original.linkedTransactionKind == .reimbursementIncome || (original.linkedTransactionKind == .installment && original.occurredAt <= now)),
              let source = state.accounts.first(where: { $0.id == original.accountID && $0.deletedAt == nil }) else { return nil }
        let categoryName = state.categories.first(where: { $0.id == original.categoryID })?.name ?? "Transaction"
        let trimmedNote = original.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedNote.isEmpty ? categoryName : trimmedNote
        // Exact historical pocket and account-side amounts. A refund never re-prices the
        // original posting with today's FX rate.
        let sourcePocket = LedgerCalculations.sourcePocket(original, for: source)
        let exactSourceAmount = original.accountAmount ?? LedgerCalculations.convert(original.amount, from: original.currency, to: sourcePocket, rates: state.settings.rates)
        switch original.type {
        case .expense, .income:
            var reversal = LedgerTransaction(id: UUID(), userID: original.userID, type: original.type == .expense ? .income : .expense, accountID: original.accountID, destinationAccountID: nil, amount: original.amount, currency: original.currency, accountAmount: exactSourceAmount, destinationAmount: nil, accountCurrency: original.accountCurrency, destinationAccountCurrency: nil, categoryID: original.categoryID, occurredAt: now, note: "REFUND \(title)", exchangeRateAtTransaction: original.exchangeRateAtTransaction, reversalOfTransactionID: original.id, createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .pending)
            reversal.taxRate = original.taxRate
            reversal.taxAmount = original.taxAmount
            reversal.taxBaseAmount = original.taxBaseAmount
            reversal.taxInputMode = original.taxInputMode
            reversal.isTaxExempt = original.isTaxExempt
            if let parentID = original.parentTransactionID {
                reversal.parentTransactionID = parentID
                reversal.linkedTransactionKind = original.linkedTransactionKind
                reversal.linkedTransactionIndex = original.linkedTransactionIndex
            }
            return reversal
        case .transfer:
            guard let destinationID = original.destinationAccountID,
                  let destination = state.accounts.first(where: { $0.id == destinationID && $0.deletedAt == nil }) else { return nil }
            let destinationPocket = LedgerCalculations.destinationPocket(original, for: destination)
            let exactDestinationAmount = original.destinationAmount ?? LedgerCalculations.convert(original.amount, from: original.currency, to: destinationPocket, rates: state.settings.rates)
            return .init(id: UUID(), userID: original.userID, type: .transfer, accountID: destination.id, destinationAccountID: source.id, amount: exactDestinationAmount, currency: destinationPocket, accountAmount: exactDestinationAmount, destinationAmount: exactSourceAmount, accountCurrency: original.destinationAccountCurrency, destinationAccountCurrency: original.accountCurrency, categoryID: .other, occurredAt: now, note: "REFUND \(title)", exchangeRateAtTransaction: source.id == destination.id && exactDestinationAmount > 0 ? original.amount * original.exchangeRateAtTransaction / exactDestinationAmount : (CurrencyRates.reference(destinationPocket, in: state.settings.rates) ?? original.exchangeRateAtTransaction), reversalOfTransactionID: original.id, createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .pending)
        }
    }
}
