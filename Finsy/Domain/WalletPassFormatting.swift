import Foundation

enum WalletPassFormatting {
    static func money(_ amount: Double, currency: CurrencyCode, space: Bool = false) -> String {
        let prefixes = ["HKD": "HK$", "USD": "US$", "CAD": "CA$", "AUD": "A$", "NZD": "NZ$", "SGD": "S$", "CNY": "CN¥", "JPY": "JP¥"]
        let prefix = prefixes[currency.rawValue] ?? currency.symbol
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let value = formatter.string(from: NSNumber(value: abs(amount))) ?? "0.00"
        return "\(amount < 0 ? "-" : "")\(prefix)\(space ? " " : "")\(value)"
    }

    static func date(_ date: Date, format: AppDateFormat, monthOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = monthOnly ? (format == .monthDay ? "MMM yyyy" : "yyyy MMM") : (format == .monthDay ? "MM/dd/yyyy" : "dd/MM/yyyy")
        return formatter.string(from: date).uppercased()
    }
}
