import Foundation

/// Central monetary display rules shared by the app and the widget extension.
///
/// Exactly three display semantics exist and must never be mixed:
/// - `symbol(_:currency:compact:)` is the normal money display (`$1,234.00`, `£25.00`, `¥1,234`).
/// - `code(_:currency:signPrefix:)` is reserved for transaction-list rows (`HKD 1,234.00`, `+USD 25.00`).
/// - `compactSymbol` / `compactCode` are the width-constrained variants used where the layout
///   cannot grow, scaling into the single K / M / B / T unit set.
///
/// Currency identifiers that are persisted, selected or shown as metadata continue to use
/// `CurrencyCode.rawValue` and never `$`, `£` or `¥`.
enum LedgerMoneyFormat {
    /// Default digit budget for the compact formatter: four integer digits plus two decimals.
    static let defaultCompactIntegerDigits = 4

    /// The only compact units, smallest first. T is the largest unit the app displays.
    private static let compactUnits: [(factor: Double, suffix: String)] = [
        (1_000, "K"),
        (1_000_000, "M"),
        (1_000_000_000, "B"),
        (1_000_000_000_000, "T")
    ]

    /// Normal monetary display: the currency's symbol, then the decimal amount.
    /// Amounts are never prefixed with the canonical currency code, so a HKD 100 amount
    /// renders as `$100.00` and a USDT 100 amount also renders as `$100.00`.
    /// `compact: true` delegates to the shared K / M / B / T formatter.
    static func symbol(_ amount: Double, currency: CurrencyCode, compact: Bool = false) -> String {
        guard !compact else { return compactSymbol(amount, currency: currency) }
        let magnitude = abs(amount)
        guard magnitude.isFinite else { return "\(displayPrefix(currency))0.00" }
        let sign = amount < 0 ? "-" : ""
        return "\(sign)\(displayPrefix(currency))\(magnitude.formatted(.number.precision(.fractionLength(2))))"
    }

    /// Width-constrained symbol display (`$9999.99K`), for the same places that use `symbol`.
    static func compactSymbol(_ amount: Double, currency: CurrencyCode, maxIntegerDigits: Int = defaultCompactIntegerDigits) -> String {
        "\(displayPrefix(currency))\(compact(amount, maxIntegerDigits: maxIntegerDigits))"
    }

    /// Width-constrained transaction display (`HKD 9999.99K`, `+USD 10.00M`).
    static func compactCode(_ amount: Double, currency: CurrencyCode, signPrefix: String = "", maxIntegerDigits: Int = defaultCompactIntegerDigits) -> String {
        "\(signPrefix)\(currency.rawValue) \(compact(amount, maxIntegerDigits: maxIntegerDigits))"
    }

    /// Compact amount with exactly two decimals and no thousands separators.
    ///
    /// The smallest K / M / B / T unit that keeps the integer part within `maxIntegerDigits` is
    /// used, and the value is **truncated** rather than rounded: rounding could push a value such
    /// as 9999.99K across the digit budget and produce one extra integer digit.
    ///
    /// ```text
    /// 9999.99   → 9999.99      (no unit needed)
    /// 10000     → 10.00K
    /// 9999999   → 9999.99K
    /// 10000000  → 10.00M
    /// ```
    static func compact(_ amount: Double, maxIntegerDigits: Int = defaultCompactIntegerDigits) -> String {
        guard amount.isFinite else { return "0.00" }
        let digits = max(1, min(9, maxIntegerDigits))
        let ceiling = hundredthsCeiling(digits)
        let sign = amount < 0 ? "-" : ""
        let magnitude = abs(amount)
        var value = hundredths(magnitude)
        var suffix = ""
        if value >= ceiling {
            if let unit = compactUnits.first(where: { hundredths(magnitude / $0.factor) < ceiling }) {
                value = hundredths(magnitude / unit.factor)
                suffix = unit.suffix
            } else if let largest = compactUnits.last {
                // Beyond T: stay in the largest unit and clamp to the digit budget.
                value = min(hundredths(magnitude / largest.factor), ceiling - 1)
                suffix = largest.suffix
            }
        }
        let integerPart = value / 100
        let fraction = value % 100
        return "\(sign)\(integerPart).\(fraction < 10 ? "0" : "")\(fraction)\(suffix)"
    }

    /// `10^digits` expressed in hundredths: the exclusive upper bound of the digit budget.
    private static func hundredthsCeiling(_ digits: Int) -> Int {
        var value = 100
        for _ in 0..<digits { value *= 10 }
        return value
    }

    /// Truncated hundredths of `value`, tolerant of binary floating point noise
    /// (9999.99 is stored slightly below itself, but must still print as 9999.99).
    private static func hundredths(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let scaled = (value * 100).rounded(.down) + 1e-6
        guard scaled < Double(Int.max / 4) else { return Int.max / 4 }
        return Int(scaled)
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
            let value = compact ? LedgerMoneyFormat.compact(amount) : amount.formatted(.number.precision(.fractionLength(2)))
            return "\(currencyCode) \(value)"
        }
        return symbol(amount, currency: currency, compact: compact)
    }

    /// Transaction-list display only: canonical currency code, then the decimal amount.
    /// Used by Latest Transactions and the main Ledger transaction rows.
    static func code(_ amount: Double, currency: CurrencyCode, signPrefix: String = "") -> String {
        return "\(signPrefix)\(currency.rawValue) \(amount.formatted(.number.precision(.fractionLength(2))))"
    }
}
