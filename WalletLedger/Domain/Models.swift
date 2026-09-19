import Foundation

struct CurrencyCode: RawRepresentable, Codable, Hashable, Identifiable, Sendable, CaseIterable, CodingKeyRepresentable {
    let rawValue: String
    var id: String { rawValue }

    private static let supportedCodes = "AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CMD CNH CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GGP GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS IMP INR IQD IRR ISK JEP JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRO MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VES VND VUV WST XAF XAG XAU XCD XCG XDR XOF XPD XPF XPT YER ZAR ZMW ZWG"
    static let allCases = supportedCodes.split(separator: " ").map { CurrencyCode(unchecked: String($0)) }

    static let HKD = CurrencyCode(unchecked: "HKD")
    static let USD = CurrencyCode(unchecked: "USD")
    static let CNY = CurrencyCode(unchecked: "CNY")
    static let MYR = CurrencyCode(unchecked: "MYR")
    static let EUR = CurrencyCode(unchecked: "EUR")
    static let GBP = CurrencyCode(unchecked: "GBP")
    static let JPY = CurrencyCode(unchecked: "JPY")

    init?(rawValue: String) {
        let normalized = rawValue.uppercased()
        guard normalized.count == 3, normalized.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else { return nil }
        self.rawValue = normalized
    }

    private init(unchecked rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let currency = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported currency code: \(value)")
        }
        self = currency
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    var name: String { Locale.current.localizedString(forCurrencyCode: rawValue) ?? rawValue }
    var symbol: String {
        switch rawValue {
        case "HKD", "USD", "AUD", "CAD", "NZD", "SGD", "TWD": "$"
        case "CNY", "JPY": "¥"
        case "MYR": "RM"
        case "EUR": "€"
        case "GBP": "£"
        case "KRW": "₩"
        case "INR": "₹"
        case "THB": "฿"
        default: rawValue
        }
    }
}

struct CurrencyDescriptor: Identifiable, Codable, Hashable, Sendable {
    var code: CurrencyCode
    var name: String
    var symbol: String?
    var id: CurrencyCode { code }

    static var bundled: [CurrencyDescriptor] {
        CurrencyCode.allCases.map { .init(code: $0, name: $0.name, symbol: $0.symbol == $0.rawValue ? nil : $0.symbol) }
    }
}

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

struct LedgerCategoryID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    static let food = Self(rawValue: "food")
    static let transport = Self(rawValue: "transport")
    static let shopping = Self(rawValue: "shopping")
    static let utilities = Self(rawValue: "utilities")
    static let other = Self(rawValue: "other")
    static let builtIns: [Self] = [.food, .transport, .shopping, .utilities, .other]
}

enum SyncStatus: String, Codable, Sendable { case synced, pending, conflict }

struct CardStyle: Codable, Hashable, Sendable {
    var startHex: String
    var endHex: String
}

struct LedgerAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userID: String
    var name: String
    var type: AccountType
    var currency: CurrencyCode
    var openingBalance: Double
    var budget: Double
    var includeInBudget: Bool
    var logo: String
    var cardStyle: CardStyle
    var cardImageData: Data? = nil
    var loanMetadata: LoanMetadata? = nil
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int
    var syncStatus: SyncStatus
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
}

enum PurchaseSessionStatus: String, Codable, CaseIterable, Sendable {
    case draft, active, awaitingSummary, completed, cancelled
}

struct PurchaseCategorySection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var categoryID: LedgerCategoryID
    var displayOrder: Int
}

struct PurchaseItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var categoryID: LedgerCategoryID
    var note: String
    var amount: Double
    var displayOrder: Int
    var isCompleted: Bool
    var completedAt: Date?
    var resolvedAccountID: UUID?
    var linkedTransactionID: UUID?
}

struct PurchaseSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ledgerBookID: UUID
    var name: String
    var status: PurchaseSessionStatus
    var sections: [PurchaseCategorySection]
    var items: [PurchaseItem]
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var receiptAttachmentID: String?
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
