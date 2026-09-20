import UIKit

enum StatementType: String, CaseIterable, Identifiable, Sendable {
    case monthly = "Monthly Statement"
    case tax = "Tax Statement"

    var id: String { rawValue }
}

enum StatementPDFGenerator {
    // Standard A4 dimensions in points (72 pt/inch)
    static let pageWidth: CGFloat = 595.2
    static let pageHeight: CGFloat = 841.8
    static let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    static let margin: CGFloat = 36
    static let contentWidth: CGFloat = pageWidth - (margin * 2)
    static let footerHeight: CGFloat = 46

    private static let mandatoryDisclaimer = "Disclaimer: Finsy is a personal bookkeeping tool and is NOT a bank, financial institution, or licensed tax advisor. This statement is generated solely from user-entered records for informational and personal budgeting purposes only."

    struct AccountMonthlySummary: Sendable {
        let account: LedgerAccount
        let openingBalance: Double
        let totalInflow: Double
        let totalOutflow: Double
        let closingBalance: Double
    }

    struct TaxItem: Sendable {
        let transaction: LedgerTransaction
        let categoryName: String
        let taxAmount: Double
        let taxBase: Double
        let rate: Double
    }

    // MARK: - Entry Points

    static func generateMonthlyStatement(monthDate: Date, accounts: [LedgerAccount], in state: LedgerState) throws -> URL {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)),
              let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1, hour: 23, minute: 59, second: 59), to: startOfMonth) else {
            throw StatementError.invalidDateRange
        }

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        let monthString = monthFormatter.string(from: startOfMonth)

        let safeAccounts = accounts.filter { $0.deletedAt == nil }
        let accountIDs = Set(safeAccounts.map(\.id))

        // Collect transactions for this month
        let allTransactions = state.transactions.filter {
            $0.deletedAt == nil &&
            $0.occurredAt >= startOfMonth &&
            $0.occurredAt <= endOfMonth &&
            (accountIDs.contains($0.accountID) || ($0.destinationAccountID != nil && accountIDs.contains($0.destinationAccountID!))) &&
            TransactionSemantics.posts($0)
        }.sorted { $0.occurredAt < $1.occurredAt }

        var summaries: [AccountMonthlySummary] = []
        for account in safeAccounts {
            let opening = calculateBalance(account: account, upTo: startOfMonth, in: state)
            var inflow: Double = 0
            var outflow: Double = 0

            for t in allTransactions {
                if t.accountID == account.id {
                    let amount = LedgerCalculations.sourcePosting(t, for: account, in: state)
                    switch t.type {
                    case .expense:
                        outflow += amount
                    case .income:
                        inflow += amount
                    case .transfer:
                        outflow += amount
                    }
                }
                if t.destinationAccountID == account.id && t.type == .transfer {
                    let amount = LedgerCalculations.destinationPosting(t, for: account, in: state)
                    inflow += amount
                }
            }
            let closing = opening + inflow - outflow
            summaries.append(AccountMonthlySummary(
                account: account,
                openingBalance: opening,
                totalInflow: inflow,
                totalOutflow: outflow,
                closingBalance: closing
            ))
        }

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            var pageIndex = 1
            var yOffset: CGFloat = margin

            func startNewPage() {
                if pageIndex > 1 {
                    drawFooter(pageNumber: pageIndex - 1)
                }
                context.beginPage()
                yOffset = margin
                drawHeader(title: "FINSY MONTHLY STATEMENT", subtitle: "Period: \(monthString)", date: Date.now, accounts: safeAccounts, yOffset: &yOffset)
                pageIndex += 1
            }

            startNewPage()

            // 1. Account Summary Section
            drawSectionTitle("Account Summary", yOffset: &yOffset)
            drawAccountSummaryTable(summaries: summaries, yOffset: &yOffset)

            yOffset += 16

            // 2. Transaction Detail Section
            drawSectionTitle("Transaction Records (\(allTransactions.count))", yOffset: &yOffset)
            drawTransactionTableHeader(yOffset: &yOffset)

            for transaction in allTransactions {
                // If row doesn't fit on this page, start new page
                if yOffset + 24 > pageHeight - margin - footerHeight {
                    startNewPage()
                    drawSectionTitle("Transaction Records (Continued)", yOffset: &yOffset)
                    drawTransactionTableHeader(yOffset: &yOffset)
                }
                drawTransactionRow(transaction: transaction, in: state, yOffset: &yOffset)
            }

            drawFooter(pageNumber: pageIndex - 1)
        }

        let filename = "Finsy_Monthly_Statement_\(calendar.component(.year, from: startOfMonth))_\(calendar.component(.month, from: startOfMonth)).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try pdfData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    static func generateTaxStatement(monthDate: Date, accounts: [LedgerAccount], in state: LedgerState) throws -> URL {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)),
              let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1, hour: 23, minute: 59, second: 59), to: startOfMonth) else {
            throw StatementError.invalidDateRange
        }

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        let monthString = monthFormatter.string(from: startOfMonth)

        let safeAccounts = accounts.filter { $0.deletedAt == nil }
        let accountIDs = Set(safeAccounts.map(\.id))
        let targetCurrency = state.settings.baseCurrency

        // Collect tax transactions using TransactionSemantics.taxEffect
        var taxItems: [TaxItem] = []
        var categoryTotals: [String: (base: Double, tax: Double)] = [:]

        let candidateTransactions = state.transactions.filter {
            $0.deletedAt == nil &&
            $0.occurredAt >= startOfMonth &&
            $0.occurredAt <= endOfMonth &&
            accountIDs.contains($0.accountID)
        }.sorted { $0.occurredAt < $1.occurredAt }

        for t in candidateTransactions {
            if let effect = TransactionSemantics.taxEffect(t, in: state, to: targetCurrency) {
                let cat = state.categories.first { $0.id == effect.categoryID }?.name ?? "General"
                let base = t.taxBaseAmount ?? (t.amount - (t.taxAmount ?? 0))
                let rate = t.taxRate ?? state.settings.taxRate(for: state.categories.first { $0.id == effect.categoryID } ?? SeedData.expenseCategories[0])
                taxItems.append(TaxItem(transaction: t, categoryName: cat, taxAmount: effect.amount, taxBase: base, rate: rate))

                var current = categoryTotals[cat] ?? (0, 0)
                current.base += base
                current.tax += effect.amount
                categoryTotals[cat] = current
            }
        }

        let totalBase = taxItems.reduce(0.0) { $0 + $1.taxBase }
        let totalTax = taxItems.reduce(0.0) { $0 + $1.taxAmount }

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            var pageIndex = 1
            var yOffset: CGFloat = margin

            func startNewPage() {
                if pageIndex > 1 {
                    drawFooter(pageNumber: pageIndex - 1)
                }
                context.beginPage()
                yOffset = margin
                drawHeader(title: "FINSY MONTHLY TAX STATEMENT", subtitle: "Period: \(monthString) · Currency: \(targetCurrency.rawValue)", date: Date.now, accounts: safeAccounts, yOffset: &yOffset)
                pageIndex += 1
            }

            startNewPage()

            // 1. Tax Summary by Category
            drawSectionTitle("Tax Summary by Category", yOffset: &yOffset)
            drawTaxCategorySummaryTable(categoryTotals: categoryTotals, totalBase: totalBase, totalTax: totalTax, currency: targetCurrency, yOffset: &yOffset)

            yOffset += 16

            // 2. Tax Transactions
            drawSectionTitle("Tax-Recognized Records (\(taxItems.count))", yOffset: &yOffset)
            drawTaxTableHeader(yOffset: &yOffset)

            for item in taxItems {
                if yOffset + 24 > pageHeight - margin - footerHeight {
                    startNewPage()
                    drawSectionTitle("Tax-Recognized Records (Continued)", yOffset: &yOffset)
                    drawTaxTableHeader(yOffset: &yOffset)
                }
                drawTaxRow(item: item, in: state, yOffset: &yOffset)
            }

            drawFooter(pageNumber: pageIndex - 1)
        }

        let filename = "Finsy_Tax_Statement_\(calendar.component(.year, from: startOfMonth))_\(calendar.component(.month, from: startOfMonth)).pdf"
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

    // MARK: - Drawing Components

    private static func drawHeader(title: String, subtitle: String, date: Date, accounts: [LedgerAccount], yOffset: inout CGFloat) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel
        ]

        title.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: titleAttrs)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateStr = "Generated: \(dateFormatter.string(from: date))"
        let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)
        dateStr.draw(at: CGPoint(x: pageWidth - margin - dateSize.width, y: yOffset + 4), withAttributes: dateAttrs)

        yOffset += 22
        subtitle.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: subAttrs)

        let accountNames = accounts.map(\.name).joined(separator: ", ")
        let accStr = "Accounts (\(accounts.count)): \(accountNames)"
        let accSize = (accStr as NSString).size(withAttributes: dateAttrs)
        accStr.draw(at: CGPoint(x: pageWidth - margin - min(accSize.width, 240), y: yOffset), withAttributes: dateAttrs)

        yOffset += 18

        // Divider
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: yOffset))
        path.addLine(to: CGPoint(x: pageWidth - margin, y: yOffset))
        UIColor.separator.setStroke()
        path.lineWidth = 1
        path.stroke()

        yOffset += 12
    }

    private static func drawSectionTitle(_ title: String, yOffset: inout CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        title.draw(at: CGPoint(x: margin, y: yOffset), withAttributes: attrs)
        yOffset += 16
    }

    private static func drawAccountSummaryTable(summaries: [AccountMonthlySummary], yOffset: inout CGFloat) {
        // Headers
        let colWidths: [CGFloat] = [130, 60, 80, 80, 80, 93]
        let headers = ["Account", "Currency", "Opening", "Inflow (+)", "Outflow (-)", "Closing"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.label
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.label
        ]

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = i >= 2 ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 14), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 16

        // Divider
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4

        for item in summaries {
            let acc = item.account
            let open = item.openingBalance
            let inf = item.totalInflow
            let outf = item.totalOutflow
            let close = item.closingBalance

            x = margin
            drawText(acc.name, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 14), attrs: cellAttrs, alignment: .left)
            x += colWidths[0]
            drawText(acc.currency.rawValue, in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 14), attrs: cellAttrs, alignment: .left)
            x += colWidths[1]
            drawText(formatMoney(open), in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 14), attrs: numAttrs, alignment: .right)
            x += colWidths[2]
            drawText(formatMoney(inf), in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 14), attrs: numAttrs, alignment: .right)
            x += colWidths[3]
            drawText(formatMoney(outf), in: CGRect(x: x, y: yOffset, width: colWidths[4], height: 14), attrs: numAttrs, alignment: .right)
            x += colWidths[4]
            drawText(formatMoney(close), in: CGRect(x: x, y: yOffset, width: colWidths[5], height: 14), attrs: numAttrs, alignment: .right)

            yOffset += 16
        }
        drawHLine(y: yOffset, width: contentWidth)
    }

    private static func drawTransactionTableHeader(yOffset: inout CGFloat) {
        let colWidths: [CGFloat] = [70, 95, 85, 173, 100]
        let headers = ["Date", "Account", "Category", "Description / Note", "Amount"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: UIColor.secondaryLabel
        ]

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = i == 4 ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 14), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 16
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4
    }

    private static func drawTransactionRow(transaction: LedgerTransaction, in state: LedgerState, yOffset: inout CGFloat) {
        let colWidths: [CGFloat] = [70, 95, 85, 173, 100]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.label
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: transaction.type == .income ? UIColor.systemGreen : UIColor.label
        ]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: transaction.occurredAt)
        let accName = state.accounts.first { $0.id == transaction.accountID }?.name ?? "Account"
        let catName = state.categories.first { $0.id == transaction.categoryID }?.name ?? "General"
        let desc = transaction.note ?? (transaction.type == .transfer ? "Transfer" : catName)
        let prefix = transaction.type == .income ? "+" : (transaction.type == .expense ? "-" : "")
        let amtStr = "\(prefix)\(transaction.currency.rawValue) \(formatMoney(transaction.amount))"

        var x = margin
        drawText(dateStr, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 14), attrs: dateAttrs, alignment: .left)
        x += colWidths[0]
        drawText(accName, in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[1]
        drawText(catName, in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[2]
        drawText(desc, in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[3]
        drawText(amtStr, in: CGRect(x: x, y: yOffset, width: colWidths[4], height: 14), attrs: numAttrs, alignment: .right)

        yOffset += 16
    }

    private static func drawTaxCategorySummaryTable(categoryTotals: [String: (base: Double, tax: Double)], totalBase: Double, totalTax: Double, currency: CurrencyCode, yOffset: inout CGFloat) {
        let colWidths: [CGFloat] = [170, 110, 110, 133]
        let headers = ["Category", "Tax Base Amount", "Tax Amount Recognized", "Effective Ratio"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.label
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.label
        ]

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = i >= 1 ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 14), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 16
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4

        for (cat, val) in categoryTotals.sorted(by: { $0.key < $1.key }) {
            let ratio = val.base > 0 ? (val.tax / val.base * 100) : 0
            x = margin
            drawText(cat, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 14), attrs: cellAttrs, alignment: .left)
            x += colWidths[0]
            drawText("\(currency.rawValue) \(formatMoney(val.base))", in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 14), attrs: numAttrs, alignment: .right)
            x += colWidths[1]
            drawText("\(currency.rawValue) \(formatMoney(val.tax))", in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 14), attrs: numAttrs, alignment: .right)
            x += colWidths[2]
            drawText(String(format: "%.1f%%", ratio), in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 14), attrs: numAttrs, alignment: .right)
            yOffset += 16
        }

        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4

        // Total Row
        x = margin
        let boldAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        drawText("Total", in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 14), attrs: boldAttrs, alignment: .left)
        x += colWidths[0]
        drawText("\(currency.rawValue) \(formatMoney(totalBase))", in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 14), attrs: boldAttrs, alignment: .right)
        x += colWidths[1]
        drawText("\(currency.rawValue) \(formatMoney(totalTax))", in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 14), attrs: boldAttrs, alignment: .right)
        x += colWidths[2]
        let totalRatio = totalBase > 0 ? (totalTax / totalBase * 100) : 0
        drawText(String(format: "%.1f%%", totalRatio), in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 14), attrs: boldAttrs, alignment: .right)
        yOffset += 16
        drawHLine(y: yOffset, width: contentWidth)
    }

    private static func drawTaxTableHeader(yOffset: inout CGFloat) {
        let colWidths: [CGFloat] = [70, 85, 80, 148, 70, 70]
        let headers = ["Date", "Account", "Category", "Note", "Tax Base", "Tax Amount"]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: UIColor.secondaryLabel
        ]

        var x = margin
        for (i, h) in headers.enumerated() {
            let alignment: NSTextAlignment = i >= 4 ? .right : .left
            drawText(h, in: CGRect(x: x, y: yOffset, width: colWidths[i], height: 14), attrs: headerAttrs, alignment: alignment)
            x += colWidths[i]
        }
        yOffset += 16
        drawHLine(y: yOffset, width: contentWidth)
        yOffset += 4
    }

    private static func drawTaxRow(item: TaxItem, in state: LedgerState, yOffset: inout CGFloat) {
        let t = item.transaction
        let catName = item.categoryName
        let taxAmt = item.taxAmount
        let taxBase = item.taxBase

        let colWidths: [CGFloat] = [70, 85, 80, 148, 70, 70]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.label
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.label
        ]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: t.occurredAt)
        let accName = state.accounts.first { $0.id == t.accountID }?.name ?? "Account"
        let desc = t.note ?? catName

        var x = margin
        drawText(dateStr, in: CGRect(x: x, y: yOffset, width: colWidths[0], height: 14), attrs: dateAttrs, alignment: .left)
        x += colWidths[0]
        drawText(accName, in: CGRect(x: x, y: yOffset, width: colWidths[1], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[1]
        drawText(catName, in: CGRect(x: x, y: yOffset, width: colWidths[2], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[2]
        drawText(desc, in: CGRect(x: x, y: yOffset, width: colWidths[3], height: 14), attrs: cellAttrs, alignment: .left)
        x += colWidths[3]
        drawText(formatMoney(taxBase), in: CGRect(x: x, y: yOffset, width: colWidths[4], height: 14), attrs: numAttrs, alignment: .right)
        x += colWidths[4]
        drawText(formatMoney(taxAmt), in: CGRect(x: x, y: yOffset, width: colWidths[5], height: 14), attrs: numAttrs, alignment: .right)

        yOffset += 16
    }

    private static func drawFooter(pageNumber: Int) {
        let footerY = pageHeight - margin - footerHeight

        // Top line for footer
        drawHLine(y: footerY, width: contentWidth)

        // Left note & Page number
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel
        ]
        "Finsy · Personal Bookkeeping Record".draw(at: CGPoint(x: margin, y: footerY + 4), withAttributes: metaAttrs)
        let pageStr = "Page \(pageNumber)"
        let pageSize = (pageStr as NSString).size(withAttributes: metaAttrs)
        pageStr.draw(at: CGPoint(x: pageWidth - margin - pageSize.width, y: footerY + 4), withAttributes: metaAttrs)

        // Mandatory Disclaimer on EVERY page
        let disclaimerParagraph = NSMutableParagraphStyle()
        disclaimerParagraph.alignment = .left
        disclaimerParagraph.lineBreakMode = .byWordWrapping
        let disclaimerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 6.5, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel,
            .paragraphStyle: disclaimerParagraph
        ]

        let disclaimerRect = CGRect(x: margin, y: footerY + 16, width: contentWidth, height: 28)
        mandatoryDisclaimer.draw(in: disclaimerRect, withAttributes: disclaimerAttrs)
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
        UIColor.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func formatMoney(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }
}

enum StatementError: LocalizedError {
    case invalidDateRange
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .invalidDateRange: "Invalid date range for monthly statement."
        case .generationFailed: "Failed to render PDF document."
        }
    }
}
