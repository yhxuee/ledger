import Foundation

extension LedgerStore {

    func updateSettings(_ change: (inout LedgerSettings) -> Void) {
        mutateState { state in
            change(&state.settings)
            state.settings.rates = CurrencyRates.mirroringUSDAliases(state.settings.rates)
            state.settings.updatedAt = .now
        }
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
        if let active = books.first(where: { $0.id == activeBookID }) {
            mutateState { state in
                state = active.state
            }
        }
        scheduleSave()
    }

    /// Background expiration must not strand changes in the normal debounced save task.
    @discardableResult func flushMarketData() async -> Bool {
        guard persistenceEnabled else { return true }
        do {
            try await persistDurableAsync()
            return true
        } catch {
            presentedError = "Local save failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addCategory(name rawName: String, detail rawDetail: String, symbol: String, colorHex: String, kind: LedgerCategoryKind = .expense) -> LedgerCategoryID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !symbol.isEmpty else { return nil }
        let id = LedgerCategoryID(rawValue: "custom-\(UUID().uuidString.lowercased())")
        mutateState { state in
            state.categories.append(.init(id: id, name: name, detail: rawDetail.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol, colorHex: colorHex, kind: kind))
        }
        scheduleSave()
        return id
    }


    func handleDeepLink(_ url: URL) {
        if url.isFileURL {
            handleOpenedFile(url)
            return
        }
        guard url.scheme == "finsy" || url.scheme == FinsyCompatibility.urlScheme else { return }
        if url.host == "transaction" && (url.path == "/add" || url.pathComponents.contains("add")) {
            activeRoute = .addTransaction
            return
        }
        if url.host == "purchase", let rawID = url.pathComponents.dropFirst().first, let id = UUID(uuidString: rawID), purchaseSessions.contains(where: { $0.id == id }) {
            routedPurchaseID = id
            activeRoute = .purchase(id)
            return
        }
        if url.host == "account", let rawID = url.pathComponents.dropFirst().first, let id = UUID(uuidString: rawID), state.accounts.contains(where: { $0.id == id && $0.deletedAt == nil }) {
            activeRoute = .account(id)
            return
        }
        if url.host == "overview" || url.host == "accounts" {
            activeRoute = .overview
            return
        }
    }

    func handleOpenedFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }

        if url.pathExtension.lowercased() == "fsykey" {
            do {
                let envelope = try JSONDecoder().decode(FinsyKeyGrantEnvelope.self, from: data)
                let privateKey = try LedgerDeviceIdentity.getOrCreatePrivateKey()
                let (_, ledgerID, _) = try LedgerCryptoService.receiveKeyGrant(envelope: envelope, devicePrivateKey: privateKey)
                if let index = books.firstIndex(where: { $0.id == ledgerID }) {
                    books[index].encryptionState = .enabled
                    scheduleSave()
                }
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }


}
