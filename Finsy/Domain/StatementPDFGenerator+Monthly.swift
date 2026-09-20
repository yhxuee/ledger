import UIKit

extension StatementPDFGenerator {
    static func generateMonthlyStatement(
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

        // Special Mode: Exactly one account selected and that account uses currency pockets
        if safeAccounts.count == 1, safeAccounts[0].usesCurrencyPockets {
            return try generateSingleMultiCurrencyStatement(
                account: safeAccounts[0],
                startOfMonth: startOfMonth,
                cutoffEnd: cutoffEnd,
                periodString: periodString,
                themeColorHex: themeColorHex,
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
            themeColorHex: themeColorHex,
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
        themeColorHex: String,
        in state: LedgerState,
        now: Date
    ) throws -> URL {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let accentColor = StatementTheme.printAccent(from: themeColorHex)
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
        // Date (12%), Account (15%), Category (13%), Description (27%), CURR (6%), FX Rate (10%), Amount (17%)
        let colWidths: [CGFloat] = [
            contentWidth * 0.12, // Date (~63pt)
            contentWidth * 0.15, // Account (~78pt)
            contentWidth * 0.13, // Category (~68pt)
            contentWidth * 0.27, // Description (~141pt)
            contentWidth * 0.06, // CURR (~31pt)
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
                    accentColor: accentColor,
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
            drawGeneralTransactionTableHeader(baseCurrency: baseCurrency, accentColor: accentColor, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)

            for (idx, posting) in postings.enumerated() {
                let descHeight = measureDescriptionHeight(text: posting.userDescription, width: colWidths[3] - 6)
                let estimatedRowHeight = max(19.0, descHeight + 7.0)

                if yOffset + estimatedRowHeight > portraitHeight - margin - footerHeight {
                    startNewPage()
                    drawSectionTitle("Transaction Records (Continued)", yOffset: &yOffset)
                    drawGeneralTransactionTableHeader(baseCurrency: baseCurrency, accentColor: accentColor, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)
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
                accentColor: accentColor,
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
        themeColorHex: String,
        in state: LedgerState,
        now: Date
    ) throws -> URL {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let accentColor = StatementTheme.printAccent(from: themeColorHex)
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
        // Date (14%), Category (20%), Description (36%), CURR (8%), Amount (22%)
        let colWidths: [CGFloat] = [
            contentWidth * 0.14, // Date (~73pt)
            contentWidth * 0.20, // Category (~105pt)
            contentWidth * 0.36, // Description (~189pt)
            contentWidth * 0.08, // CURR (~42pt)
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
                    accentColor: accentColor,
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
                    drawMultiCurrencyTransactionTableHeader(pocketCurrency: pocketCurrency, accentColor: accentColor, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)

                    for (idx, posting) in pocketPostings.enumerated() {
                        let descHeight = measureDescriptionHeight(text: posting.userDescription, width: colWidths[2] - 6)
                        let estimatedRowHeight = max(19.0, descHeight + 7.0)

                        if yOffset + estimatedRowHeight > portraitHeight - margin - footerHeight {
                            startNewPage()
                            drawSectionTitle("\(pocketCurrency.rawValue) Pocket (Continued)", yOffset: &yOffset)
                            drawMultiCurrencyTransactionTableHeader(pocketCurrency: pocketCurrency, accentColor: accentColor, contentWidth: contentWidth, colWidths: colWidths, yOffset: &yOffset)
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
                accentColor: accentColor,
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
        accentColor: UIColor,
        contentWidth: CGFloat,
        colWidths: [CGFloat],
        yOffset: inout CGFloat
    ) {
        let headers = ["DATE", "ACCOUNT", "CATEGORY", "DESCRIPTION", "CURR", "FX RATE", "AMOUNT \(baseCurrency.rawValue)"]
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
        accentColor.withAlphaComponent(0.6).setFill()
        UIRectFill(CGRect(x: margin, y: yOffset, width: contentWidth, height: 0.75))
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
        accentColor: UIColor,
        contentWidth: CGFloat,
        colWidths: [CGFloat],
        yOffset: inout CGFloat
    ) {
        let headers = ["DATE", "CATEGORY", "DESCRIPTION", "CURR", "AMOUNT \(pocketCurrency.rawValue)"]
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
        accentColor.withAlphaComponent(0.6).setFill()
        UIRectFill(CGRect(x: margin, y: yOffset, width: contentWidth, height: 0.75))
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
        accentColor: UIColor,
        state: LedgerState,
        now: Date
    ) {
        let calendar = Calendar.current
        let baseCurrency = state.settings.baseCurrency
        let (summary, windows) = ThreeMonthFinancialEngine.calculate(for: startOfMonth, in: state, baseCurrency: baseCurrency, now: now)

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
        // Accent rule
        accentColor.setFill()
        UIRectFill(CGRect(x: margin, y: yOffset, width: pageWidth - (margin * 2), height: 1.0))
        yOffset += 24

        let metrics: [(title: String, amount: Double)] = [
            ("Average Net Worth", summary.averageNetWorth),
            ("Average Monthly Income", summary.averageIncome),
            ("Average Monthly Spending", summary.averageSpending),
            ("Average Monthly Turnover", summary.averageTurnover)
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
            accentColor.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.8
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
        • Average Net Worth is based on month-end asset values minus liabilities across active accounts.
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


}
