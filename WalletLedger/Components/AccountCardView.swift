import SwiftUI

struct AccountCardView: View {
    var account: AccountViewModel?
    var portfolioBalance: Double = 0
    var baseCurrency: CurrencyCode = .HKD
    var compact = false
    var portfolioTitle = "Net Worth"
    var portfolioAssets: Double?
    var portfolioLiabilities: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            HStack(spacing: 8) {
                Text(account?.account.logo ?? "ALL")
                    .font(account == nil ? .caption.weight(.bold) : .headline.bold())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.32), in: Capsule())
                if let account {
                    Text(account.account.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: account?.account.type.symbol ?? "wallet.bifold.fill").font(.title3)
            }
            .cardInformationRegion()
            Spacer(minLength: 8)
            if account == nil {
                Text("Portfolio").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(portfolioTitle).font((compact ? Font.headline : .title3).weight(.bold)).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                SensitiveMoneyText(amount: account?.balance ?? portfolioBalance, currency: account?.account.currency ?? baseCurrency, maxIntegerDigits: 7)
                    .font(.system(size: compact ? 24 : 34, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
                if let account {
                    AccountCardMetadata(account: account.account)
                }
            }
            .cardInformationRegion()
            if account == nil, let portfolioAssets, let portfolioLiabilities {
                HStack(spacing: 24) {
                    portfolioMetric("Total Assets", value: portfolioAssets)
                    portfolioMetric("Liabilities", value: portfolioLiabilities)
                }
            }
        }
        .padding(compact ? 16 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardArtwork(data: account?.account.cardImageData, fallback: background)
        .aspectRatio(85.6 / 53.98, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }

    private var background: LinearGradient {
        let style = account?.account.cardStyle ?? .init(startHex: "F2C7D8", endHex: "B9D9F1")
        return LinearGradient(colors: [Color(hex: style.startHex), Color(hex: style.endHex)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func portfolioMetric(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            SensitiveMoneyText(amount: value, currency: baseCurrency, maxIntegerDigits: 6).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

/// Shared hierarchy for real account cards, with the type shown exactly once.
struct AccountCardMetadata: View {
    let account: LedgerAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text(LocalizedStringKey(account.type.rawValue)) + Text(verbatim: " · \(account.currency.rawValue)"))
                .lineLimit(1)
            if account.type == .stocks {
                Text(stockDetails)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if account.normalizedPockets.count > 1 {
                Text("\(account.normalizedPockets.count) currencies")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var stockDetails: String {
        let market = account.stockMetadata?.market.rawValue ?? account.settlementCurrency.rawValue
        let symbol = account.stockMetadata?.symbol.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return symbol.isEmpty ? market : "\(symbol) · \(market)"
    }
}
