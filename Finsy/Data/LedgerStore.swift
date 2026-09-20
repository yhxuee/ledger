import Foundation
import SwiftUI
import CloudKit

enum AppRoute: Equatable, Sendable {
    case addTransaction
    case purchase(UUID)
}

enum PurchaseFinalizationError: LocalizedError, Equatable, Sendable {
    case missingSession, notReady, invalidItem, paymentAccountUnavailable, missingRate, inconsistentPurchaseData
    var errorDescription: String? {
        switch self {
        case .missingSession: "Purchase session was not found."
        case .notReady: "Complete every purchase item before creating ledger transactions."
        case .invalidItem: "Each purchase item needs a name, category and positive amount."
        case .paymentAccountUnavailable: "Choose an active payment account before starting or completing this purchase."
        case .missingRate: "Set a valid exchange rate for the purchase and payment account currencies first."
        case .inconsistentPurchaseData: "This purchase contains conflicting ledger links and could not be finalized safely."
        }
    }
}

enum StateMutationImpact: Sendable {
    case purchaseOnly
    case financial
    case full
}

@MainActor
final class LedgerStore: ObservableObject {
    static let shared = LedgerStore()
    var fxRefreshes: Set<UUID> = []
    var lastFinancialRefresh = Date.now
    private var activeMutationImpact: StateMutationImpact?
    var persistenceFailureHook: (@MainActor () throws -> Void)?

    @Published private(set) var state: LedgerState {
        didSet {
            let impact = activeMutationImpact ?? .financial
            switch impact {
            case .purchaseOnly:
                cachedIndex = nil
            case .financial, .full:
                cachedIndex = nil
                cachedAccountViews = nil
                cachedActiveTransactions = nil
                financialRevision &+= 1
                scheduleNextInstallmentRefresh()
            }
        }
    }

    @discardableResult
    func mutateState<R>(_ impact: StateMutationImpact = .financial, _ mutation: (inout LedgerState) throws -> R) rethrows -> R {
        var newState = state
        let result = try mutation(&newState)
        activeMutationImpact = impact
        defer { activeMutationImpact = nil }
        state = newState
        return result
    }
    @Published private(set) var financialRevision: UInt64 = 0

    var cachedIndex: LedgerIndex?
    var cachedAccountViews: [AccountViewModel]?
    var cachedActiveTransactions: [LedgerTransaction]?
    private var installmentTimerTask: Task<Void, Never>?

    @Published var books: [LedgerBook]
    @Published var activeBookID: UUID
    @Published var currencyCatalog: [CurrencyDescriptor]
    @Published var presentedError: String?
    /// Nonfatal Purchase Mode infrastructure notice (App Group bridge / Live Activity).
    /// Never used for business-logic failures and never presented as a modal alert.
    @Published var purchaseSyncWarning: String?
    @Published var undoMessage: String?
    @Published var routedPurchaseID: UUID?
    @Published var activeRoute: AppRoute?
    @Published var requestedAnalyticsType: LedgerTransactionType? = nil
    @Published var requestedAnalyticsRange: AnalyticsRange? = nil
    @Published var requestedAnalyticsCustomRange: ClosedRange<Date>? = nil
    var saveTask: Task<Void, Never>?
    var undoTransactions: [LedgerTransaction] = []
    var undoState: LedgerState?
    var currencyCatalogUpdatedAt: Date?
    /// A dismissed bridge notice stays dismissed for the current purchase.
    var suppressedPurchaseSyncWarning: String?
    var persistenceEnabled: Bool
    @Published var lastSyncError: String?
    var saveRevision: UInt64 = 0
    nonisolated static let localRepository = LocalLedgerRepository()

    init() {
        persistenceEnabled = false
        currencyCatalog = CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = nil
        let initial = SeedData.makeProductionEmpty()
        let fallback = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now)
        books = [fallback]; activeBookID = fallback.id; state = initial
        do {
            try FinsyStorage.prepare()
            let cachedCatalog = CurrencyCatalogCache.load()
            currencyCatalog = CurrencyDescriptor.appCatalog(cachedCatalog?.currencies ?? [])
            currencyCatalogUpdatedAt = cachedCatalog?.fetchedAt
            if let library = try Self.loadLibrary() {
                guard let active = library.books.first(where: { $0.id == library.activeBookID }) ?? library.books.first else { throw BackupError.invalidFormat }
                books = library.books; activeBookID = active.id; state = active.state
            } else if let legacy = try Self.loadLegacyState() {
                state = legacy; books[0].state = legacy
            }
            persistenceEnabled = true
            processDueRecurring()
            scheduleSave()
            scheduleNextInstallmentRefresh()
        } catch {
            // Keep disk data untouched. The existing error presentation reports the failure.
            presentedError = "The ledger could not be loaded. Existing data has been preserved. \(error.localizedDescription)"
        }
    }

    init(stateForTesting initialState: LedgerState) {
        persistenceEnabled = false
        let book = LedgerBook(id: UUID(), name: "Test Ledger", state: initialState, createdAt: .now, updatedAt: .now)
        state = initialState
        books = [book]
        activeBookID = book.id
        currencyCatalog = CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = nil
    }

    var index: LedgerIndex {
        if let cachedIndex { return cachedIndex }
        let idx = LedgerIndex(state: state)
        cachedIndex = idx
        return idx
    }

    var accounts: [AccountViewModel] {
        if let cachedAccountViews { return cachedAccountViews }
        let result = LedgerCalculations.accountViews(state, index: index)
        cachedAccountViews = result
        return result
    }

    var activeTransactions: [LedgerTransaction] {
        if let cachedActiveTransactions { return cachedActiveTransactions }
        let result = index.activeTransactionsSorted
        cachedActiveTransactions = result
        return result
    }

    var activeBookName: String { books.first(where: { $0.id == activeBookID })?.name ?? "Ledger" }
    var activeBook: LedgerBook {
        var book = books.first(where: { $0.id == activeBookID }) ?? LedgerBook(id: activeBookID, name: activeBookName, state: state, createdAt: .now, updatedAt: .now)
        book.state = state
        return book
    }
    var availableCurrencies: [CurrencyCode] {
        var codes = currencyCatalog.map(\.code)
        codes.append(contentsOf: state.settings.rates.keys.filter { !codes.contains($0) }.sorted { $0.rawValue < $1.rawValue })
        return codes.filter { CurrencyRates.reference($0, in: state.settings.rates) != nil }
    }

    func markDeleted(in state: inout LedgerState, at index: Int, date: Date) {
        state.transactions[index].deletedAt = date
        state.transactions[index].updatedAt = date
        state.transactions[index].version += 1
        state.transactions[index].syncStatus = .pending
    }

    func markDeleted(at index: Int, date: Date) {
        mutateState { state in
            markDeleted(in: &state, at: index, date: date)
        }
    }

    /// Refresh time-dependent views without changing the stored schedule or posting flags.
    func refreshDueInstallments(now: Date = .now) {
        let previous = lastFinancialRefresh
        lastFinancialRefresh = now
        let hasMatured = state.transactions.contains(where: {
            $0.deletedAt == nil && $0.linkedTransactionKind == .installment && $0.occurredAt > previous && $0.occurredAt <= now
        })
        if hasMatured {
            cachedIndex = nil
            cachedAccountViews = nil
            cachedActiveTransactions = nil
            financialRevision &+= 1
            objectWillChange.send()
            OverviewWidgetRelay.updateSnapshot(store: self)
        }
        scheduleNextInstallmentRefresh(now: now)
    }

    func scheduleNextInstallmentRefresh(now: Date = .now) {
        installmentTimerTask?.cancel()
        installmentTimerTask = nil

        let futureInstallments = index.activeTransactions.filter {
            $0.linkedTransactionKind == .installment && $0.occurredAt > now
        }
        guard let nextDueDate = futureInstallments.map(\.occurredAt).min() else { return }

        let delay = max(0.1, nextDueDate.timeIntervalSince(now))
        installmentTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshDueInstallments(now: .now)
        }
    }
}
