import SwiftUI

/// Custom shape representing a physical receipt or ticket with repeated triangular
/// tear/serration notches along the top and bottom edges and clean, straight vertical sides.
struct SerratedTicketShape: Shape {
    var toothWidth: CGFloat = 12
    var toothDepth: CGFloat = 6

    init(toothWidth: CGFloat = 12, toothDepth: CGFloat = 6) {
        self.toothWidth = toothWidth
        self.toothDepth = toothDepth
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let count = max(2, Int((rect.width / toothWidth).rounded(.down)))
        let actualToothWidth = rect.width / CGFloat(count)

        // Top edge: starts at top-left tooth trough, peaks at minY, troughs at minY + toothDepth
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + toothDepth))
        for i in 0..<count {
            let startX = rect.minX + CGFloat(i) * actualToothWidth
            let midX = startX + actualToothWidth / 2
            let endX = startX + actualToothWidth
            path.addLine(to: CGPoint(x: midX, y: rect.minY))
            path.addLine(to: CGPoint(x: endX, y: rect.minY + toothDepth))
        }

        // Right edge: clean straight vertical line to bottom tooth trough
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - toothDepth))

        // Bottom edge: moves from right to left, peaks downward at maxY, troughs at maxY - toothDepth
        for i in 0..<count {
            let startX = rect.maxX - CGFloat(i) * actualToothWidth
            let midX = startX - actualToothWidth / 2
            let endX = startX - actualToothWidth
            path.addLine(to: CGPoint(x: midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: endX, y: rect.maxY - toothDepth))
        }

        // Left edge: clean straight vertical line back up to top-left tooth trough
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + toothDepth))
        path.closeSubpath()

        return path
    }
}

/// A subtle perforated/dashed line separator for ticket sections.
private struct PerforatedDivider: View {
    var body: some View {
        DividerLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(height: 1)
            .foregroundStyle(Color.secondary.opacity(0.3))
    }

    private struct DividerLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// A physical receipt/event-ticket styled summary card for purchase sessions.
/// Features top and bottom triangular tear notches, paper surface styling,
/// clean receipt typography, and detailed itemized items.
struct PurchaseWalletTicketCard: View {
    let session: PurchaseSession
    let categoryResolver: (LedgerCategoryID) -> String
    let totalTax: Double
    let baseCurrency: CurrencyCode?
    let baseCurrencyEquivalent: Double?

    @Environment(\.colorScheme) private var colorScheme

    init(
        session: PurchaseSession,
        categoryResolver: @escaping (LedgerCategoryID) -> String,
        totalTax: Double,
        baseCurrency: CurrencyCode? = nil,
        baseCurrencyEquivalent: Double? = nil
    ) {
        self.session = session
        self.categoryResolver = categoryResolver
        self.totalTax = totalTax
        self.baseCurrency = baseCurrency
        self.baseCurrencyEquivalent = baseCurrencyEquivalent
    }

    private var formattedDate: String {
        let date = session.completedAt ?? session.createdAt
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Header: Receipt Badge & Session Title
            VStack(spacing: 6) {
                HStack {
                    Text("FINSY RECEIPT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(1.5)
                    Spacer()
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(session.name.isEmpty ? String(localized: "Purchase Session") : session.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }

                HStack {
                    Text(formattedDate)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            PerforatedDivider()

            // Itemized list
            let orderedItems = session.orderedItems
            VStack(spacing: 10) {
                ForEach(orderedItems) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            let title = item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? categoryResolver(item.categoryID)
                                : item.note
                            Text(title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(categoryResolver(item.categoryID))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SensitiveMoneyText(
                            amount: item.amount,
                            currency: session.currency,
                            maxIntegerDigits: 4
                        )
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    }
                }
            }

            PerforatedDivider()

            // Financial Summary: Total & Tax
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TOTAL")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    SensitiveMoneyText(
                        amount: session.plannedAmount,
                        currency: session.currency,
                        maxIntegerDigits: 4
                    )
                    .font(.headline.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                }

                if let converted = baseCurrencyEquivalent, let base = baseCurrency {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("≈")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SensitiveMoneyText(
                            amount: converted,
                            currency: base,
                            maxIntegerDigits: 4
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("TAX")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    SensitiveMoneyText(
                        amount: totalTax,
                        currency: session.currency,
                        maxIntegerDigits: 4
                    )
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .background(
            SerratedTicketShape(toothWidth: 14, toothDepth: 7)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        )
        .overlay(
            SerratedTicketShape(toothWidth: 14, toothDepth: 7)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
