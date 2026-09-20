import Foundation
import SwiftUI

/// Widget-safe accent palette for Purchase Live Activities.
///
/// The app target's `LedgerPalette` is UIKit-backed and cannot be used from the widget
/// extension, so Purchase Mode uses these shared constants in both processes. The colors
/// mirror the app accent values (`#F05E4F` coral, `#62B28F` teal, `#36A7C9` blue).
enum PurchaseActivityPalette {
    /// Active shopping accent.
    static let accentHex = "F05E4F"
    /// Completed / success accent.
    static let successHex = "62B28F"
    /// Secondary progress accent.
    static let infoHex = "36A7C9"

    static let accent = color(hex: accentHex)
    static let success = color(hex: successHex)
    static let info = color(hex: infoHex)

    /// Dark neutral surface for the Lock Screen presentation (never pure black).
    static let surface = color(hex: "14181C")
    static let onSurface = Color.white
    static let secondaryText = Color.white.opacity(0.7)
    /// Unfilled progress track inside a dark system surface.
    static let track = Color.white.opacity(0.22)

    /// Coral while shopping, teal once every item is complete.
    static func progressTint(completed: Bool) -> Color { completed ? success : accent }

    /// Category identification color for a completed/next item indicator.
    static func categoryColor(hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return accent }
        return color(hex: hex)
    }

    static func color(hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
