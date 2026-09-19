import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WalletLedgerWidgetBundle: WidgetBundle {
    var body: some Widget { PurchaseLiveActivityWidget() }
}

struct PurchaseLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PurchaseActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    PurchaseProgressRing(fraction: context.state.completionFraction, completed: context.state.isCompleted)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.state.isCompleted ? "Purchase Complete" : context.attributes.title).font(.headline).lineLimit(1)
                        Text("\(context.state.completedItemCount) / \(context.state.totalItemCount) items").font(.caption)
                        Text(amount(context.state.completedAmount, code: context.attributes.currencyCode)).font(.headline.monospacedDigit()).privacySensitive()
                        Text("Planned \(amount(context.state.totalPlannedAmount, code: context.attributes.currencyCode))").font(.caption).privacySensitive()
                    }
                    Spacer(minLength: 0)
                }
                if !context.state.isCompleted {
                    ForEach(context.state.nextItems) { item in itemRow(item, sessionID: context.attributes.sessionID, code: context.attributes.currencyCode) }
                }
            }
            .padding()
            .widgetURL(deepLink(context.attributes.sessionID))
            .activityBackgroundTint(.black.opacity(0.88)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PurchaseProgressRing(fraction: context.state.completionFraction, completed: context.state.isCompleted)
                        .frame(width: 58, height: 58).padding(5)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(amount(context.state.completedAmount, code: context.attributes.currencyCode))
                            .font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
                        Text("\(context.state.completedItemCount) / \(context.state.totalItemCount) items").font(.caption)
                    }.padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if context.state.isCompleted { Label("Purchase Complete", systemImage: "checkmark.circle.fill") }
                        else { ForEach(context.state.nextItems) { item in itemRow(item, sessionID: context.attributes.sessionID, code: context.attributes.currencyCode) } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isCompleted ? "checkmark.circle.fill" : "cart.fill")
            } compactTrailing: {
                Text(context.state.completionFraction, format: .percent.precision(.fractionLength(0))).font(.caption2.monospacedDigit())
            } minimal: {
                Gauge(value: context.state.completionFraction) { EmptyView() }.gaugeStyle(.accessoryCircular)
            }
            .widgetURL(deepLink(context.attributes.sessionID))
        }
    }

    private func itemRow(_ item: PurchaseActivityAttributes.ItemPreview, sessionID: UUID, code: String) -> some View {
        HStack {
            Button(intent: CompletePurchaseItemIntent(sessionID: sessionID, itemID: item.id)) { Image(systemName: "circle") }
                .buttonStyle(.plain).accessibilityLabel("Complete \(item.name)")
            Text(item.name).lineLimit(1)
            Spacer()
            Text(amount(item.amount, code: code)).font(.caption.monospacedDigit()).privacySensitive()
        }
    }
    private func deepLink(_ id: UUID) -> URL { URL(string: "walletledger://purchase/\(id.uuidString)")! }
    /// Lock Screen / Dynamic Island monetary amounts use the currency symbol, never the code.
    private func amount(_ value: Double, code: String) -> String { LedgerMoneyFormat.symbol(value, currencyCode: code) }
}
