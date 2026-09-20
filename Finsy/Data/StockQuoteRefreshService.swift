import Foundation
@preconcurrency import BackgroundTasks
import Combine

extension StockMarket {
    var providerRegion: String {
        switch self { case .US: "United States"; case .HK: "Hong Kong"; case .CN: "Mainland China" }
    }
    func matchesRegion(_ region: String) -> Bool {
        if self == .CN { return ["China", "Mainland China", "Shanghai", "Shenzhen"].contains(region) }
        return region == providerRegion
    }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timezoneID)!
        return value
    }
    var timezoneID: String {
        switch self { case .US: "America/New_York"; case .HK: "Asia/Hong_Kong"; case .CN: "Asia/Shanghai" }
    }
    var slotMinutes: [Int] {
        switch self { case .US: [600, 780, 970]; case .HK: [600, 840, 975]; case .CN: [600, 840, 905] }
    }
    func dateKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func date(from key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: key)
    }
    func slots(on date: Date) -> [Date] {
        slotMinutes.compactMap { calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: date) }
    }
    /// Exchange-published 2026 calendars. Unknown years require positive MARKET_STATUS evidence;
    /// a weekday alone never establishes a trading day. Extend this table with annual notices.
    func knownTradingDay(_ date: Date) -> Bool? {
        if calendar.isDateInWeekend(date) { return false }
        guard calendar.component(.year, from: date) == 2026 else { return nil }
        let holidays: Set<String>
        switch self {
        case .US: holidays = ["01-01", "01-19", "02-16", "04-03", "05-25", "06-19", "07-03", "09-07", "11-26", "12-25"]
        case .HK: holidays = ["01-01", "02-17", "02-18", "02-19", "04-03", "04-06", "04-07", "05-01", "05-25", "06-19", "07-01", "10-01", "10-19", "12-25"]
        case .CN: holidays = ["01-01", "01-02", "02-16", "02-17", "02-18", "02-19", "02-20", "02-23", "04-06", "05-01", "05-04", "05-05", "06-19", "09-25", "10-01", "10-02", "10-05", "10-06", "10-07"]
        }
        return !holidays.contains(String(dateKey(date).suffix(5)))
    }
    func expectsOpen(at date: Date) -> Bool {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let day = dateKey(date)
        switch self {
        case .US:
            let close = ["2026-11-27", "2026-12-24"].contains(day) ? 780 : 960
            return minute >= 570 && minute < close
        case .HK:
            if ["2026-02-16", "2026-12-24", "2026-12-31"].contains(day) { return minute >= 570 && minute < 720 }
            return (570..<720).contains(minute) || (780..<960).contains(minute)
        case .CN: return (570..<690).contains(minute) || (780..<900).contains(minute)
        }
    }
}

/// Main actor serializes foreground/background checks, including durable attempt reservation.
@MainActor
final class StockQuoteRefreshService: ObservableObject {
    static let shared = StockQuoteRefreshService()
    @Published private(set) var status: String?
    struct SlotState: Codable {
        var market: StockMarket
        var tradingDate: String
        var slot: Int
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
    }
    private struct Cache: Codable {
        var slots: [SlotState] = []
        var quotes: [String: AlphaVantageService.Quote] = [:]
        var observedOpen: [StockMarket: String] = [:]
        var observedClosed: [StockMarket: String] = [:]
    }
    private var cache: Cache
    private var running = false
    private let file: URL

    private init() {
        file = URL.applicationSupportDirectory.appendingPathComponent("stock-refresh.json")
        cache = (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))) ?? Cache()
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
    }
    private func key(_ market: StockMarket, _ symbol: String) -> String { "\(market.rawValue):\(symbol)" }

    func refreshIfDue(store: LedgerStore, now: Date = .now) async {
        guard !running else { return }
        running = true
        defer { running = false }
        // Cached results are applied even when a new account is added after a slot completed.
        store.applyStockQuotes(cache.quotes)
        let stocks = store.allStockMetadata
        let markets = Set(stocks.map(\.market))
        guard !markets.isEmpty else { return }
        do {
            guard try MarketDataKeychain.read() != nil else { status = MarketDataError.missingKey.localizedDescription; return }
            let due = markets.sorted { $0.rawValue < $1.rawValue }.compactMap { market -> (StockMarket, [Int])? in
                guard market.knownTradingDay(now) != false else { return nil }
                let day = market.dateKey(now)
                let slots = market.slots(on: now).enumerated().filter { index, date in
                    date <= now && !cache.slots.contains { $0.market == market && $0.tradingDate == day && $0.slot == index && ($0.lastAttemptAt != nil || $0.lastSuccessAt != nil) }
                }.map(\.offset)
                return slots.isEmpty ? nil : (market, slots)
            }
            guard !due.isEmpty else { return }
            // Reserve all due slots before any network suspension, including failures/expiration.
            cache.slots.removeAll { now.timeIntervalSince($0.lastAttemptAt ?? .distantPast) > 8 * 86400 }
            for (market, slots) in due {
                for slot in slots { cache.slots.append(.init(market: market, tradingDate: market.dateKey(now), slot: slot, lastAttemptAt: now)) }
            }
            try persist()
            let statuses = try await AlphaVantageService.shared.marketStatus()
            try Task.checkCancellation()
            for (market, _) in due {
                try Task.checkCancellation()
                let day = market.dateKey(now)
                let records = statuses.filter { market.matchesRegion($0.region) }
                let open = records.contains { $0.open }
                if open { cache.observedOpen[market] = day; cache.observedClosed[market] = nil }
                if !records.isEmpty && !open && market.expectsOpen(at: now) {
                    cache.observedClosed[market] = day
                    status = "\(market.rawValue) market reports closed. Cached prices retained."
                    continue
                }
                guard cache.observedClosed[market] != day,
                      market.knownTradingDay(now) == true || cache.observedOpen[market] == day else {
                    status = "\(market.rawValue) trading day could not be confirmed. Cached prices retained."
                    continue
                }
                // Manual codes remain usable offline. Only US codes can safely be sent without
                // a resolved provider symbol; do not guess HK/CN exchange suffixes.
                let symbols = Set(stocks.filter { $0.market == market }.compactMap { stock in
                    stock.providerSymbol ?? (market == .US && !stock.symbol.isEmpty ? stock.symbol : nil)
                })
                guard !symbols.isEmpty else { status = "Select a symbol search result to enable quotes for \(market.rawValue)."; continue }
                var successful = true
                for symbol in symbols.sorted() {
                    try Task.checkCancellation()
                    do {
                        let quote = try await AlphaVantageService.shared.quote(symbol: symbol)
                        try Task.checkCancellation()
                        guard let quoteDate = market.date(from: quote.tradingDay), quoteDate <= now else { throw MarketDataError.invalidResponse }
                        let cacheKey = key(market, symbol)
                        if let old = cache.quotes[cacheKey],
                           old.tradingDay > quote.tradingDay || (old.tradingDay == quote.tradingDay && old.fetchedAt > quote.fetchedAt) { continue }
                        cache.quotes[cacheKey] = quote
                        try persist()
                        store.applyStockQuotes(cache.quotes)
                    } catch MarketDataError.rateLimit { throw MarketDataError.rateLimit }
                    catch is CancellationError { throw CancellationError() }
                    catch { successful = false; status = error.localizedDescription }
                }
                if successful {
                    // One current fetch satisfies earlier missed or failed slots for this day.
                    for index in cache.slots.indices where cache.slots[index].market == market && cache.slots[index].tradingDate == day {
                        cache.slots[index].lastSuccessAt = .now
                    }
                    status = "Last available prices checked. Data may be end-of-day."
                }
            }
            try persist()
        } catch { status = error is CancellationError ? "Refresh interrupted. Cached prices retained." : error.localizedDescription }
    }

    func nextRefresh(markets: Set<StockMarket>, after now: Date = .now) -> Date? {
        markets.flatMap { market -> [Date] in
            (0...10).flatMap { offset -> [Date] in
                guard let day = market.calendar.date(byAdding: .day, value: offset, to: now), market.knownTradingDay(day) != false else { return [] }
                return market.slots(on: day).filter { $0 > now }
            }
        }.min()
    }
}

@MainActor
enum MarketRefreshBackground {
    static let identifier = "com.finsy.app.market-refresh"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let work = Task { @MainActor in
                    let store = LedgerStore.shared
                    await StockQuoteRefreshService.shared.refreshIfDue(store: store)
                    _ = try? await store.refreshExchangeRatesIfNeeded()
                    let saved = await store.flushMarketData()
                    schedule(store: store)
                    refresh.setTaskCompleted(success: saved && !Task.isCancelled)
                }
                refresh.expirationHandler = { work.cancel() }
            }
        }
    }
    static func schedule(store: LedgerStore) {
        let markets = Set(store.allStockMetadata.map(\.market))
        let nextStock = StockQuoteRefreshService.shared.nextRefresh(markets: markets)
        let nextFX = store.state.settings.automaticRates ? Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) : nil
        guard let next = [nextStock, nextFX].compactMap({ $0 }).min() else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = next
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* Foreground catch-up remains available when background refresh is disabled. */ }
    }
}
