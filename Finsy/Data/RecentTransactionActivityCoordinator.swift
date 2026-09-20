import ActivityKit
import Foundation

@MainActor
final class RecentTransactionActivityCoordinator {
    static let shared = RecentTransactionActivityCoordinator()

    private var autoEndTask: Task<Void, Never>?
    private var observers: [Any] = []

    private init() {}

    func registerObservers(store: LedgerStore) {
        // Remove prior observers if any
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
        observers.removeAll()

        let undoObs = NotificationCenter.default.addObserver(
            forName: .didRequestRecentTransactionUndo,
            object: nil,
            queue: .main
        ) { [weak store] note in
            guard let store, let id = note.object as? UUID else { return }
            if let tx = store.state.transactions.first(where: { $0.id == id && $0.deletedAt == nil }) {
                store.deleteTransaction(tx)
            }
        }
        observers.append(undoObs)

        let refundObs = NotificationCenter.default.addObserver(
            forName: .didRequestRecentTransactionRefund,
            object: nil,
            queue: .main
        ) { [weak store] note in
            guard let store, let id = note.object as? UUID else { return }
            if let tx = store.state.transactions.first(where: { $0.id == id && $0.deletedAt == nil }) {
                _ = store.refundTransaction(tx)
            }
        }
        observers.append(refundObs)
    }

    func reconcilePendingActions(store: LedgerStore) {
        let snapshots = RecentTransactionSharedStore.loadSnapshots()
        for s in snapshots {
            if s.isUndone {
                if let tx = store.state.transactions.first(where: { $0.id == s.id && $0.deletedAt == nil }) {
                    store.deleteTransaction(tx)
                }
            } else if s.isRefunded {
                if let tx = store.state.transactions.first(where: { $0.id == s.id && $0.deletedAt == nil && $0.reversalTransactionID == nil }) {
                    _ = store.refundTransaction(tx)
                }
            }
        }
    }

    func didRecordTransaction(
        _ transaction: LedgerTransaction,
        account: LedgerAccount?,
        category: LedgerCategory?
    ) async {
        // If transaction is part of an ongoing purchase session, Purchase Live Activity handles it
        guard transaction.purchaseSessionID == nil else { return }

        // End any active recent transaction activity
        await endCurrentActivity()

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let title = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? category?.name
            ?? (transaction.type == .transfer ? "Transfer" : "Transaction")

        let sign = transaction.type == .expense ? "-" : "+"
        let formattedAmount = String(format: "%.2f", transaction.amount)
        let amountText = "\(sign)\(transaction.currency.symbol)\(formattedAmount)"
        let isRefundable = transaction.type == .expense && !transaction.isReversal && transaction.reversalTransactionID == nil
        let accountName = account?.name ?? "Account"
        let expiresAt = Date.now.addingTimeInterval(10)

        let snapshot = RecentTransactionActionSnapshot(
            id: transaction.id,
            title: title,
            amountText: amountText,
            occurredAt: transaction.occurredAt,
            expiresAt: expiresAt,
            isRefundable: isRefundable,
            accountName: accountName
        )
        RecentTransactionSharedStore.saveSnapshot(snapshot)

        let attributes = RecentTransactionActivityAttributes(transactionID: transaction.id)
        let state = RecentTransactionActivityAttributes.ContentState(
            transactionID: transaction.id,
            title: title,
            amountText: amountText,
            isExpense: transaction.type == .expense,
            accountName: accountName,
            occurredAt: transaction.occurredAt,
            expiresAt: expiresAt,
            isRefundable: isRefundable
        )

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: expiresAt),
                pushType: nil
            )

            autoEndTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10.5))
                guard !Task.isCancelled else { return }
                await self?.endCurrentActivity()
            }
        } catch {
            // Live activity request failed gracefully (e.g. simulator or disabled)
        }
    }

    func endCurrentActivity() async {
        autoEndTask?.cancel()
        autoEndTask = nil
        for activity in Activity<RecentTransactionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
