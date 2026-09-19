import Foundation
import Security

/// Device-only, non-synchronizing and non-migrating. Never enters a ledger or preferences file.
enum MarketDataKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.medx.WalletLedger.AlphaVantage",
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false]
    }
    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MarketDataError.keychain }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MarketDataError.missingKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw MarketDataError.keychain }
        } else if status != errSecSuccess { throw MarketDataError.keychain }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MarketDataError.keychain }
    }
}

enum MarketDataError: LocalizedError {
    case missingKey, keychain, rateLimit, invalidResponse, connection
    var errorDescription: String? {
        switch self {
        case .missingKey: "Configure an Alpha Vantage key, or enter the stock code manually."
        case .keychain: "The device Keychain is unavailable."
        case .rateLimit: "Alpha Vantage limit reached. Cached prices are retained; retry at the next scheduled opportunity."
        case .invalidResponse: "Alpha Vantage did not return usable market data. Manual entry remains available."
        case .connection: "Could not connect to Alpha Vantage. Cached prices are retained."
        }
    }
}

actor AlphaVantageService {
    static let shared = AlphaVantageService()
    struct Match: Identifiable, Sendable {
        let symbol: String
        let name: String
        let region: String
        let currency: String
        var id: String { symbol }
        func belongs(to market: StockMarket) -> Bool {
            currency == market.settlementCurrency.rawValue && market.matchesRegion(region)
        }
    }
    struct Quote: Codable, Sendable {
        let symbol: String
        let price: Double
        /// GLOBAL_QUOTE supplies a trading date, not a realtime timestamp.
        let tradingDay: String
        let fetchedAt: Date
    }
    struct MarketStatus: Sendable {
        let region: String
        let open: Bool
    }
    private var searchCache: [String: [Match]] = [:]
    private var searches: [String: Task<[Match], Error>] = [:]
    private var failedSearches: [String: (date: Date, error: MarketDataError)] = [:]
    private var quotes: [String: Task<Quote, Error>] = [:]
    private var quoteCache: [String: Quote] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    func resetCaches() { searchCache = [:]; quoteCache = [:]; failedSearches = [:] }

    private func request(_ function: String, parameters: [String: String] = [:]) async throws -> [String: Any] {
        guard let key = try MarketDataKeychain.read(), !key.isEmpty else { throw MarketDataError.missingKey }
        var url = URLComponents(string: "https://www.alphavantage.co/query")!
        url.queryItems = (["function": function, "apikey": key].merging(parameters) { _, new in new })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url.url!) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MarketDataError.connection } // Never expose URLs containing credentials.
        guard let http = response as? HTTPURLResponse else { throw MarketDataError.connection }
        if http.statusCode == 429 { throw MarketDataError.rateLimit }
        guard (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MarketDataError.invalidResponse }
        if object["Note"] != nil { throw MarketDataError.rateLimit }
        if let information = object["Information"] as? String {
            let text = information.lowercased()
            if ["rate", "frequency", "limit", "requests"].contains(where: { text.contains($0) }) { throw MarketDataError.rateLimit }
            throw MarketDataError.invalidResponse
        }
        if object["Error Message"] != nil { throw MarketDataError.invalidResponse }
        return object
    }

    func search(_ query: String, market: StockMarket) async throws -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard query.count >= 2 else { return [] }
        if let cached = searchCache[query] { return cached.filter { $0.belongs(to: market) } }
        if let failure = failedSearches[query], Date.now.timeIntervalSince(failure.date) < 300 { throw failure.error }
        let task: Task<[Match], Error>
        if let existing = searches[query] { task = existing }
        else {
            task = Task {
                let response = try await self.request("SYMBOL_SEARCH", parameters: ["keywords": query])
                guard let rows = response["bestMatches"] as? [[String: String]] else { throw MarketDataError.invalidResponse }
                return rows.compactMap { row in
                    guard let symbol = row["1. symbol"], let name = row["2. name"],
                          let region = row["4. region"], let currency = row["8. currency"] else { return nil }
                    return Match(symbol: symbol, name: name, region: region, currency: currency)
                }
            }
            searches[query] = task
        }
        defer { searches[query] = nil }
        do {
            let result = try await task.value
            searchCache[query] = result
            return result.filter { $0.belongs(to: market) }
        } catch {
            if let failure = error as? MarketDataError { failedSearches[query] = (.now, failure) }
            throw error
        }
    }

    func quote(symbol: String) async throws -> Quote {
        if let cached = quoteCache[symbol], Date.now.timeIntervalSince(cached.fetchedAt) < 60 { return cached }
        if let pending = quotes[symbol] { return try await pending.value }
        let task = Task<Quote, Error> {
            let response = try await self.request("GLOBAL_QUOTE", parameters: ["symbol": symbol])
            guard let quote = response["Global Quote"] as? [String: String],
                  quote["01. symbol"] == symbol, let rawPrice = quote["05. price"],
                  let price = Double(rawPrice), price.isFinite, price > 0,
                  let day = quote["07. latest trading day"], day.count == 10 else { throw MarketDataError.invalidResponse }
            return Quote(symbol: symbol, price: price, tradingDay: day, fetchedAt: .now)
        }
        quotes[symbol] = task
        defer { quotes[symbol] = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if let old = quoteCache[symbol], old.tradingDay > result.tradingDay { return old }
        quoteCache[symbol] = result
        return result
    }

    func marketStatus() async throws -> [MarketStatus] {
        let response = try await request("MARKET_STATUS")
        guard let rows = response["markets"] as? [[String: String]] else { throw MarketDataError.invalidResponse }
        return rows.filter { $0["market_type"] == "Equity" }.compactMap { row in
            guard let region = row["region"], let status = row["current_status"] else { return nil }
            return MarketStatus(region: region, open: status.lowercased() == "open")
        }
    }
}
