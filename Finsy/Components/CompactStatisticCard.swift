import SwiftUI

struct CompactStatisticCard<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .ledgerGlass(
            in: RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
    }
}

extension CompactStatisticCard where Content == AnyView {
    init(_ title: LocalizedStringKey, amount: Double, currency: CurrencyCode) {
        self.init(title) {
            AnyView(
                SensitiveMoneyText(amount: amount, currency: currency, compact: true)
                    .font(.headline.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            )
        }
    }
}
