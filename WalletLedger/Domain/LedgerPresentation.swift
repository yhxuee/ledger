import Foundation

enum LedgerPresentationEntry: Identifiable {
    case transaction(LedgerTransaction)
    case linkedGroup(LedgerTransaction, Date)
    case purchase(PurchaseSession, [LedgerTransaction], Date)

    var occurredAt: Date {
        switch self {
        case .transaction(let item): item.occurredAt
        case .linkedGroup(_, let date), .purchase(_, _, let date): date
        }
    }
    var id: String {
        switch self {
        case .transaction(let item): "transaction-\(item.id)"
        case .linkedGroup(let parent, let date): "linked-\(parent.id)-\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"
        case .purchase(let session, _, let date): "purchase-\(session.id)-\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"
        }
    }
}

enum LedgerPresentation {
    /// Resolve against the whole book even when the visible activity is filtered by date/account.
    /// Future installments remain available in disclosure, never as chronology occurrences.
    static func entries(transactions: [LedgerTransaction], state: LedgerState, collapsePurchases: Bool = true, now: Date = .now) -> [LedgerPresentationEntry] {
        let all = Dictionary(uniqueKeysWithValues: state.transactions.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        let sessions = Dictionary(uniqueKeysWithValues: (state.purchaseSessions ?? []).map { ($0.id, $0) })
        var entries: [String: LedgerPresentationEntry] = [:]
        for activity in transactions where activity.deletedAt == nil {
            if activity.linkedTransactionKind == .installment && activity.occurredAt > now { continue }
            if activity.isReversal && (activity.purchaseSessionID != nil || (activity.reversalOfTransactionID.flatMap { all[$0] }?.purchaseSessionID != nil)) {
                continue
            }
            let parent = activity.parentTransactionID.flatMap { all[$0] } ?? activity
            let entry: LedgerPresentationEntry
            if collapsePurchases, let sessionID = parent.purchaseSessionID, let session = sessions[sessionID] {
                let children = all.values.filter { $0.purchaseSessionID == sessionID && $0.parentTransactionID == nil && !$0.isReversal }.sorted { $0.occurredAt < $1.occurredAt }
                // Preserve the original single Purchase row; subsequent linked activity gets a dated occurrence.
                let date = activity.parentTransactionID == nil ? (children.map(\.occurredAt).max() ?? activity.occurredAt) : activity.occurredAt
                entry = .purchase(session, children, date)
            } else if parent.groupMode != nil {
                entry = .linkedGroup(parent, activity.occurredAt)
            } else {
                entry = .transaction(parent)
            }
            if entries[entry.id] == nil || entries[entry.id]!.occurredAt < entry.occurredAt { entries[entry.id] = entry }
        }
        return entries.values.sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt }
    }
}
