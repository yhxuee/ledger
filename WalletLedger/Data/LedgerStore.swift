import Foundation
import SwiftUI
import CloudKit

@MainActor
final class LedgerStore: ObservableObject {
    static let shared = LedgerStore()
    private var fxRefreshes: Set<UUID> = []
    @Published private(set) var state: LedgerState
    @Published private(set) var books: [LedgerBook]
    @Published private(set) var activeBookID: UUID
    @Published private(set) var currencyCatalog: [CurrencyDescriptor]
    @Published var presentedError: String?
    /// Nonfatal Purchase Mode infrastructure notice (App Group bridge / Live Activity).
    /// Never used for business-logic failures and never presented as a modal alert.
    @Published var purchaseSyncWarning: String?
    @Published var undoMessage: String?
    @Published var routedPurchaseID: UUID?
    @Published var requestedAnalyticsType: LedgerTransactionType? = nil
    @Published var requestedAnalyticsRange: AnalyticsRange? = nil
    @Published var requestedAnalyticsCustomRange: ClosedRange<Date>? = nil
    private var saveTask: Task<Void, Never>?
    private var undoTransactions: [LedgerTransaction] = []
    private var undoState: LedgerState?
    private var currencyCatalogUpdatedAt: Date?
    /// A dismissed bridge notice stays dismissed for the current purchase.
    private var suppressedPurchaseSyncWarning: String?
    private let persistenceEnabled: Bool
    nonisolated private static let localRepository = LocalLedgerRepository()

    init() {
        persistenceEnabled = true
        let cachedCatalog = CurrencyCatalogCache.load()
        currencyCatalog = CurrencyDescriptor.appCatalog(cachedCatalog?.currencies ?? [])
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
        return codes.filter { CurrencyRates.reference($0, in: state.settings.rates) != nil }
    }

    func refreshCurrencyCatalogIfNeeded(force: Bool = false) async throws {
        if !force, let updated = currencyCatalogUpdatedAt, Date.now.timeIntervalSince(updated) < 7 * 86_400 { return }
        let currencies = CurrencyDescriptor.appCatalog(try await FrankfurterRateService.shared.currencyCatalog())
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

    /// Resolves a requested currency pocket against an account.
    /// Single-currency accounts only ever post to their primary currency; a multi-currency
    /// account rejects an unknown pocket rather than silently redirecting the money.
    private func resolvedPocket(_ requested: CurrencyCode?, for account: LedgerAccount) -> CurrencyCode? {
        guard let requested else { return account.currency }
        guard account.usesCurrencyPockets else { return account.currency }
        return account.pocketCurrencies.contains(requested) ? requested : nil
    }

    @discardableResult
    func addTransaction(type: LedgerTransactionType, accountID: UUID, destinationAccountID: UUID?, amount: Double, currency: CurrencyCode, categoryID: LedgerCategoryID, occurredAt: Date, note: String?, noteAttachmentID: String? = nil, purchaseSessionID: UUID? = nil, purchaseItemID: UUID? = nil, accountCurrency: CurrencyCode? = nil, accountAmount: Double? = nil, destinationAccountCurrency: CurrencyCode? = nil, destinationAmount: Double? = nil) -> LedgerTransaction? {
        guard amount.isFinite, amount > 0, CurrencyRates.reference(currency, in: state.settings.rates) != nil, let source = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }) else { return nil }
        let destination = destinationAccountID.flatMap { id in state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) }
        guard type != .transfer || (destination != nil && destination?.id != source.id) else { return nil }
        let rates = state.settings.rates
        guard CurrencyRates.reference(source.currency, in: rates) != nil,
              destination.map({ CurrencyRates.reference($0.currency, in: rates) != nil }) ?? true else { return nil }
        guard let sourcePocket = resolvedPocket(accountCurrency, for: source) else { return nil }
        // `accountAmount` is authoritative: it is the actual amount posted to the pocket and may
        // differ from the FX estimate (bank spread, fees, settlement rate).
        let resolvedAccountAmount = accountAmount ?? LedgerCalculations.convert(amount, from: currency, to: sourcePocket, rates: rates)
        guard resolvedAccountAmount.isFinite else { return nil }
        var resolvedDestinationPocket: CurrencyCode?
        var resolvedDestinationAmount: Double?
        if type == .transfer, let destination {
            guard let destinationPocket = resolvedPocket(destinationAccountCurrency, for: destination) else { return nil }
            resolvedDestinationPocket = destination.usesCurrencyPockets ? destinationPocket : nil
            let value = destinationAmount ?? LedgerCalculations.convert(amount, from: currency, to: destinationPocket, rates: rates)
            guard value.isFinite else { return nil }
            resolvedDestinationAmount = value
        }
        let item = LedgerTransaction(id: UUID(), userID: state.settings.userID, type: type, accountID: source.id, destinationAccountID: type == .transfer ? destination?.id : nil, amount: amount, currency: currency, accountAmount: resolvedAccountAmount, destinationAmount: resolvedDestinationAmount, accountCurrency: source.usesCurrencyPockets ? sourcePocket : nil, destinationAccountCurrency: resolvedDestinationPocket, categoryID: type == .transfer ? .other : categoryID, occurredAt: occurredAt, note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, noteAttachmentID: noteAttachmentID, exchangeRateAtTransaction: CurrencyRates.reference(currency, in: rates) ?? 1, purchaseSessionID: purchaseSessionID, purchaseItemID: purchaseItemID, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
        state.transactions.insert(item, at: 0)
        scheduleSave()
        return item
    }

    func updateTransaction(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }), !state.transactions[index].isLockedByReversal, let source = state.accounts.first(where: { $0.id == item.accountID }) else { return }
        guard item.amount.isFinite, item.amount > 0, source.deletedAt == nil else { return }
        guard let sourcePocket = resolvedPocket(item.accountCurrency, for: source) else { return }
        let original = state.transactions[index]
        let keepsFX = item.currency == original.currency && item.accountID == original.accountID &&
            item.destinationAccountID == original.destinationAccountID && item.type == original.type &&
            item.accountCurrency == original.accountCurrency && item.destinationAccountCurrency == original.destinationAccountCurrency
        let scale = original.amount > 0 ? item.amount / original.amount : 1
        var updated = item
        updated.accountCurrency = source.usesCurrencyPockets ? sourcePocket : nil
        // A supplied account amount that differs from the stored one is a manual override and is
        // authoritative. An untouched value follows an amount edit (previous behaviour).
        if keepsFX, item.accountAmount == original.accountAmount, let existing = original.accountAmount {
            updated.accountAmount = existing * scale
        } else if let supplied = item.accountAmount, supplied.isFinite {
            updated.accountAmount = supplied
        } else {
            updated.accountAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: sourcePocket, rates: state.settings.rates)
        }
        if item.type == .transfer, let destinationID = item.destinationAccountID, let destination = state.accounts.first(where: { $0.id == destinationID }) {
            guard destination.deletedAt == nil, let destinationPocket = resolvedPocket(item.destinationAccountCurrency, for: destination) else { return }
            updated.destinationAccountCurrency = destination.usesCurrencyPockets ? destinationPocket : nil
            if keepsFX, item.destinationAmount == original.destinationAmount, let existing = original.destinationAmount {
                updated.destinationAmount = existing * scale
            } else if let supplied = item.destinationAmount, supplied.isFinite {
                updated.destinationAmount = supplied
            } else {
                updated.destinationAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: destinationPocket, rates: state.settings.rates)
            }
            updated.categoryID = .other
        } else {
            updated.destinationAccountID = nil
            updated.destinationAmount = nil
            updated.destinationAccountCurrency = nil
        }
        updated.exchangeRateAtTransaction = keepsFX ? original.exchangeRateAtTransaction : (CurrencyRates.reference(item.currency, in: state.settings.rates) ?? 1)
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

    /// A pocket that still holds money cannot be removed until it is cleared or transferred out.
    func pocketRemovalMessage(for draft: LedgerAccount) -> String? {
        guard let existing = state.accounts.first(where: { $0.id == draft.id }), existing.usesCurrencyPockets else { return nil }
        let kept = Set(draft.normalizedPockets.map(\.currency))
        for pocket in existing.normalizedPockets where !kept.contains(pocket.currency) {
            let balance = LedgerCalculations.pocketBalance(pocket.currency, for: existing, in: state)
            guard balance.isFinite, abs(balance) > 0.005 else { continue }
            return "\(pocket.currency.rawValue) pocket still holds \(LedgerFormat.money(balance, currency: pocket.currency)). Clear or transfer it first."
        }
        return nil
    }

    /// Saves an account. `desiredPocketBalances` holds one entry per pocket; pockets that are not
    /// listed keep their stored opening balance, and a pocket's opening balance absorbs its own
    /// ledger delta so the requested balance is what the user sees.
    func saveAccount(_ draft: LedgerAccount, desiredBalance: Double, desiredPocketBalances: [CurrencyCode: Double] = [:]) {
        var account = draft
        // Stocks settle in the market currency, so normalise before any balance arithmetic.
        if account.type == .stocks {
            let market = account.stockMetadata?.market ?? .US
            if account.stockMetadata == nil { account.stockMetadata = .init(market: market, symbol: "") }
            if let current = state.accounts.first(where: { $0.id == account.id })?.stockMetadata,
               current.market == account.stockMetadata?.market,
               current.symbol == account.stockMetadata?.symbol,
               current.providerSymbol == account.stockMetadata?.providerSymbol,
               let date = current.latestPriceAt,
               date >= (account.stockMetadata?.latestPriceAt ?? .distantPast) {
                account.stockMetadata?.latestPrice = current.latestPrice
                account.stockMetadata?.latestPriceAt = date
            }
            guard let stock = account.stockMetadata, stock.costBasis.isFinite, stock.value.isFinite,
                  stock.averageCost >= 0, stock.quantity >= 0 else {
                presentedError = "Enter a valid cost price and quantity."
                return
            }
            account.currency = market.settlementCurrency
            account.isMultiCurrency = false
            account.currencyPockets = []
        }
        account.isMultiCurrency = account.usesCurrencyPockets
        var pockets = account.normalizedPockets
        let previousRuleID = state.accounts.first(where: { $0.id == draft.id })?.loanMetadata?.linkedRecurringRuleID

        if account.usesCurrencyPockets {
            for index in pockets.indices {
                let currency = pockets[index].currency
                var zeroOpening = account
                zeroOpening.openingBalance = 0
                zeroOpening.currencyPockets = [.init(currency: currency, openingBalance: 0)]
                let ledgerDelta = LedgerCalculations.pocketBalance(currency, for: zeroOpening, in: state)
                let desired = desiredPocketBalances[currency] ?? (pockets[index].openingBalance + ledgerDelta)
                pockets[index].openingBalance = desired - ledgerDelta
            }
            account.currencyPockets = pockets
            // The primary currency stays mirrored for readers that only understand `openingBalance`.
            if let primary = pockets.first(where: { $0.currency == account.currency }) { account.openingBalance = primary.openingBalance }
        } else if account.type == .stocks {
            // Holdings valuation is independent of cash postings and never creates a P/L transaction.
            account.openingBalance = 0
            account.currencyPockets = []
        } else {
            var zeroOpening = draft
            zeroOpening.openingBalance = 0
            zeroOpening.isMultiCurrency = false
            zeroOpening.currencyPockets = []
            let ledgerDelta = LedgerCalculations.balance(for: zeroOpening, in: state)
            account.openingBalance = desiredBalance - ledgerDelta
            account.currencyPockets = [.init(currency: account.currency, openingBalance: account.openingBalance)]
        }

        if let current = state.accounts.first(where: { $0.id == draft.id }) {
            account.version = current.version + 1
            account.createdAt = current.createdAt
        } else {
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
            for index in sessions.indices where sessions[index].accountID == account.id && (sessions[index].status == .active || sessions[index].status == .awaitingSummary) {
                sessions[index].status = .draft
                sessions[index].updatedAt = deletedAt
                let stopped = sessions[index]
                if persistenceEnabled {
                    try? PurchaseSharedStateStore.write(session: stopped)
                    Task { await PurchaseLiveActivityController.shared.end(sessionID: stopped.id) }
                }
            }
            state.purchaseSessions = sessions
        }
        undoMessage = "Account deleted"
        scheduleSave()
    }

    func moveAccount(from sourceID: UUID, to destinationID: UUID) {
        guard sourceID != destinationID else { return }
        guard let sourceIndex = state.accounts.firstIndex(where: { $0.id == sourceID }),
              let destIndex = state.accounts.firstIndex(where: { $0.id == destinationID }) else { return }
        let account = state.accounts.remove(at: sourceIndex)
        state.accounts.insert(account, at: destIndex)
        scheduleSave()
    }

    func updateSettings(_ change: (inout LedgerSettings) -> Void) {
        change(&state.settings)
        state.settings.rates = CurrencyRates.mirroringUSDAliases(state.settings.rates)
        state.settings.updatedAt = .now
        scheduleSave()
    }

    @discardableResult
    func refreshExchangeRatesIfNeeded(force: Bool = false) async throws -> String? {
        guard force || state.settings.automaticRates else { return nil }
        if !force, let updated = state.settings.exchangeRatesUpdatedAt, Calendar.current.isDateInToday(updated) { return nil }
        let requestedBookID = activeBookID
        guard fxRefreshes.insert(requestedBookID).inserted else { return nil }
        defer { fxRefreshes.remove(requestedBookID) }
        let result = try await FrankfurterRateService.shared.latest()
        guard requestedBookID == activeBookID else { return nil }
        updateSettings {
            $0.rates.merge(result.rates) { _, new in new }
            $0.rates[.HKD] = 1
            $0.exchangeRatesUpdatedAt = .now
        }
        return result.sourceDate
    }

    var allStockMetadata: [StockMetadata] {
        let snapshot = librarySnapshot()
        var stocks: [StockMetadata] = []
        for book in snapshot.books {
            for account in book.state.accounts {
                guard account.deletedAt == nil, account.type == .stocks,
                      let metadata = account.stockMetadata else { continue }
                stocks.append(metadata)
            }
        }
        return stocks
    }

    func applyStockQuotes(_ quotes: [String: AlphaVantageService.Quote]) {
        commitActiveBook()
        var changed = false
        for bookIndex in books.indices {
            for index in books[bookIndex].state.accounts.indices {
                var account = books[bookIndex].state.accounts[index]
                guard account.deletedAt == nil, account.type == .stocks, var stock = account.stockMetadata,
                      let symbol = stock.providerSymbol ?? (stock.market == .US ? stock.symbol : nil),
                      let quote = quotes["\(stock.market.rawValue):\(symbol)"],
                      let date = stock.market.date(from: quote.tradingDay),
                      date >= (stock.latestPriceAt ?? .distantPast),
                      stock.latestPrice != quote.price || stock.latestPriceAt != date else { continue }
                stock.latestPrice = quote.price
                stock.latestPriceAt = date
                account.stockMetadata = stock
                account.updatedAt = .now
                account.version += 1
                account.syncStatus = .pending
                books[bookIndex].state.accounts[index] = account
                books[bookIndex].updatedAt = .now
                changed = true
            }
        }
        guard changed else { return }
        if let active = books.first(where: { $0.id == activeBookID }) { state = active.state }
        scheduleSave()
    }

    /// Background expiration must not strand changes in the normal debounced save task.
    @discardableResult func flushMarketData() -> Bool {
        guard persistenceEnabled else { return true }
        do { try Self.writeLibrary(librarySnapshot()); return true }
        catch { presentedError = "Local save failed: \(error.localizedDescription)"; return false }
    }

    @discardableResult
    func addCategory(name rawName: String, detail rawDetail: String, symbol: String, colorHex: String, kind: LedgerCategoryKind = .expense) -> LedgerCategoryID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !symbol.isEmpty else { return nil }
        let id = LedgerCategoryID(rawValue: "custom-\(UUID().uuidString.lowercased())")
        state.categories.append(.init(id: id, name: name, detail: rawDetail.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol, colorHex: colorHex, kind: kind))
        scheduleSave()
        return id
    }

    /// Dismisses the inline bridge notice. The identical notice is not shown again for the
    /// current purchase, so it cannot reappear on the next item tap.
    func dismissPurchaseSyncWarning() {
        suppressedPurchaseSyncWarning = purchaseSyncWarning
        purchaseSyncWarning = nil
    }

    /// Records a nonfatal bridge notice.
    ///
    /// - Repeats of the same notice are dropped, so item taps never spam the Purchase screens.
    /// - A dismissed notice stays dismissed until the bridge state changes.
    /// - A successful bridge clears a stale notice and resets the dismissal, so a later
    ///   failure is reported again.
    func reportPurchaseSyncWarning(_ message: String?) {
        guard let message, !message.isEmpty else {
            if purchaseSyncWarning != nil { purchaseSyncWarning = nil }
            suppressedPurchaseSyncWarning = nil
            return
        }
        guard suppressedPurchaseSyncWarning != message else { return }
        if purchaseSyncWarning != message { purchaseSyncWarning = message }
    }

    /// Category identification colors attached to Live Activity item rows.
    var purchaseActivityCategoryColors: [String: String] {
        Dictionary(state.categories.map { ($0.id.rawValue, $0.colorHex) }, uniquingKeysWith: { first, _ in first })
    }

    var recurringRules: [RecurringRule] { (state.recurringRules ?? []).filter { $0.deletedAt == nil } }
    var purchaseSessions: [PurchaseSession] { (state.purchaseSessions ?? []).filter { $0.status != .cancelled }.sorted { $0.createdAt > $1.createdAt } }

    func savePurchaseSession(_ session: PurchaseSession) {
        var sessions = state.purchaseSessions ?? []
        var updated = session
        updated.ledgerBookID = activeBookID
        updated.updatedAt = .now
        updated.normalizeSections()
        if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated } else { sessions.append(updated) }
        state.purchaseSessions = sessions
        do { try persistPurchaseChanges() }
        catch { presentedError = "Purchase save failed: \(error.localizedDescription)" }
    }

    private func persistPurchaseChanges() throws {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        try Self.writeLibrary(librarySnapshot())
        scheduleSave()
    }

    @discardableResult
    func startPurchaseSession(_ sessionID: UUID, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async throws -> PurchaseActivityOutcome {
        guard var session = purchaseSessions.first(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        guard session.status == .draft else { throw PurchaseFinalizationError.notReady }
        try PurchaseRules.validatePayment(session, in: state)
        try PurchaseRules.validateItems(session, in: state)
        // Local-first: the purchase becomes active and is durably persisted before any
        // App Group / ActivityKit work runs. Those steps can never fail the start.
        session.status = .active
        session.startedAt = .now
        session.completedAt = nil
        for index in session.items.indices { session.items[index].isCompleted = false; session.items[index].completedAt = nil }
        session.updatedAt = .now
        savePurchaseSession(session)
        try persistPurchaseChanges()
        purchaseSyncWarning = nil
        suppressedPurchaseSyncWarning = nil
        guard let persistedSession = purchaseSessions.first(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        #if DEBUG
        PurchaseActivityDiagnostics.logStart(session: persistedSession)
        #endif
        return await publish(session: persistedSession, requestActivity: true, activityStarter: activityStarter)
    }

    /// Mirrors a committed session to the App Group bridge and the Live Activity.
    /// Never throws and never rolls back local state; bridge problems become warnings.
    @discardableResult
    func publish(session: PurchaseSession, requestActivity: Bool, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async -> PurchaseActivityOutcome {
        let outcome = await activityStarter.publish(session: session, categoryColors: purchaseActivityCategoryColors, requestActivityIfNeeded: requestActivity)
        reportPurchaseSyncWarning(outcome.warning)
        #if DEBUG
        PurchaseActivityDiagnostics.log(outcome: outcome, session: session)
        #endif
        return outcome
    }

    /// Bridges the current stored session (used after local mutations).
    @discardableResult
    func publishPurchase(sessionID: UUID, requestActivity: Bool? = nil, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async -> PurchaseActivityOutcome? {
        guard let session = purchaseSessions.first(where: { $0.id == sessionID }) else { return nil }
        return await publish(session: session, requestActivity: requestActivity ?? (session.status == .active), activityStarter: activityStarter)
    }

    func cancelPurchaseSession(_ session: PurchaseSession) {
        var cancelled = session
        cancelled.status = .cancelled
        cancelled.updatedAt = .now
        savePurchaseSession(cancelled)
        let cancelledID = cancelled.id
        Task { [weak self] in
            guard let self else { return }
            await PurchaseLiveActivityController.shared.end(sessionID: cancelledID)
            self.dismissPurchaseSyncWarning()
        }
    }

    /// Local-first item completion.
    ///
    /// The stored `PurchaseSession` is the source of truth: it is validated, mutated and
    /// persisted here, and the App Group / Live Activity bridge is updated afterwards by
    /// `publish(session:requestActivity:)`. A failing bridge can therefore never roll back
    /// the completion, return nil, change the session status or dismiss the screen.
    @discardableResult
    func setPurchaseItem(_ itemID: UUID, in sessionID: UUID, completed: Bool) -> PurchaseSession? {
        guard var session = purchaseSessions.first(where: { $0.id == sessionID }),
              session.status == .active || session.status == .awaitingSummary,
              let index = session.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        session.items[index].isCompleted = completed
        session.items[index].completedAt = completed ? .now : nil
        // Only a fully completed list leaves the active state; non-final taps stay active.
        if session.items.allSatisfy(\.isCompleted) {
            session.status = .awaitingSummary
            session.completedAt = .now
        } else {
            session.status = .active
            session.completedAt = nil
        }
        session.updatedAt = .now
        savePurchaseSession(session)
        return purchaseSessions.first(where: { $0.id == sessionID }) ?? session
    }

    func finalizePurchaseSession(_ sessionID: UUID, receiptAttachmentID: String?) throws {
        guard var sessions = state.purchaseSessions, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        let session = sessions[sessionIndex]
        if session.status == .completed { return }
        guard session.status == .awaitingSummary, session.items.allSatisfy(\.isCompleted) else { throw PurchaseFinalizationError.notReady }
        try PurchaseRules.validatePayment(session, in: state)
        try PurchaseRules.validateItems(session, in: state)
        guard let accountID = session.accountID else { throw PurchaseFinalizationError.paymentAccountUnavailable }
        guard let paymentAccount = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }) else { throw PurchaseFinalizationError.paymentAccountUnavailable }
        // Post each child to the pocket that already holds the purchase currency, else the primary pocket.
        let purchasePocket = paymentAccount.defaultPocket(for: session.currency)
        // Validate the entire purchase before adding any financial children.
        for itemIndex in sessions[sessionIndex].items.indices where sessions[sessionIndex].items[itemIndex].linkedTransactionID == nil {
            let item = sessions[sessionIndex].items[itemIndex]
            guard let transaction = addTransaction(type: .expense, accountID: accountID, destinationAccountID: nil, amount: item.amount, currency: session.currency, categoryID: item.categoryID, occurredAt: item.completedAt ?? .now, note: item.note, purchaseSessionID: sessionID, purchaseItemID: item.id, accountCurrency: purchasePocket) else { throw PurchaseFinalizationError.invalidItem }
            sessions[sessionIndex].items[itemIndex].linkedTransactionID = transaction.id
        }
        sessions[sessionIndex].receiptAttachmentID = receiptAttachmentID ?? session.receiptAttachmentID
        sessions[sessionIndex].status = .completed
        sessions[sessionIndex].completedAt = .now
        sessions[sessionIndex].updatedAt = .now
        state.purchaseSessions = sessions
        try persistPurchaseChanges()
        let finished = sessions[sessionIndex]
        Task { [weak self] in
            guard let self else { return }
            await self.publish(session: finished, requestActivity: false)
        }
    }

    /// Merges newer App Group snapshots (checked from the Lock Screen / Dynamic Island) into
    /// the local store. Only strictly newer snapshots win, and local state is persisted after
    /// a successful merge. Never touches `presentedError`: the bridge is a nonfatal channel.
    @discardableResult
    func reconcileSharedActivePurchases() -> Bool {
        // Explicit availability check: do not discover a missing container through item taps.
        guard PurchaseSharedStateStore.availability().isAvailable else { return false }
        guard var sessions = state.purchaseSessions else { return false }
        var changed = false
        for index in sessions.indices where sessions[index].status == .active || sessions[index].status == .awaitingSummary {
            let local = sessions[index]
            guard let snapshot = PurchaseSharedStateStore.newerSnapshot(for: local),
                  PurchaseRules.shouldAdoptSharedSnapshot(snapshot, over: local),
                  (try? PurchaseRules.validatePayment(snapshot.session, in: state)) != nil else { continue }
            sessions[index] = snapshot.session
            changed = true
        }
        guard changed else { return false }
        state.purchaseSessions = sessions
        do { try persistPurchaseChanges() }
        catch { presentedError = "Purchase sync failed: \(error.localizedDescription)" }
        return true
    }

    func handleDeepLink(_ url: URL) {
        guard (url.scheme == "finsy" || url.scheme == "walletledger"), url.host == "purchase", let rawID = url.pathComponents.dropFirst().first, let id = UUID(uuidString: rawID), purchaseSessions.contains(where: { $0.id == id }) else { return }
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
                if amount > 0 { addTransaction(type: rule.type, accountID: rule.accountID, destinationAccountID: rule.destinationAccountID, amount: amount, currency: rule.currency, categoryID: rule.categoryID, occurredAt: rule.nextRunAt, note: rule.note, accountCurrency: rule.accountCurrency, destinationAccountCurrency: rule.destinationAccountCurrency) }
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
            var importedState = envelope.data
            SchemaMigration.normalize(&importedState)
            try BackupCodec.validate(importedState)
            if activeBook.effectiveStorageKind == .local {
                state = importedState
            } else {
                commitActiveBook()
                let now = Date.now
                let imported = LedgerBook(id: UUID(), name: "Imported Ledger", state: importedState, createdAt: now, updatedAt: now, storageKind: .local, cloudZoneName: nil, cloudZoneOwnerName: nil)
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
        guard var library = try? localRepository.loadLibrary() else { return nil }
        guard !library.books.isEmpty else { return nil }
        SchemaMigration.normalize(&library)
        guard library.books.allSatisfy({ (try? BackupCodec.validate($0.state)) != nil }) else { return nil }
        return library
    }

    private static func loadLegacyState() -> LedgerState? {
        let url = storageFolder.appending(path: "ledger.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        var state: LedgerState
        if let current = try? BackupCodec.decoder().decode(LedgerState.self, from: data), current.schemaVersion >= 2 { state = current }
        else if let old = try? BackupCodec.decoder().decode(LedgerStateV1.self, from: data), old.schemaVersion <= 1 { state = SchemaMigration.migrate(old) }
        else { return nil }
        PurchaseRules.migrateDevelopmentSessions(in: &state)
        SchemaMigration.normalize(&state)
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
    case missingSession, notReady, invalidItem, paymentAccountUnavailable, missingRate
    var errorDescription: String? {
        switch self { case .missingSession: "Purchase session was not found."; case .notReady: "Complete every purchase item before creating ledger transactions."; case .invalidItem: "Each purchase item needs a name, category and positive amount."; case .paymentAccountUnavailable: "Choose an active payment account before starting or completing this purchase."; case .missingRate: "Set a valid exchange rate for the purchase and payment account currencies first." }
    }
}
