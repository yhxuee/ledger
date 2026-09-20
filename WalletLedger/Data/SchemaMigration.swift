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
    }

    static func normalize(_ library: inout LedgerLibrary) {
        for index in library.books.indices where library.books[index].state.schemaVersion <= BackupCodec.currentSchemaVersion {
            var state = library.books[index].state
            normalize(&state)
            library.books[index].state = state
        }
    }
}
