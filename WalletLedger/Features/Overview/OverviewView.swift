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
                    MiniActivityChart(buckets: sixMonthsSummary.buckets)
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

private struct CardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct AccountPickerView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    @Binding var selectedAccountID: UUID?
    @State private var workingOrder: [UUID] = []
    @State private var draggedID: UUID? = nil
    @State private var sourceIndex: Int? = nil
    @State private var targetIndex: Int? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var isSettling = false
    @State private var cardHeight: CGFloat = 200
    private let stackSpacing: CGFloat = -36

    private var step: CGFloat {
        max(cardHeight + stackSpacing, 60)
    }

    private var orderedAccounts: [AccountViewModel] {
        let map = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0) })
        let ordered = workingOrder.compactMap { map[$0] }
        if ordered.count == store.accounts.count {
            return ordered
        }
        return store.accounts
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: stackSpacing) {
                    Button {
                        if draggedID == nil && !isSettling {
                            selectedAccountID = nil
                            dismiss()
                        }
                    } label: {
                        AccountCardView(account: nil, portfolioBalance: LedgerCalculations.portfolioBalance(store.state), baseCurrency: store.state.settings.baseCurrency, compact: true)
                    }
                    .buttonStyle(.plain)
                    .zIndex(0)

                    ForEach(Array(orderedAccounts.enumerated()), id: \.element.id) { index, item in
                        cardView(for: item, index: index)
                    }
                }
                .padding()
            }
            .coordinateSpace(name: "AccountStackSpace")
            .scrollDisabled(draggedID != nil)
            .background(LedgerBackground())
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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
            }
        }
        .onAppear {
            workingOrder = store.accounts.map(\.id)
        }
        .onChange(of: store.accounts) { _, newAccounts in
            let newIDs = newAccounts.map(\.id)
            if Set(workingOrder) != Set(newIDs) {
                workingOrder = newIDs
            }
        }
        .onPreferenceChange(CardHeightPreferenceKey.self) { height in
            if draggedID == nil, height > 50 {
                cardHeight = height
            }
        }
    }

    private func cardOffset(for index: Int, isDragging: Bool) -> CGFloat {
        if isDragging {
            return dragTranslation
        }
        guard let s = sourceIndex, let t = targetIndex else { return 0 }
        if s < t {
            if index > s && index <= t {
                return -step
            }
        } else if s > t {
            if index >= t && index < s {
                return step
            }
        }
        return 0
    }

    @ViewBuilder
    private func cardView(for item: AccountViewModel, index: Int) -> some View {
        let isDragging = draggedID == item.id
        let otherOffset = cardOffset(for: index, isDragging: false)
        let effectiveOffset = isDragging ? dragTranslation : otherOffset

        AccountCardView(account: item, baseCurrency: store.state.settings.baseCurrency, compact: true)
            .background(
                Group {
                    if index == 0 {
                        GeometryReader { geo in
                            Color.clear.preference(key: CardHeightPreferenceKey.self, value: geo.size.height)
                        }
                    }
                }
            )
            .scaleEffect(isDragging ? 1.03 : 1.0)
            .shadow(color: .black.opacity(isDragging ? 0.35 : 0.08), radius: isDragging ? 20 : 8, y: isDragging ? 10 : 3)
            .offset(y: effectiveOffset)
            .zIndex(isDragging ? 1000 : Double(index + 1))
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: isDragging)
            .animation(isDragging ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.86), value: otherOffset)
            .contentShape(Rectangle())
            .gesture(dragGesture(for: item, index: index))
            .onTapGesture {
                if draggedID == nil && !isSettling {
                    selectedAccountID = item.id
                    dismiss()
                }
            }
    }

    private func dragGesture(for item: AccountViewModel, index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(coordinateSpace: .named("AccountStackSpace")))
            .onChanged { value in
                guard !isSettling else { return }
                switch value {
                case .first(true):
                    if draggedID == nil {
                        draggedID = item.id
                        sourceIndex = index
                        targetIndex = index
                        dragTranslation = 0
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                case .second(true, let drag):
                    if draggedID == nil {
                        draggedID = item.id
                        sourceIndex = index
                        targetIndex = index
                        dragTranslation = 0
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    guard let drag = drag, let s = sourceIndex else { return }
                    dragTranslation = drag.translation.height

                    let rawDelta = Int((drag.translation.height / step).rounded())
                    let count = orderedAccounts.count
                    let newTarget = min(max(s + rawDelta, 0), count - 1)
                    if newTarget != targetIndex {
                        targetIndex = newTarget
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                guard let s = sourceIndex, let t = targetIndex, draggedID == item.id else {
                    draggedID = nil
                    sourceIndex = nil
                    targetIndex = nil
                    dragTranslation = 0
                    return
                }

                isSettling = true
                let targetSlotOffset = CGFloat(t - s) * step
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                    dragTranslation = targetSlotOffset
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    if s != t && s < workingOrder.count && t < workingOrder.count {
                        var newOrder = workingOrder
                        let moved = newOrder.remove(at: s)
                        newOrder.insert(moved, at: t)
                        workingOrder = newOrder
                        store.setAccountOrder(newOrder)
                    }
                    draggedID = nil
                    sourceIndex = nil
                    targetIndex = nil
                    dragTranslation = 0
                    isSettling = false
                }
            }
    }
}
