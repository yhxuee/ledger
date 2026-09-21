import ActivityKit
import Foundation

/// Activity attributes for Recent Transaction Dynamic Island & Live Activity.
/// Completely independent from PurchaseActivityAttributes.
public struct RecentTransactionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var transactionID: UUID
        public var transactionType: String
        public var categorySymbol: String
        public var categoryColorHex: String
        public var amountText: String
        public var isRefundable: Bool
        public var statusText: String?
        public var title: String
        public var isExpense: Bool
        public var accountName: String
        public var occurredAt: Date
        public var expiresAt: Date

        public init(
            transactionID: UUID,
            transactionType: String = "Expense",
            categorySymbol: String = "tag.fill",
            categoryColorHex: String = "F05E4F",
            amountText: String,
            isRefundable: Bool,
            statusText: String? = nil,
            title: String = "",
            isExpense: Bool = true,
            accountName: String = "",
            occurredAt: Date = .now,
            expiresAt: Date = .now
        ) {
            self.transactionID = transactionID
            self.transactionType = transactionType
            self.categorySymbol = categorySymbol
            self.categoryColorHex = categoryColorHex
            self.amountText = amountText
            self.isRefundable = isRefundable
            self.statusText = statusText
            self.title = title
            self.isExpense = isExpense
            self.accountName = accountName
            self.occurredAt = occurredAt
            self.expiresAt = expiresAt
        }
    }

    public var transactionID: UUID

    public init(transactionID: UUID) {
        self.transactionID = transactionID
    }
}
