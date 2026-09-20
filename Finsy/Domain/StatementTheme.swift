import UIKit

enum StatementTheme {
    static let defaultHex = "3A78C2"

    /// Preserves user-chosen hue while enforcing high print contrast against white paper.
    static func printAccent(from hex: String) -> UIColor {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let r, g, b: CGFloat
        switch clean.count {
        case 8:
            r = CGFloat((value >> 16) & 0xff) / 255.0
            g = CGFloat((value >> 8) & 0xff) / 255.0
            b = CGFloat(value & 0xff) / 255.0
        case 6:
            r = CGFloat((value >> 16) & 0xff) / 255.0
            g = CGFloat((value >> 8) & 0xff) / 255.0
            b = CGFloat(value & 0xff) / 255.0
        default:
            return UIColor(red: 0.23, green: 0.47, blue: 0.76, alpha: 1.0)
        }

        let baseColor = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        guard baseColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else {
            return baseColor
        }

        // Relative luminance: 0.2126*R + 0.7152*G + 0.0722*B
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        var safeBri = bri
        var safeSat = sat
        if lum > 0.45 {
            safeBri = min(bri, 0.58)
            if safeSat < 0.35 && lum > 0.85 {
                safeSat = 0.20
                safeBri = 0.35
            } else {
                safeSat = max(sat, 0.50)
            }
        }

        return UIColor(hue: hue, saturation: safeSat, brightness: safeBri, alpha: 1.0)
    }
}

