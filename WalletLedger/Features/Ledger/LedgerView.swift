import SwiftUI

struct LedgerView: View {
    private struct DayGroup: Identifiable {
        let date: Date
        let items: [LedgerTransaction]

        var id: Date { date }
    }

    @EnvironmentObject private var store: LedgerStore
    @State private var query = ""
    @State private var selectedCategories = Set<LedgerCategoryID>()
    @State private var selectedAccounts = Set<UUID>()
    @State private var editing: LedgerTransaction?
    @State private var showingRangePicker = false
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var rangeEnd = Date.now
    @State private var hasCustomRange = false
    @State private var showingCalendar = false
    @State private var calendarDay = Date.now
    @State private var hasCalendarDay = false

    private var filtered: [LedgerTransaction] {
        store.activeTransactions.filter { item in
            let matchesCategory = selectedCategories.isEmpty || (item.type == .expense && selectedCategories.contains(item.categoryID))
            let matchesAccount = selectedAccounts.isEmpty || selectedAccounts.contains(item.accountID) || item.destinationAccountID.map { selectedAccounts.contains($0) } == true
            let matchesRange = !hasCustomRange || (item.occurredAt >= Calendar.current.startOfDay(for: rangeStart) && item.occurredAt < (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: rangeEnd)) ?? rangeEnd))
            let matchesDay = !hasCalendarDay || (item.type == .expense && Calendar.current.isDate(item.occurredAt, inSameDayAs: calendarDay))
            let searchable = [item.note ?? "", item.categoryID.rawValue, item.currency.rawValue, String(item.amount)].joined(separator: " ").lowercased()
            return matchesCategory && matchesAccount && matchesRange && matchesDay && (query.isEmpty || searchable.contains(query.lowercased()))
        }
    }
    private var groups: [DayGroup] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .map { DayGroup(date: $0.key, items: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingCalendar { calendarPanel }
            List {
                ForEach(groups) { group in
                    Section(group.date.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                        ForEach(group.items) { item in
                            Button { editing = item } label: { TransactionRow(transaction: item, category: category(item.categoryID)) }.buttonStyle(.plain)
                                .swipeActions { Button("Delete", role: .destructive) { store.deleteTransaction(item) } }
                        }
                    }
                }
                if filtered.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .scrollContentBackground(.hidden)
        }
        .background(LedgerBackground())
        .navigationTitle("Ledger")
        .searchable(text: $query, prompt: "Transactions")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Menu { ForEach(store.state.categories) { category in Toggle(category.name, isOn: categoryBinding(category.id)) } } label: { Label("Expense Categories", systemImage: "tag") }
                    Menu { ForEach(store.accounts) { item in Toggle(item.account.name, isOn: accountBinding(item.id)) } } label: { Label("Accounts", systemImage: "wallet.bifold") }
                    Divider()
                    Button { showingRangePicker = true } label: { Label("Custom Range", systemImage: "calendar.badge.clock") }
                    if filtersActive { Button("Clear Filters", role: .destructive, action: clearFilters) }
                } label: { Label("Filter", systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                Button {
                    showingCalendar.toggle()
                    hasCalendarDay = true
                    calendarDay = .now
                } label: { Image(systemName: hasCalendarDay ? "calendar.circle.fill" : "calendar") }
                .accessibilityLabel("Daily calendar")
                LedgerBookMenu()
            }
        }
        .fullScreenCover(item: $editing) { TransactionEditorView(transaction: $0) }
        .sheet(isPresented: $showingRangePicker) {
            DateRangePickerSheet(start: rangeStart, end: rangeEnd) { start, end in rangeStart = start; rangeEnd = end; hasCustomRange = true; hasCalendarDay = false }
        }
        .onChange(of: store.activeBookID) { _, _ in clearFilters() }
    }

    private var filtersActive: Bool { !selectedCategories.isEmpty || !selectedAccounts.isEmpty || hasCustomRange || hasCalendarDay }
    private func categoryBinding(_ id: LedgerCategoryID) -> Binding<Bool> { Binding(get: { selectedCategories.contains(id) }, set: { enabled in if enabled { selectedCategories.insert(id) } else { selectedCategories.remove(id) } }) }
    private func accountBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { selectedAccounts.contains(id) }, set: { enabled in if enabled { selectedAccounts.insert(id) } else { selectedAccounts.remove(id) } }) }
    private func clearFilters() { selectedCategories.removeAll(); selectedAccounts.removeAll(); hasCustomRange = false; hasCalendarDay = false; showingCalendar = false }

    private var calendarPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(calendarDay.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.headline)
                Spacer()
                Button("Clear") { hasCalendarDay = false; showingCalendar = false }.font(.subheadline)
            }.padding(.horizontal)
            DatePicker("Day", selection: $calendarDay, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: calendarDay) { _, _ in hasCalendarDay = true }
        }
        .padding(.top, 8)
        .background(.thinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.first { $0.id == id } ?? LedgerCategory(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F") }
}
