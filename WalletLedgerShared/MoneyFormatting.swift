import Foundation

/// Central monetary display rules shared by the app and the widget extension.
///
/// Exactly two display semantics exist and must never be mixed:
/// - `symbol(_:currency:compact:)` is the normal money display (`$1,234.00`, `£25.00`, `¥1,234`).
/// - `code(_:currency:signPrefix:)` is reserved for transaction-list rows (`HKD 1,234.00`, `+USD 25.00`).
///
/// Currency identifiers that are persisted, selected or shown as metadata continue to use
/// `CurrencyCode.rawValue` and never `$`, `£` or `¥`.
enum LedgerMoneyFormat {
    /// Normal monetary display: the currency's symbol, then the decimal amount.
    /// Amounts are never prefixed with the canonical currency code, so a HKD 100 amount
    /// renders as `$100.00` and a USDT 100 amount also renders as `$100.00`.
    static func symbol(_ amount: Double, currency: CurrencyCode, compact: Bool = false) -> String {
        let magnitude = abs(amount)
        guard magnitude.isFinite else { return "\(displayPrefix(currency))0" }
        let sign = amount < 0 ? "-" : ""
        if compact, magnitude >= 1_000 {
            let value = magnitude / 1_000
            // Keeps a single decimal only when it is meaningful: 12.5k, 120k, 15k.
            return "\(sign)\(displayPrefix(currency))\(value.formatted(.number.precision(.fractionLength(0...1))))k"
        }
        return "\(sign)\(displayPrefix(currency))\(magnitude.formatted(.number.precision(.fractionLength(2))))"
    }

    /// A currency without a distinct symbol falls back to its own code, which needs a separator
    /// (`CHF 1,000.00`) instead of being glued to the amount (`CHF1,000.00`).
    private static func displayPrefix(_ currency: CurrencyCode) -> String {
        let symbol = currency.symbol
        return symbol == currency.rawValue ? "\(symbol) " : symbol
    }

    /// Symbol display for a persisted identifier, such as the Live Activity attribute payload.
    /// Unknown identifiers fall back to the identifier itself rather than inventing a symbol.
    static func symbol(_ amount: Double, currencyCode: String, compact: Bool = false) -> String {
        guard let currency = CurrencyCode(rawValue: currencyCode) else {
            return "\(currencyCode) \(amount.formatted(.number.precision(.fractionLength(2))))"
        }
        return symbol(amount, currency: currency, compact: compact)
    }

    /// Transaction-list display only: canonical currency code, then the decimal amount.
    /// Used by Latest Transactions and the main Ledger transaction rows.
    static func code(_ amount: Double, currency: CurrencyCode, signPrefix: String = "") -> String {
        "\(signPrefix)\(currency.rawValue) \(amount.formatted(.number.precision(.fractionLength(2))))"
    }
}
