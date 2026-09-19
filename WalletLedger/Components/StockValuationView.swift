import SwiftUI

struct StockValuationView: View {
    let stock: StockMetadata
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let price = stock.latestPrice {
                SensitiveMoneyText(amount: price, currency: stock.market.settlementCurrency).font(.title3.bold())
            }
            SensitiveValueContent { Text("\(stock.quantity.formatted()) shares") }
            metric(stock.latestPrice == nil ? "Cost Basis" : "Market Value", stock.value)
            metric("Average Cost", stock.averageCost)
            if let profit = stock.unrealizedPL {
                HStack {
                    Text("Unrealized P/L")
                    Spacer()
                    SensitiveValueText((profit > 0 ? "+" : "") + LedgerFormat.money(profit, currency: stock.market.settlementCurrency, maxIntegerDigits: 6))
                }
            }
            if let date = stock.latestPriceAt {
                Text("Last available price · \(stock.market.dateKey(date))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Market price unavailable. Value uses cost basis.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func metric(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            SensitiveMoneyText(amount: value, currency: stock.market.settlementCurrency, maxIntegerDigits: 6)
        }
    }
}
