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
        var completedItemCount: Int = 0
        var totalItemCount: Int = 0

        static func make(session: PurchaseSession) -> Self {
            .init(totalPlannedAmount: session.plannedAmount,
                  completedAmount: session.completedAmount,
                  completionFraction: session.completionFraction,
                  nextItems: session.orderedItems.filter { !$0.isCompleted }.prefix(3).map {
                      .init(id: $0.id, name: $0.note, amount: $0.amount)
                  },
                  isCompleted: session.status == .awaitingSummary || session.status == .completed,
                  completedItemCount: session.completedItemCount,
                  totalItemCount: session.items.count)
        }
    }

    var sessionID: UUID
    var title: String
    var currencyCode: String
}
