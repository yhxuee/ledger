import SwiftUI

struct AccountsPortfolioSummaryView: View {
    let netWorth: Double
    let assets: Double
    let liabilities: Double
    let currency: CurrencyCode

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NET WORTH").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SensitiveMoneyText(amount: netWorth, currency: currency)
                    .font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                metric("Total Assets", value: assets, liability: false)
                metric("Liabilities", value: liabilities, liability: true)
            }
        }
        .padding(22)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24))
    }

    private func metric(_ label: String, value: Double, liability: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SensitiveMoneyText(amount: value, currency: currency)
                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(liability ? Color.red : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
