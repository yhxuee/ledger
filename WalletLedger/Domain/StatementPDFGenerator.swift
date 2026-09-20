import UIKit

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

enum StatementPostingResolver {
    static func resolveUserFacingDescription(
        transaction t: LedgerTransaction,
        isDestinationSide: Bool,
        state: LedgerState
    ) -> String {
        // 1. Check if note is non-empty and not an internal system note
        if let note = t.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            let lower = note.lowercased()
            if !lower.starts(with: "refund support for") && !lower.contains("combinedpaymentrefundsupport") {
                return note
            }
        }

        // 2. Semantic description
        if t.type == .transfer {
            if let destID = t.destinationAccountID, let destAcc = state.accounts.first(where: { $0.id == destID }) {
                if isDestinationSide, let srcAcc = state.accounts.first(where: { $0.id == t.accountID }) {
                    return "Transfer from \(srcAcc.name)"
                } else {
                    return "Transfer to \(destAcc.name)"
                }
            }
            return "Transfer"
        }

        if let kind = t.linkedTransactionKind {
            switch kind {
            case .installment:
                if let index = t.linkedTransactionIndex {
                    let total = t.parentTransactionID.flatMap { pID in
                        state.transactions.first(where: { $0.id == pID })?.installmentMetadata?.totalInstallments
                    } ?? 0
                    return total > 0 ? "Installment \(index) / \(total)" : "Installment \(index)"
                }
                return "Installment"
            case .splitSelfExpense:
                return "Split Expense"
            case .splitSettlement:
                return "Split Settlement"
            case .reimbursementOriginal:
                return "Reimbursement Pending"
            case .reimbursementIncome:
                return "Reimbursement Settlement"
            case .refundOriginal:
                return "Refunded Purchase"
            case .refundIncome:
                if let pID = t.parentTransactionID, let parent = state.transactions.first(where: { $0.id == pID }) {
                    let catName = state.categories.first(where: { $0.id == parent.categoryID })?.name ?? "Purchase"
                    let pNote = parent.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "Refund · \((pNote != nil && !pNote!.isEmpty) ? pNote! : catName)"
                }
                return "Refund"
            case .combinedPaymentItem:
                return state.categories.first(where: { $0.id == t.categoryID })?.name ?? "General"
            case .combinedPaymentRefund:
                return "Combined Payment Refund"
            case .combinedPaymentRefundSupport:
                if let pID = t.parentTransactionID, let parent = state.transactions.first(where: { $0.id == pID }) {
                    let catName = state.categories.first(where: { $0.id == parent.categoryID })?.name ?? "General"
                    return "Refund · \(catName)"
                }
                return "Refund"
            }
        }

        if t.isReversal {
            if let origID = t.reversalOfTransactionID, let orig = state.transactions.first(where: { $0.id == origID }) {
                let catName = state.categories.first(where: { $0.id == orig.categoryID })?.name ?? "Purchase"
                let oNote = orig.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Refund · \((oNote != nil && !oNote!.isEmpty) ? oNote! : catName)"
            }
            return "Refund"
        }

        // 3. Fallback to Category Name
        return state.categories.first(where: { $0.id == t.categoryID })?.name ?? "General"
    }

    static func resolvePostings(
        transactions: [LedgerTransaction],
        selectedAccountIDs: Set<UUID>,
        baseCurrency: CurrencyCode,
        in state: LedgerState
    ) -> [MonthlyStatementPosting] {
        var postings: [MonthlyStatementPosting] = []

        for t in transactions {
            guard TransactionSemantics.posts(t) else { continue }

            // 1. Source Account Posting (Debit for Expense / Transfer, Credit for Income)
            if selectedAccountIDs.contains(t.accountID),
               let sourceAccount = state.accounts.first(where: { $0.id == t.accountID }) {
                let origCurrency = t.currency
                let origAmount: Double
                switch t.type {
                case .expense:
                    origAmount = t.recognizedExpenseAmount
                case .income, .transfer:
                    origAmount = t.amount
                }

                let sourcePocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
                let nativePosting = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)

                let baseAmount: Double
                let effectiveFX: Double

                if origCurrency == baseCurrency {
                    baseAmount = origAmount
                    effectiveFX = 1.0
                } else if sourcePocket == baseCurrency, let accAmt = t.accountAmount, accAmt.isFinite, accAmt > 0 {
                    baseAmount = accAmt
                    effectiveFX = origAmount > 0.0001 ? baseAmount / origAmount : 1.0
                } else if t.exchangeRateAtTransaction.isFinite, t.exchangeRateAtTransaction > 0 {
                    baseAmount = LedgerCalculations.convertHistorical(origAmount, rate: t.exchangeRateAtTransaction, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = origAmount > 0.0001 ? baseAmount / origAmount : 1.0
                } else {
                    baseAmount = LedgerCalculations.convert(origAmount, from: origCurrency, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = origAmount > 0.0001 ? baseAmount / origAmount : 1.0
                }

                let direction: StatementPostingDirection = (t.type == .income) ? .credit : .debit
                let userDesc = resolveUserFacingDescription(transaction: t, isDestinationSide: false, state: state)

                postings.append(MonthlyStatementPosting(
                    transactionID: t.id,
                    date: t.occurredAt,
                    accountID: t.accountID,
                    categoryID: t.type == .transfer ? .other : t.categoryID,
                    isTransfer: t.type == .transfer,
                    userDescription: userDesc,
                    originalCurrency: origCurrency,
                    originalAmount: origAmount,
                    baseCurrency: baseCurrency,
                    baseAmount: baseAmount,
                    effectiveFXRate: effectiveFX,
                    direction: direction,
                    pocketCurrency: sourcePocket,
                    nativeAmount: nativePosting
                ))
            }

            // 2. Destination Account Posting (Credit for Transfer)
            if t.type == .transfer,
               let destID = t.destinationAccountID,
               selectedAccountIDs.contains(destID),
               let destAccount = state.accounts.first(where: { $0.id == destID }) {
                let destPocket = LedgerCalculations.destinationPocket(t, for: destAccount)
                let nativePosting = LedgerCalculations.destinationPosting(t, for: destAccount, in: state)
                let origCurrency = destPocket
                let origAmount = nativePosting

                let baseAmount: Double
                let effectiveFX: Double

                if destPocket == baseCurrency {
                    baseAmount = nativePosting
                    effectiveFX = 1.0
                } else if let destAmt = t.destinationAmount, destAmt.isFinite, destPocket == baseCurrency {
                    baseAmount = destAmt
                    effectiveFX = 1.0
                } else if t.exchangeRateAtTransaction.isFinite, t.exchangeRateAtTransaction > 0 {
                    let rate = CurrencyRates.reference(destPocket, in: state.settings.rates) ?? t.exchangeRateAtTransaction
                    baseAmount = LedgerCalculations.convertHistorical(nativePosting, rate: rate, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = nativePosting > 0.0001 ? baseAmount / nativePosting : 1.0
                } else {
                    baseAmount = LedgerCalculations.convert(nativePosting, from: destPocket, to: baseCurrency, rates: state.settings.rates)
                    effectiveFX = nativePosting > 0.0001 ? baseAmount / nativePosting : 1.0
                }

                let userDesc = resolveUserFacingDescription(transaction: t, isDestinationSide: true, state: state)

                postings.append(MonthlyStatementPosting(
                    transactionID: t.id,
                    date: t.occurredAt,
                    accountID: destID,
                    categoryID: .other,
                    isTransfer: true,
                    userDescription: userDesc,
                    originalCurrency: destPocket,
                    originalAmount: origAmount,
                    baseCurrency: baseCurrency,
                    baseAmount: baseAmount,
                    effectiveFXRate: effectiveFX,
                    direction: .credit,
                    pocketCurrency: destPocket,
                    nativeAmount: nativePosting
                ))
            }
        }

        return postings.sorted { $0.date < $1.date }
    }
}

enum StatementPDFGenerator {
    // Standard A4 dimensions in points (72 pt/inch)
    static let portraitWidth: CGFloat = 595.2
    static let portraitHeight: CGFloat = 841.8

    static let landscapeWidth: CGFloat = 841.8
    static let landscapeHeight: CGFloat = 595.2

    static let margin: CGFloat = 36
    static let footerHeight: CGFloat = 46

    // Fixed print-safe colors for document rendering (independent of trait environment / Dark Mode)
    private static let textColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
    private static let secondaryTextColor = UIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1.0)
    private static let ruleColor = UIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
    private static let tableHeaderBgColor = UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
    private static let alternateRowBgColor = UIColor(red: 0.985, green: 0.985, blue: 0.985, alpha: 1.0)

    private static let mandatoryDisclaimer = "Disclaimer: Finsy is a personal bookkeeping tool and is NOT a bank, financial institution, or licensed tax advisor. This statement is generated solely from user-entered records for informational and personal budgeting purposes only."
    private static let taxDisclaimer = "Disclaimer: Finsy is a personal bookkeeping tool and is NOT a bank, financial institution, or licensed tax advisor. This statement is generated solely from user-entered records for informational and personal budgeting purposes only. This document does not constitute official tax advice."

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

    struct MonthPeriod: Sendable {
        let monthStart: Date
        let monthEnd: Date
        let label: String
        let isCurrentPartial: Bool
    }

    // MARK: - Date Helpers

    private static func periodEnd(for startOfMonth: Date, calendar: Calendar, now: Date) -> Date {
        guard let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: startOfMonth) else {
            return now
        }
        if calendar.isDate(startOfMonth, equalTo: now, toGranularity: .month) {
            return now
        } else {
            return endOfMonth
        }
    }

    private static func formatPeriodString(startOfMonth: Date, periodEnd: Date, calendar: Calendar, now: Date) -> String {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM"
        let monthName = monthFormatter.string(from: startOfMonth)
        let year = calendar.component(.year, from: startOfMonth)

        let startDay = 1
        let endDay = calendar.component(.day, from: periodEnd)
        return "\(monthName) \(startDay)–\(endDay), \(year)"
    }

    private static func formatAccountsHeader(accounts: [LedgerAccount], allAccountsSelected: Bool) -> String {
        if allAccountsSelected {
            return "Accounts: All"
        } else if accounts.count == 1 {
            return "Account: \(accounts[0].name)"
        } else {
            return "Accounts: \(accounts.map(\.name).joined(separator: ", "))"
        }
    }

    private static func formatFXRate(_ rate: Double) -> String {
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

    private static func computeThreeMonthWindows(
        startOfMonth: Date,
        cutoffEnd: Date,
        calendar: Calendar,
        now: Date
    ) -> (m1: MonthPeriod, m2: MonthPeriod, m3: MonthPeriod, rangeString: String, currentPartialNote: String?) {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        let isM3Partial = calendar.isDate(startOfMonth, equalTo: now, toGranularity: .month)
        let m3 = MonthPeriod(monthStart: startOfMonth, monthEnd: cutoffEnd, label: monthFormatter.string(from: startOfMonth), isCurrentPartial: isM3Partial)

        let m2Start = calendar.date(byAdding: .month, value: -1, to: startOfMonth)!
        let m2End = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: m2Start)!
        let m2 = MonthPeriod(monthStart: m2Start, monthEnd: m2End, label: monthFormatter.string(from: m2Start), isCurrentPartial: false)

        let m1Start = calendar.date(byAdding: .month, value: -2, to: startOfMonth)!
        let m1End = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: m1Start)!
        let m1 = MonthPeriod(monthStart: m1Start, monthEnd: m1End, label: monthFormatter.string(from: m1Start), isCurrentPartial: false)

        let rangeString = "\(monthFormatter.string(from: m1Start)) – \(monthFormatter.string(from: startOfMonth))"

        var partialNote: String? = nil
        if isM3Partial {
            let fullDF = DateFormatter()
            fullDF.dateStyle = .long
            partialNote = "Current-month figures are based on records through \(fullDF.string(from: cutoffEnd))."
        }

        return (m1, m2, m3, rangeString, partialNote)
    }

    // MARK: - Entry Points

    static func generateMonthlyStatement(
        monthDate: Date,
        accounts: [LedgerAccount],
        allAccountsSelected: Bool = false,
        in state: LedgerState,
        now: Date = .now
    ) throws -> URL {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) else {
            throw StatementError.invalidDateRange
        }
        let cutoffEnd = periodEnd(for: startOfMonth, calendar: calendar, now: now)
        let periodString = formatPeriodString(startOfMonth: startOfMonth, periodEnd: cutoffEnd, calendar: calendar, now: now)

        let safeAccounts = accounts.filter { $0.deletedAt == nil }
        guard !safeAccounts.isEmpty else {
            throw StatementError.noDataAvailable
        }

        // Special Mode: Exactly one account selected and that account uses currency pockets
        if safeAccounts.count == 1, safeAccounts[0].usesCurrencyPockets {
            return try generateSingleMultiCurrencyStatement(
                account: safeAccounts[0],
                startOfMonth: startOfMonth,
                cutoffEnd: cutoffEnd,
                periodString: periodString,
                in: state,
                now: now
            )
        }

        // General Mode: Multi-account or single non-multi-currency account, base-currency denominated
        return try generateGeneralFinsyStatement(
            accounts: safeAccounts,
            allAccountsSelected: allAccountsSelected,
            startOfMonth: startOfMonth,
            cutoffEnd: cutoffEnd,
            periodString: periodString,
            in: state,
            now: now
        )
    }

    // MARK: - General Base-Currency Finsy Statement

    private static func generateGeneralFinsyStatement(
        accounts: [LedgerAccount],
        allAccountsSelected: Bool,
        startOfMonth: Date,
        cutoffEnd: Date,
        periodString: String,
        in state: LedgerState,
        now: Date
    ) throws -> URL {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let accountIDs = Set(accounts.map(\.id))

        // Collect transactions
        let allTransactions = state.transactions.filter {
            $0.deletedAt == nil &&
            $0.occurredAt >= startOfMonth &&
            $0.occurredAt <= cutoffEnd &&
            (accountIDs.contains($0.accountID) || ($0.destinationAccountID != nil && accountIDs.contains($0.destinationAccountID!))) &&
            TransactionSemantics.posts($0)
        }.sorted { $0.occurredAt < $1.occurredAt }

        let postings = StatementPostingResolver.resolvePostings(
            transactions: allTransactions,
            selectedAccountIDs: accountIDs,
            baseCurrency: baseCurrency,
            in: state
        )

        // Calculate Account Summaries in Base Currency
        var summaries: [AccountMonthlySummary] = []
        for account in accounts {
            let openingNative = calculateBalance(account: account, upTo: startOfMonth, in: state)
            let openingBase = LedgerCalculations.convert(openingNative, from: account.currency, to: baseCurrency, rates: state.settings.rates)

            let accPostings = postings.filter { $0.accountID == account.id }
            let inflow = accPostings.filter { $0.direction == .credit }.reduce(0.0) { $0 + $1.baseAmount }
            let outflow = accPostings.filter { $0.direction == .debit }.reduce(0.0) { $0 + $1.baseAmount }
            let closing = openingBase + inflow - outflow

            summaries.append(AccountMonthlySummary(
                account: account,
                openingBalance: openingBase,
                totalInflow: inflow,
                totalOutflow: outflow,
                closingBalance: closing
            ))
        }

        let accountsText = formatAccountsHeader(accounts: accounts, allAccountsSelected: allAccountsSelected)

        let pageRect = CGRect(x: 0, y: 0, width: portraitWidth, height: portraitHeight)
        let contentWidth = portraitWidth - (margin * 2)

        // General Statement columns (7 columns):
        // Date (12%), Account (15%), Category (13%), Description (25%), Currency (8%), FX Rate (10%), Amount (17%)
        let colWidths: [CGFloat] = [
            contentWidth * 0.12, // Date (~63pt)
            contentWidth * 0.15, // Account (~78pt)
            contentWidth * 0.13, // Category (~68pt)
            contentWidth * 0.25, // Description (~131pt)
            contentWidth * 0.08, // Currency (~42pt)
            contentWidth * 0.10, // FX Rate (~52pt)
            contentWidth * 0.17  // Amount (~89pt)
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            var pageIndex = 1
            var yOffset: CGFloat = margin

            func startNewPage() {
                if pageIndex > 1 {
                    drawFooter(pageNumber: pageIndex - 1, totalWidth: portraitWidth, totalHeight: portraitHeight, disclaimer: mandatoryDisclaimer)
                }
                context.beginPage()
                UIColor.white.setFill()
                UIRectFill(pageRect)

                yOffset = margin
                drawHeader(
                    title: "FINSY STATEMENT",
                    periodString: periodString,
                    baseCurrency: baseCurrency,
                    accountPrimaryCurrency: nil,
                    accountsText: accountsText,
                    date: now,
                    pageWidth: portraitWidth,
                    yOffset: &yOffset
                )
                pageIndex += 1
            }

            startNewPage()

            // 1. Account Summary Section (in Base Currency)
            drawSectionTitle("Account Summary (Amounts in \(baseCurrency.rawValue))", yOffset: &yOffset)
            drawGeneralAccountSummaryTable(
                summaries: summaries,
                baseCurrency: baseCurrency,
                contentWidth: contentWidth,
                yOffset: &yOffset
            )

            yOffset += 18

            // 2. Transaction Records Table (7 columns)
            drawSectionTitle("Transaction Records (\(postings.count))", yOffset: &yOffset)
            drawGeneralTransactionTableHeader(baseCurrency: baseCurrency, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)

            for (idx, posting) in postings.enumerated() {
                let descHeight = measureDescriptionHeight(text: posting.userDescription, width: colWidths[3] - 6)
                let estimatedRowHeight = max(19.0, descHeight + 7.0)

                if yOffset + estimatedRowHeight > portraitHeight - margin - footerHeight {
                    startNewPage()
                    drawSectionTitle("Transaction Records (Continued)", yOffset: &yOffset)
                    drawGeneralTransactionTableHeader(baseCurrency: baseCurrency, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)
                }

                drawGeneralTransactionRow(
                    posting: posting,
                    baseCurrency: baseCurrency,
                    in: state,
                    contentWidth: contentWidth,
                    colWidths: colWidths,
                    isAlternate: idx % 2 == 1,
                    yOffset: &yOffset
                )
            }

            // Finish the last content page with its footer
            drawFooter(pageNumber: pageIndex - 1, totalWidth: portraitWidth, totalHeight: portraitHeight, disclaimer: mandatoryDisclaimer)

            // 3. Append 3-Month Personal Summary on a dedicated final page
            context.beginPage()
            UIColor.white.setFill()
            UIRectFill(pageRect)
            drawThreeMonthPersonalSummaryPage(
                startOfMonth: startOfMonth,
                cutoffEnd: cutoffEnd,
                pageWidth: portraitWidth,
                pageHeight: portraitHeight,
                pageNumber: pageIndex,
                state: state,
                now: now
            )
        }

        let year = calendar.component(.year, from: startOfMonth)
        let month = calendar.component(.month, from: startOfMonth)
        let monthStr = String(format: "%02d", month)
        let filename = "Finsy_Statement_\(year)_\(monthStr).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try pdfData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    // MARK: - Native Multi-Currency Account Statement Mode

    private static func generateSingleMultiCurrencyStatement(
        account: LedgerAccount,
        startOfMonth: Date,
        cutoffEnd: Date,
        periodString: String,
        in state: LedgerState,
        now: Date
    ) throws -> URL {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let accountIDs: Set<UUID> = [account.id]

        let allTransactions = state.transactions.filter {
            $0.deletedAt == nil &&
            $0.occurredAt >= startOfMonth &&
            $0.occurredAt <= cutoffEnd &&
            (accountIDs.contains($0.accountID) || ($0.destinationAccountID != nil && accountIDs.contains($0.destinationAccountID!))) &&
            TransactionSemantics.posts($0)
        }.sorted { $0.occurredAt < $1.occurredAt }

        let allPostings = StatementPostingResolver.resolvePostings(
            transactions: allTransactions,
            selectedAccountIDs: accountIDs,
            baseCurrency: baseCurrency,
            in: state
        )

        let pockets = account.normalizedPockets
        let accountsText = "Account: \(account.name)"

        let pageRect = CGRect(x: 0, y: 0, width: portraitWidth, height: portraitHeight)
        let contentWidth = portraitWidth - (margin * 2)

        // Multi-currency pocket columns (5 columns):
        // Date (14%), Category (20%), Description (34%), Currency (10%), Amount (22%)
        let colWidths: [CGFloat] = [
            contentWidth * 0.14, // Date (~73pt)
            contentWidth * 0.20, // Category (~105pt)
            contentWidth * 0.34, // Description (~178pt)
            contentWidth * 0.10, // Currency (~52pt)
            contentWidth * 0.22  // Amount (~115pt)
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            var pageIndex = 1
            var yOffset: CGFloat = margin

            func startNewPage() {
                if pageIndex > 1 {
                    drawFooter(pageNumber: pageIndex - 1, totalWidth: portraitWidth, totalHeight: portraitHeight, disclaimer: mandatoryDisclaimer)
                }
                context.beginPage()
                UIColor.white.setFill()
                UIRectFill(pageRect)

                yOffset = margin
                drawHeader(
                    title: "FINSY STATEMENT",
                    periodString: periodString,
                    baseCurrency: baseCurrency,
                    accountPrimaryCurrency: account.currency,
                    accountsText: accountsText,
                    date: now,
                    pageWidth: portraitWidth,
                    yOffset: &yOffset
                )
                pageIndex += 1
            }

            startNewPage()

            // Group by Currency Pocket (Primary currency first)
            for (pIdx, pocket) in pockets.enumerated() {
                let pocketCurrency = pocket.currency
                let pocketPostings = allPostings.filter { $0.accountID == account.id && $0.pocketCurrency == pocketCurrency }

                let opening = calculatePocketBalance(pocket: pocketCurrency, account: account, upTo: startOfMonth, in: state)
                let inflow = pocketPostings.filter { $0.direction == .credit }.reduce(0.0) { $0 + $1.nativeAmount }
                let outflow = pocketPostings.filter { $0.direction == .debit }.reduce(0.0) { $0 + $1.nativeAmount }
                let closing = opening + inflow - outflow

                if yOffset + 90 > portraitHeight - margin - footerHeight {
                    startNewPage()
                }

                let tag = (pocketCurrency == account.currency) ? " (Primary Currency)" : ""
                drawSectionTitle("\(pocketCurrency.rawValue) Pocket\(tag)", yOffset: &yOffset)

                drawPocketSummaryTable(
                    pocketCurrency: pocketCurrency,
                    opening: opening,
                    inflow: inflow,
                    outflow: outflow,
                    closing: closing,
                    contentWidth: contentWidth,
                    yOffset: &yOffset
                )

                yOffset += 14

                if pocketPostings.isEmpty {
                    let emptyAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
                        .foregroundColor: secondaryTextColor
                    ]
                    "No transactions recorded for this pocket in this period.".draw(at: CGPoint(x: margin, y: yOffset), withAttributes: emptyAttrs)
                    yOffset += 24
                } else {
                    drawMultiCurrencyTransactionTableHeader(pocketCurrency: pocketCurrency, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)

                    for (idx, posting) in pocketPostings.enumerated() {
                        let descHeight = measureDescriptionHeight(text: posting.userDescription, width: colWidths[2] - 6)
                        let estimatedRowHeight = max(19.0, descHeight + 7.0)

                        if yOffset + estimatedRowHeight > portraitHeight - margin - footerHeight {
                            startNewPage()
                            drawSectionTitle("\(pocketCurrency.rawValue) Pocket (Continued)", yOffset: &yOffset)
                            drawMultiCurrencyTransactionTableHeader(pocketCurrency: pocketCurrency, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)
                        }

                        drawMultiCurrencyTransactionRow(
                            posting: posting,
                            pocketCurrency: pocketCurrency,
                            in: state,
                            contentWidth: contentWidth,
                            colWidths: colWidths,
                            isAlternate: idx % 2 == 1,
                            yOffset: &yOffset
                        )
                    }
                    yOffset += 16
                }

                if pIdx < pockets.count - 1 {
                    yOffset += 10
                }
            }

            drawFooter(pageNumber: pageIndex - 1, totalWidth: portraitWidth, totalHeight: portraitHeight, disclaimer: mandatoryDisclaimer)

            // Append 3-Month Personal Summary on a dedicated final page
            context.beginPage()
            UIColor.white.setFill()
            UIRectFill(pageRect)
            drawThreeMonthPersonalSummaryPage(
                startOfMonth: startOfMonth,
                cutoffEnd: cutoffEnd,
                pageWidth: portraitWidth,
                pageHeight: portraitHeight,
                pageNumber: pageIndex,
                state: state,
                now: now
            )
        }

        let year = calendar.component(.year, from: startOfMonth)
        let month = calendar.component(.month, from: startOfMonth)
        let monthStr = String(format: "%02d", month)
        let filename = "Finsy_Statement_\(year)_\(monthStr).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try pdfData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    // MARK: - Tax Statement (A4 Landscape)

    static func generateTaxStatement(
        monthDate: Date,
        accounts: [LedgerAccount],
        allAccountsSelected: Bool = false,
        in state: LedgerState,
        now: Date = .now
    ) throws -> URL {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) else {
            throw StatementError.invalidDateRange
        }
        let cutoffEnd = periodEnd(for: startOfMonth, calendar: calendar, now: now)
        let periodString = formatPeriodString(startOfMonth: startOfMonth, periodEnd: cutoffEnd, calendar: calendar, now: now)

        let safeAccounts = accounts.filter { $0.deletedAt == nil }
        guard !safeAccounts.isEmpty else {
            throw StatementError.noDataAvailable
        }
        let accountIDs = Set(safeAccounts.map(\.id))
        let targetCurrency = state.settings.baseCurrency

        var taxItems: [TaxItem] = []
        var categoryTotals: [String: (base: Double, tax: Double, count: Int)] = [:]

        let candidateTransactions = state.transactions.filter {
            $0.deletedAt == nil &&
            $0.occurredAt >= startOfMonth &&
            $0.occurredAt <= cutoffEnd &&
            accountIDs.contains($0.accountID)
        }.sorted { $0.occurredAt < $1.occurredAt }

        for transaction in candidateTransactions {
            guard let taxResult = TransactionSemantics.taxEffect(transaction, in: state, to: targetCurrency, now: now),
                  abs(taxResult.amount) > 0.0001 || (transaction.isTaxExempt == true && transaction.amount > 0) else {
                continue
            }

            let catName = state.categories.first { $0.id == taxResult.categoryID }?.name ?? "General"
            let accName = safeAccounts.first { $0.id == transaction.accountID }?.name ?? "Account"
            let note = transaction.note ?? ""
            let rate = transaction.taxRate ?? (state.categories.first(where: { $0.id == taxResult.categoryID }).map { state.settings.taxRate(for: $0) } ?? 0)

            let grossInTarget = LedgerCalculations.convert(transaction.amount, from: transaction.currency, to: targetCurrency, rates: state.settings.rates)
            let baseInTxCurrency = transaction.taxBaseAmount ?? (transaction.amount - (transaction.taxAmount ?? 0))
            let baseInTarget = LedgerCalculations.convert(baseInTxCurrency, from: transaction.currency, to: targetCurrency, rates: state.settings.rates)
            let taxAmt = taxResult.amount

            var status = "Taxable"
            if transaction.isTaxExempt == true {
                status = "Tax-Free"
            } else if transaction.isReversal {
                status = "Refund Support"
            } else if transaction.groupMode == .combinedPayment {
                status = "Combined"
            }

            taxItems.append(TaxItem(
                transaction: transaction,
                accountName: accName,
                categoryName: catName,
                note: note,
                grossAmount: grossInTarget,
                taxBase: baseInTarget,
                rate: rate,
                taxAmount: taxAmt,
                status: status
            ))

            let current = categoryTotals[catName, default: (base: 0, tax: 0, count: 0)]
            categoryTotals[catName] = (
                base: current.base + baseInTarget,
                tax: current.tax + taxAmt,
                count: current.count + 1
            )
        }

        let totalBase = categoryTotals.values.reduce(0.0) { $0 + $1.base }
        let totalTax = categoryTotals.values.reduce(0.0) { $0 + $1.tax }

        let accountsText = formatAccountsHeader(accounts: safeAccounts, allAccountsSelected: allAccountsSelected)

        let pageRect = CGRect(x: 0, y: 0, width: landscapeWidth, height: landscapeHeight)
        let contentWidth = landscapeWidth - (margin * 2)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            var pageIndex = 1
            var yOffset: CGFloat = margin

            func startNewPage() {
                if pageIndex > 1 {
                    drawFooter(pageNumber: pageIndex - 1, totalWidth: landscapeWidth, totalHeight: landscapeHeight, disclaimer: taxDisclaimer)
                }
                context.beginPage()
                UIColor.white.setFill()
                UIRectFill(pageRect)

                yOffset = margin
                drawHeader(
                    title: "FINSY MONTHLY TAX STATEMENT",
                    periodString: periodString,
                    baseCurrency: targetCurrency,
                    accountPrimaryCurrency: nil,
                    accountsText: accountsText,
                    date: now,
                    pageWidth: landscapeWidth,
                    yOffset: &yOffset
                )
                pageIndex += 1
            }

            startNewPage()

            // 1. Tax Summary by Category
            drawSectionTitle("Tax Summary by Category", yOffset: &yOffset)
            drawTaxCategorySummaryTable(
                categoryTotals: categoryTotals,
                totalBase: totalBase,
                totalTax: totalTax,
                currency: targetCurrency,
                contentWidth: contentWidth,
                yOffset: &yOffset
            )

            yOffset += 18

            // 2. Tax Recognized Records Table (Landscape, 9 columns)
            drawSectionTitle("Tax-Recognized Records (\(taxItems.count))", yOffset: &yOffset)
            drawTaxTableHeader(contentWidth: contentWidth, yOffset: &yOffset)

            for (idx, item) in taxItems.enumerated() {
                let note = item.note
                let estimatedRowHeight: CGFloat = note.count > 35 ? 28 : 20
                if yOffset + estimatedRowHeight > landscapeHeight - margin - footerHeight {
                    startNewPage()
                    drawSectionTitle("Tax-Recognized Records (Continued)", yOffset: &yOffset)
                    drawTaxTableHeader(contentWidth: contentWidth, yOffset: &yOffset)
                }
                drawTaxRow(
                    item: item,
                    in: state,
                    contentWidth: contentWidth,
                    rowHeight: estimatedRowHeight,
                    isAlternate: idx % 2 == 1,
                    yOffset: &yOffset
                )
            }

            drawFooter(pageNumber: pageIndex - 1, totalWidth: landscapeWidth, totalHeight: landscapeHeight, disclaimer: taxDisclaimer)
        }

        let year = calendar.component(.year, from: startOfMonth)
        let month = calendar.component(.month, from: startOfMonth)
        let monthStr = String(format: "%02d", month)
        let filename = "Finsy_Tax_Statement_\(year)_\(monthStr).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try pdfData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    // MARK: - Calculation Helpers

    private static func calculateBalance(account: LedgerAccount, upTo cutoff: Date, in state: LedgerState) -> Double {
        let opening = account.openingBalance
        return state.transactions.reduce(opening) { balance, transaction in
            guard transaction.deletedAt == nil, transaction.occurredAt < cutoff, TransactionSemantics.posts(transaction) else {
                return balance
            }
            var updated = balance
            if transaction.accountID == account.id {
                let amount = LedgerCalculations.sourcePosting(transaction, for: account, in: state)
                switch transaction.type {
                case .expense, .transfer: updated -= amount
                case .income: updated += amount
                }
            }
            if transaction.type == .transfer, transaction.destinationAccountID == account.id {
                updated += LedgerCalculations.destinationPosting(transaction, for: account, in: state)
            }
            return updated
        }
    }

    private static func calculatePocketBalance(pocket: CurrencyCode, account: LedgerAccount, upTo cutoff: Date, in state: LedgerState) -> Double {
        let opening = account.normalizedPockets.first(where: { $0.currency == pocket })?.openingBalance ?? 0
        return state.transactions.reduce(opening) { balance, transaction in
            guard transaction.deletedAt == nil, transaction.occurredAt < cutoff, TransactionSemantics.posts(transaction) else {
                return balance
            }
            var updated = balance
            if transaction.accountID == account.id, LedgerCalculations.sourcePocket(transaction, for: account) == pocket {
                let amount = LedgerCalculations.sourcePosting(transaction, for: account, in: state)
                switch transaction.type {
                case .expense, .transfer: updated -= amount
                case .income: updated += amount
                }
            }
            if transaction.type == .transfer, transaction.destinationAccountID == account.id, LedgerCalculations.destinationPocket(transaction, for: account) == pocket {
                updated += LedgerCalculations.destinationPosting(transaction, for: account, in: state)
            }
            return updated
        }
    }

    // MARK: - 3-Month Whole-Ledger Metrics Calculations

    private static func totalActiveAssets(at cutoff: Date, baseCurrency: CurrencyCode, in state: LedgerState) -> Double {
        let activeAccounts = state.accounts.filter { $0.deletedAt == nil && !$0.effectiveIsFrozen }
        var assetsTotal: Double = 0

        for account in activeAccounts {
            if account.type == .stocks, let stock = account.stockMetadata {
                let val = (stock.latestPriceAt != nil && stock.latestPriceAt! <= cutoff) ? stock.value : stock.costBasis
                let converted = LedgerCalculations.convert(val, from: account.currency, to: baseCurrency, rates: state.settings.rates)
                if converted > 0 { assetsTotal += converted }
            } else if account.usesCurrencyPockets {
                var accountTotalBase: Double = 0
                for pocket in account.normalizedPockets {
                    let pBal = calculatePocketBalance(pocket: pocket.currency, account: account, upTo: cutoff, in: state)
                    accountTotalBase += LedgerCalculations.convert(pBal, from: pocket.currency, to: baseCurrency, rates: state.settings.rates)
                }
                if accountTotalBase > 0 { assetsTotal += accountTotalBase }
            } else {
                let bal = calculateBalance(account: account, upTo: cutoff, in: state)
                let converted = LedgerCalculations.convert(bal, from: account.currency, to: baseCurrency, rates: state.settings.rates)
                if converted > 0 { assetsTotal += converted }
            }
        }

        return assetsTotal
    }

    private static func monthlyRecognizedIncome(from: Date, to: Date, baseCurrency: CurrencyCode, in state: LedgerState, now: Date) -> Double {
        let txs = state.transactions.filter {
            $0.deletedAt == nil && $0.occurredAt >= from && $0.occurredAt <= to
        }
        return txs.compactMap { TransactionSemantics.incomeEffect($0, in: state, to: baseCurrency, now: now) }.reduce(0.0, +)
    }

    private static func monthlyRecognizedExpense(from: Date, to: Date, baseCurrency: CurrencyCode, in state: LedgerState, now: Date) -> Double {
        let txs = state.transactions.filter {
            $0.deletedAt == nil && $0.occurredAt >= from && $0.occurredAt <= to
        }
        return txs.compactMap { TransactionSemantics.expenseEffect($0, in: state, to: baseCurrency, now: now) }.reduce(0.0, +)
    }

    private static func monthlyExternalTurnover(from: Date, to: Date, baseCurrency: CurrencyCode, in state: LedgerState) -> Double {
        let ownedAccountIDs = Set(state.accounts.filter { $0.deletedAt == nil }.map(\.id))
        let txs = state.transactions.filter {
            $0.deletedAt == nil && $0.occurredAt >= from && $0.occurredAt <= to && TransactionSemantics.posts($0)
        }

        var turnover: Double = 0
        for t in txs {
            if t.type == .transfer {
                let srcOwned = ownedAccountIDs.contains(t.accountID)
                let destOwned = t.destinationAccountID.map { ownedAccountIDs.contains($0) } ?? false
                // Internal transfer between own accounts: excluded from turnover
                if srcOwned && destOwned {
                    continue
                } else if srcOwned, let sourceAccount = state.accounts.first(where: { $0.id == t.accountID }) {
                    let posted = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)
                    let pocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
                    turnover += LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
                } else if destOwned, let destID = t.destinationAccountID, let destAccount = state.accounts.first(where: { $0.id == destID }) {
                    let posted = LedgerCalculations.destinationPosting(t, for: destAccount, in: state)
                    let pocket = LedgerCalculations.destinationPocket(t, for: destAccount)
                    turnover += LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
                }
            } else if t.type == .expense, let sourceAccount = state.accounts.first(where: { $0.id == t.accountID }) {
                let posted = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)
                let pocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
                turnover += LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
            } else if t.type == .income, let sourceAccount = state.accounts.first(where: { $0.id == t.accountID }) {
                let posted = LedgerCalculations.sourcePosting(t, for: sourceAccount, in: state)
                let pocket = LedgerCalculations.sourcePocket(t, for: sourceAccount)
                turnover += LedgerCalculations.convert(posted, from: pocket, to: baseCurrency, rates: state.settings.rates)
            }
        }

        return turnover
    }

    // MARK: - Drawing Components

    private static func drawHeader(
        title: String,
        periodString: String,
        baseCurrency: CurrencyCode?,
        accountPrimaryCurrency: CurrencyCode?,
        accountsText: String,
        date: Date,
        pageWidth: CGFloat,
        yOffset: inout CGFloat
    ) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 21, weight: .bold),
            .foregroundColor: textColor
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: secondaryTextColor
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: secondaryTextColor
        ]

        title.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: titleAttrs)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateStr = "Generated: \(dateFormatter.string(from: date))"
        let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)
        dateStr.draw(at: CGPoint(x: pageWidth - margin - dateSize.width, y: yOffset + 4), withAttributes: dateAttrs)

        yOffset += 24

        // Line 1: Period, Base Currency, Account Primary Currency
        var metaLine = "Period: \(periodString)"
        if let baseCurrency {
            metaLine += " · Base Currency: \(baseCurrency.rawValue)"
        }
        if let accountPrimaryCurrency, accountPrimaryCurrency != baseCurrency {
            metaLine += " · Account Primary Currency: \(accountPrimaryCurrency.rawValue)"
        }
        metaLine.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: subAttrs)

        yOffset += 16

        // Line 2: Accounts Text (Word-wrapped)
        let accountsParagraph = NSMutableParagraphStyle()
        accountsParagraph.lineBreakMode = .byWordWrapping
        let accAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: secondaryTextColor,
            .paragraphStyle: accountsParagraph
        ]
        let availableWidth = pageWidth - (margin * 2)
        let accBounding = (accountsText as NSString).boundingRect(
            with: CGSize(width: availableWidth, height: 40),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: accAttrs,
            context: nil
        )
        let accHeight = max(14, ceil(accBounding.height))
        (accountsText as NSString).draw(
            in: CGRect(x: margin, y: yOffset, width: availableWidth, height: accHeight),
            withAttributes: accAttrs
        )

        yOffset += accHeight + 8

        // Divider
        drawHLine(y: yOffset, width: pageWidth - (margin * 2))
        yOffset += 12
    }

    private static func drawSectionTitle(_ title: String, yOffset: inout CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: textColor
        ]
        title.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: attrs)
        yOffset += 18
    }

    private static func measureDescriptionHeight(text: String, width: CGFloat) -> CGFloat {
        let descParagraph = NSMutableParagraphStyle()
        descParagraph.lineBreakMode = .byWordWrapping
        descParagraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .paragraphStyle: descParagraph
        ]
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: 60),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        return ceil(bounding.height)
    }

    // MARK: - General Statement Tables

    private static func drawGeneralAccountSummaryTable(
        summaries: [AccountMonthlySummary],
        baseCurrency: CurrencyCode,
        contentWidth: CGFloat,
        yOffset: inout CGFloat
    ) {
        let colWidths: [CGFloat] = [
            contentWidth * 0.32, // Account
            contentWidth * 0.17, // Opening
            contentWidth * 0.17, // Inflow (+)
            contentWidth * 0.17, // Outflow (-)
            contentWidth * 0.17  // Closing
        ]
        let headers = ["Account", "Opening", "Inflow (+)", "Outflow (-)", "Closing"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: textColor
        ]

        let headerRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 18)
        tableHeaderBgColor.setFill()
        UIRectFill(headerRect)

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = i >= 1 ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 16), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4

        for (idx, item) in summaries.enumerated() {
            let acc = item.account
            let rowRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 20)
            if idx % 2 == 1 {
                alternateRowBgColor.setFill()
                UIRectFill(rowRect)
            }

            x = margin
            drawText(acc.name, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 16), attrs: cellAttrs, alignment: .left)
            x += colWidths[0]
            drawText(formatMoney(item.openingBalance), in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 16), attrs: numAttrs, alignment: .right)
            x += colWidths[1]
            drawText(formatMoney(item.totalInflow), in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 16), attrs: numAttrs, alignment: .right)
            x += colWidths[2]
            drawText(formatMoney(item.totalOutflow), in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 16), attrs: numAttrs, alignment: .right)
            x += colWidths[3]
            drawText(formatMoney(item.closingBalance), in: CGRect(x: x, y: yOffset, width: colWidths[4], height: 16), attrs: numAttrs, alignment: .right)

            yOffset += 20
        }

        if summaries.count > 1 {
            drawHLine(y: yOffset, width: contentWidth)
            yOffset += 4
            let boldNumAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: textColor
            ]
            let boldTextAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: textColor
            ]

            let totalOpening = summaries.reduce(0.0) { $0 + $1.openingBalance }
            let totalInflow = summaries.reduce(0.0) { $0 + $1.totalInflow }
            let totalOutflow = summaries.reduce(0.0) { $0 + $1.totalOutflow }
            let totalClosing = summaries.reduce(0.0) { $0 + $1.closingBalance }

            x = margin
            drawText("Total", in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 16), attrs: boldTextAttrs, alignment: .left)
            x += colWidths[0]
            drawText(formatMoney(totalOpening), in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 16), attrs: boldNumAttrs, alignment: .right)
            x += colWidths[1]
            drawText(formatMoney(totalInflow), in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 16), attrs: boldNumAttrs, alignment: .right)
            x += colWidths[2]
            drawText(formatMoney(totalOutflow), in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 16), attrs: boldNumAttrs, alignment: .right)
            x += colWidths[3]
            drawText(formatMoney(totalClosing), in: CGRect(x: x, y: yOffset, width: colWidths[4], height: 16), attrs: boldNumAttrs, alignment: .right)

            yOffset += 20
        }

        drawHLine(y: yOffset, width: contentWidth)
    }

    private static func drawGeneralTransactionTableHeader(
        baseCurrency: CurrencyCode,
        contentWidth: CGFloat,
        colWidths: [CGFloat],
        yOffset: inout CGFloat
    ) {
        let headers = ["DATE", "ACCOUNT", "CATEGORY", "DESCRIPTION", "CURRENCY", "FX RATE", "AMOUNT \(baseCurrency.rawValue)"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]

        let headerRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 18)
        tableHeaderBgColor.setFill()
        UIRectFill(headerRect)

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = (i == 5 || i == 6) ? .right : (i == 4 ? .center : .left)
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 16), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4
    }

    private static func drawGeneralTransactionRow(
        posting: MonthlyStatementPosting,
        baseCurrency: CurrencyCode,
        in state: LedgerState,
        contentWidth: CGFloat,
        colWidths: [CGFloat],
        isAlternate: Bool,
        yOffset: inout CGFloat
    ) {
        let topPadding: CGFloat = 3
        let bottomPadding: CGFloat = 4

        let descParagraph = NSMutableParagraphStyle()
        descParagraph.lineBreakMode = .byWordWrapping
        descParagraph.alignment = .left
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: descParagraph
        ]

        let descWidth = colWidths[3] - 6
        let bounding = (posting.userDescription as NSString).boundingRect(
            with: CGSize(width: descWidth, height: 60),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: descAttrs,
            context: nil
        )
        let descHeight = ceil(bounding.height)
        let minRowHeight: CGFloat = 19
        let rowHeight = max(minRowHeight, descHeight + topPadding + bottomPadding)

        if isAlternate {
            let rowRect = CGRect(x: margin, y: yOffset - 1, width: contentWidth, height: rowHeight)
            alternateRowBgColor.setFill()
            UIRectFill(rowRect)
        }

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: secondaryTextColor
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: textColor
        ]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: posting.date)
        let accName = state.accounts.first { $0.id == posting.accountID }?.name ?? "Account"
        let catName = posting.isTransfer ? "Transfer" : (state.categories.first { $0.id == posting.categoryID }?.name ?? "General")
        let curStr = posting.originalCurrency.rawValue
        let fxStr = formatFXRate(posting.effectiveFXRate)

        let amtVal = formatMoney(posting.baseAmount)
        let amtStr = (posting.direction == .credit) ? "\(amtVal)CR" : amtVal

        let cellY = yOffset + topPadding

        var x = margin
        drawText(dateStr, in: CGRect(x: x, y: cellY, width: colWidths[0], height: 14), attrs: dateAttrs, alignment: .left)
        x += colWidths[0]
        drawText(accName, in: CGRect(x: x, y: cellY, width: colWidths[1], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[1]
        drawText(catName, in: CGRect(x: x, y: cellY, width: colWidths[2], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[2]
        (posting.userDescription as NSString).draw(
            in: CGRect(x: x, y: cellY, width: descWidth, height: descHeight),
            withAttributes: descAttrs
        )
        x += colWidths[3]
        drawText(curStr, in: CGRect(x: x, y: cellY, width: colWidths[4], height: 14), attrs: cellAttrs, alignment: .center)
        x += colWidths[4]
        drawText(fxStr, in: CGRect(x: x, y: cellY, width: colWidths[5], height: 14), attrs: numAttrs, alignment: .right)
        x += colWidths[5]
        drawText(amtStr, in: CGRect(x: x, y: cellY, width: colWidths[6], height: 14), attrs: numAttrs, alignment: .right)

        yOffset += rowHeight
    }

    // MARK: - Native Multi-Currency Account Drawing Helpers

    private static func drawPocketSummaryTable(
        pocketCurrency: CurrencyCode,
        opening: Double,
        inflow: Double,
        outflow: Double,
        closing: Double,
        contentWidth: CGFloat,
        yOffset: inout CGFloat
    ) {
        let colWidths: [CGFloat] = [
            contentWidth * 0.25, // Opening
            contentWidth * 0.25, // Inflow (+)
            contentWidth * 0.25, // Outflow (-)
            contentWidth * 0.25  // Closing
        ]
        let headers = ["Opening Balance", "Inflow (+)", "Outflow (-)", "Closing Balance"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: textColor
        ]

        let headerRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 18)
        tableHeaderBgColor.setFill()
        UIRectFill(headerRect)

        var x = margin
        for (i, h) in headers.enumerated() {
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 16), attrs: headerAttrs, alignment: .right)
            x += colWidths[i]
        }
        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4

        x = margin
        drawText("\(pocketCurrency.rawValue) \(formatMoney(opening))", in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[0]
        drawText("\(pocketCurrency.rawValue) \(formatMoney(inflow))", in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[1]
        drawText("\(pocketCurrency.rawValue) \(formatMoney(outflow))", in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[2]
        drawText("\(pocketCurrency.rawValue) \(formatMoney(closing))", in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 16), attrs: numAttrs, alignment: .right)

        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
    }

    private static func drawMultiCurrencyTransactionTableHeader(
        pocketCurrency: CurrencyCode,
        contentWidth: CGFloat,
        colWidths: [CGFloat],
        yOffset: inout CGFloat
    ) {
        let headers = ["DATE", "CATEGORY", "DESCRIPTION", "CURRENCY", "AMOUNT \(pocketCurrency.rawValue)"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]

        let headerRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 18)
        tableHeaderBgColor.setFill()
        UIRectFill(headerRect)

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = (i == 4) ? .right : (i == 3 ? .center : .left)
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 16), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4
    }

    private static func drawMultiCurrencyTransactionRow(
        posting: MonthlyStatementPosting,
        pocketCurrency: CurrencyCode,
        in state: LedgerState,
        contentWidth: CGFloat,
        colWidths: [CGFloat],
        isAlternate: Bool,
        yOffset: inout CGFloat
    ) {
        let topPadding: CGFloat = 3
        let bottomPadding: CGFloat = 4

        let descParagraph = NSMutableParagraphStyle()
        descParagraph.lineBreakMode = .byWordWrapping
        descParagraph.alignment = .left
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: descParagraph
        ]

        let descWidth = colWidths[2] - 6
        let bounding = (posting.userDescription as NSString).boundingRect(
            with: CGSize(width: descWidth, height: 60),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: descAttrs,
            context: nil
        )
        let descHeight = ceil(bounding.height)
        let minRowHeight: CGFloat = 19
        let rowHeight = max(minRowHeight, descHeight + topPadding + bottomPadding)

        if isAlternate {
            let rowRect = CGRect(x: margin, y: yOffset - 1, width: contentWidth, height: rowHeight)
            alternateRowBgColor.setFill()
            UIRectFill(rowRect)
        }

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: secondaryTextColor
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: textColor
        ]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: posting.date)
        let catName = posting.isTransfer ? "Transfer" : (state.categories.first { $0.id == posting.categoryID }?.name ?? "General")
        let curStr = posting.originalCurrency.rawValue

        let amtVal = formatMoney(posting.nativeAmount)
        let amtStr = (posting.direction == .credit) ? "\(amtVal)CR" : amtVal

        let cellY = yOffset + topPadding

        var x = margin
        drawText(dateStr, in: CGRect(x: x, y: cellY, width: colWidths[0], height: 14), attrs: dateAttrs, alignment: .left)
        x += colWidths[0]
        drawText(catName, in: CGRect(x: x, y: cellY, width: colWidths[1], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[1]
        (posting.userDescription as NSString).draw(
            in: CGRect(x: x, y: cellY, width: descWidth, height: descHeight),
            withAttributes: descAttrs
        )
        x += colWidths[2]
        drawText(curStr, in: CGRect(x: x, y: cellY, width: colWidths[3], height: 14), attrs: cellAttrs, alignment: .center)
        x += colWidths[3]
        drawText(amtStr, in: CGRect(x: x, y: cellY, width: colWidths[4], height: 14), attrs: numAttrs, alignment: .right)

        yOffset += rowHeight
    }

    // MARK: - 3-Month Personal Summary Dedicated Page

    private static func drawThreeMonthPersonalSummaryPage(
        startOfMonth: Date,
        cutoffEnd: Date,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        pageNumber: Int,
        state: LedgerState,
        now: Date
    ) {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let windows = computeThreeMonthWindows(startOfMonth: startOfMonth, cutoffEnd: cutoffEnd, calendar: calendar, now: now)

        var yOffset: CGFloat = margin

        // Page Header
        let docTitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 21, weight: .bold),
            .foregroundColor: textColor
        ]
        let subTitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: textColor
        ]
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: secondaryTextColor
        ]

        "Finsy Statement".draw(at: CGPoint(x: margin, y: yOffset), withAttributes: docTitleAttrs)
        yOffset += 28

        "3-Month Personal Summary".draw(at: CGPoint(x: margin, y: yOffset), withAttributes: subTitleAttrs)
        yOffset += 18

        let rangeMeta = "\(windows.rangeString) · Base Currency: \(baseCurrency.rawValue)"
        rangeMeta.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: metaAttrs)
        yOffset += 16

        if let partialNote = windows.currentPartialNote {
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 8.5, weight: .regular),
                .foregroundColor: secondaryTextColor
            ]
            partialNote.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: noteAttrs)
            yOffset += 14
        }

        yOffset += 4
        drawHLine(y: yOffset, width: pageWidth - (margin * 2))
        yOffset += 24

        // Calculations across 3 months
        let m1Assets = totalActiveAssets(at: windows.m1.monthEnd, baseCurrency: baseCurrency, in: state)
        let m2Assets = totalActiveAssets(at: windows.m2.monthEnd, baseCurrency: baseCurrency, in: state)
        let m3Assets = totalActiveAssets(at: windows.m3.monthEnd, baseCurrency: baseCurrency, in: state)
        let avgAssets = (m1Assets + m2Assets + m3Assets) / 3.0

        let m1Income = monthlyRecognizedIncome(from: windows.m1.monthStart, to: windows.m1.monthEnd, baseCurrency: baseCurrency, in: state, now: now)
        let m2Income = monthlyRecognizedIncome(from: windows.m2.monthStart, to: windows.m2.monthEnd, baseCurrency: baseCurrency, in: state, now: now)
        let m3Income = monthlyRecognizedIncome(from: windows.m3.monthStart, to: windows.m3.monthEnd, baseCurrency: baseCurrency, in: state, now: now)
        let avgIncome = (m1Income + m2Income + m3Income) / 3.0

        let m1Expense = monthlyRecognizedExpense(from: windows.m1.monthStart, to: windows.m1.monthEnd, baseCurrency: baseCurrency, in: state, now: now)
        let m2Expense = monthlyRecognizedExpense(from: windows.m2.monthStart, to: windows.m2.monthEnd, baseCurrency: baseCurrency, in: state, now: now)
        let m3Expense = monthlyRecognizedExpense(from: windows.m3.monthStart, to: windows.m3.monthEnd, baseCurrency: baseCurrency, in: state, now: now)
        let avgExpense = (m1Expense + m2Expense + m3Expense) / 3.0

        let m1Turnover = monthlyExternalTurnover(from: windows.m1.monthStart, to: windows.m1.monthEnd, baseCurrency: baseCurrency, in: state)
        let m2Turnover = monthlyExternalTurnover(from: windows.m2.monthStart, to: windows.m2.monthEnd, baseCurrency: baseCurrency, in: state)
        let m3Turnover = monthlyExternalTurnover(from: windows.m3.monthStart, to: windows.m3.monthEnd, baseCurrency: baseCurrency, in: state)
        let avgTurnover = (m1Turnover + m2Turnover + m3Turnover) / 3.0

        let metrics: [(title: String, amount: Double)] = [
            ("Average Total Assets", avgAssets),
            ("Average Monthly Income", avgIncome),
            ("Average Monthly Spending", avgExpense),
            ("Average Monthly Turnover", avgTurnover)
        ]

        // 2x2 Metric Cards
        let usableWidth = pageWidth - (margin * 2)
        let cardSpacing: CGFloat = 16
        let cardWidth = (usableWidth - cardSpacing) / 2
        let cardHeight: CGFloat = 80

        let cardTitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]
        let cardValAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold),
            .foregroundColor: textColor
        ]

        for (index, metric) in metrics.enumerated() {
            let col = index % 2
            let row = index / 2
            let cardX = margin + CGFloat(col) * (cardWidth + cardSpacing)
            let cardY = yOffset + CGFloat(row) * (cardHeight + cardSpacing)

            let cardRect = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
            let path = UIBezierPath(roundedRect: cardRect, cornerRadius: 8)
            tableHeaderBgColor.setFill()
            path.fill()
            ruleColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            metric.title.draw(at: CGPoint(x: cardX + 14, y: cardY + 14), withAttributes: cardTitleAttrs)
            let amtFormatted = "\(baseCurrency.rawValue) \(formatMoney(metric.amount))"
            amtFormatted.draw(at: CGPoint(x: cardX + 14, y: cardY + 38), withAttributes: cardValAttrs)
        }

        yOffset += (cardHeight * 2) + cardSpacing + 36

        // Footnotes
        let footnoteTitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: textColor
        ]
        "Metric Definitions & Accounting Notes".draw(at: CGPoint(x: margin, y: yOffset), withAttributes: footnoteTitleAttrs)
        yOffset += 16

        let footnoteParagraph = NSMutableParagraphStyle()
        footnoteParagraph.lineSpacing = 3
        footnoteParagraph.lineBreakMode = .byWordWrapping
        let footnoteAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: secondaryTextColor,
            .paragraphStyle: footnoteParagraph
        ]

        let footnotesText = """
        • Average Total Assets is based on month-end asset values across active accounts.
        • Monthly Income and Spending use Finsy's recognized analytics semantics.
        • Monthly Turnover represents external cash movement and excludes transfers between your own Finsy accounts.
        • Historical investment values may use book value where historical market quotes are unavailable.
        """

        (footnotesText as NSString).draw(
            in: CGRect(x: margin, y: yOffset, width: usableWidth, height: 75),
            withAttributes: footnoteAttrs
        )

        // Standard Page Footer
        drawFooter(pageNumber: pageNumber, totalWidth: pageWidth, totalHeight: pageHeight, disclaimer: mandatoryDisclaimer)
    }

    // MARK: - Tax Statement Tables (Landscape)

    private static func drawTaxCategorySummaryTable(
        categoryTotals: [String: (base: Double, tax: Double, count: Int)],
        totalBase: Double,
        totalTax: Double,
        currency: CurrencyCode,
        contentWidth: CGFloat,
        yOffset: inout CGFloat
    ) {
        let colWidths: [CGFloat] = [
            contentWidth * 0.35,
            contentWidth * 0.20,
            contentWidth * 0.225,
            contentWidth * 0.225
        ]
        let headers = ["Category", "Records", "Tax Base (\(currency.rawValue))", "Tax Amount (\(currency.rawValue))"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: textColor
        ]

        let headerRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 18)
        tableHeaderBgColor.setFill()
        UIRectFill(headerRect)

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = i >= 2 ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 16), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4

        for (idx, item) in categoryTotals.sorted(by: { $0.key < $1.key }).enumerated() {
            let (cat, val) = item
            if idx % 2 == 1 {
                let rowRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 20)
                alternateRowBgColor.setFill()
                UIRectFill(rowRect)
            }

            x = margin
            drawText(cat, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 16), attrs: cellAttrs, alignment: .left)
            x += colWidths[0]
            drawText("\(val.count) records", in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 16), attrs: cellAttrs, alignment: .left)
            x += colWidths[1]
            drawText("\(currency.rawValue) \(formatMoney(val.base))", in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 16), attrs: numAttrs, alignment: .right)
            x += colWidths[2]
            drawText("\(currency.rawValue) \(formatMoney(val.tax))", in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 16), attrs: numAttrs, alignment: .right)

            yOffset += 20
        }

        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4
        let boldNumAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: textColor
        ]
        let boldTextAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: textColor
        ]
        x = margin
        drawText("Total", in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 16), attrs: boldTextAttrs, alignment: .left)
        x += colWidths[0] + colWidths[1]
        drawText("\(currency.rawValue) \(formatMoney(totalBase))", in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 16), attrs: boldNumAttrs, alignment: .right)
        x += colWidths[2]
        drawText("\(currency.rawValue) \(formatMoney(totalTax))", in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 16), attrs: boldNumAttrs, alignment: .right)

        yOffset += 20
        drawHLine(y: yOffset, width: contentWidth)
    }

    private static func drawTaxTableHeader(contentWidth: CGFloat, yOffset: inout CGFloat) {
        let colWidths: [CGFloat] = [
            contentWidth * 0.09,
            contentWidth * 0.12,
            contentWidth * 0.12,
            contentWidth * 0.22,
            contentWidth * 0.10,
            contentWidth * 0.10,
            contentWidth * 0.07,
            contentWidth * 0.10,
            contentWidth * 0.08
        ]
        let headers = ["Date", "Account", "Category", "Description / Note", "Gross Amt", "Tax Base", "Rate", "Tax Amount", "Status"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: secondaryTextColor
        ]

        let headerRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: 18)
        tableHeaderBgColor.setFill()
        UIRectFill(headerRect)

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = (i >= 4 && i <= 7) ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 16), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 18
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4
    }

    private static func drawTaxRow(
        item: TaxItem,
        in state: LedgerState,
        contentWidth: CGFloat,
        rowHeight: CGFloat,
        isAlternate: Bool,
        yOffset: inout CGFloat
    ) {
        let colWidths: [CGFloat] = [
            contentWidth * 0.09,
            contentWidth * 0.12,
            contentWidth * 0.12,
            contentWidth * 0.22,
            contentWidth * 0.10,
            contentWidth * 0.10,
            contentWidth * 0.07,
            contentWidth * 0.10,
            contentWidth * 0.08
        ]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: secondaryTextColor
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: textColor
        ]

        if isAlternate {
            let rowRect = CGRect(x: margin, y: yOffset - 2, width: contentWidth, height: rowHeight)
            alternateRowBgColor.setFill()
            UIRectFill(rowRect)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: item.transaction.occurredAt)
        let rateStr = String(format: "%.1f%%", item.rate * 100)

        var x = margin
        drawText(dateStr, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 16), attrs: dateAttrs, alignment: .left)
        x += colWidths[0]
        drawText(item.accountName, in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 16), attrs: cellAttrs, alignment: .left)
        x += colWidths[1]
        drawText(item.categoryName, in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 16), attrs: cellAttrs, alignment: .left)
        x += colWidths[2]
        drawText(item.note.isEmpty ? "—" : item.note, in: CGRect(x: x, y: yOffset, width: colWidths[3], height: rowHeight), attrs: cellAttrs, alignment: .left)
        x += colWidths[3]
        drawText(formatMoney(item.grossAmount), in: CGRect(x: x, y: yOffset, width: colWidths[4], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[4]
        drawText(formatMoney(item.taxBase), in: CGRect(x: x, y: yOffset, width: colWidths[5], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[5]
        drawText(rateStr, in: CGRect(x: x, y: yOffset, width: colWidths[6], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[6]
        drawText(formatMoney(item.taxAmount), in: CGRect(x: x, y: yOffset, width: colWidths[7], height: 16), attrs: numAttrs, alignment: .right)
        x += colWidths[7]
        drawText(item.status, in: CGRect(x: x, y: yOffset, width: colWidths[8], height: 16), attrs: cellAttrs, alignment: .left)

        yOffset += rowHeight
    }

    // MARK: - Footer & Common Drawing

    private static func drawFooter(pageNumber: Int, totalWidth: CGFloat, totalHeight: CGFloat, disclaimer: String) {
        let footerY = totalHeight - margin - footerHeight
        let usableWidth = totalWidth - (margin * 2)

        drawHLine(y: footerY, width: usableWidth)

        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: secondaryTextColor
        ]
        "Finsy · Personal Bookkeeping Record".draw(at: CGPoint(x: margin, y: footerY + 4), withAttributes: metaAttrs)
        let pageStr = "Page \(pageNumber)"
        let pageSize = (pageStr as NSString).size(withAttributes: metaAttrs)
        pageStr.draw(at: CGPoint(x: totalWidth - margin - pageSize.width, y: footerY + 4), withAttributes: metaAttrs)

        let disclaimerParagraph = NSMutableParagraphStyle()
        disclaimerParagraph.alignment = .left
        disclaimerParagraph.lineBreakMode = .byWordWrapping
        let disclaimerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: secondaryTextColor,
            .paragraphStyle: disclaimerParagraph
        ]

        let disclaimerRect = CGRect(x: margin, y: footerY + 18, width: usableWidth, height: 26)
        disclaimer.draw(in: disclaimerRect, withAttributes: disclaimerAttrs)
    }

    private static func drawText(_ text: String, in rect: CGRect, attrs: [NSAttributedString.Key: Any], alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        var finalAttrs = attrs
        finalAttrs[.paragraphStyle] = style
        (text as NSString).draw(in: rect, withAttributes: finalAttrs)
    }

    private static func drawHLine(y: CGFloat, width: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: margin + width, y: y))
        ruleColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func formatMoney(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }
}
