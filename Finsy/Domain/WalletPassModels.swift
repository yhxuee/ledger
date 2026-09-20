import Foundation

struct WalletRelevantLocation: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var relevantText: String

    init(id: UUID = UUID(), latitude: Double, longitude: Double, relevantText: String) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.relevantText = relevantText
    }
}

enum WalletAccountPassSource: Codable, Hashable, Sendable {
    case allAccounts
    case specificAccount(UUID)
}

struct AccountPassSnapshot: Codable, Hashable, Sendable {
    var passTypeIdentifier: String
    var serialNumber: String
    var title: String
    var balanceAmount: Double
    var currency: CurrencyCode
    var formattedBalance: String
    var accountCount: Int
    var locations: [WalletRelevantLocation]
    var generatedAt: Date

    init(
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

struct PurchaseReceiptPassSnapshot: Codable, Hashable, Sendable {
    var passTypeIdentifier: String
    var serialNumber: String
    var sessionID: UUID
    var storeName: String
    var totalAmount: Double
    var currency: CurrencyCode
    var formattedTotal: String
    var itemCount: Int
    var itemsSummary: String
    var finalizedAt: Date

    init(
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

struct TaxReceiptPassSnapshot: Codable, Hashable, Sendable {
    var passTypeIdentifier: String
    var serialNumber: String
    var year: Int
    var month: Int
    var monthName: String
    var totalExpenseTax: Double
    var totalTaxableExpense: Double
    var currency: CurrencyCode
    var formattedExpenseTax: String
    var formattedTaxableExpense: String
    var generatedAt: Date

    init(
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

enum WalletPassError: LocalizedError, Sendable {
    case libraryUnavailable
    case signingServiceUnavailable(String)
    case invalidPassData
    case passAlreadyExists
    case addPassCancelled

    var errorDescription: String? {
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
