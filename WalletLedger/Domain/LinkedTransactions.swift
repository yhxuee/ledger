import Foundation

enum TransactionGroupMode: String, Codable, Hashable, Sendable { case split, reimbursement, installment }
enum LinkedTransactionKind: String, Codable, Hashable, Sendable { case splitSettlement, reimbursement, installment }
struct SplitTransactionMetadata: Codable, Hashable, Sendable { var participantCount: Int }
struct InstallmentPlanMetadata: Codable, Hashable, Sendable {
    enum Interval: String, Codable, CaseIterable, Sendable { case monthly, customDays }
    enum FeeMethod: String, Codable, CaseIterable, Sendable { case totalFee, monthlyInterest }
    var count: Int
    var interval: Interval
    var intervalDays: Int
    var feeMethod: FeeMethod
    /// An amount for totalFee; a decimal rate (0.01 = 1%) for monthlyInterest.
    var fee: Double
}

enum TransactionAttentionState: Equatable {
    case splitOutstanding(Int)
    case reimbursementPending(Double, CurrencyCode)
}

/// Single authority for posting, consumption, tax, and linked-group completion.
enum TransactionSemantics {
    static func posts(_ transaction: LedgerTransaction, now: Date = .now) -> Bool {
        transaction.deletedAt == nil && transaction.groupMode != .installment &&
        !(transaction.linkedTransactionKind == .installment && transaction.occurredAt > now)
    }

    static func analyticsScale(_ transaction: LedgerTransaction, now: Date = .now) -> Double {
        guard posts(transaction, now: now) else { return 0 }
        if transaction.linkedTransactionKind == .splitSettlement || transaction.linkedTransactionKind == .reimbursement || transaction.groupMode == .reimbursement { return 0 }
        if transaction.groupMode == .split { return 1 / Double(max(2, transaction.splitMetadata?.participantCount ?? 2)) }
        return 1
    }

    static func eligible(_ transaction: LedgerTransaction) -> Bool {
        transaction.deletedAt == nil && transaction.type == .expense && !transaction.isLockedByReversal && transaction.parentTransactionID == nil && transaction.groupMode == nil
    }

    static func children(of parent: LedgerTransaction, in state: LedgerState) -> [LedgerTransaction] {
        state.transactions.filter { $0.deletedAt == nil && $0.parentTransactionID == parent.id }
            .sorted { ($0.linkedTransactionIndex ?? 0, $0.occurredAt) < ($1.linkedTransactionIndex ?? 0, $1.occurredAt) }
    }

    static func outstandingSlots(_ parent: LedgerTransaction, in state: LedgerState) -> [Int] {
        guard parent.groupMode == .split, let count = parent.splitMetadata?.participantCount, count >= 2 else { return [] }
        let paid = Set(children(of: parent, in: state).filter { $0.linkedTransactionKind == .splitSettlement }.compactMap(\.linkedTransactionIndex))
        return (1..<count).filter { !paid.contains($0) }
    }

    static func remainingReimbursement(_ parent: LedgerTransaction, in state: LedgerState) -> Double {
        guard parent.exchangeRateAtTransaction > 0 else { return parent.amount }
        let recovered = children(of: parent, in: state).filter { $0.linkedTransactionKind == .reimbursement }.reduce(0) {
            $0 + $1.amount * $1.exchangeRateAtTransaction / parent.exchangeRateAtTransaction
        }
        let remaining = TaxCalculations.rounded(max(0, parent.amount - recovered))
        return remaining < 0.01 ? 0 : remaining
    }

    static func attention(_ parent: LedgerTransaction, in state: LedgerState) -> TransactionAttentionState? {
        if parent.groupMode == .split {
            let count = outstandingSlots(parent, in: state).count
            return count > 0 ? .splitOutstanding(count) : nil
        }
        if parent.groupMode == .reimbursement {
            let amount = remainingReimbursement(parent, in: state)
            return amount > 0 ? .reimbursementPending(amount, parent.currency) : nil
        }
        return nil
    }

    static func validTransfer(source: LedgerAccount, destinationID: UUID?, sourceCurrency: CurrencyCode?, destinationCurrency: CurrencyCode?) -> Bool {
        guard let destinationID else { return false }
        guard destinationID == source.id else { return true }
        guard source.usesCurrencyPockets, let sourceCurrency, let destinationCurrency else { return false }
        return sourceCurrency != destinationCurrency && source.pocketCurrencies.contains(sourceCurrency) && source.pocketCurrencies.contains(destinationCurrency)
    }
}

enum InstallmentSchedule {
    /// Residue belongs to the last child, including the original stored purchase tax.
    static func portion(_ total: Double, count: Int, index: Int) -> Double {
        let regular = TaxCalculations.rounded(total / Double(count))
        return index == count - 1 ? total - regular * Double(count - 1) : regular
    }

    static func generate(parent: LedgerTransaction, plan: InstallmentPlanMetadata, now: Date = .now) -> [LedgerTransaction]? {
        guard (2...360).contains(plan.count), plan.intervalDays > 0, plan.intervalDays <= 3650,
              plan.fee.isFinite, plan.fee >= 0 else { return nil }
        var outstanding = parent.amount
        var result: [LedgerTransaction] = []
        for index in 0..<plan.count {
            let principal = portion(parent.amount, count: plan.count, index: index)
            let fee = plan.feeMethod == .totalFee ? portion(plan.fee, count: plan.count, index: index) : TaxCalculations.rounded(outstanding * plan.fee)
            guard principal > 0, (principal + fee).isFinite else { return nil }
            var child = parent
            child.id = UUID()
            child.groupMode = nil; child.splitMetadata = nil; child.installmentMetadata = nil
            child.parentTransactionID = parent.id; child.linkedTransactionKind = .installment; child.linkedTransactionIndex = index + 1
            child.purchaseSessionID = nil; child.purchaseItemID = nil
            child.noteAttachmentID = nil
            child.amount = TaxCalculations.rounded(principal + fee)
            if let posting = parent.accountAmount { child.accountAmount = child.amount * posting / parent.amount }
            child.occurredAt = Calendar.current.date(byAdding: plan.interval == .monthly ? .month : .day,
                value: plan.interval == .monthly ? index : plan.intervalDays * index, to: parent.occurredAt) ?? parent.occurredAt
            if let tax = parent.taxAmount { child.taxAmount = portion(tax, count: plan.count, index: index) }
            if let base = parent.taxBaseAmount { child.taxBaseAmount = portion(base, count: plan.count, index: index) }
            child.createdAt = now; child.updatedAt = now; child.version = 1; child.syncStatus = .pending
            result.append(child)
            outstanding -= principal
        }
        return result
    }
}
