import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @EnvironmentObject private var privacy: PrivacyController
    @Binding var section: AppSection
    @Binding var selectedAccountID: UUID?
    @State private var showTransactionEditor = false
    @State private var editingTransaction: LedgerTransaction?
    @State private var showingBudgetDetail = false
    @State private var activeDetailMetric: OverviewMetricKind? = nil

    private var selected: AccountViewModel? { selectedAccountID.flatMap { id in store.accounts.first { $0.id == id } } }
    private var transactions: [LedgerTransaction] { LedgerCalculations.transactions(store.state, accountID: selectedAccountID) }
    private var usage: (budget: Double, spent: Double, ratio: Double) { selected.map { LedgerCalculations.budgetUsage(store.state, account: $0.account) } ?? LedgerCalculations.budgetUsage(store.state) }
    private var usageCurrency: CurrencyCode { selected?.account.currency ?? store.state.settings.baseCurrency }

    // Metric summaries
    private var weeklySummary: AnalyticsSummary {
        LedgerCalculations.analytics(store.state, range: .week, type: .expense, accountID: selectedAccountID)
    }

    private var todayRange: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? .now
        return start...end
    }

    private var todaySummary: AnalyticsSummary {
        LedgerCalculations.analytics(store.state, range: .week, type: .expense, accountID: selectedAccountID, customRange: todayRange)
    }

    private var sixMonthsSummary: AnalyticsSummary {
        LedgerCalculations.analytics(store.state, range: .sixMonths, type: .expense, accountID: selectedAccountID)
    }

    private func categorySegments(from summary: AnalyticsSummary) -> [CategorySegmentData] {
        let cats = store.state.categories.filter { $0.kind == .expense }
        return cats.compactMap { cat in
            let val = summary.categoryTotals[cat.id, default: 0]
            guard val.isFinite, val > 0 else { return nil }
            return CategorySegmentData(category: cat, value: val)
        }
    }

    var body: some View {
        ScrollView {
            topSection
                .padding(.horizontal).padding(.top, 8)
            latest.padding(.horizontal).padding(.top, 18).padding(.bottom, 30)
        }
        .background(LedgerBackground())
        .navigationTitle(selected?.account.name ?? "Overview")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ToolbarIconButton(systemName: "plus", label: "Add transaction") { showTransactionEditor = true } }
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() }
        }
        .sheet(isPresented: $showTransactionEditor) {
            TransactionEditorView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(item: $editingTransaction) {
            TransactionEditorView(transaction: $0)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showingBudgetDetail) {
            BudgetDetailView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(item: $activeDetailMetric) { metric in
            OverviewMetricDetailSheet(metric: metric, selectedAccountID: selectedAccountID) {
                activeDetailMetric = nil
                navigateToAnalytics(for: metric)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

struct VerticalOverviewHeroLayout: Layout {
    var spacing: CGFloat = 12
    var cardFraction: CGFloat = 0.47
    var maxCardWidth: CGFloat = 280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width > 0, !subviews.isEmpty else {
            return .zero
        }
        let usableWidth = max(0, width - spacing)
        let cardWidth = min(maxCardWidth, usableWidth * cardFraction)
        let cardHeight = cardWidth * (85.60 / 53.98)
        return CGSize(width: width, height: cardHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let usableWidth = max(0, bounds.width - spacing)
        let cardWidth = min(maxCardWidth, usableWidth * cardFraction)
        let cardHeight = cardWidth * (85.60 / 53.98)
        let metricWidth = max(0, usableWidth - cardWidth)
        let metricHeight = max(0, (cardHeight - spacing) / 2)

        // Subview 0: Portrait Card
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: cardWidth, height: cardHeight)
        )

        // Metrics on the right
        if subviews.count == 2 {
            subviews[1].place(
                at: CGPoint(x: bounds.minX + cardWidth + spacing, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metricWidth, height: cardHeight)
            )
        } else if subviews.count >= 3 {
            subviews[1].place(
                at: CGPoint(x: bounds.minX + cardWidth + spacing, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metricWidth, height: metricHeight)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.minX + cardWidth + spacing, y: bounds.minY + metricHeight + spacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metricWidth, height: metricHeight)
            )
        }
    }
}

    @ViewBuilder
    private var topSection: some View {
        let configured = preferences.value.overviewMetrics.prefix(2)
        switch preferences.value.overviewCardLayout {
        case .portrait:
            VerticalOverviewHeroLayout(spacing: 12, cardFraction: 0.47, maxCardWidth: 280) {
                OverviewAccountPickerButton(selectedAccountID: $selectedAccountID, layout: .portrait)
                if let first = configured.first {
                    metricCard(for: first, layout: .portraitSideColumn)
                }
                if configured.count > 1 {
                    metricCard(for: configured[1], layout: .portraitSideColumn)
                }
            }
        case .horizontal:
            VStack(spacing: 16) {
                OverviewAccountPickerButton(selectedAccountID: $selectedAccountID, layout: .horizontal)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(configured)) { kind in
                        metricCard(for: kind, layout: .horizontalGrid)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metricCard(for kind: OverviewMetricKind, layout: OverviewMetricLayout = .horizontalGrid) -> some View {
        let isSideColumn = (layout == .portraitSideColumn)
        switch kind {
        case .weeklyActivity:
            Button { activeDetailMetric = .weeklyActivity } label: {
                MetricCard("Weekly Activity", compact: isSideColumn, layout: layout) {
                    MiniActivityChart(buckets: weeklySummary.buckets, height: isSideColumn ? nil : 45)
                        .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : 45)
                    SensitiveMoneyText(amount: weeklySummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font((isSideColumn ? Font.subheadline : .headline).bold())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : nil)

        case .budget:
            Button { showingBudgetDetail = true } label: {
                MetricCard("Budget / Remain", compact: isSideColumn, layout: layout) {
                    SensitiveMoneyText(amount: usage.budget - usage.spent, currency: usageCurrency, maxIntegerDigits: 6)
                        .font((isSideColumn ? Font.headline : .title2).bold())
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                    if isSideColumn {
                        Spacer(minLength: 2)
                    }
                    ProgressView(value: privacy.isLocked ? 0 : min(max(usage.ratio, 0), 1))
                        .tint(usage.ratio > 1 ? .red : LedgerPalette.coral)
                    if isSideColumn {
                        Spacer(minLength: 2)
                    }
                    SensitiveValueText("\(Int(usage.ratio * 100))% of monthly budget used", maskLength: 8)
                        .font(isSideColumn ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : nil)

        case .todayExpensePie:
            Button { activeDetailMetric = .todayExpensePie } label: {
                MetricCard("Today Expense", compact: isSideColumn, layout: layout) {
                    MiniPieChart(segments: categorySegments(from: todaySummary), height: isSideColumn ? nil : 45)
                        .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : 45)
                    SensitiveMoneyText(amount: todaySummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font((isSideColumn ? Font.subheadline : .headline).bold())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : nil)

        case .weekExpensePie:
            Button { activeDetailMetric = .weekExpensePie } label: {
                MetricCard("This Week Expense", compact: isSideColumn, layout: layout) {
                    MiniPieChart(segments: categorySegments(from: weeklySummary), height: isSideColumn ? nil : 45)
                        .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : 45)
                    SensitiveMoneyText(amount: weeklySummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font((isSideColumn ? Font.subheadline : .headline).bold())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : nil)

        case .sixMonthTrend:
            Button { activeDetailMetric = .sixMonthTrend } label: {
                MetricCard("6M Trends", compact: isSideColumn, layout: layout) {
                    SixMonthTrendChart(buckets: sixMonthsSummary.buckets)
                        .chartXAxis(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : 45)
                    SensitiveMoneyText(amount: sixMonthsSummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font((isSideColumn ? Font.subheadline : .headline).bold())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: isSideColumn ? .infinity : nil)
        }
    }

    private func navigateToAnalytics(for metric: OverviewMetricKind) {
        store.requestedAnalyticsType = .expense
        switch metric {
        case .weeklyActivity, .weekExpensePie:
            store.requestedAnalyticsRange = .week
        case .todayExpensePie:
            store.requestedAnalyticsCustomRange = todayRange
        case .sixMonthTrend:
            store.requestedAnalyticsRange = .sixMonths
        case .budget:
            store.requestedAnalyticsRange = .month
        }
        section = .analytics
    }

    private var latest: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest Transactions").font(.title2.bold())
                Spacer()
                Button { section = .ledger } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline.bold())
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Ledger")
            }
            LazyVStack(spacing: 0) {
                ForEach(transactions.prefix(8)) { item in
                    Button { if !item.isLockedByReversal { editingTransaction = item } } label: { TransactionRow(transaction: item, category: category(item.categoryID)).padding(.horizontal, 15).padding(.vertical, 7) }
                        .buttonStyle(.plain)
                    if item.id != transactions.prefix(8).last?.id { Divider().padding(.leading, 67) }
                }
                if transactions.isEmpty { ContentUnavailableView("No Transactions", systemImage: "tray", description: Text("Add the first entry for this account.")) }
            }
            .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.first { $0.id == id } ?? LedgerCategory(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F") }
}

struct CategorySegmentData: Identifiable {
    let category: LedgerCategory
    let value: Double
    var id: LedgerCategoryID { category.id }
}

private struct MiniPieChart: View {
    let segments: [CategorySegmentData]
    var height: CGFloat? = 45

    var body: some View {
        if let height {
            chartBody(diameter: height)
                .frame(height: height)
        } else {
            GeometryReader { proxy in
                let diameter = max(24, min(proxy.size.width, proxy.size.height))
                chartBody(diameter: diameter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func chartBody(diameter: CGFloat) -> some View {
        if segments.isEmpty {
            Image(systemName: "chart.pie")
                .font(.system(size: max(16, diameter * 0.58)))
                .foregroundStyle(.secondary)
                .frame(width: diameter, height: diameter)
        } else {
            Chart(segments) { segment in
                SectorMark(angle: .value("Spent", segment.value), innerRadius: .ratio(0.55), angularInset: 1.0)
                    .foregroundStyle(Color(hex: segment.category.colorHex))
            }
            .chartLegend(.hidden)
            .frame(width: diameter, height: diameter)
        }
    }
}

private struct SixMonthTrendChart: View {
    @EnvironmentObject private var privacy: PrivacyController
    let buckets: [AnalyticsBucket]

    var body: some View {
        Chart(buckets) { bucket in
            AreaMark(x: .value("Period", bucket.label),
                     y: .value("Amount", privacy.isLocked ? 0 : bucket.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.blue.opacity(0.10))
            LineMark(x: .value("Period", bucket.label),
                     y: .value("Amount", privacy.isLocked ? 0 : bucket.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

private struct MiniActivityChart: View {
    @EnvironmentObject private var privacy: PrivacyController
    let buckets: [AnalyticsBucket]
    var height: CGFloat? = 45

    var body: some View {
        let maximum = max(buckets.map(\.value).max() ?? 1, 1)
        if let height {
            let barMax = max(4, height - 14)
            bars(maximum: maximum, barMax: barMax)
                .frame(height: height)
        } else {
            GeometryReader { proxy in
                let barMax = max(8, proxy.size.height - 16)
                bars(maximum: maximum, barMax: barMax)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func bars(maximum: Double, barMax: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(buckets) { bucket in
                VStack(spacing: 2) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LedgerPalette.coral.gradient)
                        .frame(height: privacy.isLocked ? 4 : max(4, barMax * bucket.value / maximum))
                    Text(bucket.label.prefix(2))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct OverviewMetricDetailSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    let metric: OverviewMetricKind
    let selectedAccountID: UUID?
    let onExpand: () -> Void

    private var summary: AnalyticsSummary {
        switch metric {
        case .todayExpensePie:
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? .now
            return LedgerCalculations.analytics(store.state, range: .week, type: .expense, accountID: selectedAccountID, customRange: start...end)
        case .weekExpensePie, .weeklyActivity:
            return LedgerCalculations.analytics(store.state, range: .week, type: .expense, accountID: selectedAccountID)
        case .sixMonthTrend:
            return LedgerCalculations.analytics(store.state, range: .sixMonths, type: .expense, accountID: selectedAccountID)
        case .budget:
            return LedgerCalculations.analytics(store.state, range: .month, type: .expense, accountID: selectedAccountID)
        }
    }

    private var segments: [CategorySegmentData] {
        let cats = store.state.categories.filter { $0.kind == .expense }
        return cats.compactMap { cat in
            let val = summary.categoryTotals[cat.id, default: 0]
            guard val.isFinite, val > 0 else { return nil }
            return CategorySegmentData(category: cat, value: val)
        }
    }

    private var segmentTotal: Double { segments.reduce(0) { $0 + $1.value } }

    private var chartBuckets: [AnalyticsBucket] {
        if metric == .weeklyActivity {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: .now)
            let weekday = calendar.component(.weekday, from: startOfToday)
            let startOfWeek = calendar.date(byAdding: .day, value: -(weekday - 1), to: startOfToday) ?? startOfToday
            return summary.buckets.enumerated().map { offset, bucket in
                let date = calendar.date(byAdding: .day, value: offset, to: startOfWeek) ?? .now
                let label = date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
                return AnalyticsBucket(id: bucket.id, label: label, value: bucket.value)
            }
        }
        return summary.buckets
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    chartCard
                    if metric == .todayExpensePie || metric == .weekExpensePie {
                        breakdownCard
                    } else {
                        statsCard
                    }
                }
                .padding()
            }
            .background(LedgerBackground())
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .accessibilityLabel("Done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onExpand()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel("Expand to Analytics")
                }
            }
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(metric.title).font(.headline)
                    Text(summary.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SensitiveMoneyText(amount: summary.total, currency: store.state.settings.baseCurrency, compact: true)
                    .font(.title3.bold())
            }

            if metric == .todayExpensePie || metric == .weekExpensePie {
                if privacy.isLocked || segments.isEmpty {
                    ContentUnavailableView("No Expense", systemImage: "chart.pie")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Chart(segments) { segment in
                        SectorMark(angle: .value("Spent", segment.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(Color(hex: segment.category.colorHex))
                            .cornerRadius(4)
                    }
                    .chartLegend(.hidden)
                    .frame(height: 200)
                }
            } else if metric == .sixMonthTrend {
                SixMonthTrendChart(buckets: chartBuckets)
                    .chartXAxis {
                        AxisMarks(values: chartBuckets.map(\.label)) {
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 200)
            } else {
                Chart(chartBuckets) { bucket in
                    BarMark(x: .value("Period", bucket.label), y: .value("Amount", privacy.isLocked ? 0 : bucket.value))
                        .foregroundStyle(LedgerPalette.coral.gradient)
                        .cornerRadius(6)
                }
                .chartYAxis(.hidden)
                .frame(height: 200)
            }
        }
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categories").font(.headline)
            LazyVStack(spacing: 8) {
                ForEach(segments) { segment in
                    HStack {
                        Circle().fill(Color(hex: segment.category.colorHex)).frame(width: 10, height: 10)
                        Text(segment.category.name).font(.subheadline)
                        Spacer()
                        SensitiveMoneyText(amount: segment.value, currency: store.state.settings.baseCurrency, compact: true)
                            .font(.subheadline.bold())
                        Text(percent(segment.category.id))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statsCard: some View {
        HStack(spacing: 10) {
            MetricCard("Average") { SensitiveMoneyText(amount: summary.average, currency: store.state.settings.baseCurrency, compact: true).font(.headline.bold()).minimumScaleFactor(0.6).lineLimit(1) }
            MetricCard("Maximum") { SensitiveMoneyText(amount: summary.maximum, currency: store.state.settings.baseCurrency, compact: true).font(.headline.bold()).minimumScaleFactor(0.6).lineLimit(1) }
            MetricCard("Minimum") { SensitiveMoneyText(amount: summary.minimum, currency: store.state.settings.baseCurrency, compact: true).font(.headline.bold()).minimumScaleFactor(0.6).lineLimit(1) }
        }
    }

    private func percent(_ categoryID: LedgerCategoryID) -> String {
        guard !privacy.isLocked, segmentTotal > 0 else { return "0%" }
        let value = summary.categoryTotals[categoryID, default: 0]
        let percentage = (value / segmentTotal * 100).rounded()
        return "\(Int(percentage))%"
    }
}

/// Keep presentation state separate from Overview's analytics render path.
private struct OverviewAccountPickerButton: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selectedAccountID: UUID?
    var layout: AccountCardLayout = .horizontal
    @State private var showingPicker = false
    @State private var accounts: [AccountViewModel] = []
    @State private var cards: [OverviewPickerCard] = [OverviewPickerCard(account: nil)]
    @State private var portfolioBalance: Double = 0

    var body: some View {
        Button { showingPicker = true } label: {
            AccountCardView(account: accounts.first { $0.id == selectedAccountID },
                            portfolioBalance: portfolioBalance,
                            baseCurrency: store.state.settings.baseCurrency,
                            layout: layout,
                            showAccountName: layout != .portrait)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingPicker) {
            AccountPickerView(selectedAccountID: $selectedAccountID, cards: cards,
                              portfolioBalance: portfolioBalance,
                              baseCurrency: store.state.settings.baseCurrency)
        }
        .task(id: store.state) {
            let state = store.state
            // Balance calculations and card metadata are prepared before presentation.
            let prepared = await Task.detached(priority: .userInitiated) {
                LedgerCalculations.accountViews(state)
            }.value
            guard !Task.isCancelled else { return }
            accounts = prepared
            cards = [OverviewPickerCard(account: nil)] + prepared.map { OverviewPickerCard(account: $0) }
            portfolioBalance = prepared.reduce(0) {
                $0 + LedgerCalculations.convert($1.balance, from: $1.account.currency,
                                                to: state.settings.baseCurrency, rates: state.settings.rates)
            }
            // Publish lightweight cards first. Cold artwork never delays sheet opening.
            for account in prepared {
                guard !Task.isCancelled else { return }
                _ = await CardArtwork.load(account.account.cardImageData)
            }
        }
    }
}

/// Stable, lightweight snapshot in persisted account order; no decoding in init.
private struct OverviewPickerCard: Identifiable {
    let account: AccountViewModel?
    var id: String { account?.id.uuidString ?? "all-accounts" }
}

private struct AccountPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedAccountID: UUID?
    let cards: [OverviewPickerCard]
    let portfolioBalance: Double
    let baseCurrency: CurrencyCode
    @State private var centeredID: String?

    init(selectedAccountID: Binding<UUID?>, cards: [OverviewPickerCard],
         portfolioBalance: Double, baseCurrency: CurrencyCode) {
        _selectedAccountID = selectedAccountID
        self.cards = cards
        self.portfolioBalance = portfolioBalance
        self.baseCurrency = baseCurrency
        _centeredID = State(initialValue: selectedAccountID.wrappedValue?.uuidString ?? "all-accounts")
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let viewportWidth = geometry.size.width
                let reducesMotion = reduceMotion
                let cardWidth = viewportWidth * 0.66
                let cardHeight = cardWidth * (85.60 / 53.98)
                let cardSpacing: CGFloat = -8
                let sideInset = (viewportWidth - cardWidth) / 2

                VStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(cards) { card in
                            Button {
                                if centeredID == card.id {
                                    selectedAccountID = card.account?.id
                                    dismiss()
                                } else {
                                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                        centeredID = card.id
                                    }
                                }
                            } label: {
                                AccountCardView(
                                    account: card.account,
                                    portfolioBalance: portfolioBalance,
                                    baseCurrency: baseCurrency,
                                    layout: .portrait,
                                    showAccountName: true
                                )
                                .frame(width: cardWidth, height: cardHeight)
                            }
                            .buttonStyle(.plain)
                            .visualEffect { content, proxy in
                                let progress = (proxy.frame(in: .scrollView(axis: .horizontal)).midX - viewportWidth / 2) / (cardWidth + cardSpacing)
                                // Snap to an exact sharp, upright state near the center.
                                // Only background cards receive blur and dimming.
                                let distance = abs(progress)
                                let normalizedDistance = min(2.0, max(0, (distance - 0.15) / 0.85))
                                let magnitude = min(1.0, normalizedDistance)
                                let fartherDistance = max(0, normalizedDistance - 1)
                                let fanProgress = (progress < 0 ? -1.0 : 1.0) * magnitude
                                return content
                                    .rotationEffect(.degrees(reducesMotion ? 0 : Double(fanProgress * 6)), anchor: .bottom)
                                    .scaleEffect(1 - magnitude * 0.08)
                                    .blur(radius: magnitude * 4 + fartherDistance * 2)
                                    .opacity(1 - Double(magnitude) * 0.3 - Double(fartherDistance) * 0.2)
                                    .offset(y: reducesMotion ? 0 : magnitude * 16)
                            }
                            .zIndex(centeredID == card.id ? 1 : 0)
                            .accessibilityAddTraits(centeredID == card.id ? .isSelected : [])
                            .id(card.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 32)
                }
                .contentMargins(.horizontal, sideInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centeredID, anchor: .center)
                .scrollClipDisabled()
                .frame(height: cardHeight + 64)

                if cards.allSatisfy({ $0.account == nil }) {
                    Text("No accounts added yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .background(LedgerBackground())
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(LedgerPalette.primaryAction(for: colorScheme))
                    .accessibilityLabel("Done")
                }
            }
        }
        .onChange(of: cards.map(\.id)) { _, ids in
            if let centeredID, !ids.contains(centeredID) {
                self.centeredID = "all-accounts"
            }
        }
    }
}
