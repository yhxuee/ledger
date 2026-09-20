import XCTest
@testable import Finsy

/// Direct coverage for the two intentional monetary display semantics:
/// normal money display uses currency symbols, transaction-list display uses canonical codes.
final class MoneyFormattingTests: XCTestCase {
    func testNormalMoneyFormattingUsesCurrencySymbols() {
        let cases: [(CurrencyCode, String)] = [(.HKD, "$"), (.USD, "$"), (.SGD, "$"), (.GBP, "£"), (.CNY, "¥"), (.JPY, "¥"), (.EUR, "€")]
        for (currency, symbol) in cases {
            let value = LedgerFormat.money(100, currency: currency)
            XCTAssertTrue(value.hasPrefix(symbol + "100"), "\(currency.rawValue) should render as \(symbol)100.00, got \(value)")
            XCTAssertFalse(value.contains(currency.rawValue), "Normal money display must not prefix the currency code: \(value)")
        }
    }

    func testNormalMoneyFormattingFallsBackToSeparatedCodeWhenNoDistinctSymbolExists() {
        let value = LedgerFormat.money(1_000, currency: .CHF)
        XCTAssertTrue(value.hasPrefix("CHF "), "A fallback code needs a separator, got \(value)")
        XCTAssertTrue(value.hasPrefix("CHF 1"))
        XCTAssertFalse(value.hasPrefix("CHF1"))
    }

    func testUSDStablecoinsUseTheDollarSymbolInNormalMoneyDisplay() {
        for coin in CurrencyCode.usdStablecoins {
            XCTAssertEqual(coin.symbol, "$", "\(coin.rawValue) displays with the dollar symbol")
            let value = LedgerFormat.money(100, currency: coin)
            XCTAssertTrue(value.hasPrefix("$100"), "\(coin.rawValue) should render as $100.00, got \(value)")
            XCTAssertFalse(value.contains(coin.rawValue), "Stablecoin amounts must not be prefixed with \(coin.rawValue): \(value)")
        }
        XCTAssertEqual(LedgerFormat.money(100, currency: .USDT), LedgerFormat.money(100, currency: .USD))
    }

    func testNegativeAmountsPlaceTheSignBeforeTheSymbol() {
        XCTAssertTrue(LedgerFormat.money(-100, currency: .USD).hasPrefix("-$100"))
        XCTAssertTrue(LedgerFormat.money(-1_200, currency: .HKD).hasPrefix("-$1"))
        XCTAssertFalse(LedgerFormat.money(-1_200, currency: .HKD).hasPrefix("$-"))
    }

    func testCompactMoneyFormattingRemainsSymbolBased() {
        let hkd = LedgerFormat.money(12_500, currency: .HKD, compact: true)
        XCTAssertTrue(hkd.hasPrefix("$12"), "Expected a symbol-prefixed compact value, got \(hkd)")
        XCTAssertTrue(hkd.hasSuffix("k"))
        XCTAssertFalse(hkd.contains("HKD"))

        let usd = LedgerFormat.money(120_000, currency: .USD, compact: true)
        XCTAssertTrue(usd.hasPrefix("$120"), "Expected $120k, got \(usd)")
        XCTAssertTrue(usd.hasSuffix("k"))
        XCTAssertFalse(usd.contains("USD"))

        let gbp = LedgerFormat.money(15_000, currency: .GBP, compact: true)
        XCTAssertTrue(gbp.hasPrefix("£15"), "Expected £15k, got \(gbp)")
        XCTAssertTrue(gbp.hasSuffix("k"))

        let usdt = LedgerFormat.money(12_500, currency: .USDT, compact: true)
        XCTAssertTrue(usdt.hasPrefix("$12"), "Expected a dollar-symbol compact value, got \(usdt)")
        XCTAssertFalse(usdt.contains("USDT"))
    }

    func testTransactionListFormattingUsesCanonicalCurrencyCodes() {
        XCTAssertTrue(LedgerFormat.transaction(100, currency: .HKD, type: .expense).hasPrefix("HKD 100"))
        XCTAssertTrue(LedgerFormat.transaction(100, currency: .USD, type: .expense).hasPrefix("USD 100"))
        XCTAssertTrue(LedgerFormat.transaction(50, currency: .USDT, type: .expense).hasPrefix("USDT 50"))
        XCTAssertTrue(LedgerFormat.transaction(500, currency: .USD, type: .income).hasPrefix("+USD 500"))

        for currency in [CurrencyCode.HKD, .USD, .GBP, .EUR, .USDT] {
            let value = LedgerFormat.transaction(25, currency: currency, type: .expense)
            XCTAssertTrue(value.contains(currency.rawValue), "Transaction rows must show the currency code: \(value)")
        }
        XCTAssertFalse(LedgerFormat.transaction(25, currency: .GBP, type: .expense).hasPrefix("£"))
        XCTAssertFalse(LedgerFormat.transaction(25, currency: .USDT, type: .expense).hasPrefix("$"))
    }

    func testNormalAndTransactionFormattingStayDistinct() {
        XCTAssertNotEqual(LedgerFormat.money(1_234, currency: .HKD), LedgerFormat.transaction(1_234, currency: .HKD, type: .expense))
        XCTAssertTrue(LedgerFormat.money(1_234, currency: .HKD).hasPrefix("$"))
        XCTAssertTrue(LedgerFormat.transaction(1_234, currency: .HKD, type: .expense).hasPrefix("HKD"))
    }

    func testLiveActivityCurrencyCodeFormattingUsesSymbols() {
        for code in ["USD", "USDT", "USDC", "PYUSD", "BUSD", "GUSD"] {
            XCTAssertTrue(LedgerMoneyFormat.symbol(48.2, currencyCode: code).hasPrefix("$48"), "\(code) must display with a dollar symbol")
        }
        XCTAssertTrue(LedgerMoneyFormat.symbol(48.2, currencyCode: "HKD").hasPrefix("$48"))
        XCTAssertTrue(LedgerMoneyFormat.symbol(48.2, currencyCode: "GBP").hasPrefix("£48"))
        XCTAssertTrue(LedgerMoneyFormat.symbol(48.2, currencyCode: "ZZZZ").hasPrefix("ZZZZ "))
    }

    func testLiveActivityIdentifiersStayCodedWhileAmountsRenderSymbols() {
        var session = PurchaseSession(id: UUID(), ledgerBookID: UUID(), name: "Groceries", status: .active, sections: [], items: [
            .init(id: UUID(), categoryID: .food, note: "Milk", amount: 48.2, displayOrder: 0, isCompleted: true, completedAt: .now, linkedTransactionID: nil)
        ], createdAt: .now, startedAt: .now, completedAt: nil, receiptAttachmentID: nil, currency: .USDT, accountID: UUID())
        session.normalizeSections()
        let attributes = PurchaseActivityAttributes(sessionID: session.id, title: session.name, currencyCode: session.currency.rawValue)
        XCTAssertEqual(attributes.currencyCode, "USDT")
        let state = PurchaseActivityAttributes.ContentState.make(session: session, interactiveCompletionAvailable: true)
        XCTAssertEqual(state.completedAmount, 48.2, accuracy: 0.0001)
        XCTAssertTrue(LedgerMoneyFormat.symbol(state.completedAmount, currencyCode: attributes.currencyCode).hasPrefix("$48"))
    }

    func testPersistedIdentifiersRemainCanonicalCodes() throws {
        for currency in [CurrencyCode.HKD, .USD, .USDT, .PYUSD] {
            let data = try JSONEncoder().encode(currency)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(currency.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(CurrencyCode.self, from: data), currency)
        }
        for locked in ["$", "£", "¥", "€"] {
            XCTAssertNil(CurrencyCode(rawValue: locked), "A symbol must never be persisted or decoded as a currency identifier.")
        }
    }
}
