import ActivityKit
import Foundation

struct PurchaseActivityAttributes: ActivityAttributes {
    struct ItemPreview: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var amount: Double
        /// Category identification color so the Lock Screen/Island rows stay recognisable.
        var categoryColorHex: String? = nil
    }

    struct ContentState: Codable, Hashable {
        var totalPlannedAmount: Double
        var completedAmount: Double
        var completionFraction: Double
        var nextItems: [ItemPreview]
        var isCompleted: Bool
        var completedItemCount: Int
        var totalItemCount: Int
        /// False when the App Group bridge is unusable, which means Lock Screen /
        /// Dynamic Island item controls would inevitably fail. The widget then renders
        /// read-only rows instead of AppIntent buttons.
        var themeColorHex: String? = nil
        var interactiveCompletionAvailable: Bool

        enum CodingKeys: String, CodingKey {
            case totalPlannedAmount, completedAmount, completionFraction, nextItems, isCompleted
            case completedItemCount, totalItemCount, interactiveCompletionAvailable, themeColorHex
        }

        init(
            totalPlannedAmount: Double,
            completedAmount: Double,
            completionFraction: Double,
            nextItems: [ItemPreview],
            isCompleted: Bool,
            completedItemCount: Int,
            totalItemCount: Int,
            interactiveCompletionAvailable: Bool,
            themeColorHex: String? = nil
        ) {
            self.totalPlannedAmount = totalPlannedAmount
            self.completedAmount = completedAmount
            self.completionFraction = completionFraction
            self.nextItems = nextItems
            self.isCompleted = isCompleted
            self.completedItemCount = completedItemCount
            self.totalItemCount = totalItemCount
            self.interactiveCompletionAvailable = interactiveCompletionAvailable
            self.themeColorHex = themeColorHex
        }

        /// Decodes states persisted by earlier builds. A missing interactivity flag is
        /// treated as read-only so the widget never renders controls that cannot work.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalPlannedAmount = try container.decode(Double.self, forKey: .totalPlannedAmount)
            completedAmount = try container.decode(Double.self, forKey: .completedAmount)
            completionFraction = try container.decode(Double.self, forKey: .completionFraction)
            nextItems = try container.decodeIfPresent([ItemPreview].self, forKey: .nextItems) ?? []
            isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
            completedItemCount = try container.decodeIfPresent(Int.self, forKey: .completedItemCount) ?? 0
            totalItemCount = try container.decodeIfPresent(Int.self, forKey: .totalItemCount) ?? 0
            themeColorHex = try container.decodeIfPresent(String.self, forKey: .themeColorHex)
            interactiveCompletionAvailable = try container.decodeIfPresent(Bool.self, forKey: .interactiveCompletionAvailable) ?? false
        }

        static func make(
            session: PurchaseSession,
            interactiveCompletionAvailable: Bool,
            categoryColors: [String: String] = [:],
            themeColorHex: String? = nil
        ) -> Self {
            .init(totalPlannedAmount: session.plannedAmount,
                  completedAmount: session.completedAmount,
                  completionFraction: session.completionFraction,
                  nextItems: session.orderedItems.filter { !$0.isCompleted }.prefix(3).map {
                      .init(id: $0.id, name: $0.note, amount: $0.amount, categoryColorHex: categoryColors[$0.categoryID.rawValue])
                  },
                  isCompleted: session.status == .awaitingSummary || session.status == .completed,
                  completedItemCount: session.completedItemCount,
                  totalItemCount: session.items.count,
                  interactiveCompletionAvailable: interactiveCompletionAvailable, themeColorHex: themeColorHex)
        }
    }

    var sessionID: UUID
    var title: String
    var currencyCode: String
}
