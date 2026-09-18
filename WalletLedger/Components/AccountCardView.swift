import SwiftUI

struct AccountCardView: View {
    var account: AccountViewModel?
    var portfolioBalance: Double = 0
    var baseCurrency: CurrencyCode = .HKD
    var compact = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(background)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(.white.opacity(0.34)).frame(width: compact ? 110 : 170).blur(radius: 4).offset(x: 32, y: -45)
                }
            VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                HStack {
                    Text(account?.account.logo ?? "ALL").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 7).background(.white.opacity(0.32), in: Capsule())
                    Spacer()
                    Image(systemName: account?.account.type.symbol ?? "wallet.bifold.fill").font(.title3)
                }
                Spacer(minLength: 8)
                Text(account?.account.type.rawValue ?? "Portfolio").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(account?.account.name ?? "All Accounts").font((compact ? Font.headline : .title3).weight(.bold)).lineLimit(1)
                Text(LedgerFormat.money(account?.balance ?? portfolioBalance, currency: account?.account.currency ?? baseCurrency))
                    .font(.system(size: compact ? 24 : 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
            }.padding(compact ? 16 : 22)
        }
        .foregroundStyle(.black.opacity(0.84))
        .aspectRatio(85.6 / 53.98, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }

    private var background: LinearGradient {
        let style = account?.account.cardStyle ?? .init(startHex: "F2C7D8", endHex: "B9D9F1")
        return LinearGradient(colors: [Color(hex: style.startHex), Color(hex: style.endHex)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
