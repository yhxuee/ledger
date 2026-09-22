import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RecentTransactionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecentTransactionActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color(uiColor: .systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(LocalizedStringKey("Recorded"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            categoryIconView(symbol: context.state.categorySymbol, colorHex: context.state.categoryColorHex)
                            Text(LocalizedStringKey(context.state.transactionType))
                                .font(.headline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(context.state.amountText)
                                .font(.headline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .privacySensitive()
                        }
                        .padding(.top, 4)

                        if let status = context.state.statusText {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(LocalizedStringKey(status))
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                                Spacer()
                            }
                        } else {
                            HStack {
                                if context.state.isRefundable {
                                    Button(intent: RefundRecentTransactionIntent(transactionID: context.state.transactionID)) {
                                        Label(LocalizedStringKey("Refund"), systemImage: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.orange)
                                }

                                Spacer()

                                Button(intent: UndoRecentTransactionIntent(transactionID: context.state.transactionID)) {
                                    Label(LocalizedStringKey("Undo"), systemImage: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.gray.opacity(0.35))
                            }
                        }
                    }
                }
            } compactLeading: {
                compactCategoryView(symbol: context.state.categorySymbol, colorHex: context.state.categoryColorHex)
            } compactTrailing: {
                Text(context.state.amountText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .privacySensitive()
            } minimal: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func compactCategoryView(symbol: String, colorHex: String) -> some View {
        let tint = PurchaseActivityPalette.categoryColor(hex: colorHex)
        if symbol.hasPrefix("emoji:") {
            Text(String(symbol.dropFirst(6)))
                .font(.system(size: 13))
        } else {
            let systemName = symbol.isEmpty ? "checkmark.circle.fill" : symbol
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func categoryIconView(symbol: String, colorHex: String) -> some View {
        let tint = PurchaseActivityPalette.categoryColor(hex: colorHex)
        if symbol.hasPrefix("emoji:") {
            Text(String(symbol.dropFirst(6)))
                .font(.system(size: 18))
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.2), in: Circle())
        } else {
            let systemName = symbol.isEmpty ? "tag.fill" : symbol
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.15), in: Circle())
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RecentTransactionActivityAttributes>) -> some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(LocalizedStringKey("Recorded"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                categoryIconView(symbol: context.state.categorySymbol, colorHex: context.state.categoryColorHex)
                Text(LocalizedStringKey(context.state.transactionType))
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(context.state.amountText)
                    .font(.headline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .privacySensitive()
            }

            if let status = context.state.statusText {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(LocalizedStringKey(status))
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Spacer()
                }
            } else {
                HStack {
                    if context.state.isRefundable {
                        Button(intent: RefundRecentTransactionIntent(transactionID: context.state.transactionID)) {
                            Label(LocalizedStringKey("Refund"), systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.orange)
                    }

                    Spacer()

                    Button(intent: UndoRecentTransactionIntent(transactionID: context.state.transactionID)) {
                        Label(LocalizedStringKey("Undo"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.gray.opacity(0.35))
                }
            }
        }
        .padding(14)
    }
}
