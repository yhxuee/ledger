import Foundation

enum PurchaseRules {
    static func validatePayment(_ session: PurchaseSession, in state: LedgerState) throws {
        guard let id = session.accountID, let account = state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw PurchaseFinalizationError.paymentAccountUnavailable
        }
        guard CurrencyRates.reference(session.currency, in: state.settings.rates) != nil,
              CurrencyRates.reference(account.currency, in: state.settings.rates) != nil else { throw PurchaseFinalizationError.missingRate }
    }

    static func validateItems(_ session: PurchaseSession, in state: LedgerState) throws {
        guard !session.items.isEmpty, session.plannedAmount.isFinite,
              session.items.allSatisfy({ $0.amount.isFinite && $0.amount > 0 && !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw PurchaseFinalizationError.invalidItem }
        let categories = Set(state.categories.map(\.id))
        guard session.items.allSatisfy({ categories.contains($0.categoryID) }) else { throw PurchaseFinalizationError.invalidItem }
    }

    static func migrateDevelopmentSessions(in state: inout LedgerState) {
        guard var sessions = state.purchaseSessions else { return }
        for index in sessions.indices {
            if sessions[index].requiresCurrencyMigration { sessions[index].currency = state.settings.baseCurrency }
            if sessions[index].requiresPaymentMigration {
                let linked = state.transactions.filter { $0.purchaseSessionID == sessions[index].id }
                let accounts = Set(sessions[index].items.compactMap(\.resolvedAccountID) + linked.map(\.accountID))
                if accounts.count == 1 { sessions[index].accountID = accounts.first }
                if sessions[index].accountID == nil && sessions[index].status != .completed { sessions[index].status = .draft }
            }
            if sessions[index].status == .active || sessions[index].status == .awaitingSummary {
                let id = sessions[index].accountID
                if !state.accounts.contains(where: { $0.id == id && $0.deletedAt == nil }) {
                    sessions[index].status = .draft
                }
            }
            sessions[index].requiresCurrencyMigration = false
            sessions[index].requiresPaymentMigration = false
            sessions[index].normalizeSections()
        }
        state.purchaseSessions = sessions
    }
}
