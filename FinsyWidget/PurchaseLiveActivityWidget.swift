import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct FinsyWidgetBundle: WidgetBundle {
    var body: some Widget {
        OverviewMetricWidget()
        PurchaseLiveActivityWidget()
        RecentTransactionLiveActivityWidget()
    }
}

struct PurchaseLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PurchaseActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(PurchaseActivityPalette.surface)
                .activitySystemActionForegroundColor(PurchaseActivityPalette.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // 46pt ring with a 13pt glyph and no outer padding: the lead element stays
                    // centred inside its region instead of touching the island's upper edge.
                    PurchaseProgressRing(
                        fraction: context.state.completionFraction,
                        completed: context.state.isCompleted,
                        tint: accent(context),
                        iconSize: 13,
                        lineWidth: 4)
                        .frame(width: 46, height: 46)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(amount(context.state.completedAmount, code: context.attributes.currencyCode))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(PurchaseActivityPalette.onSurface)
                            .lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
                        Text("\(context.state.completedItemCount) / \(context.state.totalItemCount) items")
                            .font(.caption2)
                            .foregroundStyle(PurchaseActivityPalette.secondaryText)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if context.state.isCompleted {
                            Label("Purchase Complete", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent(context))
                        } else {
                            ForEach(context.state.nextItems) { item in
                                itemRow(item,
                                        sessionID: context.attributes.sessionID,
                                        code: context.attributes.currencyCode,
                                        interactive: context.state.interactiveCompletionAvailable)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isCompleted ? "checkmark.circle.fill" : "cart.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent(context))
            } compactTrailing: {
                Text(context.state.completionFraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(accent(context))
            } minimal: {
                Gauge(value: context.state.completionFraction) { EmptyView() }
                    .gaugeStyle(.accessoryCircular)
                    .tint(accent(context))
            }
            .widgetURL(deepLink(context.attributes.sessionID))
            .keylineTint(accent(context))
        }
    }

    /// Lock Screen: dark charcoal surface (never pure black) with coral/teal accents.
    private func lockScreen(_ context: ActivityViewContext<PurchaseActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PurchaseProgressRing(
                    fraction: context.state.completionFraction,
                    completed: context.state.isCompleted,
                        tint: accent(context),
                    iconSize: 16,
                    lineWidth: 5)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.isCompleted ? "Purchase Complete" : context.attributes.title)
                        .font(.headline).foregroundStyle(PurchaseActivityPalette.onSurface).lineLimit(1)
                    Text("\(context.state.completedItemCount) / \(context.state.totalItemCount) items")
                        .font(.caption).foregroundStyle(PurchaseActivityPalette.secondaryText)
                    Text(amount(context.state.completedAmount, code: context.attributes.currencyCode))
                        .font(.headline.monospacedDigit()).foregroundStyle(accent(context)).privacySensitive()
                    Text("Planned \(amount(context.state.totalPlannedAmount, code: context.attributes.currencyCode))")
                        .font(.caption).foregroundStyle(PurchaseActivityPalette.secondaryText).privacySensitive()
                }
                Spacer(minLength: 0)
            }
            if !context.state.isCompleted {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(context.state.nextItems) { item in
                        itemRow(item,
                                sessionID: context.attributes.sessionID,
                                code: context.attributes.currencyCode,
                                interactive: context.state.interactiveCompletionAvailable)
                    }
                }
            }
        }
        .padding()
        .widgetURL(deepLink(context.attributes.sessionID))
    }

    /// AppIntent controls need a usable App Group bridge. Without it the rows are read-only,
    /// so the widget never offers a control that is guaranteed to fail.
    @ViewBuilder
    private func itemRow(_ item: PurchaseActivityAttributes.ItemPreview, sessionID: UUID, code: String, interactive: Bool) -> some View {
        HStack(spacing: 8) {
            if interactive {
                Button(intent: CompletePurchaseItemIntent(sessionID: sessionID, itemID: item.id)) {
                    Image(systemName: "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PurchaseActivityPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete \(item.name)")
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PurchaseActivityPalette.categoryColor(hex: item.categoryColorHex))
                    .accessibilityHidden(true)
            }
            Text(item.name).lineLimit(1).foregroundStyle(PurchaseActivityPalette.onSurface)
            Spacer()
            Text(amount(item.amount, code: code))
                .font(.caption.monospacedDigit())
                .foregroundStyle(PurchaseActivityPalette.secondaryText)
                .privacySensitive()
        }
    }

    private func accent(_ context: ActivityViewContext<PurchaseActivityAttributes>) -> Color {
        context.state.isCompleted
            ? PurchaseActivityPalette.color(hex: context.state.themeColorHex ?? "3A78C2")
            : PurchaseActivityPalette.accent
    }

    private func deepLink(_ id: UUID) -> URL { URL(string: "finsy://purchase/\(id.uuidString)")! }
    /// Lock Screen / Dynamic Island monetary amounts use the currency symbol, never the code.
    private func amount(_ value: Double, code: String) -> String { LedgerMoneyFormat.symbol(value, currencyCode: code) }
}
