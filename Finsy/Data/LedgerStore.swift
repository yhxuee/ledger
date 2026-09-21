import Foundation
import SwiftUI
import CloudKit

enum AppRoute: Equatable, Sendable {
    case addTransaction
    case purchase(UUID)
    case account(UUID)
    case overview
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
    var encryptionMigrations: Set<UUID> = []
    var lastFinancialRefresh = Date.now
    private var activeMutationImpact: StateMutationImpact?
    #if DEBUG
    var persistenceTestHook: (@MainActor @Sendable () async throws -> Void)?
    #endif

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
    /// Nonfatal Recent Transaction Live Activity notice.
    @Published var recentActivityWarning: String?
    @Published var undoMessage: String?
    @Published var routedPurchaseID: UUID?
    @Published var activeRoute: AppRoute?
    @Published var requestedAnalyticsType: LedgerTransactionType? = nil
    @Published var requestedAnalyticsRange: AnalyticsRange? = nil
    @Published var requestedAnalyticsCustomRange: ClosedRange<Date>? = nil
    @Published var hasMoreTransactions: Bool = false
    @Published var isLoadingMoreTransactions: Bool = false
    var saveTask: Task<Void, Never>?
    var undoTransactions: [LedgerTransaction] = []
    var activeUndoOperation: LedgerUndoOperation?
    var currencyCatalogUpdatedAt: Date?
    /// A dismissed bridge notice stays dismissed for the current purchase.
    var suppressedPurchaseSyncWarning: String?
    var persistenceEnabled: Bool
    @Published var lastSyncError: String?
    var saveRevision: UInt64 = 0
    nonisolated static let localRepository = LocalLedgerRepository()

    init() {
        let startupStart = Date.now
        persistenceEnabled = false
        currencyCatalog = CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = nil
        let initial = SeedData.makeProductionEmpty()
        let fallback = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now)
        books = [fallback]; activeBookID = fallback.id; state = initial
        do {
            let storageOpenStart = Date.now
            try FinsyStorage.prepare()
            LedgerDiagnostics.recordStartupPhase("storage-open", duration: Date.now.timeIntervalSince(storageOpenStart))
            let cachedCatalog = CurrencyCatalogCache.load()
            currencyCatalog = CurrencyDescriptor.appCatalog(cachedCatalog?.currencies ?? [])
            currencyCatalogUpdatedAt = cachedCatalog?.fetchedAt
            let loadStart = Date.now
            if let library = try Self.loadLibrary() {
                guard let active = library.books.first(where: { $0.id == library.activeBookID }) ?? library.books.first else { throw BackupError.invalidFormat }
                books = library.books; activeBookID = active.id; state = active.state
                let totalTxs = library.books.reduce(0) { $0 + $1.state.transactions.count }
                LedgerDiagnostics.recordStartupPhase("materialize", duration: Date.now.timeIntervalSince(loadStart), books: library.books.count, transactions: totalTxs)
            } else if let legacy = try Self.loadLegacyState() {
                state = legacy; books[0].state = legacy
                LedgerDiagnostics.recordStartupPhase("legacy-materialize", duration: Date.now.timeIntervalSince(loadStart), books: 1, transactions: legacy.transactions.count)
            }
            persistenceEnabled = true
            let recurringStart = Date.now
            processDueRecurring()
            LedgerDiagnostics.recordStartupPhase("process-recurring", duration: Date.now.timeIntervalSince(recurringStart))
            scheduleNextInstallmentRefresh()
            let totalStartupDuration = Date.now.timeIntervalSince(startupStart)
            let finalTxs = books.reduce(0) { $0 + $1.state.transactions.count }
            LedgerDiagnostics.recordStartupPhase("ready", duration: totalStartupDuration, books: books.count, transactions: finalTxs)
        } catch {
            // Keep disk data untouched. The existing error presentation reports the failure.
            presentedError = String(format: String(localized: "The ledger could not be loaded. Existing data has been preserved. %@"), error.localizedDescription)
            LedgerDiagnostics.failure(error, operation: "startup", logger: LedgerDiagnostics.persistence)
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
        let result: [AccountViewModel]
        if persistenceEnabled, let repo = try? Self.localRepository.transactionRepository() {
            let activeAccounts = index.activeAccounts
            result = activeAccounts.map { acc in
                if let bal = try? repo.accountBalance(for: acc, bookID: activeBookID, rates: state.settings.rates) {
                    return AccountViewModel(account: acc, balance: bal)
                } else {
                    return AccountViewModel(account: acc, balance: LedgerCalculations.balance(for: acc, in: state, index: index))
                }
            }
        } else {
            result = LedgerCalculations.accountViews(state, index: index)
        }
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

    func transaction(id: UUID) -> LedgerTransaction? {
        if let inMemory = state.transactions.first(where: { $0.id == id }) {
            return inMemory
        }
        guard persistenceEnabled else { return nil }
        return try? Self.localRepository.transactionRepository().transaction(id: id, bookID: activeBookID)
    }

    func transactions(from: Date? = nil, to: Date? = nil) -> [LedgerTransaction] {
        if !persistenceEnabled {
            return state.transactions.filter { tx in
                tx.deletedAt == nil &&
                (from == nil || tx.occurredAt >= from!) &&
                (to == nil || tx.occurredAt <= to!)
            }.sorted { $0.occurredAt > $1.occurredAt }
        }

        let diskTransactions = (try? Self.localRepository.transactionRepository().transactions(
            bookID: activeBookID,
            from: from,
            to: to,
            limit: nil,
            offset: nil
        )) ?? []

        var map = Dictionary(diskTransactions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for tx in state.transactions {
            let inRange = (from == nil || tx.occurredAt >= from!) && (to == nil || tx.occurredAt <= to!)
            if inRange {
                if tx.deletedAt != nil {
                    map.removeValue(forKey: tx.id)
                } else {
                    map[tx.id] = tx
                }
            } else {
                map.removeValue(forKey: tx.id)
            }
        }
        return map.values.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    func materializeFullState() -> LedgerState {
        // Under full-hydration baseline, in-memory state is always fully materialized.
        state
    }

    func loadNextTransactionPage(pageSize: Int = 250) {
        hasMoreTransactions = false
    }

    func refreshHasMoreTransactions() {
        hasMoreTransactions = false
    }
}
