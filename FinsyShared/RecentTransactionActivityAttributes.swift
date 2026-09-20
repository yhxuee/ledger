import ActivityKit
import Foundation

/// Activity attributes for 10-second Recent Transaction Undo & Refund Live Activity.
/// Completely independent from PurchaseActivityAttributes.
public struct RecentTransactionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var transactionID: UUID
        public var title: String
        public var amountText: String
        public var isExpense: Bool
        public var accountName: String
        public var occurredAt: Date
        public var expiresAt: Date
        public var isRefundable: Bool
        public var statusText: String?

        public init(
            transactionID: UUID,
            title: String,
            amountText: String,
            isExpense: Bool,
            accountName: String,
            occurredAt: Date,
            expiresAt: Date,
            isRefundable: Bool,
            statusText: String? = nil
        ) {
            self.transactionID = transactionID
            self.title = title
            self.amountText = amountText
            self.isExpense = isExpense
            self.accountName = accountName
            self.occurredAt = occurredAt
            self.expiresAt = expiresAt
            self.isRefundable = isRefundable
            self.statusText = statusText
        }
    }

    public var transactionID: UUID

    public init(transactionID: UUID) {
        self.transactionID = transactionID
    }
}
