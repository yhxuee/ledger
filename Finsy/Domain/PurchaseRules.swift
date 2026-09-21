import Foundation

enum PurchaseRules {
    static func validatePayment(_ session: PurchaseSession, in state: LedgerState) throws {
        guard let id = session.accountID, let account = state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw PurchaseFinalizationError.paymentAccountUnavailable
        }
        guard CurrencyRates.reference(session.currency, in: state.settings.rates) != nil,
              CurrencyRates.reference(account.currency, in: state.settings.rates) != nil else { throw PurchaseFinalizationError.missingRate }
    }

    static func validItemCategory(_ id: LedgerCategoryID, in state: LedgerState, allowArchived: Bool = false) -> Bool {
        guard let category = state.categories.first(where: { $0.id == id }) else { return false }
        let notArchived = allowArchived || !state.settings.archivedCategoryIDs.contains(id)
        return category.kind == .expense && !category.id.isSystemLinked && notArchived
    }

    static func validateItems(_ session: PurchaseSession, in state: LedgerState) throws {
        guard !session.items.isEmpty, session.plannedAmount.isFinite,
              session.items.allSatisfy({ $0.amount.isFinite && $0.amount > 0 && !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw PurchaseFinalizationError.invalidItem }
        guard session.items.allSatisfy({ validItemCategory($0.categoryID, in: state, allowArchived: true) }) else { throw PurchaseFinalizationError.invalidItem }
    }

    /// A shared App Group snapshot may replace local Purchase state only when it belongs to
    /// the same payment identity and is *strictly* newer. Timestamps carry subsecond
    /// precision in both processes, so rapid item taps keep a deterministic order.
    static func shouldAdoptSharedSnapshot(_ snapshot: PurchaseSharedSnapshot, over local: PurchaseSession) -> Bool {
        guard snapshot.session.accountID == local.accountID,
              snapshot.session.currency == local.currency else { return false }
        let localTimestamp = local.updatedAt ?? local.startedAt ?? local.createdAt
        return snapshot.updatedAt > localTimestamp
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
