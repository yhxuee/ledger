import SwiftUI

struct PurchaseModeView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var selected: PurchaseSession?
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.purchaseSessions) { session in
                    Button { selected = session } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.name.isEmpty ? "Untitled Purchase" : session.name).font(.headline)
                                Text(session.status.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SensitiveMoneyText(amount: session.plannedAmount, currency: session.currency, maxIntegerDigits: 4).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.85)
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
                if store.purchaseSessions.isEmpty { ContentUnavailableView("No Purchase Lists", systemImage: "cart", description: Text("Create a reusable shopping-style purchase list.")) }
            }
            .navigationTitle("Purchase Mode").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { PurchaseStatusNotice() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } } }
            .sheet(isPresented: $creating) { PurchaseSessionEditorView(session: nil) }
            .sheet(item: $selected) { PurchaseSessionFlowView(sessionID: $0.id) }
        }
    }
}

private extension PurchaseSessionStatus {
    var title: String {
        switch self { case .draft: "Draft"; case .active: "Active"; case .awaitingSummary: "Awaiting Summary"; case .completed: "Completed"; case .cancelled: "Cancelled" }
    }
}

struct PurchaseSessionFlowView: View {
    @EnvironmentObject private var store: LedgerStore
    let sessionID: UUID
    var body: some View {
        if let session = store.purchaseSessions.first(where: { $0.id == sessionID }) {
            switch session.status {
            case .draft: PurchaseSessionEditorView(session: session)
            case .active: ActivePurchaseView(sessionID: sessionID)
            case .awaitingSummary: PurchaseSummaryView(sessionID: sessionID, readOnly: false)
            case .completed: PurchaseSummaryView(sessionID: sessionID, readOnly: true)
            case .cancelled: ContentUnavailableView("Purchase Cancelled", systemImage: "cart.badge.minus")
            }
        } else { ContentUnavailableView("Purchase Not Found", systemImage: "exclamationmark.triangle") }
    }
}

struct PurchaseSessionEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var session: PurchaseSession
    @State private var initialized = false
    @State private var starting = false
    @State private var startedSessionID: UUID?
    @FocusState private var focusedItem: UUID?
    private let isNew: Bool

    init(session: PurchaseSession?) {
        isNew = session == nil
        _session = State(initialValue: session ?? .init(id: UUID(), ledgerBookID: UUID(), name: "", status: .draft, sections: [], items: [], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil))
    }

    var body: some View {
        if let startedSessionID { PurchaseSessionFlowView(sessionID: startedSessionID) }
        else { editor }
    }

    private var editor: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Purchase Name", text: $session.name)
                    CurrencyPickerLink(selection: $session.currency, stablecoinDescriptions: false)
                    Picker("Payment Account", selection: $session.accountID) {
                        Text("Choose Account").tag(Optional<UUID>.none)
                        if let id = session.accountID, !store.accounts.contains(where: { $0.id == id }) {
                            Text("Account unavailable").tag(Optional(id))
                        }
                        ForEach(store.accounts) { account in
                            Text("\(account.account.name) · \(account.account.currency.rawValue)").tag(Optional(account.id))
                        }
                    }
                    if !paymentValid {
                        Text("Select an active payment account and configure the currency rates before starting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(session.orderedSections) { section in
                    Section {
                        ForEach(items(in: section.categoryID)) { item in
                            inlineRow(item)
                                .listRowBackground(Color(hex: category(section.categoryID).colorHex).opacity(0.09))
                                .swipeActions {
                                    Button("Delete", role: .destructive) { session.items.removeAll { $0.id == item.id } }
                                }
                        }
                        .onMove { offsets, destination in moveItems(categoryID: section.categoryID, offsets: offsets, destination: destination) }
                        Button { addItem(categoryID: section.categoryID) } label: { Label("Add Item", systemImage: "plus") }
                            .listRowBackground(Color(hex: category(section.categoryID).colorHex).opacity(0.09))
                    } header: {
                        HStack {
                            CategoryIcon(category: category(section.categoryID))
                            Text(category(section.categoryID).name)
                            Spacer()
                            Menu {
                                Button("Move Up") { moveSection(section.id, by: -1) }
                                Button("Move Down") { moveSection(section.id, by: 1) }
                            } label: { Image(systemName: "arrow.up.arrow.down") }
                            .accessibilityLabel("Reorder \(category(section.categoryID).name)")
                        }.foregroundStyle(Color(hex: category(section.categoryID).colorHex))
                    }
                }
                Section {
                    Button { addItem(categoryID: store.state.categories.first?.id ?? .other) } label: { Label("Add Item", systemImage: "plus.circle.fill") }
                }
                Section {
                    Button("Save for Later") { saveDraft(); dismiss() }
                    Button("Start Purchase") { Task { await startPurchase() } }
                        .fontWeight(.semibold).disabled(!canStart || starting)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LedgerBackground())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "New Purchase" : "Edit Purchase").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { PurchaseStatusNotice() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { saveDraft(); dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedItem = nil
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .onAppear {
                guard !initialized else { return }
                if isNew {
                    session.accountID = store.accounts.first?.id
                    session.currency = store.accounts.first?.account.currency ?? store.state.settings.baseCurrency
                }
                session.ledgerBookID = store.activeBookID
                session.normalizeSections()
                initialized = true
                saveDraft()
            }
            .onChange(of: session) { _, _ in
                guard initialized, !starting else { return }
                session.normalizeSections()
                saveDraft()
            }
        }
        .anchoredCurrencyDropdownLayer()
    }

    private func inlineRow(_ item: PurchaseItem) -> some View {
        HStack(spacing: 8) {
            TextField("Item", text: itemBinding(item, \.note))
                .focused($focusedItem, equals: item.id)
                .accessibilityLabel("Item name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(store.state.categories) { value in
                    Button { setCategory(itemID: item.id, categoryID: value.id) } label: {
                        Label(value.name, systemImage: value.symbol)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    CategoryIcon(category: category(item.categoryID))
                    Text(category(item.categoryID).name).lineLimit(1)
                }.font(.caption).foregroundStyle(Color(hex: category(item.categoryID).colorHex))
                    .frame(maxWidth: 90)
            }.accessibilityLabel("Category")
            Text(session.currency.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            SensitiveNumericField(placeholder: "0.00", value: itemBinding(item, \.amount), fractionDigits: 2, width: 82)
                .accessibilityLabel("Amount in \(session.currency.rawValue)")
        }.padding(.vertical, 4)
    }
    private func itemBinding<Value>(_ item: PurchaseItem, _ key: WritableKeyPath<PurchaseItem, Value>) -> Binding<Value> {
        Binding(get: { (session.items.first { $0.id == item.id } ?? item)[keyPath: key] }, set: { value in
            guard let index = session.items.firstIndex(where: { $0.id == item.id }) else { return }
            session.items[index][keyPath: key] = value
        })
    }
    private var paymentValid: Bool { (try? PurchaseRules.validatePayment(session, in: store.state)) != nil }
    private var canStart: Bool { paymentValid && (try? PurchaseRules.validateItems(session, in: store.state)) != nil }
    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.last! }
    private func items(in id: LedgerCategoryID) -> [PurchaseItem] { session.orderedItems.filter { $0.categoryID == id } }
    private func saveDraft() { if initialized && !starting { store.savePurchaseSession(session) } }
    private func addItem(categoryID: LedgerCategoryID) {
        let item = PurchaseItem(id: UUID(), categoryID: categoryID, note: "", amount: 0, displayOrder: (session.items.map(\.displayOrder).max() ?? -1) + 1, isCompleted: false, completedAt: nil, linkedTransactionID: nil)
        session.items.append(item)
        session.normalizeSections()
        focusedItem = item.id
    }
    private func setCategory(itemID: UUID, categoryID: LedgerCategoryID) {
        guard let index = session.items.firstIndex(where: { $0.id == itemID }) else { return }
        session.items[index].categoryID = categoryID
        session.normalizeSections()
    }
    private func moveSection(_ id: UUID, by delta: Int) {
        var sections = session.orderedSections
        guard let index = sections.firstIndex(where: { $0.id == id }), sections.indices.contains(index + delta) else { return }
        sections.swapAt(index, index + delta)
        for i in sections.indices { sections[i].displayOrder = i }
        session.sections = sections
    }
    private func moveItems(categoryID: LedgerCategoryID, offsets: IndexSet, destination: Int) {
        var values = items(in: categoryID)
        values.move(fromOffsets: offsets, toOffset: destination)
        for index in values.indices {
            if let original = session.items.firstIndex(where: { $0.id == values[index].id }) { session.items[original].displayOrder = index }
        }
    }
    private func startPurchase() async {
        guard !starting else { return }
        if session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.name = "Purchase" }
        store.savePurchaseSession(session)
        starting = true
        defer { starting = false }
        do { _ = try await store.startPurchaseSession(session.id); startedSessionID = session.id }
        catch { store.presentedError = error.localizedDescription }
    }
}

struct ActivePurchaseView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    private var session: PurchaseSession? { store.purchaseSessions.first { $0.id == sessionID } }
    var body: some View {
        NavigationStack {
            List {
                if let session {
                    Section {
                        HStack(spacing: 20) {
                            PurchaseProgressRing(fraction: session.completionFraction, completed: session.items.allSatisfy(\.isCompleted), iconSize: 18, lineWidth: 5)
                                .frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(session.completedItemCount) / \(session.items.count) items").font(.headline)
                                SensitiveMoneyText(amount: session.completedAmount, currency: session.currency, maxIntegerDigits: 4).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.85)
                                HStack { Text("Planned").foregroundStyle(.secondary); SensitiveMoneyText(amount: session.plannedAmount, currency: session.currency, maxIntegerDigits: 4) }.font(.caption)
                            }
                        }.padding(.vertical, 8)
                    }
                    ForEach(session.orderedSections) { section in
                        Section(category(section.categoryID).name) {
                            ForEach(session.orderedItems.filter { $0.categoryID == section.categoryID }) { item in
                                Button { toggle(item, in: session) } label: {
                                    HStack {
                                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                        Text(item.note).strikethrough(item.isCompleted)
                                        Spacer()
                                        SensitiveMoneyText(amount: item.amount, currency: session.currency, maxIntegerDigits: 4)
                                    }
                                }
                                .listRowBackground(Color(hex: category(section.categoryID).colorHex).opacity(0.09))
                            }
                        }
                    }
                }
            }
            .navigationTitle(session?.name ?? "Purchase").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { PurchaseStatusNotice() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: sessionID) { await refreshFromSharedBridge() }
        }
    }

    /// Local-first toggle: the stored session changes and is persisted immediately, then the
    /// App Group / Live Activity bridge is refreshed in the background. Nothing here can
    /// dismiss the screen, change the status or roll the completion back.
    @MainActor private func toggle(_ item: PurchaseItem, in session: PurchaseSession) {
        guard let updated = store.setPurchaseItem(item.id, in: session.id, completed: !item.isCompleted) else { return }
        HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
        if updated.status == .awaitingSummary { HapticFeedback.success(enabled: preferences.value.hapticFeedbackEnabled) }
        Task { await store.publishPurchase(sessionID: session.id, requestActivity: updated.status == .active) }
    }

    /// Controlled reconciliation boundary: reads the bridge when this screen appears and
    /// while it stays visible, so Lock Screen/Island completions appear without leaving it.
    @MainActor private func refreshFromSharedBridge() async {
        while !Task.isCancelled {
            store.reconcileSharedActivePurchases()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.last! }
}
