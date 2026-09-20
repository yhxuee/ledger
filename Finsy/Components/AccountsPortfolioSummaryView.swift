import SwiftUI

struct AccountsPortfolioSummaryView: View {
    let netWorth: Double
    let assets: Double
    let liabilities: Double
    let currency: CurrencyCode
    /// Same base size as the Overview large balance, and Dynamic Type compatible.
    @ScaledMetric(relativeTo: .largeTitle) private var netWorthSize = 34.0
    @ScaledMetric(relativeTo: .title2) private var detailSize = 24.0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NET WORTH").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SensitiveMoneyText(amount: netWorth, currency: currency, maxIntegerDigits: 7)
                    .font(.system(size: netWorthSize, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
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
            SensitiveMoneyText(amount: value, currency: currency, maxIntegerDigits: 6)
                .font(.system(size: detailSize, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(liability ? Color.red : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
