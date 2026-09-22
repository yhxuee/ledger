import ActivityKit
import Foundation
import UIKit

public enum RecentTransactionPresentation: Sendable {
    case standard
    case transient
    case none
}

public enum RecentTransactionActivityOutcome: Equatable, Sendable {
    case started(activityID: String)
    case activitiesDisabled
    case skippedPurchaseTransaction
    case skippedNoPresentation
    case superseded
    case requestFailed(domain: String, code: Int, message: String)
}

@MainActor
final class RecentTransactionActivityCoordinator {
    static let shared = RecentTransactionActivityCoordinator()

    private var lifecycleTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var activeActivityID: String?
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
            let id = note.object as? UUID
            let targetBookID = note.userInfo?["ledgerBookID"] as? UUID
            Task { @MainActor [weak store] in
                RecentTransactionActivityCoordinator.shared.handleActionTriggered()
                guard let store, let id else { return }
                if let targetBookID {
                    guard targetBookID == store.activeBookID else { return }
                }
                if let tx = store.state.transactions.first(where: { $0.id == id && $0.deletedAt == nil }) {
                    store.deleteTransaction(tx)
                }
            }
        }
        observers.append(undoObs)

        let refundObs = NotificationCenter.default.addObserver(
            forName: .didRequestRecentTransactionRefund,
            object: nil,
            queue: .main
        ) { [weak store] note in
            let id = note.object as? UUID
            let targetBookID = note.userInfo?["ledgerBookID"] as? UUID
            Task { @MainActor [weak store] in
                RecentTransactionActivityCoordinator.shared.handleActionTriggered()
                guard let store, let id else { return }
                if let targetBookID {
                    guard targetBookID == store.activeBookID else { return }
                }
                if let tx = store.state.transactions.first(where: { $0.id == id && $0.deletedAt == nil && $0.reversalTransactionID == nil }) {
                    _ = store.refundTransaction(tx)
                }
            }
        }
        observers.append(refundObs)
    }

    func handleActionTriggered() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        let operationID = UUID()
        currentOperationID = operationID
        let activityID = activeActivityID
        activeActivityID = nil
        Task {
            if let activityID {
                await Self.endActivity(id: activityID)
            } else {
                await Self.endAllActivities()
            }
        }
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
        ledgerBookID: UUID,
        presentation: RecentTransactionPresentation = .standard
    ) async -> RecentTransactionActivityOutcome {
        guard presentation != .none else {
            return .skippedNoPresentation
        }

        // If transaction is part of an ongoing purchase session, Purchase Live Activity handles it
        guard transaction.purchaseSessionID == nil else {
            return .skippedPurchaseTransaction
        }

        // Newest transaction wins: cancel prior lifecycle and clear state
        lifecycleTask?.cancel()
        lifecycleTask = nil

        // End any active recent transaction activity immediately
        await endRecentActivities()

        let operationID = UUID()
        currentOperationID = operationID
        activeActivityID = nil

        let createdAt = Date.now
        let duration: TimeInterval = (presentation == .transient) ? 3.0 : 8.5
        let expiresAt = createdAt.addingTimeInterval(duration)

        let amountText = LedgerMoneyFormat.code(abs(transaction.amount), currency: transaction.currency)
        let isRefundable = transaction.type == .expense && !transaction.isReversal && transaction.reversalTransactionID == nil
        let accountName = account?.name ?? "Account"
        let title = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? category?.name
            ?? (transaction.type == .transfer ? "Transfer" : "Transaction")

        let categorySymbol: String
        let categoryColorHex: String
        if let category {
            categorySymbol = category.symbol
            categoryColorHex = category.colorHex
        } else {
            switch transaction.type {
            case .expense:
                categorySymbol = "creditcard.fill"
                categoryColorHex = PurchaseActivityPalette.accentHex
            case .income:
                categorySymbol = "arrow.down.circle.fill"
                categoryColorHex = PurchaseActivityPalette.successHex
            case .transfer:
                categorySymbol = "arrow.left.arrow.right.circle.fill"
                categoryColorHex = PurchaseActivityPalette.infoHex
            }
        }

        let transactionType: String
        switch transaction.type {
        case .expense: transactionType = "Expense"
        case .income: transactionType = "Income"
        case .transfer: transactionType = "Transfer"
        }

        let snapshot = RecentTransactionActionSnapshot(
            operationID: operationID,
            ledgerBookID: ledgerBookID,
            transactionID: transaction.id,
            title: title,
            amountText: amountText,
            occurredAt: transaction.occurredAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            isRefundable: isRefundable,
            accountName: accountName
        )
        RecentTransactionSharedStore.saveSnapshot(snapshot)

        guard isLiveActivityAvailable else {
            LedgerDiagnostics.activity.notice("Recent transaction activity unavailable")
            #if DEBUG
            let appGroupAvailable = RecentTransactionSharedStore.containerURL() != nil
            print("[RecentActivity] activitiesEnabled=false applicationState=n/a appGroupAvailable=\(appGroupAvailable) requestResult=activitiesDisabled")
            #endif
            return .activitiesDisabled
        }

        let attributes = RecentTransactionActivityAttributes(transactionID: transaction.id)
        let state = RecentTransactionActivityAttributes.ContentState(
            transactionID: transaction.id,
            transactionType: transactionType,
            categorySymbol: categorySymbol,
            categoryColorHex: categoryColorHex,
            amountText: amountText,
            isRefundable: isRefundable,
            statusText: nil,
            title: title,
            isExpense: transaction.type == .expense,
            accountName: accountName,
            occurredAt: transaction.occurredAt,
            expiresAt: expiresAt
        )

        do {
            let activity: Activity<RecentTransactionActivityAttributes>
            if presentation == .transient {
                if #available(iOS 18.0, *), UIApplication.shared.applicationState == .active {
                    activity = try startTransientActivity(
                        attributes: attributes,
                        state: state,
                        staleDate: expiresAt
                    )
                } else {
                    activity = try startStandardActivity(
                        attributes: attributes,
                        state: state,
                        staleDate: expiresAt
                    )
                }
            } else {
                activity = try startStandardActivity(
                    attributes: attributes,
                    state: state,
                    staleDate: expiresAt
                )
            }
            activeActivityID = activity.id

            let alertConfig = AlertConfiguration(
                title: "\(amountText)",
                body: "\(title)",
                sound: .default
            )
            await Self.updateActivityAlert(
                activityID: activity.id,
                content: ActivityContent(state: state, staleDate: expiresAt),
                alertConfiguration: alertConfig
            )

            guard currentOperationID == operationID else {
                return .superseded
            }

            LedgerDiagnostics.activity.info("Recent transaction activity started presentation=\(String(describing: presentation)) id=\(activity.id)")

            #if DEBUG
            let appState = await UIApplication.shared.applicationState
            let appGroupAvailable = RecentTransactionSharedStore.containerURL() != nil
            print("[RecentActivity] started id=\(activity.id) presentation=\(presentation) appState=\(appState.rawValue) appGroupAvailable=\(appGroupAvailable)")
            #endif

            let sleepSeconds: Double = (presentation == .transient) ? 3.0 : 8.5

            lifecycleTask = Task { [weak self, operationID, activityID = activity.id, transactionID = transaction.id] in
                try? await Task.sleep(for: .seconds(sleepSeconds))
                guard !Task.isCancelled else { return }
                guard let self = self, self.currentOperationID == operationID else { return }

                if let snap = RecentTransactionSharedStore.loadSnapshot(id: transactionID),
                   snap.isUndone || snap.isRefunded {
                    await Self.endActivity(id: activityID)
                    guard self.currentOperationID == operationID else { return }
                    self.activeActivityID = nil
                    self.currentOperationID = nil
                    return
                }

                await Self.endActivity(id: activityID)
                guard self.currentOperationID == operationID else { return }
                self.activeActivityID = nil
                self.currentOperationID = nil
            }

            return .started(activityID: activity.id)
        } catch {
            LedgerDiagnostics.failure(error, operation: "Start recent transaction activity", logger: LedgerDiagnostics.activity)
            let nsError = error as NSError
            #if DEBUG
            let appState = await UIApplication.shared.applicationState
            let appGroupAvailable = RecentTransactionSharedStore.containerURL() != nil
            print("[RecentActivity] activitiesEnabled=true applicationState=\(appState.rawValue) appGroupAvailable=\(appGroupAvailable) requestResult=requestFailed(\(nsError.domain), \(nsError.code))")
            #endif
            return .requestFailed(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
        }
    }

    @available(iOS 18.0, *)
    private func startTransientActivity(
        attributes: RecentTransactionActivityAttributes,
        state: RecentTransactionActivityAttributes.ContentState,
        staleDate: Date
    ) throws -> Activity<RecentTransactionActivityAttributes> {
        try Activity.request(
            attributes: attributes,
            content: ActivityContent(
                state: state,
                staleDate: staleDate
            ),
            pushType: nil,
            style: .transient
        )
    }

    private func startStandardActivity(
        attributes: RecentTransactionActivityAttributes,
        state: RecentTransactionActivityAttributes.ContentState,
        staleDate: Date
    ) throws -> Activity<RecentTransactionActivityAttributes> {
        if #available(iOS 18.0, *) {
            return try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    staleDate: staleDate
                ),
                pushType: nil,
                style: .standard
            )
        } else {
            return try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    staleDate: staleDate
                ),
                pushType: nil
            )
        }
    }

    nonisolated private static func updateActivityAlert(
        activityID: String,
        content: ActivityContent<RecentTransactionActivityAttributes.ContentState>,
        alertConfiguration: AlertConfiguration
    ) async {
        for activity in Activity<RecentTransactionActivityAttributes>.activities where activity.id == activityID {
            await activity.update(content, alertConfiguration: alertConfiguration)
        }
    }

    nonisolated private static func endActivity(id: String) async {
        for activity in Activity<RecentTransactionActivityAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func endRecentActivities() async {
        guard isLiveActivityAvailable else { return }
        await Self.endAllActivities()
    }

    nonisolated private static func endAllActivities() async {
        for activity in Activity<RecentTransactionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func endCurrentActivity() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        currentOperationID = nil
        let activityID = activeActivityID
        activeActivityID = nil
        if let activityID {
            await Self.endActivity(id: activityID)
        } else {
            await endRecentActivities()
        }
    }
}
