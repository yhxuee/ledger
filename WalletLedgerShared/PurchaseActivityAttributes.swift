import ActivityKit
import Foundation

struct PurchaseActivityAttributes: ActivityAttributes {
    struct ItemPreview: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var amount: Double
    }

    struct ContentState: Codable, Hashable {
        var totalPlannedAmount: Double
        var completedAmount: Double
        var completionFraction: Double
        var nextItems: [ItemPreview]
        var isCompleted: Bool
    }

    var sessionID: UUID
    var title: String
    var currencyCode: String
}
