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
            Link(destination: deepLink(context.attributes.sessionID)) {
                HStack(spacing: 14) {
                    ProgressView(value: context.state.completionFraction).progressViewStyle(.circular)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.isCompleted ? "Purchase Complete" : context.attributes.title).font(.headline).lineLimit(1)
                        Text(amount(context.state.completedAmount, code: context.attributes.currencyCode)).font(.subheadline.monospacedDigit()).privacySensitive()
                    }
                    Spacer()
                    Text(context.state.completionFraction, format: .percent.precision(.fractionLength(0))).font(.headline.monospacedDigit()).privacySensitive()
                }.padding()
            }
            .activityBackgroundTint(.black.opacity(0.88)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Gauge(value: context.state.completionFraction) { Image(systemName: "cart.fill") }.gaugeStyle(.accessoryCircular)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(amount(context.state.completedAmount, code: context.attributes.currencyCode)).font(.caption.bold().monospacedDigit()).privacySensitive()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if context.state.isCompleted { Label("Purchase Complete", systemImage: "checkmark.circle.fill") }
                        else { ForEach(context.state.nextItems) { item in itemRow(item, sessionID: context.attributes.sessionID) } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isCompleted ? "checkmark.circle.fill" : "cart.fill")
            } compactTrailing: {
                Text(context.state.completionFraction, format: .percent.precision(.fractionLength(0))).font(.caption2.monospacedDigit()).privacySensitive()
            } minimal: {
                Gauge(value: context.state.completionFraction) { EmptyView() }.gaugeStyle(.accessoryCircular)
            }
            .widgetURL(deepLink(context.attributes.sessionID))
        }
    }

    private func itemRow(_ item: PurchaseActivityAttributes.ItemPreview, sessionID: UUID) -> some View {
        HStack {
            Button(intent: CompletePurchaseItemIntent(sessionID: sessionID, itemID: item.id)) { Image(systemName: "circle") }.buttonStyle(.plain)
            Text(item.name).lineLimit(1)
            Spacer()
            Text(item.amount, format: .number.precision(.fractionLength(2))).font(.caption.monospacedDigit()).privacySensitive()
        }
    }
    private func deepLink(_ id: UUID) -> URL { URL(string: "walletledger://purchase/\(id.uuidString)")! }
    private func amount(_ value: Double, code: String) -> String { value.formatted(.currency(code: code)) }
}
