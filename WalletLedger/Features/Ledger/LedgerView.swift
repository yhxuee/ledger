import SwiftUI

struct LedgerView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @State private var query = ""
    @State private var isSearchPresented = false
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
    @State private var expandedPurchaseIDs = Set<UUID>()

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

    private var entries: [PurchaseLedgerEntry] {
        PurchaseLedgerPresentation.entries(
            transactions: filtered,
            sessions: store.purchaseSessions,
            collapsePurchases: !filtersActive && query.isEmpty
        )
    }

    private struct DateGroup: Identifiable {
        let day: Date
        let entries: [PurchaseLedgerEntry]
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
                                    switch entry {
                                    case .transaction(let item):
                                        transactionButton(item)
                                    case .purchase(let session, let children):
                                        purchaseRow(session: session, children: children)
                                        if expandedPurchaseIDs.contains(session.id) {
                                            ForEach(children) { child in
                                                Divider().padding(.leading, 67)
                                                transactionButton(child, isPurchaseChild: true)
                                            }
                                        }
                                    }
                                }
                            }
                            .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
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
            .padding(.bottom, 80)
        }
        .background(LedgerBackground())
        .navigationTitle("Ledger")
        .modifier(LedgerSearchModifier(text: $query, isPresented: $isSearchPresented))
        .safeAreaInset(edge: .bottom) {
            if !isSearchPresented {
                HStack {
                    Spacer()
                    GlassIconButton(systemName: "magnifyingglass", label: "Search transactions") { isSearchPresented = true }
                }.padding(.horizontal, 18).padding(.vertical, 6)
            }
        }
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

    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.first { $0.id == id } ?? LedgerCategory(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F") }

    private func transactionButton(_ item: LedgerTransaction, isPurchaseChild: Bool = false) -> some View {
        Button { if !item.isLockedByReversal { editing = item } } label: {
            TransactionRow(transaction: item, category: category(item.categoryID), showsDate: false)
                .padding(.leading, isPurchaseChild ? 22 : 14).padding(.trailing, 14)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if preferences.value.swipeActionOrientation == .refundLeadingDeleteTrailing {
                refundButton(item)
                deleteButton(item)
            } else {
                deleteButton(item)
                refundButton(item)
            }
        }
    }

    private func purchaseRow(session: PurchaseSession, children: [LedgerTransaction]) -> some View {
        Button {
            withAnimation(.snappy) {
                if expandedPurchaseIDs.contains(session.id) { expandedPurchaseIDs.remove(session.id) }
                else { expandedPurchaseIDs.insert(session.id) }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "cart.fill").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                    .background(.primary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text("\(children.count) items · Purchase").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SensitiveMoneyText(amount: PurchaseLedgerPresentation.displayedTotal(children, session: session, rates: store.state.settings.rates), currency: session.currency, maxIntegerDigits: 4)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: LedgerAmountWidth.row, alignment: .trailing)
                    .layoutPriority(1)
                Image(systemName: expandedPurchaseIDs.contains(session.id) ? "chevron.down" : "chevron.right")
                    .font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            withAnimation(.snappy) {
                _ = expandedPurchaseIDs.insert(session.id)
            }
        }
        .accessibilityHint("Expands the individual purchase transactions")
    }

    private func deleteButton(_ item: LedgerTransaction) -> some View {
        Button("Delete", role: .destructive) {
            HapticFeedback.warning(enabled: preferences.value.hapticFeedbackEnabled)
            store.deleteTransaction(item)
        }
    }

    private func refundButton(_ item: LedgerTransaction) -> some View {
        Button { store.refundTransaction(item) } label: { Label("Refund", systemImage: "arrow.uturn.backward.circle") }
            .tint(.blue)
            .disabled(item.isLockedByReversal)
    }
}

private struct LedgerSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.searchable(text: $text, isPresented: $isPresented, prompt: Text("Transactions"))
        } else {
            content.overlay(alignment: .bottom) {
                if isPresented {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Transactions", text: $text).textFieldStyle(.plain)
                        Button { text = ""; isPresented = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    .padding(12)
                    .ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
                }
            }
        }
    }
}
