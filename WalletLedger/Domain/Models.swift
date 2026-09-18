import Foundation

enum CurrencyCode: String, Codable, CaseIterable, Identifiable, Sendable {
    case HKD, USD, CNY, MYR, EUR, GBP, JPY
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .HKD, .USD: "$"
        case .CNY, .JPY: "¥"
        case .MYR: "RM"
        case .EUR: "€"
        case .GBP: "£"
        }
    }
}

enum AccountType: String, Codable, CaseIterable, Identifiable, Sendable {
    case checking = "Checking"
    case savings = "Savings"
    case credit = "Credit"
    case investment = "Investment"
    case cash = "Cash"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .checking: "building.columns"
        case .savings: "banknote"
        case .credit: "creditcard"
        case .investment: "chart.line.uptrend.xyaxis"
        case .cash: "wallet.bifold"
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
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int
    var syncStatus: SyncStatus
}

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
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int
    var syncStatus: SyncStatus
}

struct RecurringRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userID: String
    var type: LedgerTransactionType
    var accountID: UUID
    var destinationAccountID: UUID?
    var amount: Double
    var currency: CurrencyCode
    var categoryID: LedgerCategoryID
    var note: String?
    var interval: RecurringInterval
    var customIntervalDays: Int
    var nextRunAt: Date
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
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
    var rates: [CurrencyCode: Double]
    var automaticRates: Bool
    var backupReminders: Bool
    var lastBackupAt: Date?
    var updatedAt: Date
    var exchangeRatesUpdatedAt: Date? = nil
}

struct LedgerState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var accounts: [LedgerAccount]
    var transactions: [LedgerTransaction]
    var categories: [LedgerCategory]
    var settings: LedgerSettings
    var recurringRules: [RecurringRule]? = nil
}

struct LedgerBook: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var state: LedgerState
    var createdAt: Date
    var updatedAt: Date
}

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
