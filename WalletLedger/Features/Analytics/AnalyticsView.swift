import Charts
import SwiftUI

private enum AnalyticsPage: Hashable {
    case expense, income, tax
}

struct AnalyticsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @State private var activePage: AnalyticsPage = .expense
    private var activeType: LedgerTransactionType { activePage == .income ? .income : .expense }
    @State private var taxExpenseCategories = Set<LedgerCategoryID>()
    @State private var taxIncomeCategories = Set<LedgerCategoryID>()
    @State private var taxAccounts = Set<UUID>()
    @State private var range: AnalyticsRange = .week
    @State private var selectedExpenseCategories = Set<LedgerCategoryID>()
    @State private var selectedIncomeCategories = Set<LedgerCategoryID>()
    @State private var selectedAccounts = Set<UUID>()
    @State private var showingRangePicker = false
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var rangeEnd = Date.now
    @State private var hasCustomRange = false

    private var currentCategories: [LedgerCategory] {
        store.state.categories.filter { $0.kind == (activeType == .income ? .income : .expense) }
    }

    private func summary(for type: LedgerTransactionType) -> AnalyticsSummary {
        let cats = type == .income ? selectedIncomeCategories : selectedExpenseCategories
        return LedgerCalculations.analytics(
            store.state,
            range: range,
            type: type,
            categories: cats,
            accountIDs: selectedAccounts,
            customRange: hasCustomRange ? rangeStart...rangeEnd : nil
        )
    }

    private struct CategorySegment: Identifiable {
        let category: LedgerCategory
        let value: Double
        var id: LedgerCategoryID { category.id }
    }

    private func categorySegments(for type: LedgerTransactionType, summary: AnalyticsSummary) -> [CategorySegment] {
        let cats = store.state.categories.filter { $0.kind == (type == .income ? .income : .expense) }
        return cats.compactMap { category in
            let value = summary.categoryTotals[category.id, default: 0]
            guard value.isFinite, value > 0 else { return nil }
            return CategorySegment(category: category, value: value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Type", selection: $activePage) {
                Text("Expense").tag(AnalyticsPage.expense)
                Text("Income").tag(AnalyticsPage.income)
                Text("Tax").tag(AnalyticsPage.tax)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            TabView(selection: $activePage) {
                pageView(for: .expense)
                    .tag(AnalyticsPage.expense)
                pageView(for: .income)
                    .tag(AnalyticsPage.income)
                TaxAnalyticsPage(range: $range, customRange: hasCustomRange ? rangeStart...rangeEnd : nil,
                                 categories: taxExpenseCategories.union(taxIncomeCategories), accountIDs: taxAccounts)
                    .tag(AnalyticsPage.tax)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(LedgerBackground())
        .navigationTitle("Analytics")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if activePage == .tax {
                        Menu("Expense Categories") {
                            ForEach(store.state.categories.filter { $0.kind == .expense }) { category in
                                Toggle(category.name, isOn: taxCategoryBinding(category.id, income: false))
                            }
                        }
                        Menu("Income Categories") {
                            ForEach(store.state.categories.filter { $0.kind == .income }) { category in
                                Toggle(category.name, isOn: taxCategoryBinding(category.id, income: true))
                            }
                        }
                    } else {
                    Menu {
                        ForEach(currentCategories) { category in
                            Toggle(category.name, isOn: categoryBinding(category.id, for: activeType))
                        }
                    } label: {
                        Label(activeType == .income ? "Income Categories" : "Expense Categories", systemImage: "tag")
                    }
                    }
                    Menu {
                        ForEach(store.accounts) { item in
                            Toggle(item.account.name, isOn: accountBinding(item.id))
                        }
                    } label: {
                        Label("Accounts", systemImage: "wallet.bifold")
                    }
                    Divider()
                    Button {
                        showingRangePicker = true
                    } label: {
                        Label("Custom Range", systemImage: "calendar.badge.clock")
                    }
                    if filtersActive {
                        Button("Clear Filters", role: .destructive, action: clearFilters)
                    }
                } label: {
                    Label("Filter", systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                LedgerBookMenu()
            }
        }
        .sheet(isPresented: $showingRangePicker) {
            DateRangePickerSheet(start: rangeStart, end: rangeEnd) { start, end in
                rangeStart = start
                rangeEnd = end
                hasCustomRange = true
            }
        }
        .onChange(of: store.activeBookID) { _, _ in
            selectedExpenseCategories.removeAll(); selectedIncomeCategories.removeAll(); selectedAccounts.removeAll()
            taxExpenseCategories.removeAll(); taxIncomeCategories.removeAll(); taxAccounts.removeAll()
            hasCustomRange = false
        }
        .onReceive(store.$requestedAnalyticsType) { newType in
            if let newType {
                withAnimation(.snappy) { activePage = newType == .income ? .income : .expense }
                store.requestedAnalyticsType = nil
            }
        }
        .onReceive(store.$requestedAnalyticsRange) { newRange in
            if let newRange {
                range = newRange
                hasCustomRange = false
                store.requestedAnalyticsRange = nil
            }
        }
        .onReceive(store.$requestedAnalyticsCustomRange) { newCustomRange in
            if let newCustomRange {
                rangeStart = newCustomRange.lowerBound
                rangeEnd = newCustomRange.upperBound
                hasCustomRange = true
                store.requestedAnalyticsCustomRange = nil
            }
        }
    }

    private func pageView(for type: LedgerTransactionType) -> some View {
        let sum = summary(for: type)
        let segments = categorySegments(for: type, summary: sum)
        let segmentTotal = segments.reduce(0) { $0 + $1.value }
        let categories = store.state.categories.filter { $0.kind == (type == .income ? .income : .expense) }

        return ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                categoryChart(type: type, summary: sum, segments: segments, segmentTotal: segmentTotal, categories: categories)
                activityChart(type: type, summary: sum)
                stats(summary: sum)
            }
            .padding()
        }
    }

    private func categoryChart(type: LedgerTransactionType, summary: AnalyticsSummary, segments: [CategorySegment], segmentTotal: Double, categories: [LedgerCategory]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Category Breakdown").font(.headline)
                    Text(summary.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SensitiveMoneyText(amount: summary.total, currency: store.state.settings.baseCurrency, compact: true)
                    .font(.title3.bold())
            }
            if privacy.isLocked || segments.isEmpty {
                ContentUnavailableView(type == .income ? "No Income" : "No Expense", systemImage: "chart.pie")
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                Chart(segments) { segment in
                    SectorMark(angle: .value(type == .income ? "Income" : "Spent", segment.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(Color(hex: segment.category.colorHex))
                        .cornerRadius(4)
                }
                .chartLegend(.hidden)
                .frame(height: 190)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                ForEach(categories) { cat in
                    HStack {
                        Circle().fill(Color(hex: cat.colorHex)).frame(width: 8, height: 8)
                        Text(cat.name).font(.caption)
                        Spacer()
                        Text(percent(cat.id, summary: summary, segmentTotal: segmentTotal)).font(.caption.bold())
                    }
                }
            }
        }
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func activityChart(type: LedgerTransactionType, summary: AnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(type == .income ? "Income" : "Expense").font(.headline)
            GeometryReader { geometry in
                let showAllLabels = allValueLabelsFit(width: geometry.size.width, summary: summary)
                let extrema = extremaIDs(for: summary)
                Chart(summary.buckets) { bucket in
                    BarMark(x: .value("Period", bucket.label), y: .value("Amount", privacy.isLocked ? 0 : bucket.value))
                        .foregroundStyle((type == .income ? LedgerPalette.emerald : LedgerPalette.coral).gradient)
                        .cornerRadius(6)
                        .annotation(position: .top) {
                            if showAllLabels || extrema.contains(bucket.id) {
                                SensitiveValueText(valueLabel(bucket.value), maskLength: 5)
                                    .environmentObject(privacy)
                                    .font(.caption2.weight(extrema.contains(bucket.id) ? .bold : .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
                .chartXAxis {
                    AxisMarks(values: axisLabels(for: summary)) { _ in
                        AxisTick()
                        AxisValueLabel(collisionResolution: .greedy).font(.caption2)
                    }
                }
                .chartYAxis(.hidden)
            }
            .frame(height: 245)
        }
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func stats(summary: AnalyticsSummary) -> some View {
        HStack(spacing: 10) {
            stat("Average", summary.average)
            stat("Maximum", summary.maximum)
            stat("Minimum", summary.minimum)
        }
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        MetricCard(title) {
            SensitiveMoneyText(amount: value, currency: store.state.settings.baseCurrency, compact: true)
                .font(.headline.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private func percent(_ categoryID: LedgerCategoryID, summary: AnalyticsSummary, segmentTotal: Double) -> String {
        guard !privacy.isLocked else { return "***" }
        let value = summary.categoryTotals[categoryID, default: 0]
        guard value.isFinite, value > 0, segmentTotal.isFinite, segmentTotal > 0 else { return "0%" }
        let percentage = (value / segmentTotal * 100).rounded()
        guard percentage.isFinite else { return "0%" }
        return "\(Int(percentage))%"
    }

    private var filtersActive: Bool {
        if activePage == .tax {
            return !taxExpenseCategories.isEmpty || !taxIncomeCategories.isEmpty || !taxAccounts.isEmpty || hasCustomRange
        }
        return !selectedExpenseCategories.isEmpty || !selectedIncomeCategories.isEmpty || !selectedAccounts.isEmpty || hasCustomRange
    }

    private func axisLabels(for summary: AnalyticsSummary) -> [String] {
        let labels = summary.buckets.map(\.label)
        guard labels.count > 8 else { return labels }
        let stride = (labels.count + 5) / 6
        return labels.enumerated().compactMap { $0.offset.isMultiple(of: stride) ? $0.element : nil }
    }

    private func extremaIDs(for summary: AnalyticsSummary) -> Set<String> {
        guard let minimum = summary.buckets.min(by: { $0.value < $1.value }),
              let maximum = summary.buckets.max(by: { $0.value < $1.value }) else { return [] }
        return [minimum.id, maximum.id]
    }

    private func valueLabel(_ value: Double) -> String {
        LedgerFormat.money(value, currency: store.state.settings.baseCurrency, compact: true)
    }

    private func allValueLabelsFit(width: CGFloat, summary: AnalyticsSummary) -> Bool {
        guard !summary.buckets.isEmpty else { return true }
        let slot = width / CGFloat(summary.buckets.count)
        return summary.buckets.allSatisfy { CGFloat(valueLabel($0.value).count) * 6.2 + 6 <= slot }
    }

    private func categoryBinding(_ id: LedgerCategoryID, for type: LedgerTransactionType) -> Binding<Bool> {
        Binding(
            get: {
                if type == .income {
                    return selectedIncomeCategories.contains(id)
                } else {
                    return selectedExpenseCategories.contains(id)
                }
            },
            set: { enabled in
                if type == .income {
                    if enabled { selectedIncomeCategories.insert(id) } else { selectedIncomeCategories.remove(id) }
                } else {
                    if enabled { selectedExpenseCategories.insert(id) } else { selectedExpenseCategories.remove(id) }
                }
            }
        )
    }

    private func accountBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { activePage == .tax ? taxAccounts.contains(id) : selectedAccounts.contains(id) },
            set: { enabled in
                if activePage == .tax {
                    if enabled { taxAccounts.insert(id) } else { taxAccounts.remove(id) }
                } else {
                    if enabled { selectedAccounts.insert(id) } else { selectedAccounts.remove(id) }
                }
            }
        )
    }

    private func taxCategoryBinding(_ id: LedgerCategoryID, income: Bool) -> Binding<Bool> {
        Binding(get: { income ? taxIncomeCategories.contains(id) : taxExpenseCategories.contains(id) }, set: { enabled in
            if income {
                if enabled { taxIncomeCategories.insert(id) } else { taxIncomeCategories.remove(id) }
            } else {
                if enabled { taxExpenseCategories.insert(id) } else { taxExpenseCategories.remove(id) }
            }
        })
    }

    private func clearFilters() {
        if activePage == .tax {
            taxExpenseCategories.removeAll(); taxIncomeCategories.removeAll(); taxAccounts.removeAll()
            hasCustomRange = false
            return
        }
        selectedExpenseCategories.removeAll()
        selectedIncomeCategories.removeAll()
        selectedAccounts.removeAll()
        hasCustomRange = false
    }
}
