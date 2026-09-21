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
    func entities(for identifiers: [String]) async throws -> [TransactionCurrencyEntity] {
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
        }.map {
            TransactionCategoryEntity(id: "\(store.activeBookID.uuidString)/\($0.id.rawValue)",
                                      name: "\($0.kind == .expense ? "Expense" : "Income"): \($0.name)")
        }
    }
    func entities(for identifiers: [String]) async throws -> [TransactionCategoryEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

enum QuickTransactionError: LocalizedError {
    case unavailable, invalidAmount, categoryUnavailable, accountUnavailable, currencyUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Unlock and open Finsy to load this ledger before recording a transaction."
        case .invalidAmount: "Enter a finite amount greater than zero."
        case .categoryUnavailable: "Choose an available category from the current ledger."
        case .accountUnavailable: "Create or unfreeze a payment account in Finsy first."
        case .currencyUnavailable: "Set an exchange rate for the selected currency in Finsy first."
        }
    }
}

struct RecordTransactionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Record Transaction"
    static let description = IntentDescription("Save an expense or income without opening Finsy. The amount is the final posted amount; the category determines expense or income. Uses the category's default account, or the first available account.")
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
        switch outcome {
        case .activitiesDisabled, .requestFailed:
            return .result(dialog: "Transaction saved. Live Activity confirmation is unavailable.")
        case .started, .skippedPurchaseTransaction, .superseded:
            return .result(dialog: "Transaction saved.")
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
        let available = state.accounts.filter { $0.isAvailableForNewTransactions }
        let defaultID = category.kind == .expense ? state.settings.defaultExpenseAccountByCategory[category.id] : nil
        guard let account = available.first(where: { $0.id == defaultID }) ?? available.first else { throw QuickTransactionError.accountUnavailable }
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
