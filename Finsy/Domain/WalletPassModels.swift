import Foundation

public struct WalletRelevantLocation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    public var relevantText: String

    public init(id: UUID = UUID(), latitude: Double, longitude: Double, relevantText: String) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.relevantText = relevantText
    }
}

public enum WalletAccountPassSource: Codable, Hashable, Sendable {
    case allAccounts
    case specificAccount(UUID)
}

public struct AccountPassSnapshot: Codable, Hashable, Sendable {
    public var passTypeIdentifier: String
    public var serialNumber: String
    public var title: String
    public var balanceAmount: Double
    public var currency: CurrencyCode
    public var formattedBalance: String
    public var accountCount: Int
    public var locations: [WalletRelevantLocation]
    public var generatedAt: Date

    public init(
        passTypeIdentifier: String = "pass.com.finsy.account",
        serialNumber: String = "finsy-primary-account-pass",
        title: String,
        balanceAmount: Double,
        currency: CurrencyCode,
        formattedBalance: String,
        accountCount: Int,
        locations: [WalletRelevantLocation],
        generatedAt: Date = .now
    ) {
        self.passTypeIdentifier = passTypeIdentifier
        self.serialNumber = serialNumber
        self.title = title
        self.balanceAmount = balanceAmount
        self.currency = currency
        self.formattedBalance = formattedBalance
        self.accountCount = accountCount
        self.locations = Array(locations.prefix(10))
        self.generatedAt = generatedAt
    }
}

public struct PurchaseReceiptPassSnapshot: Codable, Hashable, Sendable {
    public var passTypeIdentifier: String
    public var serialNumber: String
    public var sessionID: UUID
    public var storeName: String
    public var totalAmount: Double
    public var currency: CurrencyCode
    public var formattedTotal: String
    public var itemCount: Int
    public var itemsSummary: String
    public var finalizedAt: Date

    public init(
        passTypeIdentifier: String = "pass.com.finsy.receipt",
        sessionID: UUID,
        storeName: String,
        totalAmount: Double,
        currency: CurrencyCode,
        formattedTotal: String,
        itemCount: Int,
        itemsSummary: String,
        finalizedAt: Date
    ) {
        self.passTypeIdentifier = passTypeIdentifier
        self.serialNumber = "purchase-\(sessionID.uuidString)"
        self.sessionID = sessionID
        self.storeName = storeName
        self.totalAmount = totalAmount
        self.currency = currency
        self.formattedTotal = formattedTotal
        self.itemCount = itemCount
        self.itemsSummary = itemsSummary
        self.finalizedAt = finalizedAt
    }
}

public struct TaxReceiptPassSnapshot: Codable, Hashable, Sendable {
    public var passTypeIdentifier: String
    public var serialNumber: String
    public var year: Int
    public var month: Int
    public var monthName: String
    public var totalExpenseTax: Double
    public var totalTaxableExpense: Double
    public var currency: CurrencyCode
    public var formattedExpenseTax: String
    public var formattedTaxableExpense: String
    public var generatedAt: Date

    public init(
        passTypeIdentifier: String = "pass.com.finsy.tax",
        year: Int,
        month: Int,
        monthName: String,
        totalExpenseTax: Double,
        totalTaxableExpense: Double,
        currency: CurrencyCode,
        formattedExpenseTax: String,
        formattedTaxableExpense: String,
        generatedAt: Date = .now
    ) {
        self.passTypeIdentifier = passTypeIdentifier
        self.serialNumber = "tax-expense-\(year)-\(String(format: "%02d", month))"
        self.year = year
        self.month = month
        self.monthName = monthName
        self.totalExpenseTax = totalExpenseTax
        self.totalTaxableExpense = totalTaxableExpense
        self.currency = currency
        self.formattedExpenseTax = formattedExpenseTax
        self.formattedTaxableExpense = formattedTaxableExpense
        self.generatedAt = generatedAt
    }
}

public enum WalletPassError: LocalizedError, Sendable {
    case libraryUnavailable
    case signingServiceUnavailable(String)
    case invalidPassData
    case passAlreadyExists
    case addPassCancelled

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            return "Apple Wallet is not available on this device."
        case .signingServiceUnavailable(let reason):
            return "Pass signing service unavailable: \(reason)"
        case .invalidPassData:
            return "The generated pass data was invalid."
        case .passAlreadyExists:
            return "This pass is already in your Apple Wallet."
        case .addPassCancelled:
            return "Adding pass to Apple Wallet was cancelled."
        }
    }
}
