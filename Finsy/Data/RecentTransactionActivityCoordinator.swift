import ActivityKit
import Foundation
import UIKit

public enum RecentTransactionActivityOutcome: Equatable, Sendable {
    case started(activityID: String)
    case activitiesDisabled
    case skippedPurchaseTransaction
    case requestFailed(domain: String, code: Int, message: String)
}

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
            if let targetBookID = note.userInfo?["ledgerBookID"] as? UUID {
                guard targetBookID == store.activeBookID else { return }
            }
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
            if let targetBookID = note.userInfo?["ledgerBookID"] as? UUID {
                guard targetBookID == store.activeBookID else { return }
            }
            if let tx = store.state.transactions.first(where: { $0.id == id && $0.deletedAt == nil && $0.reversalTransactionID == nil }) {
                _ = store.refundTransaction(tx)
            }
        }
        observers.append(refundObs)
    }

    func reconcilePendingActions(store: LedgerStore) {
        let snapshots = RecentTransactionSharedStore.loadSnapshots()
        for s in snapshots {
            guard s.ledgerBookID == store.activeBookID else { continue }
            guard Date.now <= s.expiresAt else { continue }
            if s.isUndone {
                if let tx = store.state.transactions.first(where: { $0.id == s.transactionID && $0.deletedAt == nil }) {
                    store.deleteTransaction(tx)
                }
            } else if s.isRefunded {
                if let tx = store.state.transactions.first(where: { $0.id == s.transactionID && $0.deletedAt == nil && $0.reversalTransactionID == nil }) {
                    _ = store.refundTransaction(tx)
                }
            }
        }
    }

    private var isLiveActivityAvailable: Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    @discardableResult
    func didRecordTransaction(
        _ transaction: LedgerTransaction,
        account: LedgerAccount?,
        category: LedgerCategory?,
        ledgerBookID: UUID
    ) async -> RecentTransactionActivityOutcome {
        // If transaction is part of an ongoing purchase session, Purchase Live Activity handles it
        guard transaction.purchaseSessionID == nil else {
            return .skippedPurchaseTransaction
        }

        let operationID = UUID()
        let expiresAt = Date.now.addingTimeInterval(10)
        let sign = transaction.type == .expense ? "-" : "+"
        let formattedAmount = LedgerMoneyFormat.symbol(transaction.amount, currency: transaction.currency)
        let amountText = "\(sign)\(formattedAmount)"
        let isRefundable = transaction.type == .expense && !transaction.isReversal && transaction.reversalTransactionID == nil
        let accountName = account?.name ?? "Account"
        let title = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? category?.name
            ?? (transaction.type == .transfer ? "Transfer" : "Transaction")

        let snapshot = RecentTransactionActionSnapshot(
            operationID: operationID,
            ledgerBookID: ledgerBookID,
            transactionID: transaction.id,
            title: title,
            amountText: amountText,
            occurredAt: transaction.occurredAt,
            createdAt: .now,
            expiresAt: expiresAt,
            isRefundable: isRefundable,
            accountName: accountName
        )
        RecentTransactionSharedStore.saveSnapshot(snapshot)

        // End any active recent transaction activity
        await endCurrentActivity()

        guard isLiveActivityAvailable else {
            #if DEBUG
            let appGroupAvailable = RecentTransactionSharedStore.containerURL() != nil
            print("[RecentActivity] activitiesEnabled=false applicationState=n/a appGroupAvailable=\(appGroupAvailable) requestResult=activitiesDisabled")
            #endif
            return .activitiesDisabled
        }

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
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: expiresAt),
                pushType: nil
            )

            autoEndTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10.5))
                guard !Task.isCancelled else { return }
                await self?.endCurrentActivity()
            }

            #if DEBUG
            let appState = await UIApplication.shared.applicationState
            let appGroupAvailable = RecentTransactionSharedStore.containerURL() != nil
            print("[RecentActivity] activitiesEnabled=true applicationState=\(appState.rawValue) appGroupAvailable=\(appGroupAvailable) requestResult=started(\(activity.id))")
            #endif

            return .started(activityID: activity.id)
        } catch {
            let nsError = error as NSError
            #if DEBUG
            let appState = await UIApplication.shared.applicationState
            let appGroupAvailable = RecentTransactionSharedStore.containerURL() != nil
            print("[RecentActivity] activitiesEnabled=true applicationState=\(appState.rawValue) appGroupAvailable=\(appGroupAvailable) requestResult=requestFailed(\(nsError.domain), \(nsError.code))")
            #endif
            return .requestFailed(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
        }
    }

    func endCurrentActivity() async {
        autoEndTask?.cancel()
        autoEndTask = nil
        guard isLiveActivityAvailable else { return }
        for activity in Activity<RecentTransactionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
