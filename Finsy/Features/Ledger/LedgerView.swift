import SwiftUI

struct LedgerView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
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
    @State private var revealedTransactionID: UUID? = nil
    @State private var isDetachDropTargeted = false

    private var filtered: [LedgerTransaction] {
        store.activeTransactions.filter { item in
            let matchesCategory = selectedCategories.isEmpty || (item.type == .expense && selectedCategories.contains(item.categoryID))
            let matchesAccount = selectedAccounts.isEmpty || selectedAccounts.contains(item.accountID) || item.destinationAccountID.map { selectedAccounts.contains($0) } == true
            let matchesRange = !hasCustomRange || (item.occurredAt >= Calendar.current.startOfDay(for: rangeStart) && item.occurredAt < (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: rangeEnd)) ?? rangeEnd))
            let matchesDay = !hasCalendarDay || (item.type == .expense && Calendar.current.isDate(item.occurredAt, inSameDayAs: calendarDay))
            return matchesCategory && matchesAccount && matchesRange && matchesDay
        }
    }

    private var entries: [LedgerPresentationEntry] {
        LedgerPresentation.entries(transactions: filtered, state: store.state, index: store.index)
    }

    private struct DateGroup: Identifiable {
        let day: Date
        let entries: [LedgerPresentationEntry]
        var id: Date { day }
    }

    private var dateGroups: [DateGroup] {
        // Group presentation entries, keeping each Purchase and its children together.
        let grouped = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.occurredAt) }
        return grouped.keys.sorted(by: >).map { day in
            DateGroup(day: day, entries: grouped[day, default: []])
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(dateGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preferences.value.dateFormat.transactionDateString(from: group.day))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            VStack(spacing: 0) {
                                ForEach(group.entries) { entry in
                                    if entry.id != group.entries.first?.id {
                                        Divider().padding(.leading, 67)
                                    }
                                    LedgerEntryRow(entry: entry)

                                }
                            }
                            .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "No Transactions",
                            systemImage: "tray",
                            description: Text(
                                filtersActive
                                    ? "No transactions match the current filters."
                                    : "Transactions will appear here."
                            )
                        )
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                    }
                } header: {
                    if showingCalendar {
                        calendarPanel
                            .background(LedgerBackground())
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let firstStr = items.first, let childID = UUID(uuidString: firstStr) else { return false }
            if store.canDetachCombinedPaymentChild(childID: childID) {
                let success = store.detachCombinedPaymentChild(childID: childID)
                if success {
                    HapticFeedback.success(enabled: preferences.value.hapticFeedbackEnabled)
                }
                return success
            }
            return false
        } isTargeted: { targeted in
            withAnimation(.snappy(duration: 0.2)) {
                isDetachDropTargeted = targeted
            }
        }
        .overlay(alignment: .top) {
            if isDetachDropTargeted {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.caption.weight(.semibold))
                    Text("Drop to remove from Combined Payment")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .ledgerGlass(interactive: false, in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .environment(\.revealedTransactionID, $revealedTransactionID)
        .background(LedgerBackground())
        .navigationTitle("Ledger")
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
                    withAnimation(.snappy) {
                        showingCalendar.toggle()
                        hasCalendarDay = showingCalendar
                        if showingCalendar { calendarDay = .now }
                    }
                } label: { Image(systemName: hasCalendarDay ? "calendar.circle.fill" : "calendar") }
                .accessibilityLabel("Daily calendar")
                LedgerBookMenu()
            }
        }
        .sheet(item: $editing) {
            TransactionEditorView(transaction: $0)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
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
        LedgerCalendarView(selection: $calendarDay, transactions: store.activeTransactions, accounts: store.accounts.map(\.account))
            .onChange(of: calendarDay) { _, _ in hasCalendarDay = true }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .ledgerGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 6)
    }

}
