import Foundation

/// Pure derived, in-memory index for rapid financial state lookups.
/// Never persisted or serialized; always rebuilt from LedgerState.
struct LedgerIndex: Sendable {
    let activeTransactions: [LedgerTransaction]
    let sortedActiveTransactions: [LedgerTransaction]

    let activeAccounts: [LedgerAccount]

    let accountsByID: [UUID: LedgerAccount]
    let categoriesByID: [LedgerCategoryID: LedgerCategory]
    let transactionsByID: [UUID: LedgerTransaction]

    let transactionsByAccountID: [UUID: [LedgerTransaction]]
    let childrenByParentID: [UUID: [LedgerTransaction]]

    let purchaseSessionsByID: [UUID: PurchaseSession]
    let purchaseTransactionsBySessionID: [UUID: [LedgerTransaction]]

    init(state: LedgerState) {
        var activeAccounts: [LedgerAccount] = []
        var accountsByID: [UUID: LedgerAccount] = [:]
        activeAccounts.reserveCapacity(state.accounts.count)
        accountsByID.reserveCapacity(state.accounts.count)
        for account in state.accounts {
            if account.deletedAt == nil {
                activeAccounts.append(account)
                accountsByID[account.id] = account
            }
        }

        var categoriesByID: [LedgerCategoryID: LedgerCategory] = [:]
        categoriesByID.reserveCapacity(state.categories.count)
        for category in state.categories {
            categoriesByID[category.id] = category
        }

        var purchaseSessionsByID: [UUID: PurchaseSession] = [:]
        if let sessions = state.purchaseSessions {
            purchaseSessionsByID.reserveCapacity(sessions.count)
            for session in sessions {
                purchaseSessionsByID[session.id] = session
            }
        }

        var activeTransactions: [LedgerTransaction] = []
        var transactionsByID: [UUID: LedgerTransaction] = [:]
        var transactionsByAccountID: [UUID: [LedgerTransaction]] = [:]
        var childrenByParentID: [UUID: [LedgerTransaction]] = [:]
        var purchaseTransactionsBySessionID: [UUID: [LedgerTransaction]] = [:]

        activeTransactions.reserveCapacity(state.transactions.count)
        transactionsByID.reserveCapacity(state.transactions.count)

        for transaction in state.transactions {
            guard transaction.deletedAt == nil else { continue }
            activeTransactions.append(transaction)
            transactionsByID[transaction.id] = transaction

            transactionsByAccountID[transaction.accountID, default: []].append(transaction)
            if transaction.type == .transfer, let destID = transaction.destinationAccountID {
                transactionsByAccountID[destID, default: []].append(transaction)
            }

            if let parentID = transaction.parentTransactionID {
                if !transaction.isReversal && transaction.linkedTransactionKind != .combinedPaymentRefundSupport {
                    childrenByParentID[parentID, default: []].append(transaction)
                }
            }

            if let sessionID = transaction.purchaseSessionID {
                if transaction.parentTransactionID == nil && !transaction.isReversal {
                    purchaseTransactionsBySessionID[sessionID, default: []].append(transaction)
                }
            }
        }

        for (parentID, children) in childrenByParentID {
            childrenByParentID[parentID] = children.sorted {
                ($0.linkedTransactionIndex ?? 0, $0.occurredAt) < ($1.linkedTransactionIndex ?? 0, $1.occurredAt)
            }
        }

        for (sessionID, txs) in purchaseTransactionsBySessionID {
            purchaseTransactionsBySessionID[sessionID] = txs.sorted { $0.occurredAt < $1.occurredAt }
        }

        self.activeTransactions = activeTransactions
        self.sortedActiveTransactions = activeTransactions.sorted { $0.occurredAt > $1.occurredAt }
        self.activeAccounts = activeAccounts
        self.accountsByID = accountsByID
        self.categoriesByID = categoriesByID
        self.transactionsByID = transactionsByID
        self.transactionsByAccountID = transactionsByAccountID
        self.childrenByParentID = childrenByParentID
        self.purchaseSessionsByID = purchaseSessionsByID
        self.purchaseTransactionsBySessionID = purchaseTransactionsBySessionID
    }

    func transactions(for accountID: UUID) -> [LedgerTransaction] {
        transactionsByAccountID[accountID] ?? []
    }

    func children(of parentID: UUID) -> [LedgerTransaction] {
        childrenByParentID[parentID] ?? []
    }

    func account(_ id: UUID) -> LedgerAccount? {
        accountsByID[id]
    }

    func category(_ id: LedgerCategoryID) -> LedgerCategory? {
        categoriesByID[id]
    }

    func transaction(_ id: UUID) -> LedgerTransaction? {
        transactionsByID[id]
    }

    var activeTransactionsSorted: [LedgerTransaction] {
        sortedActiveTransactions
    }
}
