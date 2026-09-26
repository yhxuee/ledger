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

    @State private var snapshot: ListSnapshot?

    private struct ListRequest: Hashable, Sendable {
        var bookID: UUID
        var revision: UInt64
        var categories: Set<LedgerCategoryID>
        var accounts: Set<UUID>
        var rangeStart: Date?
        var rangeEnd: Date?
        var day: Date?
        var today: Date
    }
    private struct DateGroup: Identifiable, Sendable {
        let day: Date
        let entries: [LedgerPresentationEntry]
        var id: Date { day }
    }
    private struct ListSnapshot: Sendable {
        var request: ListRequest
        var groups: [DateGroup]
        var window: LedgerListWindow
    }
    private var listRequest: ListRequest {
        let calendar = Calendar.current
        return ListRequest(bookID: store.activeBookID, revision: store.financialRevision,
            categories: selectedCategories, accounts: selectedAccounts,
            rangeStart: hasCustomRange ? calendar.startOfDay(for: rangeStart) : nil,
            rangeEnd: hasCustomRange ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: rangeEnd)) : nil,
            day: hasCalendarDay ? calendar.startOfDay(for: calendarDay) : nil,
            today: calendar.startOfDay(for: .now))
    }
    private var currentSnapshot: ListSnapshot? {
        guard snapshot?.request == listRequest else { return nil }
        return snapshot
    }

    nonisolated private static func buildSnapshot(request: ListRequest, state: LedgerState, index: LedgerIndex) -> ListSnapshot? {
        let calendar = Calendar.current
        let nextDay = request.day.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        var matching: [LedgerTransaction] = []
        matching.reserveCapacity(index.sortedActiveTransactions.count)
        for item in index.sortedActiveTransactions {
            if Task.isCancelled { return nil }
            guard request.categories.isEmpty || (item.type == .expense && request.categories.contains(item.categoryID)),
                  request.accounts.isEmpty || request.accounts.contains(item.accountID) || item.destinationAccountID.map({ request.accounts.contains($0) }) == true,
                  request.rangeStart.map({ item.occurredAt >= $0 }) ?? true,
                  request.rangeEnd.map({ item.occurredAt < $0 }) ?? true else { continue }
            if let day = request.day, let nextDay {
                guard item.type == .expense, item.occurredAt >= day, item.occurredAt < nextDay else { continue }
            }
            matching.append(item)
        }
        let window = LedgerListWindow.select(matching, now: request.today, calendar: calendar)
        let entries = LedgerPresentation.entries(transactions: window.transactions, state: state, index: index)
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.occurredAt) }
        let groups = grouped.keys.sorted(by: >).map { DateGroup(day: $0, entries: grouped[$0, default: []]) }
        return ListSnapshot(request: request, groups: groups, window: window)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(currentSnapshot?.groups ?? []) { group in
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

                    if let currentSnapshot, currentSnapshot.window.transactions.isEmpty {
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
                    if let window = currentSnapshot?.window, window.excludedByMonths > 0 || window.excludedByCount > 0 {
                        VStack(alignment: .leading, spacing: 5) {
                            if window.excludedByMonths > 0 {
                                Text("12-month limit: \(window.excludedByMonths) transactions outside the latest 12 months are hidden.")
                            }
                            if window.excludedByCount > 0 {
                                Text("3,600-transaction limit: \(window.excludedByCount) additional transactions in this period are hidden.")
                            }
                            Text("All records remain available for analytics, backup, sync, and export.")
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                    if currentSnapshot == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
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
                    Menu { ForEach(store.state.categories) { category in Toggle(category.displayName, isOn: categoryBinding(category.id)) } } label: { Label("Expense Categories", systemImage: "tag") }
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
        .task(id: listRequest) {
            let request = listRequest
            guard snapshot?.request != request else { return }
            let state = store.state
            let index = store.index
            let worker = Task.detached(priority: .userInitiated) {
                Self.buildSnapshot(request: request, state: state, index: index)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let result else { return }
            snapshot = result
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
