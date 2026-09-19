import Foundation

enum RefundEngine {
    static func makeReversal(of original: LedgerTransaction, in state: LedgerState, now: Date = .now) -> LedgerTransaction? {
        guard original.deletedAt == nil, !original.isReversal,
              let source = state.accounts.first(where: { $0.id == original.accountID && $0.deletedAt == nil }) else { return nil }
        let categoryName = state.categories.first(where: { $0.id == original.categoryID })?.name ?? "Transaction"
        let trimmedNote = original.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedNote.isEmpty ? categoryName : trimmedNote
        switch original.type {
        case .expense, .income:
            let exactSourceAmount = original.accountAmount ?? LedgerCalculations.convert(original.amount, from: original.currency, to: source.currency, rates: state.settings.rates)
            return .init(id: UUID(), userID: original.userID, type: original.type == .expense ? .income : .expense, accountID: original.accountID, destinationAccountID: nil, amount: original.amount, currency: original.currency, accountAmount: exactSourceAmount, destinationAmount: nil, categoryID: original.categoryID, occurredAt: now, note: "REFUND \(title)", exchangeRateAtTransaction: original.exchangeRateAtTransaction, reversalOfTransactionID: original.id, createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .pending)
        case .transfer:
            guard let destinationID = original.destinationAccountID,
                  let destination = state.accounts.first(where: { $0.id == destinationID && $0.deletedAt == nil }) else { return nil }
            let exactSourceAmount = original.accountAmount ?? LedgerCalculations.convert(original.amount, from: original.currency, to: source.currency, rates: state.settings.rates)
            let exactDestinationAmount = original.destinationAmount ?? LedgerCalculations.convert(original.amount, from: original.currency, to: destination.currency, rates: state.settings.rates)
            return .init(id: UUID(), userID: original.userID, type: .transfer, accountID: destination.id, destinationAccountID: source.id, amount: exactDestinationAmount, currency: destination.currency, accountAmount: exactDestinationAmount, destinationAmount: exactSourceAmount, categoryID: .other, occurredAt: now, note: "REFUND \(title)", exchangeRateAtTransaction: CurrencyRates.reference(destination.currency, in: state.settings.rates) ?? original.exchangeRateAtTransaction, reversalOfTransactionID: original.id, createdAt: now, updatedAt: now, deletedAt: nil, version: 1, syncStatus: .pending)
        }
    }
}
