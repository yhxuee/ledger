import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @EnvironmentObject private var privacy: PrivacyController
    @Binding var section: AppSection
    @Binding var selectedAccountID: UUID?
    @State private var showAccountPicker = false
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) { hero.frame(minWidth: 320, maxWidth: 520); metrics.frame(minWidth: 360, maxWidth: .infinity) }
                VStack(spacing: 16) { hero; metrics }
            }
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
        .sheet(isPresented: $showAccountPicker) { AccountPickerView(selectedAccountID: $selectedAccountID) }
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

    private var hero: some View {
        Button { showAccountPicker = true } label: {
            AccountCardView(account: selected, portfolioBalance: LedgerCalculations.portfolioBalance(store.state), baseCurrency: store.state.settings.baseCurrency)
        }.buttonStyle(.plain)
    }

    private var metrics: some View {
        let configured = preferences.value.overviewMetrics.prefix(2)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(configured)) { kind in
                metricCard(for: kind)
            }
        }
    }

    @ViewBuilder
    private func metricCard(for kind: OverviewMetricKind) -> some View {
        switch kind {
        case .weeklyActivity:
            Button { activeDetailMetric = .weeklyActivity } label: {
                MetricCard("Weekly Activity") {
                    MiniActivityChart(buckets: weeklySummary.buckets)
                    SensitiveMoneyText(amount: weeklySummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font(.headline.bold())
                }
                .frame(minHeight: 146)
            }
            .buttonStyle(.plain)

        case .budget:
            Button { showingBudgetDetail = true } label: {
                MetricCard("Budget / Remain") {
                    SensitiveMoneyText(amount: usage.budget - usage.spent, currency: usageCurrency, maxIntegerDigits: 6)
                        .font(.title2.bold())
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    ProgressView(value: privacy.isLocked ? 0 : min(max(usage.ratio, 0), 1))
                        .tint(usage.ratio > 1 ? .red : LedgerPalette.coral)
                    SensitiveValueText("\(Int(usage.ratio * 100))% of monthly budget used", maskLength: 8)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 146)
            }
            .buttonStyle(.plain)

        case .todayExpensePie:
            Button { activeDetailMetric = .todayExpensePie } label: {
                MetricCard("Today Expense") {
                    MiniPieChart(segments: categorySegments(from: todaySummary))
                    SensitiveMoneyText(amount: todaySummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font(.headline.bold())
                }
                .frame(minHeight: 146)
            }
            .buttonStyle(.plain)

        case .weekExpensePie:
            Button { activeDetailMetric = .weekExpensePie } label: {
                MetricCard("This Week Expense") {
                    MiniPieChart(segments: categorySegments(from: weeklySummary))
                    SensitiveMoneyText(amount: weeklySummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font(.headline.bold())
                }
                .frame(minHeight: 146)
            }
            .buttonStyle(.plain)

        case .sixMonthTrend:
            Button { activeDetailMetric = .sixMonthTrend } label: {
                MetricCard("6M Trends") {
                    SixMonthTrendChart(buckets: sixMonthsSummary.buckets)
                        .chartXAxis(.hidden)
                        .frame(height: 45)
                    SensitiveMoneyText(amount: sixMonthsSummary.total, currency: store.state.settings.baseCurrency, compact: true)
                        .font(.headline.bold())
                }
                .frame(minHeight: 146)
            }
            .buttonStyle(.plain)
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
    var body: some View {
        if segments.isEmpty {
            Image(systemName: "chart.pie")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(height: 45)
        } else {
            Chart(segments) { segment in
                SectorMark(angle: .value("Spent", segment.value), innerRadius: .ratio(0.55), angularInset: 1.0)
                    .foregroundStyle(Color(hex: segment.category.colorHex))
            }
            .chartLegend(.hidden)
            .frame(height: 45)
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
    var body: some View {
        let maximum = max(buckets.map(\.value).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(buckets) { bucket in
                VStack(spacing: 3) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LedgerPalette.coral.gradient)
                        .frame(height: privacy.isLocked ? 4 : max(4, 30 * bucket.value / maximum))
                    Text(bucket.label.prefix(2))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }.frame(height: 45)
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

/// A snapshot in persisted account order. Images are decoded when accounts change,
/// never from the per-frame carousel effect.
private struct OverviewPickerCard: Identifiable {
    let account: AccountViewModel?
    let artwork: CardArtwork?
    var id: String { account?.id.uuidString ?? "all-accounts" }

    @MainActor init(account: AccountViewModel?) {
        self.account = account
        self.artwork = CardArtwork.load(account?.account.cardImageData)
    }
}

private struct AccountPickerView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedAccountID: UUID?
    @State private var cards: [OverviewPickerCard] = []
    @State private var centeredID: String?
    @State private var portfolioBalance: Double = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let viewportWidth = geometry.size.width
                let reducesMotion = reduceMotion
                let cardWidth = viewportWidth * 0.66
                let cardHeight = cardWidth * (85.60 / 53.98)
                let cardSpacing: CGFloat = -8
                let sideInset = (viewportWidth - cardWidth) / 2

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
                                OverviewPortraitAccountCard(
                                    card: card,
                                    portfolioBalance: portfolioBalance,
                                    baseCurrency: store.state.settings.baseCurrency
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
                .frame(maxHeight: .infinity, alignment: .center)
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
        .onAppear {
            refreshCards(store.accounts)
            centeredID = selectedAccountID?.uuidString ?? "all-accounts"
        }
        .onChange(of: store.accounts) { _, accounts in refreshCards(accounts) }
        .onChange(of: store.state.settings) { _, _ in
            portfolioBalance = LedgerCalculations.portfolioBalance(store.state)
        }
    }

    private func refreshCards(_ accounts: [AccountViewModel]) {
        portfolioBalance = LedgerCalculations.portfolioBalance(store.state)
        // accountViews preserves state.accounts order; this picker never writes order.
        cards = [OverviewPickerCard(account: nil)] + accounts.map { OverviewPickerCard(account: $0) }
        if let centeredID, !cards.contains(where: { $0.id == centeredID }) {
            self.centeredID = "all-accounts"
        }
    }
}

/// Dedicated portrait layout; the normal Overview hero card remains horizontal.
private struct OverviewPortraitAccountCard: View {
    let card: OverviewPickerCard
    let portfolioBalance: Double
    let baseCurrency: CurrencyCode

    private var account: LedgerAccount? { card.account?.account }
    private var style: CardStyle {
        account?.cardStyle ?? .init(startHex: "F2C7D8", endHex: "B9D9F1")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(account?.logo ?? "ALL")
                    .font(.headline.bold())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.32), in: Capsule())
                Text(account?.name ?? "Net Worth")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: account?.type.symbol ?? "wallet.bifold.fill")
                    .font(.subheadline)
            }
            .cardInformationRegion()
            Spacer(minLength: 12)
            SensitiveMoneyText(amount: card.account?.balance ?? portfolioBalance,
                               currency: account?.currency ?? baseCurrency,
                               maxIntegerDigits: 4)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .cardInformationRegion()
            if let account {
                AccountCardMetadata(account: account)
                    .cardInformationRegion()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardArtwork(card.artwork, fallback: LinearGradient(
            colors: [Color(hex: style.startHex), Color(hex: style.endHex)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .accessibilityElement(children: .combine)
    }
}
