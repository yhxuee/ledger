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
    var monthTitle: String? = nil
    var formattedExpenses: String? = nil
    var formattedIncome: String? = nil
    var entries: Int? = nil
    var remainingLabel: String? = nil
    var formattedRemaining: String? = nil
    var recentEntries: String? = nil
    var themeColorHex: String? = nil
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

struct PurchaseReceiptPassItem: Codable, Hashable, Sendable {
    var name: String
    var category: String
    var amount: Double
    var formattedAmount: String

    init(name: String, category: String, amount: Double, formattedAmount: String) {
        self.name = name
        self.category = category
        self.amount = amount
        self.formattedAmount = formattedAmount
    }
}

struct PurchaseReceiptPassSnapshot: Codable, Hashable, Sendable {
    var formattedDate: String? = nil
    var payment: String? = nil
    var invoiceNumber: String? = nil
    var transactionStatus: String? = nil
    var themeColorHex: String? = nil
    var barcode: WalletReceiptBarcode? = nil
    var passTypeIdentifier: String
    var serialNumber: String
    var sessionID: UUID
    var storeName: String
    var totalAmount: Double
    var currency: CurrencyCode
    var formattedTotal: String
    var itemCount: Int
    var itemsSummary: String
    var items: [PurchaseReceiptPassItem]
    var taxAmount: Double
    var formattedTax: String
    var finalizedAt: Date

    enum CodingKeys: String, CodingKey {
        case passTypeIdentifier, serialNumber, sessionID, storeName, totalAmount, currency, formattedTotal, itemCount, itemsSummary, items, taxAmount, formattedTax, finalizedAt
        case formattedDate, payment, invoiceNumber, transactionStatus, themeColorHex, barcode
    }

    init(
        passTypeIdentifier: String = "pass.com.finsy.receipt",
        sessionID: UUID,
        storeName: String,
        totalAmount: Double,
        currency: CurrencyCode,
        formattedTotal: String,
        itemCount: Int,
        itemsSummary: String,
        items: [PurchaseReceiptPassItem] = [],
        taxAmount: Double = 0.0,
        formattedTax: String = "",
        finalizedAt: Date
    ) {
        self.passTypeIdentifier = passTypeIdentifier
        // A receipt stays as it was when added, even if the session is exported again.
        self.serialNumber = "purchase-\(sessionID.uuidString)"
        self.sessionID = sessionID
        self.storeName = storeName
        self.totalAmount = totalAmount
        self.currency = currency
        self.formattedTotal = formattedTotal
        self.itemCount = itemCount
        self.itemsSummary = itemsSummary
        self.items = items
        self.taxAmount = taxAmount
        self.formattedTax = formattedTax
        self.finalizedAt = finalizedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .passTypeIdentifier) ?? "pass.com.finsy.receipt"
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        storeName = try container.decode(String.self, forKey: .storeName)
        totalAmount = try container.decode(Double.self, forKey: .totalAmount)
        currency = try container.decode(CurrencyCode.self, forKey: .currency)
        formattedTotal = try container.decode(String.self, forKey: .formattedTotal)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        itemsSummary = try container.decodeIfPresent(String.self, forKey: .itemsSummary) ?? ""
        items = try container.decodeIfPresent([PurchaseReceiptPassItem].self, forKey: .items) ?? []
        taxAmount = try container.decodeIfPresent(Double.self, forKey: .taxAmount) ?? 0.0
        formattedTax = try container.decodeIfPresent(String.self, forKey: .formattedTax) ?? ""
        finalizedAt = try container.decode(Date.self, forKey: .finalizedAt)
        formattedDate = try container.decodeIfPresent(String.self, forKey: .formattedDate)
        payment = try container.decodeIfPresent(String.self, forKey: .payment)
        invoiceNumber = try container.decodeIfPresent(String.self, forKey: .invoiceNumber)
        transactionStatus = try container.decodeIfPresent(String.self, forKey: .transactionStatus)
        themeColorHex = try container.decodeIfPresent(String.self, forKey: .themeColorHex)
        barcode = try container.decodeIfPresent(WalletReceiptBarcode.self, forKey: .barcode)
    }
}

struct WalletReceiptBarcode: Codable, Hashable, Sendable {
    var message: String
    var format: String
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
        // A later export of the same month must not replace an earlier snapshot.
        self.serialNumber = "tax-expense-\(year)-\(String(format: "%02d", month))-\(UUID().uuidString)"
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
