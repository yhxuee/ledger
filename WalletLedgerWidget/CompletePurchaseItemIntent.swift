import AppIntents
import ActivityKit
import Foundation

struct CompletePurchaseItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Purchase Item"
    static let description = IntentDescription("Marks an item complete in the active purchase shared with Wallet Ledger.")
    static let openAppWhenRun = false

    @Parameter(title: "Session ID") var sessionID: String
    @Parameter(title: "Item ID") var itemID: String

    init() {}
    init(sessionID: UUID, itemID: UUID) { self.sessionID = sessionID.uuidString; self.itemID = itemID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let sessionUUID = UUID(uuidString: sessionID), let itemUUID = UUID(uuidString: itemID),
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.org.medx.WalletLedger") else { return .result() }
        let url = folder.appending(path: "active-purchase-\(sessionUUID.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var session = root["session"] as? [String: Any],
              var items = session["items"] as? [[String: Any]],
              let index = items.firstIndex(where: { ($0["id"] as? String)?.lowercased() == itemUUID.uuidString.lowercased() }) else { return .result() }
        items[index]["isCompleted"] = true
        items[index]["completedAt"] = ISO8601DateFormatter().string(from: .now)
        session["items"] = items
        if items.allSatisfy({ ($0["isCompleted"] as? Bool) == true }) {
            session["status"] = "awaitingSummary"
            session["completedAt"] = ISO8601DateFormatter().string(from: .now)
        }
        root["session"] = session
        root["updatedAt"] = ISO8601DateFormatter().string(from: .now)
        let output = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try output.write(to: url, options: [.atomic, .completeFileProtection])
        let total = items.reduce(0.0) { $0 + (($1["amount"] as? NSNumber)?.doubleValue ?? 0) }
        let completedItems = items.filter { ($0["isCompleted"] as? Bool) == true }
        let completedAmount = completedItems.reduce(0.0) { $0 + (($1["amount"] as? NSNumber)?.doubleValue ?? 0) }
        let next = items.filter { ($0["isCompleted"] as? Bool) != true }.sorted { (($0["displayOrder"] as? NSNumber)?.intValue ?? 0) < (($1["displayOrder"] as? NSNumber)?.intValue ?? 0) }.prefix(3).compactMap { value -> PurchaseActivityAttributes.ItemPreview? in
            guard let rawID = value["id"] as? String, let id = UUID(uuidString: rawID) else { return nil }
            return .init(id: id, name: value["note"] as? String ?? "Item", amount: (value["amount"] as? NSNumber)?.doubleValue ?? 0)
        }
        let state = PurchaseActivityAttributes.ContentState(totalPlannedAmount: total, completedAmount: completedAmount, completionFraction: total > 0 ? completedAmount / total : 0, nextItems: next, isCompleted: completedItems.count == items.count)
        if let activity = Activity<PurchaseActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionUUID }) {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        return .result()
    }
}
