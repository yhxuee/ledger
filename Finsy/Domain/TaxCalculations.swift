import Foundation

enum TaxInputMode: String, Codable, Hashable, Sendable {
    case beforeTax
    case finalAmount

    var title: String {
        switch self {
        case .beforeTax: String(localized: "Before Tax")
        case .finalAmount: String(localized: "Final Amount")
        }
    }
}

struct TaxSettings: Codable, Hashable, Sendable {
    var categoryRates: [LedgerCategoryID: Double] = [:]
    var isTaxInclusive: Bool = true

    enum CodingKeys: String, CodingKey {
        case categoryRates
        case isTaxInclusive
    }

    init(categoryRates: [LedgerCategoryID: Double] = [:], isTaxInclusive: Bool = true) {
        self.categoryRates = categoryRates
        self.isTaxInclusive = isTaxInclusive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryRates = try container.decodeIfPresent([LedgerCategoryID: Double].self, forKey: .categoryRates) ?? [:]
        isTaxInclusive = try container.decodeIfPresent(Bool.self, forKey: .isTaxInclusive) ?? true
    }
}

extension LedgerSettings {
    var isTaxInclusive: Bool {
        taxSettings?.isTaxInclusive ?? true
    }

    var defaultTaxInputMode: TaxInputMode {
        isTaxInclusive ? .finalAmount : .beforeTax
    }

    func taxRate(for category: LedgerCategory) -> Double {
        let fallback = category.kind == .expense ? 0.09 : 0.15
        return TaxCalculations.validRate(taxSettings?.categoryRates[category.id] ?? fallback,
                                         income: category.kind == .income)
    }
}

struct TaxSnapshot: Hashable, Sendable {
    let rate: Double
    let tax: Double
    let base: Double
    let finalAmount: Double
    let mode: TaxInputMode
    let exempt: Bool
    let hypotheticalTax: Double
}

enum TaxCalculations {
    static func validRate(_ rate: Double, income: Bool) -> Double {
        guard rate.isFinite else { return 0 }
        return min(max(0, rate), income ? 0.9999 : 10)
    }

    static func resolve(entered: Double, type: LedgerTransactionType, rate: Double,
                        mode: TaxInputMode, exempt: Bool = false) -> TaxSnapshot? {
        guard (type == .expense || type == .income), entered.isFinite else { return nil }
        let r = validRate(rate, income: type == .income)
        let value = abs(entered)
        let base: Double
        let tax: Double
        let final: Double
        let hypothetical: Double

        if exempt {
            final = value
            tax = 0
            if mode == .beforeTax {
                base = value
                hypothetical = value * r
            } else {
                if type == .expense {
                    let embeddedBase = value / (1 + r)
                    hypothetical = value - embeddedBase
                    base = embeddedBase
                } else {
                    let gross = r < 1 ? (value / (1 - r)) : value
                    hypothetical = gross - value
                    base = gross
                }
            }
        } else if mode == .beforeTax {
            base = value
            tax = base * r
            final = type == .expense ? base + tax : max(0, base - tax)
            hypothetical = tax
        } else {
            final = value
            base = type == .expense ? final / (1 + r) : (r < 1 ? final / (1 - r) : final)
            tax = abs(final - base)
            hypothetical = tax
        }
        return TaxSnapshot(
            rate: r,
            tax: tax,
            base: base,
            finalAmount: final,
            mode: mode,
            exempt: exempt,
            hypotheticalTax: hypothetical
        )
    }

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    static func percentString(_ rate: Double) -> String {
        (rate * 100).formatted(.number.precision(.fractionLength(0...2)))
    }

    static func percent(_ rate: Double) -> String {
        percentString(rate) + "%"
    }
}

extension LedgerTransaction {
    var taxSnapshot: TaxSnapshot? {
        guard (type == .expense || type == .income),
              let rate = taxRate,
              let tax = taxAmount,
              let base = taxBaseAmount,
              let mode = taxInputMode else { return nil }
        let exempt = isTaxExempt == true
        let hypothetical = exempt ? TaxCalculations.rounded(base * rate) : tax
        return TaxSnapshot(
            rate: rate,
            tax: tax,
            base: base,
            finalAmount: amount,
            mode: mode,
            exempt: exempt,
            hypotheticalTax: hypothetical
        )
    }

    mutating func applyTax(_ snapshot: TaxSnapshot?) {
        guard (type == .expense || type == .income), let snapshot else {
            taxRate = nil
            taxAmount = nil
            taxBaseAmount = nil
            taxInputMode = nil
            isTaxExempt = nil
            return
        }
        taxRate = snapshot.rate
        taxAmount = TaxCalculations.rounded(snapshot.tax)
        taxBaseAmount = TaxCalculations.rounded(snapshot.base)
        taxInputMode = snapshot.mode
        isTaxExempt = snapshot.exempt
    }
}

extension LedgerCalculations {
    static func taxEffect(_ transaction: LedgerTransaction, in state: LedgerState, to target: CurrencyCode, now: Date = .now) -> Double? {
        TransactionSemantics.taxEffect(transaction, in: state, to: target, now: now)?.amount
    }
}
