import SwiftUI

struct ForecastRiskBanner: View {
    @EnvironmentObject private var privacy: PrivacyController
    let forecast: CashFlowForecast
    let onDismiss: () -> Void
    let onSelect: () -> Void

    private var severity: ForecastRiskSeverity {
        forecast.highestSeverity ?? .yellow
    }

    private var bannerTitle: LocalizedStringKey {
        severity == .red ? "Budget Risk" : "Spending Forecast"
    }

    private var bannerMessage: String {
        if privacy.isLocked {
            return String(localized: "Spending forecast needs your attention.")
        }
        let count = forecast.budgetRisks.count
        if count == 1, let first = forecast.budgetRisks.first {
            let pct = Int64((first.exceedance * 100).rounded())
            return String(format: String(localized: "%@ is projected to exceed its budget by %lld%%."), first.title, pct)
        } else {
            return String(format: String(localized: "%lld budget items are projected to exceed their limits."), Int64(count))
        }
    }

    private var accentColor: Color {
        severity == .red ? .red : .orange
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(bannerTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Text(bannerMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            accentColor.opacity(severity == .red ? 0.16 : 0.12)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            onSelect()
        }
    }
}
