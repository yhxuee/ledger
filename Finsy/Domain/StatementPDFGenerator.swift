import UIKit

enum StatementPDFGenerator {
    static let portraitWidth: CGFloat = 595.2
    static let portraitHeight: CGFloat = 841.8

    static let landscapeWidth: CGFloat = 841.8
    static let landscapeHeight: CGFloat = 595.2

    static let margin: CGFloat = 36
    static let footerHeight: CGFloat = 46

    // Fixed print-safe colors for document rendering (independent of trait environment / Dark Mode)
    static let textColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
    static let secondaryTextColor = UIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1.0)
    static let ruleColor = UIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
    static let tableHeaderBgColor = UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
    static let alternateRowBgColor = UIColor(red: 0.985, green: 0.985, blue: 0.985, alpha: 1.0)

    static let mandatoryDisclaimer = "Disclaimer: Finsy is a personal bookkeeping tool and is NOT a bank, financial institution, or licensed tax advisor. This statement is generated solely from user-entered records for informational and personal budgeting purposes only."
    static let taxDisclaimer = "Disclaimer: Finsy is a personal bookkeeping tool and is NOT a bank, financial institution, or licensed tax advisor. This statement is generated solely from user-entered records for informational and personal budgeting purposes only. This document does not constitute official tax advice."

    struct AccountMonthlySummary: Sendable {
        let account: LedgerAccount
        let openingBalance: Double
        let totalInflow: Double
        let totalOutflow: Double
        let closingBalance: Double
    }

    struct TaxItem: Sendable {
        let transaction: LedgerTransaction
        let accountName: String
        let categoryName: String
        let note: String
        let grossAmount: Double
        let taxBase: Double
        let rate: Double
        let taxAmount: Double
        let status: String
    }

    // MARK: - Date Helpers

    static func periodEnd(for startOfMonth: Date, calendar: Calendar, now: Date) -> Date {
        guard let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: startOfMonth) else {
            return now
        }
        if calendar.isDate(startOfMonth, equalTo: now, toGranularity: .month) {
            return now
        } else {
            return endOfMonth
        }
    }

    static func formatPeriodString(startOfMonth: Date, periodEnd: Date, calendar: Calendar, now: Date) -> String {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM"
        let monthName = monthFormatter.string(from: startOfMonth)
        let year = calendar.component(.year, from: startOfMonth)

        let startDay = 1
        let endDay = calendar.component(.day, from: periodEnd)
        return "\(monthName) \(startDay)–\(endDay), \(year)"
    }

    static func formatAccountsHeader(accounts: [LedgerAccount], allAccountsSelected: Bool) -> String {
        if allAccountsSelected {
            return "Accounts: All"
        } else if accounts.count == 1 {
            return "Account: \(accounts[0].name)"
        } else {
            return "Accounts: \(accounts.map(\.name).joined(separator: ", "))"
        }
    }

    static func formatFXRate(_ rate: Double) -> String {
        if abs(rate - 1.0) < 0.00001 {
            return "1"
        }
        let formatted = String(format: "%.4f", rate)
        var trimmed = formatted
        while trimmed.hasSuffix("0") && trimmed.contains(".") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func computeThreeMonthWindows(
        startOfMonth: Date,
        cutoffEnd: Date,
        calendar: Calendar,
        now: Date
    ) -> (m1: MonthPeriod, m2: MonthPeriod, m3: MonthPeriod, rangeString: String, currentPartialNote: String?) {
        ThreeMonthFinancialEngine.computeThreeMonthWindows(startOfMonth: startOfMonth, cutoffEnd: cutoffEnd, calendar: calendar, now: now)
    }


}
