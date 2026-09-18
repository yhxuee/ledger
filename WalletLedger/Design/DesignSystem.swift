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

    static func category(_ id: LedgerCategoryID) -> Color {
        switch id { case .food: coral; case .transport: blue; case .shopping: amber; case .utilities: purple; case .other: teal }
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

enum LedgerFormat {
    static func money(_ amount: Double, currency: CurrencyCode, compact: Bool = false) -> String {
        if compact && abs(amount) >= 1_000 {
            let value = amount / 1_000
            return "\(currency.symbol)\(currency.symbol.count > 1 ? " " : "")\(value.formatted(.number.precision(.fractionLength(abs(value) >= 10 ? 0 : 1))))k"
        }
        return "\(currency.symbol)\(currency.symbol.count > 1 ? " " : "")\(amount.formatted(.number.precision(.fractionLength(2))))"
    }

    static func transaction(_ amount: Double, currency: CurrencyCode, type: LedgerTransactionType) -> String {
        let sign = type == .expense || type == .transfer ? "−" : "+"
        return "\(sign)\(currency.rawValue) \(amount.formatted(.number.precision(.fractionLength(2))))"
    }
}

struct LedgerBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(uiColor: .systemGroupedBackground), Color(hex: "F5ECE8").opacity(0.45), Color(hex: "E8F2F5").opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct MetricCard<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.7)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
