import Foundation
import SwiftUI
import CloudKit

enum AppRoute: Equatable, Sendable {
    case addTransaction
    case purchase(UUID)
    case account(UUID)
    case overview
    case ledger
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

public enum LedgerAccessState: Sendable {
    case normal
    case readOnlyRecovery
    case unavailable
}

    private(set) var accessState: LedgerAccessState = .unavailable

    @discardableResult
    func mutateState<R>(_ impact: StateMutationImpact = .financial, _ mutation: (inout LedgerState) throws -> R) rethrows -> R {
        guard canMutateLedger else {
            var discarded = state
            let result = try mutation(&discarded)
            rejectRecoveryMutation()
            return result
        }
        var newState = state
        let result = try mutation(&newState)
        activeMutationImpact = impact
        defer { activeMutationImpact = nil }
        state = newState
        return result
    }

    var canMutateLedger: Bool { accessState == .normal }

    func rejectRecoveryMutation() {
        guard !canMutateLedger else { return }
        activeUndoOperation = nil
        undoTransactions = []
        undoMessage = nil
        if accessState == .readOnlyRecovery {
            presentedError = String(localized: "This recovered snapshot is read-only. Export it before resetting or replacing local data.")
        } else {
            presentedError = String(localized: "The ledger could not be loaded safely. Editing is disabled to protect existing data.")
        }
    }

    func leaveRecoveryModeAfterReset() {
        persistenceRecoveryMode = nil
        persistenceBaseline = nil
        accessState = .normal
    }

    /// Ledger selection is read-only navigation and remains available for exporting every book
    /// in a recovered JSON library. This never commits or schedules a SQLite save.
    func switchRecoveredBook(to id: UUID) {
        guard persistenceRecoveryMode == .legacyJSONReadOnlyRecovery,
              let book = books.first(where: { $0.id == id }) else { return }
        activeBookID = id
        activeMutationImpact = .full
        state = book.state
        activeMutationImpact = nil
        undoTransactions = []
        activeUndoOperation = nil
        undoMessage = nil
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
    @Published var acceptingCloudShare = false
    @Published var incomingDeviceAuthorization: IncomingDeviceAuthorization?
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
    var saveTask: Task<Void, Never>?
    var undoTransactions: [LedgerTransaction] = []
    var activeUndoOperation: LedgerUndoOperation?
    var currencyCatalogUpdatedAt: Date?
    /// A dismissed bridge notice stays dismissed for the current purchase.
    var suppressedPurchaseSyncWarning: String?
    var iCloudSyncReady = false
    var persistenceEnabled: Bool
    /// Set only when a stale legacy snapshot is exposed because SQLite failed validation.
    /// Automatic writes and domain processing stay disabled so neither store is damaged.
    private(set) var persistenceRecoveryMode: LedgerLibraryLoadSource?
    @Published var cloudSyncDates: [String: Date] = (UserDefaults.standard.dictionary(forKey: "Finsy.cloudSyncDates") ?? [:]).compactMapValues { $0 as? Date }
    @Published var sharedLedgerIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "Finsy.sharedLedgerIDs") ?? [])

    func markCloudSyncCompleted(participant: Bool) {
        for book in books where (participant ? book.effectiveStorageKind == .cloudParticipant : book.effectiveStorageKind == .cloudOwner) {
            cloudSyncDates[book.id.uuidString] = .now
        }
        UserDefaults.standard.set(cloudSyncDates, forKey: "Finsy.cloudSyncDates")
    }

    func markLedgerShared(_ id: UUID) {
        sharedLedgerIDs.insert(id.uuidString)
        UserDefaults.standard.set(Array(sharedLedgerIDs), forKey: "Finsy.sharedLedgerIDs")
        Task {
            do { try await CloudLedgerService.shared.updateICloudPreference() }
            catch { self.lastSyncError = error.localizedDescription }
        }
    }

    @Published var lastSyncError: String?
    var saveRevision: UInt64 = 0
    /// Validated SQLite snapshot used only to seed the serialized writer after launch.
    var persistenceBaseline: LedgerLibrary?
    nonisolated static let localRepository = LocalLedgerRepository()

    init() {
        let startupStart = Date.now
        accessState = .unavailable
        persistenceEnabled = false
        persistenceRecoveryMode = nil
        persistenceBaseline = nil
        currencyCatalog = CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = nil
        let initial = SeedData.makeProductionEmpty()
        let fallback = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now, isImplicitPlaceholder: true)
        books = [fallback]; activeBookID = fallback.id; state = initial
        do {
            let storageOpenStart = Date.now
            try FinsyStorage.prepare()
            LedgerDiagnostics.recordStartupPhase("storage-open", duration: Date.now.timeIntervalSince(storageOpenStart))
            let cachedCatalog = CurrencyCatalogCache.load()
            currencyCatalog = CurrencyDescriptor.appCatalog(cachedCatalog?.currencies ?? [])
            currencyCatalogUpdatedAt = cachedCatalog?.fetchedAt
            let loadStart = Date.now
            if let result = try Self.loadLibraryResult() {
                let library = result.library
                guard let active = library.books.first(where: { $0.id == library.activeBookID }) ?? library.books.first else { throw BackupError.invalidFormat }
                books = library.books; activeBookID = active.id; state = active.state
                persistenceBaseline = result.writerBaseline
                let totalTxs = library.books.reduce(0) { $0 + $1.state.transactions.count }
                LedgerDiagnostics.recordStartupPhase("materialize", duration: Date.now.timeIntervalSince(loadStart), books: library.books.count, transactions: totalTxs)
                if result.source == .legacyJSONReadOnlyRecovery {
                    persistenceRecoveryMode = result.source
                    accessState = .readOnlyRecovery
                    presentedError = String(
                        format: String(localized: "The current database could not be loaded. A legacy snapshot is open read-only so you can export it. Existing files were preserved. %@"),
                        result.sqliteFailureDescription ?? ""
                    )
                } else {
                    accessState = .normal
                }
            } else if let legacy = try Self.loadLegacyState() {
                state = legacy; books[0].state = legacy
                accessState = .normal
                LedgerDiagnostics.recordStartupPhase("legacy-materialize", duration: Date.now.timeIntervalSince(loadStart), books: 1, transactions: legacy.transactions.count)
            } else {
                accessState = .normal
            }
            persistenceEnabled = persistenceRecoveryMode == nil
            guard persistenceEnabled else {
                LedgerDiagnostics.persistence.notice("Startup entered read-only legacy recovery mode")
                return
            }
            let recurringStart = Date.now
            processDueRecurring()
            LedgerDiagnostics.recordStartupPhase("process-recurring", duration: Date.now.timeIntervalSince(recurringStart))
            scheduleNextInstallmentRefresh()
            let totalStartupDuration = Date.now.timeIntervalSince(startupStart)
            let finalTxs = books.reduce(0) { $0 + $1.state.transactions.count }
            LedgerDiagnostics.recordStartupPhase("ready", duration: totalStartupDuration, books: books.count, transactions: finalTxs)
        } catch {
            // Keep disk data untouched. The existing error presentation reports the failure.
            accessState = .unavailable
            presentedError = String(format: String(localized: "The ledger could not be loaded safely. Editing is disabled to protect existing data. %@"), error.localizedDescription)
            LedgerDiagnostics.failure(error, operation: "startup", logger: LedgerDiagnostics.persistence)
        }
    }

    init(stateForTesting initialState: LedgerState, recoveryMode: LedgerLibraryLoadSource? = nil) {
        persistenceEnabled = false
        persistenceRecoveryMode = recoveryMode
        persistenceBaseline = nil
        accessState = recoveryMode == .legacyJSONReadOnlyRecovery ? .readOnlyRecovery : .normal
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
        // The domain engine is the posting authority for refunds, installments and grouped
        // transactions. The SQLite aggregate intentionally lacks that presentation metadata.
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
        guard canMutateLedger else { rejectRecoveryMutation(); return }
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

        // Wake periodically for very distant schedules and clock changes. Converting an
        // unbounded interval to UInt64 nanoseconds can trap during startup.
        let delay = min(max(0.1, nextDueDate.timeIntervalSince(now)), 86_400)
        installmentTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshDueInstallments(now: .now)
        }
    }

    func transaction(id: UUID) -> LedgerTransaction? {
        state.transactions.first(where: { $0.id == id })
    }

    func transactions(from: Date? = nil, to: Date? = nil) -> [LedgerTransaction] {
        // The index already owns the stable chronology for this financial revision.
        index.sortedActiveTransactions.filter { tx in
            if let from, tx.occurredAt < from { return false }
            if let to, tx.occurredAt > to { return false }
            return true
        }
    }

    func materializeFullState() -> LedgerState {
        // Under full-hydration baseline, in-memory state is always fully materialized.
        state
    }
}
