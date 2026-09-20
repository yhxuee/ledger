import AppIntents
import Charts
import SwiftUI
import WidgetKit

struct OverviewMetricEntry: TimelineEntry {
    let date: Date
    let metric: OverviewMetricWidgetOption
    let snapshot: OverviewWidgetSnapshot
}

struct OverviewMetricTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = OverviewMetricEntry
    typealias Intent = SelectOverviewMetricIntent

    func placeholder(in context: Context) -> OverviewMetricEntry {
        OverviewMetricEntry(date: .now, metric: .budgetRemain, snapshot: .placeholder)
    }

    func snapshot(for configuration: SelectOverviewMetricIntent, in context: Context) async -> OverviewMetricEntry {
        let snapshot = OverviewWidgetSnapshotStore.read()
        return OverviewMetricEntry(date: .now, metric: configuration.metric, snapshot: snapshot)
    }

    func timeline(for configuration: SelectOverviewMetricIntent, in context: Context) async -> Timeline<OverviewMetricEntry> {
        let snapshot = OverviewWidgetSnapshotStore.read()
        let entry = OverviewMetricEntry(date: .now, metric: configuration.metric, snapshot: snapshot)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
}

struct OverviewMetricWidget: Widget {
    let kind: String = "FinsyOverviewMetric"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectOverviewMetricIntent.self,
            provider: OverviewMetricTimelineProvider()
        ) { entry in
            OverviewMetricWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
        }
        .configurationDisplayName("Finsy Metric")
        .description("Display your financial metrics at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OverviewMetricWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: OverviewMetricEntry

    var body: some View {
        switch family {
        case .systemMedium:
            OverviewMediumMetricView(entry: entry)
        default:
            OverviewSmallMetricView(entry: entry)
        }
    }
}

// MARK: - Amount Helpers

private func widgetFormattedAmount(_ amount: Double, currency: CurrencyCode, masked: Bool) -> String {
    if masked { return "••••" }
    if abs(amount) >= 1_000 {
        return LedgerMoneyFormat.compactSymbol(amount, currency: currency)
    }
    return LedgerMoneyFormat.symbol(amount, currency: currency)
}

// MARK: - Small Widget

private struct OverviewSmallMetricView: View {
    let entry: OverviewMetricEntry

    var body: some View {
        switch entry.metric {
        case .budgetRemain:
            smallBudgetRemain
        case .weeklyActivity:
            smallWeeklyActivity
        case .todayExpense:
            smallExpense(title: "TODAY EXPENSE", data: entry.snapshot.todayExpense)
        case .weekExpense:
            smallExpense(title: "WEEK EXPENSE", data: entry.snapshot.weekExpense)
        case .sixMonthTrend:
            smallSixMonthTrend
        }
    }

    private var smallBudgetRemain: some View {
        let budget = entry.snapshot.budgetRemain
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked

        return VStack(alignment: .leading, spacing: 0) {
            Text("BUDGET REMAIN")
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
                .tracking(0.7)

            Spacer(minLength: 4)

            Text(widgetFormattedAmount(budget.remaining, currency: currency, masked: masked))
                .font(.system(size: 24, weight: .bold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.60)
                .privacySensitive()

            Spacer(minLength: 6)

            ProgressView(value: budget.hasBudget ? min(max(budget.ratio, 0), 1) : 0)
                .tint(budget.ratio > 1 ? .red : PurchaseActivityPalette.accent)

            Spacer().frame(height: 3)

            if budget.hasBudget {
                Text(masked ? "••% used" : "\(Int(budget.ratio * 100))% used")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No budget")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var smallWeeklyActivity: some View {
        let activity = entry.snapshot.weeklyActivity
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked
        let maxVal = max(activity.buckets.map(\.amount).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 0) {
            Text("WEEKLY ACTIVITY")
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
                .tracking(0.7)

            Spacer(minLength: 4)

            if activity.buckets.isEmpty || activity.total == 0 {
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(0..<7, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.20))
                                .frame(maxWidth: .infinity, maxHeight: 6)
                        }
                    }
                    Text("No recorded expenses")
                        .font(.system(size: 9, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(activity.buckets) { bucket in
                        VStack(spacing: 2) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(PurchaseActivityPalette.accent)
                                .frame(height: max(4, 38 * bucket.amount / maxVal))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 4)

            Text(widgetFormattedAmount(activity.total, currency: currency, masked: masked))
                .font(.system(size: 20, weight: .bold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .privacySensitive()
        }
    }

    private func smallExpense(title: String, data: OverviewWidgetExpenseData) -> some View {
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked

        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
                .tracking(0.7)

            Spacer(minLength: 4)

            if data.segments.isEmpty || data.total == 0 {
                VStack(spacing: 4) {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 5)
                        .frame(width: 38, height: 38)
                    Text("No recorded expenses")
                        .font(.system(size: 9, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(data.segments) { segment in
                    SectorMark(
                        angle: .value("Amount", segment.amount),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.0
                    )
                    .foregroundStyle(PurchaseActivityPalette.categoryColor(hex: segment.colorHex))
                }
                .chartLegend(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 4)

            Text(widgetFormattedAmount(data.total, currency: currency, masked: masked))
                .font(.system(size: 20, weight: .bold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .privacySensitive()
        }
    }

    private var smallSixMonthTrend: some View {
        let trend = entry.snapshot.sixMonthTrend
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked

        return VStack(alignment: .leading, spacing: 0) {
            Text("6M TRENDS")
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
                .tracking(0.7)

            Spacer(minLength: 4)

            if trend.buckets.isEmpty || trend.total == 0 {
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.20))
                        .frame(maxWidth: .infinity, maxHeight: 3)
                    Text("No recorded expenses")
                        .font(.system(size: 9, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(trend.buckets) { bucket in
                    AreaMark(
                        x: .value("Month", bucket.label),
                        y: .value("Amount", bucket.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(PurchaseActivityPalette.info.opacity(0.15))

                    LineMark(
                        x: .value("Month", bucket.label),
                        y: .value("Amount", bucket.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(PurchaseActivityPalette.info)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 4)

            Text(widgetFormattedAmount(trend.total, currency: currency, masked: masked))
                .font(.system(size: 20, weight: .bold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .privacySensitive()
        }
    }
}

// MARK: - Medium Widget

private struct OverviewMediumMetricView: View {
    let entry: OverviewMetricEntry

    var body: some View {
        switch entry.metric {
        case .budgetRemain:
            mediumBudgetRemain
        case .weeklyActivity:
            mediumWeeklyActivity
        case .todayExpense:
            mediumExpense(title: "TODAY EXPENSE", data: entry.snapshot.todayExpense)
        case .weekExpense:
            mediumExpense(title: "WEEK EXPENSE", data: entry.snapshot.weekExpense)
        case .sixMonthTrend:
            mediumSixMonthTrend
        }
    }

    private var mediumBudgetRemain: some View {
        let budget = entry.snapshot.budgetRemain
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("BUDGET REMAIN")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)

                Spacer()

                Text(widgetFormattedAmount(budget.remaining, currency: currency, masked: masked))
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .privacySensitive()
            }

            Spacer()

            ProgressView(value: budget.hasBudget ? min(max(budget.ratio, 0), 1) : 0)
                .tint(budget.ratio > 1 ? .red : PurchaseActivityPalette.accent)

            Spacer()

            if budget.hasBudget {
                Text(masked ? "••% of monthly budget used" : "\(Int(budget.ratio * 100))% of monthly budget used")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No budget configured")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func mediumExpense(title: String, data: OverviewWidgetExpenseData) -> some View {
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked

        return HStack(spacing: 16) {
            // Left: Donut Chart
            if data.segments.isEmpty || data.total == 0 {
                VStack(spacing: 6) {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 7)
                        .frame(width: 58, height: 58)
                    Text("No expenses")
                        .font(.system(size: 10, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80)
            } else {
                Chart(data.segments) { segment in
                    SectorMark(
                        angle: .value("Amount", segment.amount),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.2
                    )
                    .foregroundStyle(PurchaseActivityPalette.categoryColor(hex: segment.colorHex))
                }
                .chartLegend(.hidden)
                .frame(width: 80, height: 80)
            }

            // Right: Header, Amount and Breakdown
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)

                Text(widgetFormattedAmount(data.total, currency: currency, masked: masked))
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .privacySensitive()

                Spacer(minLength: 2)

                if data.segments.isEmpty || data.total == 0 {
                    Text("No recorded expenses")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(data.segments.prefix(3)) { seg in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(PurchaseActivityPalette.categoryColor(hex: seg.colorHex))
                                    .frame(width: 6, height: 6)
                                Text(seg.name)
                                    .font(.system(size: 10, weight: .medium, design: .default))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(widgetFormattedAmount(seg.amount, currency: currency, masked: masked))
                                    .font(.system(size: 10, weight: .semibold, design: .default))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var mediumWeeklyActivity: some View {
        let activity = entry.snapshot.weeklyActivity
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked
        let maxVal = max(activity.buckets.map(\.amount).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("WEEKLY ACTIVITY")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)

                Spacer()

                Text(widgetFormattedAmount(activity.total, currency: currency, masked: masked))
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .privacySensitive()
            }

            Spacer()

            if activity.buckets.isEmpty || activity.total == 0 {
                Text("No recorded expenses")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(activity.buckets) { bucket in
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(PurchaseActivityPalette.accent)
                                .frame(height: max(4, 48 * bucket.amount / maxVal))
                            Text(bucket.label.prefix(2))
                                .font(.system(size: 9, weight: .semibold, design: .default))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 64)
            }
        }
    }

    private var mediumSixMonthTrend: some View {
        let trend = entry.snapshot.sixMonthTrend
        let currency = entry.snapshot.currency
        let masked = entry.snapshot.isPrivacyMasked

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("6M TRENDS")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)

                Spacer()

                Text(widgetFormattedAmount(trend.total, currency: currency, masked: masked))
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .privacySensitive()
            }

            Spacer()

            if trend.buckets.isEmpty || trend.total == 0 {
                Text("No recorded expenses")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(trend.buckets) { bucket in
                    AreaMark(
                        x: .value("Month", bucket.label),
                        y: .value("Amount", bucket.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(PurchaseActivityPalette.info.opacity(0.15))

                    LineMark(
                        x: .value("Month", bucket.label),
                        y: .value("Amount", bucket.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(PurchaseActivityPalette.info)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxis {
                    AxisMarks(values: trend.buckets.map(\.label)) {
                        AxisValueLabel()
                            .font(.system(size: 9, weight: .semibold, design: .default))
                    }
                }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(maxWidth: .infinity, maxHeight: 64)
            }
        }
    }
}
