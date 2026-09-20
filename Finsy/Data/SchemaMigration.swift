import Foundation

struct LedgerSettingsV1: Codable, Sendable {
    var userID: String
    var baseCurrency: CurrencyCode
    var rates: [CurrencyCode: Double]
    var automaticRates: Bool
    var backupReminders: Bool
    var lastBackupAt: Date?
    var updatedAt: Date
    var exchangeRatesUpdatedAt: Date?
}

struct LedgerStateV1: Codable, Sendable {
    var schemaVersion: Int
    var accounts: [LedgerAccount]
    var transactions: [LedgerTransaction]
    var categories: [LedgerCategory]
    var settings: LedgerSettingsV1
    var recurringRules: [RecurringRule]?
}

struct LedgerBookV1: Codable, Sendable {
    var id: UUID
    var name: String
    var state: LedgerStateV1
    var createdAt: Date
    var updatedAt: Date
}

struct LedgerLibraryV1: Codable, Sendable {
    var schemaVersion: Int
    var activeBookID: UUID
    var books: [LedgerBookV1]
}

struct LedgerBackupEnvelopeV1: Codable, Sendable {
    var metadata: BackupMetadata
    var data: LedgerStateV1
}

enum SchemaMigration {
    static func migrate(_ old: LedgerStateV1) -> LedgerState {
        let accountAllocations = old.accounts.reduce(into: [UUID: Double]()) { result, account in
            if account.deletedAt == nil, account.includeInBudget, account.budget > 0 { result[account.id] = account.budget }
        }
        let budget = BudgetPlan(mode: .account, categoryAllocations: [:], accountAllocations: accountAllocations, updatedAt: old.settings.updatedAt)
        let settings = LedgerSettings(
            userID: old.settings.userID,
            baseCurrency: old.settings.baseCurrency,
            exchangeRates: .init(rates: old.settings.rates, automatic: old.settings.automaticRates, updatedAt: old.settings.exchangeRatesUpdatedAt),
            defaultExpenseAccountByCategory: [:],
            budgetPlan: budget,
            backupReminders: old.settings.backupReminders,
            lastBackupAt: old.settings.lastBackupAt,
            updatedAt: old.settings.updatedAt
        )
        return LedgerState(schemaVersion: 2, accounts: old.accounts, transactions: old.transactions, categories: old.categories, settings: settings, recurringRules: old.recurringRules)
    }

    static func migrate(_ old: LedgerLibraryV1) -> LedgerLibrary {
        .init(
            schemaVersion: 2,
            activeBookID: old.activeBookID,
            books: old.books.map { .init(id: $0.id, name: $0.name, state: migrate($0.state), createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
        )
    }

    static func migrate(_ old: LedgerBackupEnvelopeV1) -> LedgerBackupEnvelope {
        var metadata = old.metadata
        metadata.schemaVersion = 2
        return .init(metadata: metadata, data: migrate(old.data))
    }

    /// Brings decoded data into the currency-pocket model without inventing or re-pricing money.
    ///
    /// - Single-currency accounts always resolve to one pocket built from `currency` + `openingBalance`,
    ///   so they keep behaving exactly as before multi-currency existed.
    /// - Multi-currency accounts keep the primary currency mirrored in `openingBalance` for legacy readers.
    /// - A pocket referenced by an active posting is re-created, otherwise that money would silently
    ///   disappear from the account total.
    static func normalize(_ state: inout LedgerState) {
        guard state.schemaVersion <= BackupCodec.currentSchemaVersion else { return }
        state.schemaVersion = BackupCodec.currentSchemaVersion
        let existingCategoryIDs = Set(state.categories.map(\.id))
        for category in SeedData.categories {
            if !existingCategoryIDs.contains(category.id) {
                state.categories.append(category)
            }
        }
        for index in state.accounts.indices {
            var account = state.accounts[index]
            guard account.usesCurrencyPockets else {
                account.currencyPockets = [.init(currency: account.currency, openingBalance: account.openingBalance.isFinite ? account.openingBalance : 0)]
                state.accounts[index] = account
                continue
            }
            var pockets = account.normalizedPockets
            var known = Set(pockets.map(\.currency))
            for transaction in state.transactions where transaction.deletedAt == nil {
                if transaction.accountID == account.id, let currency = transaction.accountCurrency, known.insert(currency).inserted {
                    pockets.append(.init(currency: currency, openingBalance: 0))
                }
                if transaction.destinationAccountID == account.id, let currency = transaction.destinationAccountCurrency, known.insert(currency).inserted {
                    pockets.append(.init(currency: currency, openingBalance: 0))
                }
            }
            account.currencyPockets = pockets
            if let primary = pockets.first(where: { $0.currency == account.currency }) { account.openingBalance = primary.openingBalance }
            state.accounts[index] = account
        }
        normalizeLinkedGroups(&state)
    }

    private static func normalizeLinkedGroups(_ state: inout LedgerState) {
        let allTransactions = state.transactions
        var newTransactions: [LedgerTransaction] = []

        for index in state.transactions.indices {
            let item = state.transactions[index]
            guard item.deletedAt == nil else { continue }

            // Installment child backfill
            if item.parentTransactionID != nil, item.linkedTransactionKind == .installment {
                if state.transactions[index].linkedStatus == nil {
                    state.transactions[index].linkedStatus = item.occurredAt <= .now ? .completed : .pending
                    if state.transactions[index].linkedStatus == .completed && state.transactions[index].completedAt == nil {
                        state.transactions[index].completedAt = item.occurredAt
                    }
                }
            }

            // Group parents backfill
            guard let mode = item.groupMode else { continue }
            let children = allTransactions.filter { $0.parentTransactionID == item.id && $0.deletedAt == nil }

            switch mode {
            case .split:
                if children.isEmpty {
                    let people = item.splitMetadata?.participantCount ?? 2
                    if let generated = SplitSchedule.generate(parent: item, people: people, now: item.occurredAt) {
                        newTransactions.append(contentsOf: generated)
                    }
                } else {
                    // Ensure existing children have linkedStatus set
                    for childIndex in state.transactions.indices where state.transactions[childIndex].parentTransactionID == item.id {
                        if state.transactions[childIndex].linkedStatus == nil {
                            state.transactions[childIndex].linkedStatus = .completed
                            if state.transactions[childIndex].completedAt == nil {
                                state.transactions[childIndex].completedAt = state.transactions[childIndex].occurredAt
                            }
                        }
                    }
                    // If splitSelfExpense is missing, add it
                    if !children.contains(where: { $0.linkedTransactionKind == .splitSelfExpense }) {
                        let people = item.splitMetadata?.participantCount ?? 2
                        let myShare = (item.amount / Double(people) * 100).rounded() / 100
                        let child1 = LedgerTransaction(
                            id: UUID(),
                            userID: item.userID,
                            type: .expense,
                            accountID: item.accountID,
                            destinationAccountID: nil,
                            amount: myShare,
                            currency: item.currency,
                            accountAmount: item.accountAmount.map { ($0 / Double(people) * 100).rounded() / 100 },
                            destinationAmount: nil,
                            accountCurrency: item.accountCurrency,
                            destinationAccountCurrency: nil,
                            categoryID: item.categoryID,
                            occurredAt: item.occurredAt,
                            note: "\(item.note ?? "Split") (My share)",
                            exchangeRateAtTransaction: item.exchangeRateAtTransaction,
                            parentTransactionID: item.id,
                            linkedTransactionKind: .splitSelfExpense,
                            linkedTransactionIndex: 0,
                            linkedStatus: .completed,
                            completedAt: item.occurredAt,
                            createdAt: item.createdAt,
                            updatedAt: item.updatedAt,
                            deletedAt: nil,
                            version: 1,
                            syncStatus: .pending,
                            taxRate: item.taxRate,
                            taxAmount: item.taxAmount.map { ($0 / Double(people) * 100).rounded() / 100 },
                            taxBaseAmount: item.taxBaseAmount.map { ($0 / Double(people) * 100).rounded() / 100 },
                            taxInputMode: item.taxInputMode,
                            isTaxExempt: item.isTaxExempt
                        )
                        newTransactions.append(child1)
                    }
                }

            case .reimbursement:
                if children.isEmpty {
                    let generated = ReimbursementSchedule.generate(parent: item, now: item.occurredAt)
                    newTransactions.append(contentsOf: generated)
                } else {
                    for childIndex in state.transactions.indices where state.transactions[childIndex].parentTransactionID == item.id {
                        if state.transactions[childIndex].linkedStatus == nil {
                            state.transactions[childIndex].linkedStatus = .completed
                            if state.transactions[childIndex].completedAt == nil {
                                state.transactions[childIndex].completedAt = state.transactions[childIndex].occurredAt
                            }
                        }
                    }
                    if !children.contains(where: { $0.linkedTransactionKind == .reimbursementOriginal }) {
                        let child1 = LedgerTransaction(
                            id: UUID(),
                            userID: item.userID,
                            type: .expense,
                            accountID: item.accountID,
                            destinationAccountID: nil,
                            amount: item.amount,
                            currency: item.currency,
                            accountAmount: item.accountAmount,
                            destinationAmount: nil,
                            accountCurrency: item.accountCurrency,
                            destinationAccountCurrency: nil,
                            categoryID: item.categoryID,
                            occurredAt: item.occurredAt,
                            note: "\(item.note ?? "Reimbursement") (Original)",
                            exchangeRateAtTransaction: item.exchangeRateAtTransaction,
                            parentTransactionID: item.id,
                            linkedTransactionKind: .reimbursementOriginal,
                            linkedTransactionIndex: 0,
                            linkedStatus: .completed,
                            completedAt: item.occurredAt,
                            createdAt: item.createdAt,
                            updatedAt: item.updatedAt,
                            deletedAt: nil,
                            version: 1,
                            syncStatus: .pending,
                            taxRate: item.taxRate,
                            taxAmount: item.taxAmount,
                            taxBaseAmount: item.taxBaseAmount,
                            taxInputMode: item.taxInputMode,
                            isTaxExempt: item.isTaxExempt
                        )
                        newTransactions.append(child1)
                    }
                }

            case .installment:
                if children.isEmpty, let plan = item.installmentMetadata {
                    if let generated = InstallmentSchedule.generate(parent: item, plan: plan, now: item.occurredAt) {
                        newTransactions.append(contentsOf: generated)
                    }
                }

            case .refund:
                if children.isEmpty {
                    let generated = RefundSchedule.generate(parent: item, now: item.occurredAt)
                    newTransactions.append(contentsOf: generated)
                }

            case .combinedPayment:
                break
            }
        }

        if !newTransactions.isEmpty {
            state.transactions.append(contentsOf: newTransactions)
        }
    }

    static func normalize(_ library: inout LedgerLibrary) {
        for index in library.books.indices where library.books[index].state.schemaVersion <= BackupCodec.currentSchemaVersion {
            var state = library.books[index].state
            normalize(&state)
            library.books[index].state = state
        }
    }
}
