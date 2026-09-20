import Foundation

enum StatementType: String, CaseIterable, Identifiable, Sendable {
    case monthly = "Finsy Statement"
    case tax = "Tax Statement"

    var id: String { rawValue }
    var displayTitle: String { rawValue }
}

enum StatementError: LocalizedError {
    case invalidDateRange
    case noDataAvailable

    var errorDescription: String? {
        switch self {
        case .invalidDateRange: return "The selected date range is invalid."
        case .noDataAvailable: return "No records were found for the selected accounts and period."
        }
    }
}

enum StatementPostingDirection: Sendable {
    case debit
    case credit
}

struct MonthlyStatementPosting: Identifiable, Sendable {
    var id: UUID = UUID()
    var transactionID: UUID
    var date: Date
    var accountID: UUID
    var categoryID: LedgerCategoryID
    var isTransfer: Bool
    var userDescription: String
    var originalCurrency: CurrencyCode
    var originalAmount: Double
    var baseCurrency: CurrencyCode
    var baseAmount: Double
    var effectiveFXRate: Double
    var direction: StatementPostingDirection
    var pocketCurrency: CurrencyCode?
    var nativeAmount: Double
}

