import AppIntents
import Foundation

struct TransactionCurrencyEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Currency"
    static let defaultQuery = TransactionCurrencyQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct TransactionCurrencyQuery: EntityQuery {
    @MainActor func suggestedEntities() async throws -> [TransactionCurrencyEntity] {
        LedgerStore.shared.availableCurrencies.map { TransactionCurrencyEntity(id: $0.rawValue) }
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [TransactionCurrencyEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

struct TransactionCategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction Category"
    static let defaultQuery = TransactionCategoryQuery()
    // Scope selections to a ledger so switching ledgers cannot silently change their meaning.
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TransactionCategoryQuery: EntityQuery {
    @MainActor func suggestedEntities() async throws -> [TransactionCategoryEntity] {
        let store = LedgerStore.shared
        return store.state.categories.filter {
            !$0.id.isSystemLinked && !store.state.settings.archivedCategoryIDs.contains($0.id)
        }.map { category in
            let displayName: String
            if LedgerCategoryID.builtIns.contains(category.id) {
                let kindTitle = category.kind == .expense ? String(localized: "Expense") : String(localized: "Income")
                displayName = String(format: String(localized: "%@: %@"), kindTitle, category.displayName)
            } else {
                displayName = category.displayName
            }
            return TransactionCategoryEntity(
                id: "\(store.activeBookID.uuidString)/\(category.id.rawValue)",
                name: displayName
            )
        }
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [TransactionCategoryEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

enum QuickTransactionError: LocalizedError, Equatable {
    case unavailable
    case invalidAmount
    case categoryUnavailable
    case noDefaultAccountConfigured
    case defaultAccountUnavailable
    case accountUnavailable
    case currencyUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Unlock and open Finsy to load this ledger before recording a transaction.")
        case .invalidAmount:
            String(localized: "Enter a finite amount greater than zero.")
        case .categoryUnavailable:
            String(localized: "Choose an available category from the current ledger.")
        case .noDefaultAccountConfigured:
            String(localized: "No default account is configured for this category. Set one in Finsy > Settings > Default Accounts.")
        case .defaultAccountUnavailable:
            String(localized: "The configured default account is unavailable or frozen. Check Finsy > Settings > Default Accounts.")
        case .accountUnavailable:
            String(localized: "Create or unfreeze a payment account in Finsy first.")
        case .currencyUnavailable:
            String(localized: "Set an exchange rate for the selected currency in Finsy first.")
        }
    }
}

struct RecordTransactionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Record Transaction"
    static let description = IntentDescription("Save an expense or income without opening Finsy. The amount is the final posted amount; the category determines expense or income. Uses the category's configured default account.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount") var amount: Double
    @Parameter(title: "Currency") var currency: TransactionCurrencyEntity
    @Parameter(title: "Category") var category: TransactionCategoryEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = LedgerStore.shared
        let recorded = try await store.recordQuickTransaction(amount: amount, currencyID: currency.id, categoryID: category.id)
        let outcome = await RecentTransactionActivityCoordinator.shared.didRecordTransaction(
            recorded.transaction, account: recorded.account, category: recorded.category, ledgerBookID: recorded.bookID)
        let formattedAmount = LedgerMoneyFormat.code(abs(recorded.transaction.amount), currency: recorded.transaction.currency)
        let categoryName = recorded.category?.displayName ?? String(localized: "Transaction")
        let baseDialog = String(format: String(localized: "Recorded %@ · %@"), formattedAmount, categoryName)
        switch outcome {
        case .activitiesDisabled, .requestFailed:
            let notice = String(localized: "Transaction saved. Live Activity confirmation is unavailable.")
            return .result(dialog: IntentDialog("\(baseDialog)\n\(notice)"))
        case .started, .skippedPurchaseTransaction, .skippedNoPresentation, .superseded:
            return .result(dialog: IntentDialog("\(baseDialog)"))
        }
    }
}

extension LedgerStore {
    func recordQuickTransaction(amount: Double, currencyID: String, categoryID: String) async throws
        -> (transaction: LedgerTransaction, account: LedgerAccount?, category: LedgerCategory?, bookID: UUID) {
        let bookID = activeBookID
        let transaction = try buildQuickTransaction(amount: amount, currencyID: currencyID, categoryID: categoryID)
        let account = state.accounts.first { $0.id == transaction.accountID }
        let category = state.categories.first { $0.id == transaction.categoryID }
        mutateState { $0.transactions.insert(transaction, at: 0) }
        do {
            try await persistDurableAsync()
        } catch {
            // Remove only this failed insertion; preserve edits made while persistence awaited.
            if activeBookID == bookID {
                mutateState { $0.transactions.removeAll { $0.id == transaction.id } }
            }
            if let index = books.firstIndex(where: { $0.id == bookID }) {
                books[index].state.transactions.removeAll { $0.id == transaction.id }
            }
            scheduleSave()
            LedgerDiagnostics.failure(error, operation: "Record shortcut transaction", logger: LedgerDiagnostics.persistence)
            throw error
        }
        return (transaction, account, category, bookID)
    }

    func buildQuickTransaction(amount: Double, currencyID: String, categoryID: String) throws -> LedgerTransaction {
        guard persistenceEnabled, activeBook.effectiveEncryptionState != .authorizationRequired else { throw QuickTransactionError.unavailable }
        guard amount.isFinite, amount > 0 else { throw QuickTransactionError.invalidAmount }
        guard let currency = CurrencyCode(rawValue: currencyID), CurrencyRates.reference(currency, in: state.settings.rates) != nil else { throw QuickTransactionError.currencyUnavailable }
        guard let category = state.categories.first(where: { "\(activeBookID.uuidString)/\($0.id.rawValue)" == categoryID }),
              !category.id.isSystemLinked, !state.settings.archivedCategoryIDs.contains(category.id) else { throw QuickTransactionError.categoryUnavailable }
        guard let defaultID = state.settings.defaultExpenseAccountByCategory[category.id] else {
            throw QuickTransactionError.noDefaultAccountConfigured
        }
        guard let account = state.accounts.first(where: { $0.id == defaultID }),
              account.deletedAt == nil,
              !account.effectiveIsFrozen,
              account.isAvailableForNewTransactions else {
            throw QuickTransactionError.defaultAccountUnavailable
        }
        let type: LedgerTransactionType = category.kind == .expense ? .expense : .income
        let tax = TaxCalculations.resolve(entered: amount, type: type, rate: state.settings.taxRate(for: category), mode: .finalAmount)
        return try buildTransaction(type: type, accountID: account.id, destinationAccountID: nil,
                                    amount: amount, currency: currency, categoryID: category.id,
                                    occurredAt: .now, note: nil, taxSnapshot: tax, in: state)
    }
}

struct AddTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Transaction"
    static let description = IntentDescription("Open Finsy to record a new transaction.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LedgerStore.shared.activeRoute = .addTransaction
        return .result()
    }
}

struct FinsyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordTransactionIntent(),
                    phrases: ["Quick transaction in \(.applicationName)"],
                    shortTitle: "Record Transaction", systemImageName: "bolt.fill")
        AppShortcut(
            intent: AddTransactionIntent(),
            phrases: [
                "Add transaction in \(.applicationName)",
                "Record expense in \(.applicationName)",
                "New transaction in \(.applicationName)",
                "Log transaction in \(.applicationName)"
            ],
            shortTitle: "Add Transaction",
            systemImageName: "plus.circle.fill"
        )
    }
}
