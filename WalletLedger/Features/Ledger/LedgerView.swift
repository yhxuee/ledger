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
    @State private var editing: LedgerTransaction?

    private var filtered: [LedgerTransaction] {
        store.activeTransactions.filter { item in
            let matchesCategory = selectedCategories.isEmpty || selectedCategories.contains(item.categoryID)
            let searchable = [item.note ?? "", item.categoryID.rawValue, item.currency.rawValue, String(item.amount)].joined(separator: " ").lowercased()
            return matchesCategory && (query.isEmpty || searchable.contains(query.lowercased()))
        }
    }
    private var groups: [DayGroup] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .map { DayGroup(date: $0.key, items: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
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
        .background(LedgerBackground())
        .navigationTitle("Ledger")
        .searchable(text: $query, prompt: "Transactions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(store.state.categories) { category in Toggle(category.name, isOn: Binding(get: { selectedCategories.contains(category.id) }, set: { enabled in if enabled { selectedCategories.insert(category.id) } else { selectedCategories.remove(category.id) } })) }
                    if !selectedCategories.isEmpty { Button("Clear Filters", role: .destructive) { selectedCategories.removeAll() } }
                } label: { Label("Filter", systemImage: selectedCategories.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
            }
        }
        .sheet(item: $editing) { TransactionEditorView(transaction: $0) }
    }

    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.first { $0.id == id } ?? LedgerCategory(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F") }
}
