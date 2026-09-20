import UIKit

extension StatementPDFGenerator {
    static func generateTaxStatement(
        monthDate: Date,
        accounts: [LedgerAccount],
        allAccountsSelected: Bool = false,
        themeColorHex: String = StatementTheme.defaultHex,
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
        let accentColor = StatementTheme.printAccent(from: themeColorHex)

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
                    title: "FINSY TAX STATEMENT",
                    periodString: periodString,
                    baseCurrency: targetCurrency,
                    accountPrimaryCurrency: nil,
                    accountsText: accountsText,
                    date: now,
                    pageWidth: landscapeWidth,
                    accentColor: accentColor,
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
            drawTaxTableHeader(accentColor: accentColor, contentWidth: contentWidth, yOffset: &yOffset)

            for (idx, item) in taxItems.enumerated() {
                let note = item.note
                let estimatedRowHeight: CGFloat = note.count > 35 ? 28 : 20
                if yOffset + estimatedRowHeight > landscapeHeight - margin - footerHeight {
                    startNewPage()
                    drawSectionTitle("Tax-Recognized Records (Continued)", yOffset: &yOffset)
                    drawTaxTableHeader(accentColor: accentColor, contentWidth: contentWidth, yOffset: &yOffset)
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

    private static func drawTaxTableHeader(accentColor: UIColor, contentWidth: CGFloat, yOffset: inout CGFloat) {
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
        accentColor.withAlphaComponent(0.6).setFill()
        UIRectFill(CGRect(x: margin, y: yOffset, width: contentWidth, height: 0.75))
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


}
