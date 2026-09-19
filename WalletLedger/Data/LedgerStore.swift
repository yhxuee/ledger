import Foundation
import SwiftUI
import CloudKit

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var state: LedgerState
    @Published private(set) var books: [LedgerBook]
    @Published private(set) var activeBookID: UUID
    @Published private(set) var currencyCatalog: [CurrencyDescriptor]
    @Published var presentedError: String?
    @Published var undoMessage: String?
    @Published var routedPurchaseID: UUID?
    private var saveTask: Task<Void, Never>?
    private var undoTransactions: [LedgerTransaction] = []
    private var undoState: LedgerState?
    private var currencyCatalogUpdatedAt: Date?
    private let persistenceEnabled: Bool
    nonisolated private static let localRepository = LocalLedgerRepository()

    init() {
        persistenceEnabled = true
        let cachedCatalog = CurrencyCatalogCache.load()
        currencyCatalog = cachedCatalog?.currencies ?? CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = cachedCatalog?.fetchedAt
        if let library = Self.loadLibrary(), let active = library.books.first(where: { $0.id == library.activeBookID }) ?? library.books.first {
            books = library.books
            activeBookID = active.id
            state = active.state
            processDueRecurring()
            scheduleSave()
        } else {
            let initial = Self.loadLegacyState() ?? SeedData.make()
            let book = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now)
            books = [book]
            activeBookID = book.id
            state = initial
            scheduleSave()
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

    var accounts: [AccountViewModel] { LedgerCalculations.accountViews(state) }
    var activeTransactions: [LedgerTransaction] { LedgerCalculations.activeTransactions(state).sorted { $0.occurredAt > $1.occurredAt } }
    var activeBookName: String { books.first(where: { $0.id == activeBookID })?.name ?? "Ledger" }
    var activeBook: LedgerBook {
        var book = books.first(where: { $0.id == activeBookID }) ?? LedgerBook(id: activeBookID, name: activeBookName, state: state, createdAt: .now, updatedAt: .now)
        book.state = state
        return book
    }
    var availableCurrencies: [CurrencyCode] {
        var codes = currencyCatalog.map(\.code)
        codes.append(contentsOf: state.settings.rates.keys.filter { !codes.contains($0) }.sorted { $0.rawValue < $1.rawValue })
        return codes.filter { state.settings.rates[$0].map { $0.isFinite && $0 > 0 } == true }
    }

    func refreshCurrencyCatalogIfNeeded(force: Bool = false) async throws {
        if !force, let updated = currencyCatalogUpdatedAt, Date.now.timeIntervalSince(updated) < 7 * 86_400 { return }
        let currencies = try await FrankfurterRateService.shared.currencyCatalog()
        let snapshot = CurrencyCatalogSnapshot(fetchedAt: .now, currencies: currencies)
        currencyCatalog = currencies
        currencyCatalogUpdatedAt = snapshot.fetchedAt
        try CurrencyCatalogCache.write(snapshot)
    }

    func switchBook(to id: UUID) {
        guard id != activeBookID else { return }
        commitActiveBook()
        guard let book = books.first(where: { $0.id == id }) else { return }
        activeBookID = book.id
        state = book.state
        undoTransactions = []
        undoState = nil
        undoMessage = nil
        processDueRecurring()
        scheduleSave()
    }

    func createBook(named rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Ledger \(books.count + 1)" : trimmed
        commitActiveBook()
        let book = LedgerBook(id: UUID(), name: name, state: SeedData.makeEmpty(), createdAt: .now, updatedAt: .now)
        books.append(book)
        activeBookID = book.id
        state = book.state
        undoTransactions = []
        undoState = nil
        undoMessage = nil
        scheduleSave()
    }

    func markActiveBookCloudOwner(zoneName: String) {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].storageKind = .cloudOwner
        books[index].cloudZoneName = zoneName
        books[index].cloudZoneOwnerName = CKCurrentUserDefaultName
        books[index].state = state
        scheduleSave()
    }

    func addOrMergeCloudBook(_ book: LedgerBook) {
        commitActiveBook()
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            guard book.updatedAt >= books[index].updatedAt else { return }
            books[index] = book
        } else { books.append(book) }
        activeBookID = book.id
        state = book.state
        scheduleSave()
    }

    @discardableResult
    func addTransaction(type: LedgerTransactionType, accountID: UUID, destinationAccountID: UUID?, amount: Double, currency: CurrencyCode, categoryID: LedgerCategoryID, occurredAt: Date, note: String?, purchaseSessionID: UUID? = nil, purchaseItemID: UUID? = nil) -> LedgerTransaction? {
        guard amount > 0, let source = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }) else { return nil }
        let destination = destinationAccountID.flatMap { id in state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) }
        guard type != .transfer || (destination != nil && destination?.id != source.id) else { return nil }
        let rates = state.settings.rates
        let item = LedgerTransaction(id: UUID(), userID: state.settings.userID, type: type, accountID: source.id, destinationAccountID: type == .transfer ? destination?.id : nil, amount: amount, currency: currency, accountAmount: LedgerCalculations.convert(amount, from: currency, to: source.currency, rates: rates), destinationAmount: type == .transfer ? destination.map { LedgerCalculations.convert(amount, from: currency, to: $0.currency, rates: rates) } : nil, categoryID: type == .transfer ? .other : categoryID, occurredAt: occurredAt, note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, exchangeRateAtTransaction: rates[currency] ?? 1, purchaseSessionID: purchaseSessionID, purchaseItemID: purchaseItemID, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
        state.transactions.insert(item, at: 0)
        scheduleSave()
        return item
    }

    func updateTransaction(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }), !state.transactions[index].isLockedByReversal, let source = state.accounts.first(where: { $0.id == item.accountID }) else { return }
        var updated = item
        updated.accountAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: source.currency, rates: state.settings.rates)
        if item.type == .transfer, let destinationID = item.destinationAccountID, let destination = state.accounts.first(where: { $0.id == destinationID }) {
            updated.destinationAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: destination.currency, rates: state.settings.rates)
            updated.categoryID = .other
        } else {
            updated.destinationAccountID = nil
            updated.destinationAmount = nil
        }
        updated.exchangeRateAtTransaction = state.settings.rates[item.currency] ?? 1
        updated.updatedAt = .now
        updated.version += 1
        updated.syncStatus = .pending
        state.transactions[index] = updated
        scheduleSave()
    }

    func deleteTransaction(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }) else { return }
        let now = Date.now
        undoState = nil
        undoTransactions = [state.transactions[index]]
        if let originalID = state.transactions[index].reversalOfTransactionID,
           let originalIndex = state.transactions.firstIndex(where: { $0.id == originalID }) {
            undoTransactions.append(state.transactions[originalIndex])
            state.transactions[originalIndex].reversalTransactionID = nil
            state.transactions[originalIndex].updatedAt = now
            state.transactions[originalIndex].version += 1
            state.transactions[originalIndex].syncStatus = .pending
        } else if let reversalID = state.transactions[index].reversalTransactionID,
                  let reversalIndex = state.transactions.firstIndex(where: { $0.id == reversalID && $0.deletedAt == nil }) {
            undoTransactions.append(state.transactions[reversalIndex])
            markDeleted(at: reversalIndex, date: now)
        }
        markDeleted(at: index, date: now)
        undoMessage = "Transaction deleted"
        scheduleSave()
    }

    func undoDelete() {
        if let undoState {
            state = undoState
            self.undoState = nil
            undoTransactions = []
            undoMessage = nil
            scheduleSave()
            return
        }
        guard !undoTransactions.isEmpty else { return }
        for item in undoTransactions {
            if let index = state.transactions.firstIndex(where: { $0.id == item.id }) { state.transactions[index] = item }
        }
        undoTransactions = []
        undoMessage = nil
        scheduleSave()
    }

    @discardableResult
    func refundTransaction(_ original: LedgerTransaction) -> LedgerTransaction? {
        guard original.deletedAt == nil, !original.isReversal, original.reversalTransactionID == nil,
              let originalIndex = state.transactions.firstIndex(where: { $0.id == original.id && $0.deletedAt == nil }),
              !state.transactions.contains(where: { $0.reversalOfTransactionID == original.id && $0.deletedAt == nil }) else { return nil }
        let now = Date.now
        guard let reversal = RefundEngine.makeReversal(of: original, in: state, now: now) else { return nil }
        state.transactions[originalIndex].reversalTransactionID = reversal.id
        state.transactions[originalIndex].updatedAt = now
        state.transactions[originalIndex].version += 1
        state.transactions[originalIndex].syncStatus = .pending
        state.transactions.insert(reversal, at: 0)
        scheduleSave()
        return reversal
    }

    private func markDeleted(at index: Int, date: Date) {
        state.transactions[index].deletedAt = date
        state.transactions[index].updatedAt = date
        state.transactions[index].version += 1
        state.transactions[index].syncStatus = .pending
    }

    func saveAccount(_ draft: LedgerAccount, desiredBalance: Double) {
        var account = draft
        var zeroOpening = draft
        zeroOpening.openingBalance = 0
        let ledgerDelta = LedgerCalculations.balance(for: zeroOpening, in: state)
        let previousRuleID = state.accounts.first(where: { $0.id == draft.id })?.loanMetadata?.linkedRecurringRuleID
        if let current = state.accounts.first(where: { $0.id == draft.id }) {
            account.openingBalance = desiredBalance - ledgerDelta
            account.version = current.version + 1
            account.createdAt = current.createdAt
        } else {
            account.openingBalance = desiredBalance - ledgerDelta
            account.version = 1
        }
        account.updatedAt = .now
        account.deletedAt = nil
        account.syncStatus = .pending
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) { state.accounts[index] = account }
        else { state.accounts.append(account) }
        syncLoanInterestRule(accountID: account.id, previousRuleID: previousRuleID)
        scheduleSave()
    }

    private func syncLoanInterestRule(accountID: UUID, previousRuleID: UUID?) {
        guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let account = state.accounts[accountIndex]
        guard account.type == .loan, var metadata = account.loanMetadata, metadata.annualPercentageRate > 0, let interval = metadata.interestInterval else {
            if let previousRuleID, let ruleIndex = state.recurringRules?.firstIndex(where: { $0.id == previousRuleID }) { state.recurringRules?[ruleIndex].isEnabled = false; state.recurringRules?[ruleIndex].updatedAt = .now }
            return
        }
        var rules = state.recurringRules ?? []
        let ruleID = metadata.linkedRecurringRuleID ?? previousRuleID ?? UUID()
        let now = Date.now
        let existing = rules.first(where: { $0.id == ruleID })
        let rule = RecurringRule(id: ruleID, userID: state.settings.userID, type: .expense, accountID: account.id, destinationAccountID: nil, amount: 0, amountKind: .loanInterest, linkedLoanAccountID: account.id, currency: account.currency, categoryID: .other, note: "\(account.name) Interest", interval: interval, customIntervalDays: max(1, metadata.customIntervalDays), nextRunAt: existing?.nextRunAt ?? nextDate(after: now, interval: interval, customDays: metadata.customIntervalDays), isEnabled: true, createdAt: existing?.createdAt ?? now, updatedAt: now)
        if let index = rules.firstIndex(where: { $0.id == ruleID }) { rules[index] = rule } else { rules.append(rule) }
        metadata.linkedRecurringRuleID = ruleID
        state.accounts[accountIndex].loanMetadata = metadata
        state.recurringRules = rules
    }

    func deleteAccount(_ account: LedgerAccount) {
        undoState = state
        let deletedAt = Date.now
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
            state.accounts[index].deletedAt = deletedAt
            state.accounts[index].updatedAt = deletedAt
            state.accounts[index].version += 1
        }
        for index in state.transactions.indices where state.transactions[index].accountID == account.id || state.transactions[index].destinationAccountID == account.id {
            state.transactions[index].deletedAt = deletedAt
            state.transactions[index].updatedAt = deletedAt
            state.transactions[index].version += 1
        }
        if var rules = state.recurringRules {
            for index in rules.indices where rules[index].accountID == account.id || rules[index].destinationAccountID == account.id { rules[index].isEnabled = false; rules[index].updatedAt = deletedAt }
            state.recurringRules = rules
        }
        state.settings.defaultExpenseAccountByCategory = state.settings.defaultExpenseAccountByCategory.filter { $0.value != account.id }
        state.settings.budgetPlan.accountAllocations[account.id] = nil
        if var sessions = state.purchaseSessions {
            for sessionIndex in sessions.indices {
                for itemIndex in sessions[sessionIndex].items.indices where sessions[sessionIndex].items[itemIndex].resolvedAccountID == account.id { sessions[sessionIndex].items[itemIndex].resolvedAccountID = nil }
            }
            state.purchaseSessions = sessions
        }
        undoMessage = "Account deleted"
        scheduleSave()
    }

    func updateSettings(_ change: (inout LedgerSettings) -> Void) {
        change(&state.settings)
        state.settings.updatedAt = .now
        scheduleSave()
    }

    @discardableResult
    func refreshExchangeRatesIfNeeded(force: Bool = false) async throws -> String? {
        guard force || state.settings.automaticRates else { return nil }
        if !force, let updated = state.settings.exchangeRatesUpdatedAt, Calendar.current.isDateInToday(updated) { return nil }
        let requestedBookID = activeBookID
        let result = try await FrankfurterRateService.shared.latest()
        guard requestedBookID == activeBookID else { return nil }
        updateSettings {
            $0.rates.merge(result.rates) { _, new in new }
            $0.rates[.HKD] = 1
            $0.exchangeRatesUpdatedAt = .now
        }
        return result.sourceDate
    }

    @discardableResult
    func addCategory(name rawName: String, detail rawDetail: String, symbol: String, colorHex: String) -> LedgerCategoryID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !symbol.isEmpty else { return nil }
        let id = LedgerCategoryID(rawValue: "custom-\(UUID().uuidString.lowercased())")
        state.categories.append(.init(id: id, name: name, detail: rawDetail.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol, colorHex: colorHex))
        scheduleSave()
        return id
    }

    var recurringRules: [RecurringRule] { (state.recurringRules ?? []).filter { $0.deletedAt == nil } }
    var purchaseSessions: [PurchaseSession] { (state.purchaseSessions ?? []).filter { $0.status != .cancelled }.sorted { $0.createdAt > $1.createdAt } }

    func savePurchaseSession(_ session: PurchaseSession) {
        var sessions = state.purchaseSessions ?? []
        var updated = session
        updated.ledgerBookID = activeBookID
        if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated } else { sessions.append(updated) }
        state.purchaseSessions = sessions
        scheduleSave()
        if updated.status == .active { Task { await PurchaseLiveActivityController.shared.startOrUpdate(session: updated, currency: state.settings.baseCurrency) } }
    }

    func cancelPurchaseSession(_ session: PurchaseSession) {
        guard var sessions = state.purchaseSessions, let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].status = .cancelled
        state.purchaseSessions = sessions
        scheduleSave()
    }

    func setPurchaseItem(_ itemID: UUID, in sessionID: UUID, completed: Bool) -> PurchaseSession? {
        guard var sessions = state.purchaseSessions, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }), let itemIndex = sessions[sessionIndex].items.firstIndex(where: { $0.id == itemID }) else { return nil }
        sessions[sessionIndex].items[itemIndex].isCompleted = completed
        sessions[sessionIndex].items[itemIndex].completedAt = completed ? .now : nil
        if sessions[sessionIndex].items.allSatisfy(\.isCompleted) { sessions[sessionIndex].status = .awaitingSummary; sessions[sessionIndex].completedAt = .now }
        else if sessions[sessionIndex].status != .draft { sessions[sessionIndex].status = .active; sessions[sessionIndex].completedAt = nil }
        state.purchaseSessions = sessions
        scheduleSave()
        Task { await PurchaseLiveActivityController.shared.startOrUpdate(session: sessions[sessionIndex], currency: state.settings.baseCurrency) }
        return sessions[sessionIndex]
    }

    func finalizePurchaseSession(_ sessionID: UUID, receiptAttachmentID: String?) throws {
        guard var sessions = state.purchaseSessions, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        if sessions[sessionIndex].status == .completed { return }
        guard sessions[sessionIndex].status == .awaitingSummary, sessions[sessionIndex].items.allSatisfy(\.isCompleted) else { throw PurchaseFinalizationError.notReady }
        for item in sessions[sessionIndex].items where item.linkedTransactionID == nil {
            guard item.amount > 0, let accountID = item.resolvedAccountID, state.accounts.contains(where: { $0.id == accountID && $0.deletedAt == nil }) else { throw PurchaseFinalizationError.invalidItem }
        }
        for itemIndex in sessions[sessionIndex].items.indices where sessions[sessionIndex].items[itemIndex].linkedTransactionID == nil {
            let item = sessions[sessionIndex].items[itemIndex]
            guard let accountID = item.resolvedAccountID,
                  let transaction = addTransaction(type: .expense, accountID: accountID, destinationAccountID: nil, amount: item.amount, currency: state.settings.baseCurrency, categoryID: item.categoryID, occurredAt: item.completedAt ?? .now, note: item.note, purchaseSessionID: sessionID, purchaseItemID: item.id) else { throw PurchaseFinalizationError.invalidItem }
            sessions[sessionIndex].items[itemIndex].linkedTransactionID = transaction.id
        }
        sessions[sessionIndex].receiptAttachmentID = receiptAttachmentID ?? sessions[sessionIndex].receiptAttachmentID
        sessions[sessionIndex].status = .completed
        sessions[sessionIndex].completedAt = .now
        state.purchaseSessions = sessions
        scheduleSave()
        Task { await PurchaseLiveActivityController.shared.startOrUpdate(session: sessions[sessionIndex], currency: state.settings.baseCurrency) }
    }

    func reconcileSharedActivePurchases() {
        guard var sessions = state.purchaseSessions else { return }
        var changed = false
        for index in sessions.indices where sessions[index].status == .active || sessions[index].status == .awaitingSummary {
            guard let snapshot = PurchaseSharedStateStore.read(sessionID: sessions[index].id), snapshot.updatedAt > (sessions[index].items.compactMap(\.completedAt).max() ?? sessions[index].startedAt ?? sessions[index].createdAt) else { continue }
            sessions[index] = snapshot.session
            changed = true
        }
        if changed { state.purchaseSessions = sessions; scheduleSave() }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "walletledger", url.host == "purchase", let rawID = url.pathComponents.dropFirst().first, let id = UUID(uuidString: rawID), purchaseSessions.contains(where: { $0.id == id }) else { return }
        routedPurchaseID = id
    }

    func saveRecurringRule(_ rule: RecurringRule) {
        var rules = state.recurringRules ?? []
        var activeRule = rule
        activeRule.deletedAt = nil
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = activeRule }
        else { rules.append(activeRule) }
        state.recurringRules = rules
        scheduleSave()
    }

    func deleteRecurringRule(_ rule: RecurringRule) {
        guard var rules = state.recurringRules, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        undoState = state
        rules[index].deletedAt = .now
        rules[index].isEnabled = false
        rules[index].updatedAt = .now
        state.recurringRules = rules
        undoMessage = "Recurring transaction deleted"
        scheduleSave()
    }

    func setRecurringRule(_ rule: RecurringRule, enabled: Bool) {
        guard var rules = state.recurringRules, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled = enabled
        rules[index].updatedAt = .now
        state.recurringRules = rules
        scheduleSave()
    }

    func processDueRecurring(now: Date = .now) {
        guard var rules = state.recurringRules, !rules.isEmpty else { return }
        var changed = false
        for index in rules.indices where rules[index].isEnabled && rules[index].deletedAt == nil {
            var executions = 0
            while rules[index].nextRunAt <= now && executions < 100 {
                let rule = rules[index]
                let amount = recurringAmount(for: rule)
                if amount > 0 { addTransaction(type: rule.type, accountID: rule.accountID, destinationAccountID: rule.destinationAccountID, amount: amount, currency: rule.currency, categoryID: rule.categoryID, occurredAt: rule.nextRunAt, note: rule.note) }
                rules[index].nextRunAt = nextDate(after: rule.nextRunAt, interval: rule.interval, customDays: rule.customIntervalDays)
                rules[index].updatedAt = now
                executions += 1
                changed = true
            }
        }
        if changed { state.recurringRules = rules; scheduleSave() }
    }

    private func recurringAmount(for rule: RecurringRule) -> Double {
        guard rule.effectiveAmountKind == .loanInterest else { return rule.amount }
        guard let accountID = rule.linkedLoanAccountID,
              let account = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }),
              let loan = account.loanMetadata, loan.annualPercentageRate > 0 else { return 0 }
        let principal = abs(LedgerCalculations.balance(for: account, in: state))
        let periods: Double
        switch rule.interval { case .weekly: periods = 52; case .monthly: periods = 12; case .yearly: periods = 1; case .customDays: periods = 365 / Double(max(1, rule.customIntervalDays)) }
        return principal * (loan.annualPercentageRate / 100) / max(1, periods)
    }

    private func nextDate(after date: Date, interval: RecurringInterval, customDays: Int) -> Date {
        let component: Calendar.Component
        let value: Int
        switch interval {
        case .weekly: component = .weekOfYear; value = 1
        case .monthly: component = .month; value = 1
        case .yearly: component = .year; value = 1
        case .customDays: component = .day; value = max(1, customDays)
        }
        return Calendar.current.date(byAdding: component, value: value, to: date) ?? date.addingTimeInterval(86_400)
    }

    func replace(with envelope: LedgerBackupEnvelope) {
        do {
            try BackupCodec.validate(envelope.data)
            if activeBook.effectiveStorageKind == .local {
                state = envelope.data
            } else {
                commitActiveBook()
                let now = Date.now
                let imported = LedgerBook(id: UUID(), name: "Imported Ledger", state: envelope.data, createdAt: now, updatedAt: now, storageKind: .local, cloudZoneName: nil, cloudZoneOwnerName: nil)
                books.append(imported)
                activeBookID = imported.id
                state = imported.state
            }
            scheduleSave()
        } catch { presentedError = error.localizedDescription }
    }

    func resetLocalData() throws {
        saveTask?.cancel()
        try Self.localRepository.resetLocalData()
        try PurchaseSharedStateStore.resetLocalSnapshots()
        Task { await PurchaseLiveActivityController.shared.endAll() }
        let initial = SeedData.make()
        let book = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now)
        books = [book]
        activeBookID = book.id
        state = initial
        currencyCatalog = CurrencyDescriptor.bundled
        currencyCatalogUpdatedAt = nil
        undoTransactions = []
        undoState = nil
        undoMessage = nil
        scheduleSave()
    }

    func backupEnvelope() -> LedgerBackupEnvelope { BackupCodec.envelope(for: state) }

    private func scheduleSave() {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        let snapshot = librarySnapshot()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            do { try Self.writeLibrary(snapshot) }
            catch { presentedError = "Local save failed: \(error.localizedDescription)" }
            if let active = snapshot.books.first(where: { $0.id == snapshot.activeBookID }), active.effectiveStorageKind != .local {
                try? await CloudLedgerService.shared.synchronize(book: active)
            }
        }
    }

    private func commitActiveBook() {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].state = state
        books[index].updatedAt = .now
    }

    private func librarySnapshot() -> LedgerLibrary {
        var snapshotBooks = books
        if let index = snapshotBooks.firstIndex(where: { $0.id == activeBookID }) {
            snapshotBooks[index].state = state
            snapshotBooks[index].updatedAt = .now
        }
        return LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: activeBookID, books: snapshotBooks)
    }

    nonisolated private static var storageFolder: URL { LocalLedgerRepository.storageFolder }

    private static func loadLibrary() -> LedgerLibrary? {
        guard let library = try? localRepository.loadLibrary() else { return nil }
        guard !library.books.isEmpty else { return nil }
        guard library.books.allSatisfy({ (try? BackupCodec.validate($0.state)) != nil }) else { return nil }
        return library
    }

    private static func loadLegacyState() -> LedgerState? {
        let url = storageFolder.appending(path: "ledger.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let state: LedgerState
        if let current = try? BackupCodec.decoder().decode(LedgerState.self, from: data), current.schemaVersion >= 2 { state = current }
        else if let old = try? BackupCodec.decoder().decode(LedgerStateV1.self, from: data), old.schemaVersion <= 1 { state = SchemaMigration.migrate(old) }
        else { return nil }
        guard (try? BackupCodec.validate(state)) != nil else { return nil }
        return state
    }

    nonisolated private static func writeLibrary(_ library: LedgerLibrary) throws {
        try localRepository.saveLibrary(library)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum PurchaseFinalizationError: LocalizedError {
    case missingSession, notReady, invalidItem
    var errorDescription: String? {
        switch self { case .missingSession: "Purchase session was not found."; case .notReady: "Complete every purchase item before creating ledger transactions."; case .invalidItem: "A purchase item is missing a valid amount or expense account." }
    }
}
