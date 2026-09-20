import ActivityKit
import AppIntents
import Foundation

public struct UndoRecentTransactionIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Undo Recent Transaction"
    public static let description = IntentDescription("Undo the most recently recorded transaction.")
    public static let isDiscoverable: Bool = false

    @Parameter(title: "Transaction ID")
    public var transactionIDString: String

    public init() {
        self.transactionIDString = ""
    }

    public init(transactionID: UUID) {
        self.transactionIDString = transactionID.uuidString
    }

    public func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: transactionIDString) else { return .result() }
        RecentTransactionSharedStore.markUndone(id: id)

        // Update Live Activity UI immediately
        for activity in Activity<RecentTransactionActivityAttributes>.activities where activity.attributes.transactionID == id {
            var state = activity.content.state
            state.statusText = "Undone"
            let finalContent = ActivityContent(state: state, staleDate: nil)
            await activity.update(finalContent, alertConfiguration: nil)
            await activity.end(finalContent, dismissalPolicy: .after(Date.now.addingTimeInterval(1.5)))
        }

        NotificationCenter.default.post(name: .didRequestRecentTransactionUndo, object: id)
        return .result()
    }
}

public struct RefundRecentTransactionIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Refund Recent Transaction"
    public static let description = IntentDescription("Refund the most recently recorded transaction.")
    public static let isDiscoverable: Bool = false

    @Parameter(title: "Transaction ID")
    public var transactionIDString: String

    public init() {
        self.transactionIDString = ""
    }

    public init(transactionID: UUID) {
        self.transactionIDString = transactionID.uuidString
    }

    public func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: transactionIDString) else { return .result() }
        RecentTransactionSharedStore.markRefunded(id: id)

        // Update Live Activity UI immediately
        for activity in Activity<RecentTransactionActivityAttributes>.activities where activity.attributes.transactionID == id {
            var state = activity.content.state
            state.statusText = "Refunded"
            let finalContent = ActivityContent(state: state, staleDate: nil)
            await activity.update(finalContent, alertConfiguration: nil)
            await activity.end(finalContent, dismissalPolicy: .after(Date.now.addingTimeInterval(1.5)))
        }

        NotificationCenter.default.post(name: .didRequestRecentTransactionRefund, object: id)
        return .result()
    }
}

extension Notification.Name {
    public static let didRequestRecentTransactionUndo = Notification.Name("FinsyDidRequestRecentTransactionUndo")
    public static let didRequestRecentTransactionRefund = Notification.Name("FinsyDidRequestRecentTransactionRefund")
}
