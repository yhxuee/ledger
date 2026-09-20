import Foundation

enum TransactionGroupMode: String, Codable, Hashable, Sendable {
    case split
    case reimbursement
    case installment
    case refund
}

enum LinkedTransactionKind: String, Codable, Hashable, Sendable {
    case splitSelfExpense
    case splitSettlement
    case reimbursementOriginal
    case reimbursementIncome
    case installment
    case refundOriginal
    case refundIncome

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "reimbursement":
            self = .reimbursementIncome
        default:
            if let kind = LinkedTransactionKind(rawValue: raw) {
                self = kind
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown LinkedTransactionKind: \(raw)")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum LinkedTransactionStatus: String, Codable, Hashable, Sendable {
    case pending
    case completed
}

struct SplitTransactionMetadata: Codable, Hashable, Sendable {
    var participantCount: Int
}

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

enum GroupStatusPresentation: Equatable, Sendable {
    case splitting             // "Splitting" (red)
    case splitComplete         // "Split Complete" (green)
    case reimbursementPending  // "Reimbursement Pending" (red)
    case reimbursed            // "Reimbursed" (green)
    case installmentActive     // "Installments Active" (red)
    case installmentComplete   // "Installments Complete" (green)
    case refundPartial         // "Partial Refund" (green)
    case refundComplete        // "Refunded" (green)

    var localizedText: String {
        switch self {
        case .splitting: "Splitting"
        case .splitComplete: "Split Complete"
        case .reimbursementPending: "Reimbursement Pending"
        case .reimbursed: "Reimbursed"
        case .installmentActive: "Installments Active"
        case .installmentComplete: "Installments Complete"
        case .refundPartial: "Partial Refund"
        case .refundComplete: "Refunded"
        }
    }

    var isPending: Bool {
        switch self {
        case .splitting, .reimbursementPending, .installmentActive:
            return true
        case .splitComplete, .reimbursed, .installmentComplete, .refundPartial, .refundComplete:
            return false
        }
    }
}

/// Centralized financial semantics engine separating account postings, expense analytics,
/// income analytics, and tax analytics across all transaction roles.
enum TransactionSemantics {
    /// Determines whether a transaction produces a real balance posting to the account.
    static func posts(_ transaction: LedgerTransaction, now: Date = .now) -> Bool {
        guard transaction.deletedAt == nil else { return false }

        // Group parents
        if let mode = transaction.groupMode {
            switch mode {
            case .split, .reimbursement, .refund:
                return true // Parent carries the full original account debit
            case .installment:
                return false // Installment parent carries zero account posting
            }
        }

        // Group children
        if let kind = transaction.linkedTransactionKind {
            switch kind {
            case .splitSelfExpense, .reimbursementOriginal, .refundOriginal:
                return false // Display-only or non-posting child records
            case .splitSettlement, .reimbursementIncome:
                return transaction.isEffectivelyCompleted // Only posts when money is received
            case .refundIncome:
                return true // Received refund moves money
            case .installment:
                return transaction.isEffectivelyCompleted // Posts when due or early completed
            }
        }

        return true
    }

    /// Single authority for Expense Analytics effect, historical-FX converted to `target`.
    static func expenseEffect(_ transaction: LedgerTransaction, in state: LedgerState, to target: CurrencyCode, now: Date = .now) -> Double? {
        guard transaction.deletedAt == nil else { return nil }

        // Group parents
        if let mode = transaction.groupMode {
            switch mode {
            case .split, .reimbursement, .installment:
                return 0
            case .refund:
                let originalVal = transaction.amount
                let refundVal = refundValueInParentCurrency(transaction, in: state)
                let remaining = max(originalVal - refundVal, 0)
                guard remaining > 0 else { return 0 }
                return LedgerCalculations.convertHistorical(remaining, rate: transaction.exchangeRateAtTransaction, to: target, rates: state.settings.rates)
            }
        }

        // Group children
        if let kind = transaction.linkedTransactionKind {
            switch kind {
            case .splitSelfExpense:
                return LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
            case .splitSettlement, .reimbursementOriginal, .reimbursementIncome, .refundOriginal, .refundIncome:
                return 0
            case .installment:
                guard transaction.isEffectivelyCompleted else { return 0 }
                return LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
            }
        }

        // Purchase child exception
        if transaction.purchaseSessionID != nil {
            if transaction.isRefunded { return 0 }
            guard transaction.type == .expense else { return nil }
            return LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
        }

        // Reversal of Purchase child: produces net zero expense analytics
        if let originalID = transaction.reversalOfTransactionID,
           let original = state.transactions.first(where: { $0.id == originalID }),
           original.purchaseSessionID != nil {
            return 0
        }

        // Normal transactions
        if let originalID = transaction.reversalOfTransactionID {
            guard let original = state.transactions.first(where: { $0.id == originalID }), original.type == .expense else { return nil }
            return -LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
        }

        guard transaction.type == .expense else { return nil }
        return LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
    }

    /// Single authority for Income Analytics effect, historical-FX converted to `target`.
    static func incomeEffect(_ transaction: LedgerTransaction, in state: LedgerState, to target: CurrencyCode, now: Date = .now) -> Double? {
        guard transaction.deletedAt == nil else { return nil }

        // Group parents
        if let mode = transaction.groupMode {
            switch mode {
            case .split, .reimbursement, .installment:
                return 0
            case .refund:
                let originalVal = transaction.amount
                let refundVal = refundValueInParentCurrency(transaction, in: state)
                let excess = max(refundVal - originalVal, 0)
                guard excess > 0 else { return 0 }
                return LedgerCalculations.convertHistorical(excess, rate: transaction.exchangeRateAtTransaction, to: target, rates: state.settings.rates)
            }
        }

        // Group children
        if let kind = transaction.linkedTransactionKind {
            switch kind {
            case .splitSelfExpense, .splitSettlement, .reimbursementOriginal, .reimbursementIncome,
                 .installment, .refundOriginal, .refundIncome:
                return 0
            }
        }

        // Reversal of purchase item produces zero income analytics
        if let originalID = transaction.reversalOfTransactionID,
           let original = state.transactions.first(where: { $0.id == originalID }),
           original.purchaseSessionID != nil {
            return 0
        }

        // Normal transactions
        if let originalID = transaction.reversalOfTransactionID {
            guard let original = state.transactions.first(where: { $0.id == originalID }), original.type == .income else { return nil }
            return -LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
        }

        guard transaction.type == .income else { return nil }
        return LedgerCalculations.historical(transaction, to: target, rates: state.settings.rates)
    }

    /// Single authority for Tax Analytics effect and category attribution.
    static func taxEffect(_ transaction: LedgerTransaction, in state: LedgerState, to target: CurrencyCode, now: Date = .now) -> (amount: Double, categoryID: LedgerCategoryID)? {
        guard transaction.deletedAt == nil else { return nil }
        let targetRate = CurrencyRates.reference(target, in: state.settings.rates) ?? 1
        guard targetRate.isFinite, targetRate > 0 else { return nil }

        // Group parents
        if let mode = transaction.groupMode {
            switch mode {
            case .split, .reimbursement, .installment:
                return nil
            case .refund:
                guard transaction.isTaxExempt != true, let originalTax = transaction.taxAmount, originalTax > 0, transaction.amount > 0 else { return nil }
                let originalVal = transaction.amount
                let refundVal = refundValueInParentCurrency(transaction, in: state)
                let remainingExpense = max(originalVal - refundVal, 0)
                let ratio = min(1.0, max(0.0, remainingExpense / originalVal))
                let recognizedTax = originalTax * ratio
                guard recognizedTax > 0.0001 else { return nil }
                let converted = recognizedTax * transaction.exchangeRateAtTransaction / targetRate
                return (converted, transaction.categoryID)
            }
        }

        // Group children
        if let kind = transaction.linkedTransactionKind {
            switch kind {
            case .splitSelfExpense:
                guard transaction.isTaxExempt != true, let childTax = transaction.taxAmount, childTax > 0 else { return nil }
                let parentCategory = state.transactions.first(where: { $0.id == transaction.parentTransactionID })?.categoryID ?? transaction.categoryID
                let converted = childTax * transaction.exchangeRateAtTransaction / targetRate
                return (converted, parentCategory)
            case .installment:
                guard transaction.isEffectivelyCompleted, transaction.isTaxExempt != true, let childTax = transaction.taxAmount, childTax > 0 else { return nil }
                let parentCategory = state.transactions.first(where: { $0.id == transaction.parentTransactionID })?.categoryID ?? transaction.categoryID
                let converted = childTax * transaction.exchangeRateAtTransaction / targetRate
                return (converted, parentCategory)
            case .splitSettlement, .reimbursementOriginal, .reimbursementIncome, .refundOriginal, .refundIncome:
                return nil
            }
        }

        // Purchase item exception: refunded purchase child + reversal = net 0
        if transaction.purchaseSessionID != nil && transaction.isRefunded {
            return nil
        }
        if let originalID = transaction.reversalOfTransactionID,
           let original = state.transactions.first(where: { $0.id == originalID }),
           original.purchaseSessionID != nil {
            return nil
        }

        // Normal standalone transaction
        guard transaction.isTaxExempt != true,
              let tax = transaction.taxAmount, tax > 0,
              transaction.exchangeRateAtTransaction > 0 else { return nil }

        if let originalID = transaction.reversalOfTransactionID {
            guard let original = state.transactions.first(where: { $0.id == originalID }),
                  original.isTaxExempt != true else { return nil }
        }

        let effect = tax * transaction.exchangeRateAtTransaction / targetRate
        let amount = transaction.isReversal ? -effect : effect
        return (amount, transaction.categoryID)
    }

    /// Evaluates refund value in parent currency using stable historical snapshots.
    static func refundValueInParentCurrency(_ parent: LedgerTransaction, in state: LedgerState) -> Double {
        guard parent.exchangeRateAtTransaction > 0 else { return 0 }
        let refundChildren = children(of: parent, in: state).filter { $0.linkedTransactionKind == .refundIncome }
        return refundChildren.reduce(0.0) { sum, child in
            sum + (child.amount * child.exchangeRateAtTransaction / parent.exchangeRateAtTransaction)
        }
    }

    /// True if an expense transaction can be converted into a group.
    static func eligible(_ transaction: LedgerTransaction) -> Bool {
        transaction.deletedAt == nil &&
        transaction.type == .expense &&
        !transaction.isLockedByReversal &&
        transaction.parentTransactionID == nil &&
        transaction.groupMode == nil &&
        transaction.purchaseSessionID == nil
    }

    /// Non-deleted, non-reversal children of a parent group.
    static func children(of parent: LedgerTransaction, in state: LedgerState) -> [LedgerTransaction] {
        state.transactions.filter { $0.deletedAt == nil && $0.parentTransactionID == parent.id && !$0.isReversal }
            .sorted { ($0.linkedTransactionIndex ?? 0, $0.occurredAt) < ($1.linkedTransactionIndex ?? 0, $1.occurredAt) }
    }

    /// Returns the semantic status presentation for parent rows.
    static func statusPresentation(for parent: LedgerTransaction, in state: LedgerState, now: Date = .now) -> GroupStatusPresentation? {
        guard let mode = parent.groupMode else { return nil }
        let groupChildren = children(of: parent, in: state)

        switch mode {
        case .split:
            let settlements = groupChildren.filter { $0.linkedTransactionKind == .splitSettlement }
            guard !settlements.isEmpty else { return .splitting }
            return settlements.allSatisfy { $0.linkedStatus == .completed } ? .splitComplete : .splitting

        case .reimbursement:
            let recovery = groupChildren.first { $0.linkedTransactionKind == .reimbursementIncome }
            return recovery?.linkedStatus == .completed ? .reimbursed : .reimbursementPending

        case .installment:
            let installments = groupChildren.filter { $0.linkedTransactionKind == .installment }
            guard !installments.isEmpty else { return .installmentActive }
            return installments.allSatisfy { $0.isEffectivelyCompleted } ? .installmentComplete : .installmentActive

        case .refund:
            let refundVal = refundValueInParentCurrency(parent, in: state)
            if refundVal <= 0.001 { return .refundPartial }
            return refundVal < (parent.amount - 0.005) ? .refundPartial : .refundComplete
        }
    }

    /// Sum of posted installment postings for refunding an installment parent.
    static func refundableInstallmentAmount(_ parent: LedgerTransaction, in state: LedgerState, now: Date = .now) -> Double {
        let installments = children(of: parent, in: state).filter { $0.linkedTransactionKind == .installment && $0.isEffectivelyCompleted }
        return installments.reduce(0.0) { $0 + $1.amount }
    }

    static func validTransfer(source: LedgerAccount, destinationID: UUID?, sourceCurrency: CurrencyCode?, destinationCurrency: CurrencyCode?) -> Bool {
        guard let destinationID else { return false }
        guard destinationID == source.id else { return true }
        guard source.usesCurrencyPockets, let sourceCurrency, let destinationCurrency else { return false }
        return sourceCurrency != destinationCurrency && source.pocketCurrencies.contains(sourceCurrency) && source.pocketCurrencies.contains(destinationCurrency)
    }
}

enum InstallmentSchedule {
    static func portion(_ total: Double, count: Int, index: Int) -> Double {
        let regular = TaxCalculations.rounded(total / Double(count))
        return index == count - 1 ? total - regular * Double(count - 1) : regular
    }

    static func generate(parent: LedgerTransaction, plan: InstallmentPlanMetadata, now: Date = .now) -> [LedgerTransaction]? {
        guard (2...360).contains(plan.count), plan.intervalDays > 0, plan.intervalDays <= 3650,
              plan.fee.isFinite, plan.fee >= 0 else { return nil }
        var outstanding = parent.amount
        var result: [LedgerTransaction] = []
        let originalTax = parent.taxAmount ?? 0
        let originalBase = parent.taxBaseAmount ?? parent.amount
        var taxSum: Double = 0
        var baseSum: Double = 0

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

            // Tax distributed strictly over principal with residue safe final rounding
            if parent.taxAmount != nil {
                let childTax = index == plan.count - 1
                    ? TaxCalculations.rounded(originalTax - taxSum)
                    : TaxCalculations.rounded(originalTax * (principal / parent.amount))
                child.taxAmount = childTax
                taxSum += childTax
            }
            if parent.taxBaseAmount != nil {
                let childBase = index == plan.count - 1
                    ? TaxCalculations.rounded(originalBase - baseSum)
                    : TaxCalculations.rounded(originalBase * (principal / parent.amount))
                child.taxBaseAmount = childBase
                baseSum += childBase
            }

            if index == 0 {
                child.linkedStatus = .completed
                child.completedAt = now
            } else {
                child.linkedStatus = .pending
                child.completedAt = nil
            }

            child.createdAt = now; child.updatedAt = now; child.version = 1; child.syncStatus = .pending
            result.append(child)
            outstanding -= principal
        }
        return result
    }
}

enum SplitSchedule {
    static func generate(parent: LedgerTransaction, people: Int, now: Date = .now) -> [LedgerTransaction]? {
        guard (2...50).contains(people), parent.amount > 0 else { return nil }
        var result: [LedgerTransaction] = []
        let originalTax = parent.taxAmount ?? 0
        let originalBase = parent.taxBaseAmount ?? parent.amount
        let regularShare = TaxCalculations.rounded(parent.amount / Double(people))
        let lastShare = TaxCalculations.rounded(parent.amount - regularShare * Double(people - 1))

        // Child 1: My Share
        var myShare = parent
        myShare.id = UUID()
        myShare.groupMode = nil
        myShare.splitMetadata = nil
        myShare.installmentMetadata = nil
        myShare.parentTransactionID = parent.id
        myShare.linkedTransactionKind = .splitSelfExpense
        myShare.linkedTransactionIndex = 0
        myShare.linkedStatus = .completed
        myShare.completedAt = now
        myShare.amount = regularShare
        myShare.accountAmount = 0
        myShare.destinationAmount = nil
        myShare.destinationAccountID = nil
        myShare.destinationAccountCurrency = nil
        let trimmedNote = parent.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        myShare.note = trimmedNote.isEmpty ? "My Share" : "\(trimmedNote) · My Share"
        myShare.noteAttachmentID = nil
        myShare.purchaseSessionID = nil
        myShare.purchaseItemID = nil
        if parent.taxAmount != nil {
            myShare.taxAmount = TaxCalculations.rounded(originalTax * (regularShare / parent.amount))
        }
        if parent.taxBaseAmount != nil {
            myShare.taxBaseAmount = TaxCalculations.rounded(originalBase * (regularShare / parent.amount))
        }
        myShare.createdAt = now; myShare.updatedAt = now; myShare.version = 1; myShare.syncStatus = .pending
        result.append(myShare)

        // Children 2..people: Settlement
        for index in 1..<people {
            let isLast = index == people - 1
            let shareAmount = isLast ? lastShare : regularShare
            var settlement = parent
            settlement.id = UUID()
            settlement.type = .income
            settlement.categoryID = .settlement
            settlement.groupMode = nil
            settlement.splitMetadata = nil
            settlement.installmentMetadata = nil
            settlement.parentTransactionID = parent.id
            settlement.linkedTransactionKind = .splitSettlement
            settlement.linkedTransactionIndex = index
            settlement.linkedStatus = .pending
            settlement.completedAt = nil
            settlement.amount = shareAmount
            settlement.accountAmount = shareAmount
            settlement.destinationAmount = nil
            settlement.destinationAccountID = nil
            settlement.destinationAccountCurrency = nil
            settlement.taxRate = nil
            settlement.taxAmount = 0
            settlement.taxBaseAmount = shareAmount
            settlement.taxInputMode = .finalAmount
            settlement.isTaxExempt = true
            settlement.note = "Settlement Person \(index + 1)"
            settlement.noteAttachmentID = nil
            settlement.purchaseSessionID = nil
            settlement.purchaseItemID = nil
            settlement.createdAt = now; settlement.updatedAt = now; settlement.version = 1; settlement.syncStatus = .pending
            result.append(settlement)
        }
        return result
    }
}

enum ReimbursementSchedule {
    static func generate(parent: LedgerTransaction, now: Date = .now) -> [LedgerTransaction] {
        var orig = parent
        orig.id = UUID()
        orig.groupMode = nil
        orig.splitMetadata = nil
        orig.installmentMetadata = nil
        orig.parentTransactionID = parent.id
        orig.linkedTransactionKind = .reimbursementOriginal
        orig.linkedTransactionIndex = 0
        orig.linkedStatus = .completed
        orig.completedAt = now
        orig.accountAmount = 0
        orig.taxAmount = 0
        orig.isTaxExempt = true
        orig.noteAttachmentID = nil
        orig.purchaseSessionID = nil
        orig.purchaseItemID = nil
        let note = parent.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        orig.note = note.isEmpty ? "Original Expense" : "\(note) · Original"
        orig.createdAt = now; orig.updatedAt = now; orig.version = 1; orig.syncStatus = .pending

        var income = parent
        income.id = UUID()
        income.type = .income
        income.categoryID = .reimbursement
        income.groupMode = nil
        income.splitMetadata = nil
        income.installmentMetadata = nil
        income.parentTransactionID = parent.id
        income.linkedTransactionKind = .reimbursementIncome
        income.linkedTransactionIndex = 1
        income.linkedStatus = .pending
        income.completedAt = nil
        income.amount = parent.amount
        income.accountAmount = parent.amount
        income.taxRate = nil
        income.taxAmount = 0
        income.taxBaseAmount = parent.amount
        income.taxInputMode = .finalAmount
        income.isTaxExempt = true
        income.note = "Reimbursement"
        income.noteAttachmentID = nil
        income.purchaseSessionID = nil
        income.purchaseItemID = nil
        income.createdAt = now; income.updatedAt = now; income.version = 1; income.syncStatus = .pending

        return [orig, income]
    }
}

enum RefundSchedule {
    static func generate(parent: LedgerTransaction, now: Date = .now) -> [LedgerTransaction] {
        var orig = parent
        orig.id = UUID()
        orig.groupMode = nil
        orig.splitMetadata = nil
        orig.installmentMetadata = nil
        orig.parentTransactionID = parent.id
        orig.linkedTransactionKind = .refundOriginal
        orig.linkedTransactionIndex = 0
        orig.linkedStatus = .completed
        orig.completedAt = now
        orig.accountAmount = 0
        orig.taxAmount = 0
        orig.isTaxExempt = true
        orig.noteAttachmentID = nil
        orig.purchaseSessionID = nil
        orig.purchaseItemID = nil
        let note = parent.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        orig.note = note.isEmpty ? "Original Expense" : "\(note) · Original"
        orig.createdAt = now; orig.updatedAt = now; orig.version = 1; orig.syncStatus = .pending

        var refund = parent
        refund.id = UUID()
        refund.type = .income
        refund.categoryID = .refund
        refund.occurredAt = now
        refund.groupMode = nil
        refund.splitMetadata = nil
        refund.installmentMetadata = nil
        refund.parentTransactionID = parent.id
        refund.linkedTransactionKind = .refundIncome
        refund.linkedTransactionIndex = 1
        refund.linkedStatus = .completed
        refund.completedAt = now
        refund.amount = parent.amount
        refund.accountAmount = parent.accountAmount ?? parent.amount
        refund.taxRate = nil
        refund.taxAmount = 0
        refund.taxBaseAmount = parent.amount
        refund.taxInputMode = .finalAmount
        refund.isTaxExempt = true
        refund.note = "REFUND " + (note.isEmpty ? "Expense" : note)
        refund.noteAttachmentID = nil
        refund.purchaseSessionID = nil
        refund.purchaseItemID = nil
        refund.createdAt = now; refund.updatedAt = now; refund.version = 1; refund.syncStatus = .pending

        return [orig, refund]
    }
}
