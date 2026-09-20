import Foundation

enum CurrencyRates {
    /// All rates are HKD reference units. Stablecoins always resolve through USD,
    /// even if a backup contains a stale or conflicting stablecoin entry.
    static func reference(_ currency: CurrencyCode, in rates: [CurrencyCode: Double]) -> Double? {
        guard let value = rates[currency.referenceCurrency], value.isFinite, value > 0 else { return nil }
        return value
    }

    static func mirroringUSDAliases(_ rates: [CurrencyCode: Double]) -> [CurrencyCode: Double] {
        var result = rates
        for coin in CurrencyCode.usdStablecoins { result[coin] = reference(.USD, in: rates) }
        return result
    }
}
