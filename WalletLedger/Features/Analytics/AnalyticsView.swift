import Charts
import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var section: AppSection
    @State private var range: AnalyticsRange = .week
    @State private var selectedCategories = Set<LedgerCategoryID>()
    private var summary: AnalyticsSummary { LedgerCalculations.analytics(store.state, range: range, categories: selectedCategories) }

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
                    ForEach(store.state.categories) { category in Toggle(category.name, isOn: Binding(get: { selectedCategories.contains(category.id) }, set: { enabled in if enabled { selectedCategories.insert(category.id) } else { selectedCategories.remove(category.id) } })) }
                    if !selectedCategories.isEmpty { Button("All Categories") { selectedCategories.removeAll() } }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                AppSectionMenu(selection: $section)
            }
        }
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
            }.chartYAxis(.hidden).frame(height: 245)
        }.padding(18).ledgerGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var stats: some View {
        HStack(spacing: 10) {
            stat("Average", summary.average); stat("Maximum", summary.maximum); stat("Minimum", summary.minimum)
        }
    }
    private func stat(_ title: String, _ value: Double) -> some View { MetricCard(title) { Text(LedgerFormat.money(value, currency: store.state.settings.baseCurrency, compact: true)).font(.headline.bold()).minimumScaleFactor(0.6).lineLimit(1) } }
    private func percent(_ category: LedgerCategoryID) -> String { summary.total > 0 ? "\(Int((summary.categoryTotals[category, default: 0] / summary.total * 100).rounded()))%" : "0%" }
}
