import UIKit

extension StatementPDFGenerator {
    // MARK: - Calculation Helpers

    private static func calculateBalance(account: LedgerAccount, upTo cutoff: Date, in state: LedgerState) -> Double {
        ThreeMonthFinancialEngine.calculateBalance(account: account, upTo: cutoff, in: state, includeCutoff: false)
    }

    private static func calculatePocketBalance(pocket: CurrencyCode, account: LedgerAccount, upTo cutoff: Date, in state: LedgerState) -> Double {
        ThreeMonthFinancialEngine.calculatePocketBalance(pocket: pocket, account: account, upTo: cutoff, in: state, includeCutoff: false)
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
        accentColor: UIColor,
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

        // Accent title rule
        accentColor.setFill()
        UIRectFill(CGRect(x: margin, y: yOffset, width: pageWidth - (margin * 2), height: 1.0))
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
