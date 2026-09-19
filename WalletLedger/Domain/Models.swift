import Foundation

enum AccountType: String, Codable, CaseIterable, Identifiable, Sendable {
    case checking = "Checking"
    case savings = "Savings"
    case credit = "Credit"
    case investment = "Investment"
    case cash = "Cash"
    case loan = "Loan"
    case lending = "Lending / Receivable"
    case stocks = "Stocks"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .checking: "building.columns"
        case .savings: "banknote"
        case .credit: "creditcard"
        case .investment: "chart.line.uptrend.xyaxis"
        case .cash: "wallet.bifold"
        case .loan: "building.columns.fill"
        case .lending: "person.crop.circle.badge.clock"
        case .stocks: "chart.line.uptrend.xyaxis"
        }
    }
}

enum LedgerTransactionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case expense, income, transfer
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Stock market selection. The market — not a free currency picker — determines the
/// settlement currency of a stocks account.
enum StockMarket: String, Codable, CaseIterable, Identifiable, Sendable {
    case US, HK, CN
    var id: String { rawValue }
    var title: String { rawValue }

    var settlementCurrency: CurrencyCode {
        switch self {
        case .US: .USD
        case .HK: .HKD
        case .CN: .CNY
        }
    }

    var symbolExample: String {
        switch self {
        case .US: "AAPL"
        case .HK: "0700"
        case .CN: "600519"
        }
    }

    /// Legacy display/validation helper only. Provider symbols must be preserved verbatim.
    func normalize(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return "" }
        switch self {
        case .US:
            return String(cleaned.filter(\.isLetter).prefix(5))
        case .HK:
            return Self.paddedDigits(cleaned, width: 4)
        case .CN:
            return Self.paddedDigits(cleaned, width: 6)
        }
    }

    func isValidSymbol(_ raw: String) -> Bool {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return false }
        switch self {
        case .US: return (1...5).contains(normalized.count)
        case .HK: return normalized.count == 4
        case .CN: return normalized.count == 6
        }
    }

    func placeholderSymbol(_ raw: String) -> String {
        let normalized = normalize(raw)
        return normalized.isEmpty ? symbolExample : normalized
    }

    private static func paddedDigits(_ value: String, width: Int) -> String {
        let digits = String(value.filter(\.isNumber).prefix(width))
        guard !digits.isEmpty else { return "" }
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

struct StockMetadata: Codable, Hashable, Sendable {
    var market: StockMarket
    var symbol: String
    var providerSymbol: String? = nil
    var averageCost: Double = 0
    var quantity: Double = 0
    var latestPrice: Double? = nil
    var latestPriceAt: Date? = nil

    var costBasis: Double { averageCost * quantity }
    var marketValue: Double? { latestPrice.map { $0 * quantity } }
    var value: Double { marketValue ?? costBasis }
    var unrealizedPL: Double? { marketValue.map { $0 - costBasis } }

    init(market: StockMarket, symbol: String, providerSymbol: String? = nil,
         averageCost: Double = 0, quantity: Double = 0, latestPrice: Double? = nil, latestPriceAt: Date? = nil) {
        self.market = market; self.symbol = symbol; self.providerSymbol = providerSymbol
        self.averageCost = averageCost; self.quantity = quantity
        self.latestPrice = latestPrice; self.latestPriceAt = latestPriceAt
    }

    enum CodingKeys: String, CodingKey { case market, symbol, providerSymbol, averageCost, quantity, latestPrice, latestPriceAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        market = try values.decode(StockMarket.self, forKey: .market)
        symbol = try values.decode(String.self, forKey: .symbol)
        providerSymbol = try values.decodeIfPresent(String.self, forKey: .providerSymbol)
        averageCost = try values.decodeIfPresent(Double.self, forKey: .averageCost) ?? 0
        quantity = try values.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        latestPrice = try values.decodeIfPresent(Double.self, forKey: .latestPrice)
        latestPriceAt = try values.decodeIfPresent(Date.self, forKey: .latestPriceAt)
    }
}

/// A single currency pocket inside a multi-currency account. Pockets are not separate
/// accounts: they are balances of the same `LedgerAccount`.
struct AccountCurrencyPocket: Codable, Hashable, Sendable, Identifiable {
    var currency: CurrencyCode
    var openingBalance: Double

    var id: String { currency.rawValue }
}

enum RecurringInterval: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekly, monthly, yearly, customDays
    var id: String { rawValue }
    var title: String {
        switch self { case .weekly: "Weekly"; case .monthly: "Monthly"; case .yearly: "Yearly"; case .customDays: "Custom Days" }
    }
}

enum BudgetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case category, account
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct BudgetPlan: Codable, Hashable, Sendable {
    var mode: BudgetMode
    var categoryAllocations: [LedgerCategoryID: Double]
    var accountAllocations: [UUID: Double]
    var updatedAt: Date

    static func empty(now: Date = .now) -> BudgetPlan {
        .init(mode: .category, categoryAllocations: [:], accountAllocations: [:], updatedAt: now)
    }
}

struct ExchangeRateSettings: Codable, Hashable, Sendable {
    var rates: [CurrencyCode: Double]
    var automatic: Bool
    var updatedAt: Date?
}

struct CardStyle: Codable, Hashable, Sendable {
    var startHex: String
    var endHex: String
}

struct LedgerAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userID: String
    var name: String
    var type: AccountType
    /// Primary currency. For a multi-currency account this is the pocket used for display totals.
    var currency: CurrencyCode
    var openingBalance: Double
    var budget: Double
    var includeInBudget: Bool
    var logo: String
    var cardStyle: CardStyle
    var cardImageData: Data? = nil
    var loanMetadata: LoanMetadata? = nil
    /// Multi-currency pockets are only supported for checking / savings / credit accounts.
    var isMultiCurrency: Bool = false
    var currencyPockets: [AccountCurrencyPocket] = []
    var stockMetadata: StockMetadata? = nil
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int
    var syncStatus: SyncStatus

    enum CodingKeys: String, CodingKey {
        case id, userID, name, type, currency, openingBalance, budget, includeInBudget, logo, cardStyle
        case cardImageData, loanMetadata, isMultiCurrency, currencyPockets, stockMetadata
        case createdAt, updatedAt, deletedAt, version, syncStatus
    }

    /// Account types that may hold more than one currency pocket.
    static let multiCurrencyTypes: Set<AccountType> = [.checking, .savings, .credit]

    var supportsMultiCurrency: Bool { Self.multiCurrencyTypes.contains(type) }

    /// True when pocket routing applies. Every other account keeps single-currency behaviour.
    var usesCurrencyPockets: Bool { isMultiCurrency && supportsMultiCurrency }

    /// Pockets exactly as they behave: never empty and always containing the primary currency.
    /// A single-currency account always resolves to one pocket built from `currency` + `openingBalance`,
    /// so it keeps behaving exactly as before this feature existed.
    var normalizedPockets: [AccountCurrencyPocket] {
        let singlePocket = AccountCurrencyPocket(currency: currency, openingBalance: openingBalance.isFinite ? openingBalance : 0)
        guard usesCurrencyPockets else { return [singlePocket] }
        var seen = Set<CurrencyCode>()
        var pockets = currencyPockets.filter { $0.openingBalance.isFinite }.filter { seen.insert($0.currency).inserted }
        if pockets.isEmpty { pockets = [singlePocket] }
        if !pockets.contains(where: { $0.currency == currency }) {
            pockets.insert(AccountCurrencyPocket(currency: currency, openingBalance: singlePocket.openingBalance), at: 0)
        }
        return pockets
    }

    var pocketCurrencies: [CurrencyCode] { normalizedPockets.map(\.currency) }
    var hasMultiplePockets: Bool { normalizedPockets.count > 1 }

    func pocket(_ currency: CurrencyCode) -> AccountCurrencyPocket? {
        normalizedPockets.first { $0.currency == currency }
    }

    /// The pocket a transaction should default to: the transaction currency when the account
    /// already holds it, otherwise the primary currency.
    func defaultPocket(for currency: CurrencyCode) -> CurrencyCode {
        guard usesCurrencyPockets else { return self.currency }
        return pocket(currency) != nil ? currency : self.currency
    }

    /// Effective settlement currency for stocks accounts (derived from the market).
    var settlementCurrency: CurrencyCode {
        type == .stocks ? (stockMetadata?.market.settlementCurrency ?? currency) : currency
    }

    /// `Checking · HKD · 4 currencies`, or `Stocks · US · AAPL` for stocks accounts.
    var metadataLine: String {
        if type == .stocks {
            let market = stockMetadata?.market.rawValue ?? settlementCurrency.rawValue
            let symbol = stockMetadata?.symbol.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return symbol.isEmpty ? "\(type.rawValue) · \(market)" : "\(symbol) · \(market)"
        }
        let base = "\(type.rawValue) · \(currency.rawValue)"
        let count = normalizedPockets.count
        return count > 1 ? "\(base) · \(count) currencies" : base
    }
}

/// Decoding lives in an extension so the memberwise initializer stays available, and so that
/// accounts saved before multi-currency existed migrate to a single pocket automatically.
extension LedgerAccount {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userID = try container.decode(String.self, forKey: .userID)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(AccountType.self, forKey: .type)
        currency = try container.decode(CurrencyCode.self, forKey: .currency)
        openingBalance = try container.decode(Double.self, forKey: .openingBalance)
        budget = try container.decode(Double.self, forKey: .budget)
        includeInBudget = try container.decode(Bool.self, forKey: .includeInBudget)
        logo = try container.decode(String.self, forKey: .logo)
        cardStyle = try container.decode(CardStyle.self, forKey: .cardStyle)
        cardImageData = try container.decodeIfPresent(Data.self, forKey: .cardImageData)
        loanMetadata = try container.decodeIfPresent(LoanMetadata.self, forKey: .loanMetadata)
        isMultiCurrency = try container.decodeIfPresent(Bool.self, forKey: .isMultiCurrency) ?? false
        currencyPockets = try container.decodeIfPresent([AccountCurrencyPocket].self, forKey: .currencyPockets) ?? []
        stockMetadata = try container.decodeIfPresent(StockMetadata.self, forKey: .stockMetadata)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        version = try container.decode(Int.self, forKey: .version)
        syncStatus = try container.decode(SyncStatus.self, forKey: .syncStatus)
    }
}

struct LoanMetadata: Codable, Hashable, Sendable {
    var annualPercentageRate: Double
    var interestInterval: RecurringInterval?
    var customIntervalDays: Int
    var linkedRecurringRuleID: UUID?
}

enum RecurringAmountKind: String, Codable, Sendable { case fixed, loanInterest }

struct LedgerTransaction: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userID: String
    var type: LedgerTransactionType
    var accountID: UUID
    var destinationAccountID: UUID?
    var amount: Double
    var currency: CurrencyCode
    var accountAmount: Double?
    var destinationAmount: Double?
    /// Pocket actually debited/credited on the source account. Nil means the account's primary currency.
    var accountCurrency: CurrencyCode? = nil
    /// Pocket actually credited on the destination account. Nil means the account's primary currency.
    var destinationAccountCurrency: CurrencyCode? = nil
    var categoryID: LedgerCategoryID
    var occurredAt: Date
    var note: String?
    /// Canonical HKD-reference units for one unit of `currency` at entry time.
    var exchangeRateAtTransaction: Double
    var reversalOfTransactionID: UUID? = nil
    var reversalTransactionID: UUID? = nil
    var purchaseSessionID: UUID? = nil
    var purchaseItemID: UUID? = nil
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int
    var syncStatus: SyncStatus

    var isReversal: Bool { reversalOfTransactionID != nil }
    var isRefunded: Bool { reversalTransactionID != nil }
    var isLockedByReversal: Bool { isReversal || isRefunded }

    /// `amount + currency` is the original transaction denomination. The account-side postings
    /// below are the actual amounts that move money in the accounts.
    var originalDenomination: (amount: Double, currency: CurrencyCode) { (amount, currency) }
}

struct RecurringRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userID: String
    var type: LedgerTransactionType
    var accountID: UUID
    var destinationAccountID: UUID?
    var amount: Double
    var amountKind: RecurringAmountKind? = nil
    var linkedLoanAccountID: UUID? = nil
    var currency: CurrencyCode
    var categoryID: LedgerCategoryID
    var note: String?
    /// Pocket the generated transaction posts to. Nil means the account's primary currency.
    var accountCurrency: CurrencyCode? = nil
    /// Pocket the generated transfer credits. Nil means the destination account's primary currency.
    var destinationAccountCurrency: CurrencyCode? = nil
    var interval: RecurringInterval
    var customIntervalDays: Int
    var nextRunAt: Date
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date? = nil

    var effectiveAmountKind: RecurringAmountKind { amountKind ?? .fixed }
}

struct LedgerCategory: Identifiable, Codable, Hashable, Sendable {
    var id: LedgerCategoryID
    var name: String
    var detail: String
    var symbol: String
    var colorHex: String

    var emoji: String? {
        guard symbol.hasPrefix("emoji:") else { return nil }
        return String(symbol.dropFirst(6))
    }
}

struct LedgerSettings: Codable, Hashable, Sendable {
    var userID: String
    var baseCurrency: CurrencyCode
    var exchangeRates: ExchangeRateSettings
    var defaultExpenseAccountByCategory: [LedgerCategoryID: UUID]
    var budgetPlan: BudgetPlan
    var backupReminders: Bool
    var lastBackupAt: Date?
    var updatedAt: Date

    var rates: [CurrencyCode: Double] {
        get { exchangeRates.rates }
        set { exchangeRates.rates = newValue }
    }
    var automaticRates: Bool {
        get { exchangeRates.automatic }
        set { exchangeRates.automatic = newValue }
    }
    var exchangeRatesUpdatedAt: Date? {
        get { exchangeRates.updatedAt }
        set { exchangeRates.updatedAt = newValue }
    }
}

struct LedgerState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var accounts: [LedgerAccount]
    var transactions: [LedgerTransaction]
    var categories: [LedgerCategory]
    var settings: LedgerSettings
    var recurringRules: [RecurringRule]? = nil
    var purchaseSessions: [PurchaseSession]? = nil
}

struct LedgerBook: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var state: LedgerState
    var createdAt: Date
    var updatedAt: Date
    var storageKind: LedgerStorageKind? = nil
    var cloudZoneName: String? = nil
    var cloudZoneOwnerName: String? = nil

    var effectiveStorageKind: LedgerStorageKind { storageKind ?? .local }
}

enum LedgerStorageKind: String, Codable, Hashable, Sendable { case local, cloudOwner, cloudParticipant }

struct LedgerLibrary: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var activeBookID: UUID
    var books: [LedgerBook]
}

struct AccountViewModel: Identifiable, Hashable, Sendable {
    var account: LedgerAccount
    var balance: Double
    var id: UUID { account.id }
}

struct BackupMetadata: Codable, Hashable, Sendable {
    var app: String
    var schemaVersion: Int
    var exportedAt: Date
    var userID: String
    var accountCount: Int
    var transactionCount: Int
    var categoryCount: Int
    var baseCurrency: CurrencyCode
}

struct LedgerBackupEnvelope: Codable, Hashable, Sendable {
    var metadata: BackupMetadata
    var data: LedgerState
}

struct ImportPreview: Identifiable, Sendable {
    let id = UUID()
    var sourceName: String
    var envelope: LedgerBackupEnvelope
    var warnings: [String]
}

enum AnalyticsRange: String, CaseIterable, Identifiable, Sendable {
    case week = "W"
    case month = "M"
    case sixMonths = "6M"
    case year = "Y"
    var id: String { rawValue }
}

struct AnalyticsBucket: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var value: Double
}

struct AnalyticsSummary: Sendable {
    var buckets: [AnalyticsBucket]
    var categoryTotals: [LedgerCategoryID: Double]
    var subtitle: String
    var total: Double
    var average: Double
    var minimum: Double
    var maximum: Double
}

struct BudgetBreakdownLine: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var currency: CurrencyCode
    var budget: Double
    var spent: Double
    var remaining: Double { budget - spent }
    var ratio: Double { budget > 0 ? spent / budget : 0 }
}

struct BudgetBreakdown: Hashable, Sendable {
    var currency: CurrencyCode
    var budget: Double
    var spent: Double
    var lines: [BudgetBreakdownLine]
    var remaining: Double { budget - spent }
    var ratio: Double { budget > 0 ? spent / budget : 0 }
}
