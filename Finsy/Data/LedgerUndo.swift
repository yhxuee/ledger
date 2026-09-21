import Foundation

/// Operation-scoped inverse mutation record.
/// Instead of capturing the entire LedgerState, this model captures only the exact entities
/// modified by a specific user operation, along with version guards.
struct LedgerUndoOperation: Sendable {
    let id: UUID
    let createdAt: Date
    var message: String

    /// Pre-operation snapshots of existing transactions modified or soft-deleted by this operation.
    var transactionSnapshots: [UUID: LedgerTransaction]

    /// Newly created transaction IDs (e.g. if an operation created new transactions, undo removes them).
    var createdTransactionIDs: Set<UUID>

    /// Pre-operation snapshots of existing accounts modified or deleted by this operation.
    var accountSnapshots: [UUID: LedgerAccount]

    /// Pre-operation snapshots of recurring rules modified or deleted.
    var recurringRuleSnapshots: [UUID: RecurringRule]

    /// Pre-operation snapshots of purchase sessions modified or deleted.
    var purchaseSessionSnapshots: [UUID: PurchaseSession]

    /// Pre-operation snapshots of category default expense account mappings modified or cleared.
    var defaultExpenseAccountByCategorySnapshots: [LedgerCategoryID: UUID]?

    /// Expected version of each transaction modified by the operation.
    /// If subsequent changes bumped the version, undo fails safely without overwriting newer data.
    var expectedTransactionVersions: [UUID: Int]

    /// Expected version of each account modified by the operation.
    var expectedAccountVersions: [UUID: Int]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        message: String,
        transactionSnapshots: [UUID: LedgerTransaction] = [:],
        createdTransactionIDs: Set<UUID> = [],
        accountSnapshots: [UUID: LedgerAccount] = [:],
        recurringRuleSnapshots: [UUID: RecurringRule] = [:],
        purchaseSessionSnapshots: [UUID: PurchaseSession] = [:],
        defaultExpenseAccountByCategorySnapshots: [LedgerCategoryID: UUID]? = nil,
        expectedTransactionVersions: [UUID: Int] = [:],
        expectedAccountVersions: [UUID: Int] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.message = message
        self.transactionSnapshots = transactionSnapshots
        self.createdTransactionIDs = createdTransactionIDs
        self.accountSnapshots = accountSnapshots
        self.recurringRuleSnapshots = recurringRuleSnapshots
        self.purchaseSessionSnapshots = purchaseSessionSnapshots
        self.defaultExpenseAccountByCategorySnapshots = defaultExpenseAccountByCategorySnapshots
        self.expectedTransactionVersions = expectedTransactionVersions
        self.expectedAccountVersions = expectedAccountVersions
    }
}
