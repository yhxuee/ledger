import Charts
import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var range: AnalyticsRange = .week
    @State private var selectedCategories = Set<LedgerCategoryID>()
    @State private var selectedAccounts = Set<UUID>()
    @State private var showingRangePicker = false
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var rangeEnd = Date.now
    @State private var hasCustomRange = false
    private var summary: AnalyticsSummary { LedgerCalculations.analytics(store.state, range: range, categories: selectedCategories, accountIDs: selectedAccounts, customRange: hasCustomRange ? rangeStart...rangeEnd : nil) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) { ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                categoryChart
                spendingChart
                stats
            }.padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Analytics")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Menu { ForEach(store.state.categories) { category in Toggle(category.name, isOn: categoryBinding(category.id)) } } label: { Label("Expense Categories", systemImage: "tag") }
                    Menu { ForEach(store.accounts) { item in Toggle(item.account.name, isOn: accountBinding(item.id)) } } label: { Label("Accounts", systemImage: "wallet.bifold") }
                    Divider()
                    Button { showingRangePicker = true } label: { Label("Custom Range", systemImage: "calendar.badge.clock") }
                    if filtersActive { Button("Clear Filters", role: .destructive, action: clearFilters) }
                } label: { Label("Filter", systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                LedgerBookMenu()
            }
        }
        .sheet(isPresented: $showingRangePicker) {
            DateRangePickerSheet(start: rangeStart, end: rangeEnd) { start, end in rangeStart = start; rangeEnd = end; hasCustomRange = true }
        }
        .onChange(of: store.activeBookID) { _, _ in clearFilters() }
    }

    private var categoryChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { VStack(alignment: .leading) { Text("Category Breakdown").font(.headline); Text(summary.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(LedgerFormat.money(summary.total, currency: store.state.settings.baseCurrency, compact: true)).font(.title3.bold()) }
            Chart(LedgerCategoryID.allCases) { category in
                SectorMark(angle: .value("Spent", summary.categoryTotals[category, default: 0]), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(LedgerPalette.category(category)).cornerRadius(4)
            }.chartLegend(.hidden).frame(height: 190)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                ForEach(store.state.categories) { category in HStack { Circle().fill(LedgerPalette.category(category.id)).frame(width: 8, height: 8); Text(category.name).font(.caption); Spacer(); Text(percent(category.id)).font(.caption.bold()) } }
            }
        }.padding(18).ledgerGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var spendingChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spending").font(.headline)
            Chart(summary.buckets) { bucket in
                BarMark(x: .value("Period", bucket.label), y: .value("Amount", bucket.value)).foregroundStyle(LedgerPalette.coral.gradient).cornerRadius(6)
                    .annotation(position: .top) { Text(LedgerFormat.money(bucket.value, currency: store.state.settings.baseCurrency, compact: true)).font(.caption2.weight(bucket.value == summary.maximum || bucket.value == summary.minimum ? .bold : .regular)).foregroundStyle(.secondary) }
            }
            .chartXAxis {
                AxisMarks(values: axisLabels) { _ in
                    AxisTick()
                    AxisValueLabel(collisionResolution: .greedy).font(.caption2)
                }
            }
            .chartYAxis(.hidden).frame(height: 245)
        }.padding(18).ledgerGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var stats: some View {
        HStack(spacing: 10) {
            stat("Average", summary.average); stat("Maximum", summary.maximum); stat("Minimum", summary.minimum)
        }
    }
    private func stat(_ title: String, _ value: Double) -> some View { MetricCard(title) { Text(LedgerFormat.money(value, currency: store.state.settings.baseCurrency, compact: true)).font(.headline.bold()).minimumScaleFactor(0.6).lineLimit(1) } }
    private func percent(_ category: LedgerCategoryID) -> String { summary.total > 0 ? "\(Int((summary.categoryTotals[category, default: 0] / summary.total * 100).rounded()))%" : "0%" }
    private var filtersActive: Bool { !selectedCategories.isEmpty || !selectedAccounts.isEmpty || hasCustomRange }
    private var axisLabels: [String] {
        let labels = summary.buckets.map(\.label)
        guard labels.count > 8 else { return labels }
        let stride = (labels.count + 5) / 6
        return labels.enumerated().compactMap { $0.offset.isMultiple(of: stride) ? $0.element : nil }
    }
    private func categoryBinding(_ id: LedgerCategoryID) -> Binding<Bool> { Binding(get: { selectedCategories.contains(id) }, set: { enabled in if enabled { selectedCategories.insert(id) } else { selectedCategories.remove(id) } }) }
    private func accountBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { selectedAccounts.contains(id) }, set: { enabled in if enabled { selectedAccounts.insert(id) } else { selectedAccounts.remove(id) } }) }
    private func clearFilters() { selectedCategories.removeAll(); selectedAccounts.removeAll(); hasCustomRange = false }
}
