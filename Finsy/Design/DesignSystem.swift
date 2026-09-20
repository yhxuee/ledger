import SwiftUI
import UIKit

enum LedgerPalette {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let coral = Color(hex: "F05E4F")
    static let blue = Color(hex: "36A7C9")
    static let amber = Color(hex: "F3A11F")
    static let purple = Color(hex: "B54AC6")
    static let teal = Color(hex: "62B28F")
    static let emerald = Color(hex: "2E7D32")

    static func category(_ id: LedgerCategoryID) -> Color {
        if id == .food { return coral }
        if id == .transport { return blue }
        if id == .shopping { return amber }
        if id == .utilities { return purple }
        return teal
    }

    static func primaryAction(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? amber : .blue
    }
}

struct CategoryIcon: View {
    let category: LedgerCategory
    var font: Font = .body

    var body: some View {
        Group {
            if let emoji = category.emoji { Text(emoji) }
            else { Image(systemName: category.symbol) }
        }
        .font(font)
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let r, g, b, a: UInt64
        switch clean.count {
        case 8: (r, g, b, a) = (value >> 24, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff)
        default: (r, g, b, a) = (value >> 16, value >> 8 & 0xff, value & 0xff, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    var rgbHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "8EC5FC" }
        return String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

/// Shared width budgets for the constrained money columns.
///
/// `LedgerAmountWidth.row` fits the widest row amount the compact formatter can produce
/// (`HKD 9999.99K`, 12 characters) on a single line without shrinking the text.
enum LedgerAmountWidth {
    static let row: CGFloat = 120
}

enum LedgerFormat {
    /// Normal monetary display: the currency symbol (`$100.00`, `£25.00`, `¥500.00`, `€20.00`).
    /// This is the formatter for every monetary amount except transaction-list rows.
    /// `compact` switches to the shared K / M / B / T formatter; `maxIntegerDigits` additionally
    /// caps the integer width for layouts that cannot grow (`HKD 9999.99K`).
    static func money(_ amount: Double, currency: CurrencyCode, compact: Bool = false, maxIntegerDigits: Int? = nil) -> String {
        if let maxIntegerDigits { return LedgerMoneyFormat.compactSymbol(amount, currency: currency, maxIntegerDigits: maxIntegerDigits) }
        return LedgerMoneyFormat.symbol(amount, currency: currency, compact: compact)
    }

    /// Transaction-list display: the canonical currency code (`HKD 100.00`, `+USD 25.00`).
    /// Reserved for Latest Transactions and the main Ledger transaction rows only.
    /// `maxIntegerDigits` is the width-constrained variant (`HKD 9999.99K`).
    static func transaction(_ amount: Double, currency: CurrencyCode, type: LedgerTransactionType, maxIntegerDigits: Int? = nil) -> String {
        if let maxIntegerDigits {
            return LedgerMoneyFormat.compactCode(amount, currency: currency, signPrefix: type == .income ? "+" : "", maxIntegerDigits: maxIntegerDigits)
        }
        return LedgerMoneyFormat.code(amount, currency: currency, signPrefix: type == .income ? "+" : "")
    }
}

struct LedgerBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                // Dark Mode: flat system background, no pastel RGB overlays.
                Color(uiColor: .systemBackground)
            } else {
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemGroupedBackground),
                        Color(hex: "F5ECE8").opacity(0.45),
                        Color(hex: "E8F2F5").opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct MetricCard<Content: View>: View {
    let title: String
    var compact: Bool = false
    var layout: OverviewMetricLayout? = nil
    let content: Content

    init(_ title: String, compact: Bool = false, layout: OverviewMetricLayout? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.compact = compact
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        let isSideColumn = (layout == .portraitSideColumn || compact)
        VStack(alignment: .leading, spacing: isSideColumn ? 6 : 8) {
            Text(LocalizedStringKey(title))
                .textCase(.uppercase)
                .font((isSideColumn ? Font.caption2 : .caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.7)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(isSideColumn ? 12 : 18)
        .frame(
            maxWidth: .infinity,
            minHeight: isSideColumn ? nil : 146,
            maxHeight: isSideColumn ? .infinity : 146,
            alignment: .topLeading
        )
        .ledgerGlass(in: RoundedRectangle(cornerRadius: isSideColumn ? 20 : 24, style: .continuous))
    }
}

