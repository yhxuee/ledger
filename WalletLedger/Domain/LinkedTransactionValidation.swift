import Foundation

enum LinkedTransactionValidation {
    static func validate(_ state: LedgerState) throws {
        let transactions = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        var slots = Set<String>()
        for item in state.transactions {
            if let mode = item.groupMode {
                guard item.type == .expense, item.parentTransactionID == nil, item.linkedTransactionKind == nil,
                      item.linkedTransactionIndex == nil, !item.isLockedByReversal else { throw BackupError.invalidValue("linked parent") }
                switch mode {
                case .split:
                    guard let metadata = item.splitMetadata, (2...50).contains(metadata.participantCount), item.installmentMetadata == nil else { throw BackupError.invalidValue("split metadata") }
                case .reimbursement:
                    guard item.splitMetadata == nil, item.installmentMetadata == nil else { throw BackupError.invalidValue("reimbursement metadata") }
                case .installment:
                    guard let plan = item.installmentMetadata, item.splitMetadata == nil,
                          (2...360).contains(plan.count), (1...3650).contains(plan.intervalDays), plan.fee.isFinite, plan.fee >= 0 else { throw BackupError.invalidValue("installment plan") }
                    if item.deletedAt == nil {
                        let children = TransactionSemantics.children(of: item, in: state)
                        guard children.count == plan.count else { throw BackupError.invalidValue("installment schedule") }
                    }
                }
            } else if item.splitMetadata != nil || item.installmentMetadata != nil {
                throw BackupError.invalidValue("orphan group metadata")
            }
            guard let parentID = item.parentTransactionID else {
                guard item.linkedTransactionKind == nil, item.linkedTransactionIndex == nil,
                      !item.categoryID.isSystemLinked else { throw BackupError.invalidValue("orphan linked transaction") }
                continue
            }
            guard let parent = transactions[parentID], parentID != item.id, parent.parentTransactionID == nil,
                  parent.groupMode != nil, let kind = item.linkedTransactionKind, !item.isLockedByReversal,
                  item.deletedAt != nil || parent.deletedAt == nil,
                  item.purchaseSessionID == nil else { throw BackupError.invalidValue("linked relationship") }
            switch kind {
            case .splitSettlement:
                guard parent.groupMode == .split, item.type == .income, item.categoryID == .settlement,
                      let index = item.linkedTransactionIndex, index > 0,
                      item.deletedAt != nil || index < (parent.splitMetadata?.participantCount ?? 0) else { throw BackupError.invalidValue("settlement slot") }
            case .reimbursement:
                guard parent.groupMode == .reimbursement, item.type == .income, item.categoryID == .reimbursement,
                      item.linkedTransactionIndex == nil else { throw BackupError.invalidValue("reimbursement child") }
            case .installment:
                guard parent.groupMode == .installment, item.type == .expense,
                      item.categoryID == parent.categoryID, let index = item.linkedTransactionIndex, index > 0,
                      item.deletedAt != nil || index <= (parent.installmentMetadata?.count ?? 0) else { throw BackupError.invalidValue("installment child") }
            }
            if kind != .installment {
                guard item.isTaxExempt == true, item.taxAmount == 0 else { throw BackupError.invalidValue("recovery tax") }
            }
            if item.deletedAt == nil, let index = item.linkedTransactionIndex {
                guard slots.insert("\(parentID)-\(index)").inserted else { throw BackupError.invalidValue("duplicate linked slot") }
            }
        }
    }
}
