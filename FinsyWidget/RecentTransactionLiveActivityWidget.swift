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
                    HStack(spacing: 8) {
                        Image(systemName: context.state.isExpense ? "arrow.down.right.circle.fill" : "arrow.up.left.circle.fill")
                            .font(.title2)
                            .foregroundStyle(context.state.isExpense ? Color.orange : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(context.state.accountName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.amountText)
                            .font(.headline.bold())
                            .foregroundStyle(context.state.isExpense ? Color.primary : Color.green)
                        if context.state.statusText == nil {
                            Text(timerInterval: context.state.occurredAt...context.state.expiresAt, countsDown: true)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let status = context.state.statusText {
                        HStack {
                            Label(LocalizedStringKey(status), systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(Color.green)
                            Spacer()
                        }
                        .padding(.top, 4)
                    } else {
                        HStack(spacing: 12) {
                            Button(intent: UndoRecentTransactionIntent(transactionID: context.state.transactionID)) {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.gray.opacity(0.35))

                            if context.state.isRefundable {
                                Button(intent: RefundRecentTransactionIntent(transactionID: context.state.transactionID)) {
                                    Label("Refund", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.orange)
                            }
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.statusText != nil ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(context.state.statusText != nil ? Color.green : Color.orange)
            } compactTrailing: {
                if let status = context.state.statusText {
                    Text(LocalizedStringKey(status))
                        .font(.caption2.bold())
                        .foregroundStyle(Color.green)
                } else {
                    Text(timerInterval: context.state.occurredAt...context.state.expiresAt, countsDown: true)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.orange)
                }
            } minimal: {
                Image(systemName: context.state.statusText != nil ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(context.state.statusText != nil ? Color.green : Color.orange)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RecentTransactionActivityAttributes>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: context.state.isExpense ? "arrow.down.right.circle.fill" : "arrow.up.left.circle.fill")
                    .font(.title3)
                    .foregroundStyle(context.state.isExpense ? Color.orange : Color.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(context.state.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.amountText)
                        .font(.headline.bold())
                        .foregroundStyle(context.state.isExpense ? Color.primary : Color.green)

                    if context.state.statusText == nil {
                        Text(timerInterval: context.state.occurredAt...context.state.expiresAt, countsDown: true)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let status = context.state.statusText {
                HStack {
                    Label(LocalizedStringKey(status), systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.green)
                    Spacer()
                }
            } else {
                HStack(spacing: 12) {
                    Button(intent: UndoRecentTransactionIntent(transactionID: context.state.transactionID)) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.gray.opacity(0.35))

                    if context.state.isRefundable {
                        Button(intent: RefundRecentTransactionIntent(transactionID: context.state.transactionID)) {
                            Label("Refund", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.orange)
                    }

                    Spacer()
                }
            }
        }
        .padding(14)
    }
}
