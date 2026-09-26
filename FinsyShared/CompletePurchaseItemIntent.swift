import AppIntents
import ActivityKit
import Foundation

struct CompletePurchaseItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Purchase Item"
    static let description = IntentDescription("Complete an item in the active purchase.")
    static let openAppWhenRun = false
    @Parameter(title: "Session ID") var sessionID: String
    @Parameter(title: "Item ID") var itemID: String
    init() {}
    init(sessionID: UUID, itemID: UUID) { self.sessionID = sessionID.uuidString; self.itemID = itemID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let sessionID = UUID(uuidString: sessionID), let itemID = UUID(uuidString: itemID) else { throw PurchaseSharedStateError.notFound }
        // The App Group snapshot holds the full cross-process PurchaseSession, so exactly one
        // item is updated while account, currency, ordering and grouping are preserved.
        let snapshot = try PurchaseSharedStateStore.updateItem(sessionID: sessionID, itemID: itemID, completed: true)
        let state = PurchaseActivityAttributes.ContentState.make(
            session: snapshot.session,
            // The shared write just succeeded, so interactive controls stay available.
            interactiveCompletionAvailable: true,
            categoryColors: snapshot.resolvedCategoryColors, themeColorHex: snapshot.themeColorHex)
        for activity in Activity<PurchaseActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        return .result()
    }
}
