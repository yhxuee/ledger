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
                            SensitiveMoneyText(amount: session.items.reduce(0) { $0 + $1.amount }, currency: store.state.settings.baseCurrency, compact: true).font(.subheadline.bold())
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
                if store.purchaseSessions.isEmpty { ContentUnavailableView("No Purchase Lists", systemImage: "cart", description: Text("Create a reusable shopping-style purchase list.")) }
            }
            .navigationTitle("Purchase Mode").navigationBarTitleDisplayMode(.inline)
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
    @State private var editingItem: PurchaseItem?
    private let isNew: Bool

    init(session: PurchaseSession?) {
        isNew = session == nil
        _session = State(initialValue: session ?? .init(id: UUID(), ledgerBookID: UUID(), name: "", status: .draft, sections: [], items: [], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Purchase") { TextField("Name or title", text: $session.name) }
                if !session.sections.isEmpty {
                    Section("Category Order") {
                        ForEach(orderedSections) { section in Text(category(section.categoryID).name) }.onMove(perform: moveSections)
                    }
                }
                ForEach(orderedSections) { section in
                    Section(category(section.categoryID).name) {
                        ForEach(items(in: section.categoryID)) { item in
                            Button { editingItem = item } label: {
                                HStack { Text(item.note.isEmpty ? "New Item" : item.note); Spacer(); SensitiveMoneyText(amount: item.amount, currency: store.state.settings.baseCurrency).font(.subheadline) }
                            }
                        }.onMove { offsets, destination in moveItems(categoryID: section.categoryID, offsets: offsets, destination: destination) }
                    }
                }
                Section { Button { addItem() } label: { Label("Add Item", systemImage: "plus.circle.fill") } }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(isNew ? "New Purchase" : "Edit Purchase").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Save for Later") { session.status = .draft; store.savePurchaseSession(session); dismiss() }
                    Button("Start") { startPurchase() }.fontWeight(.semibold).disabled(!canStart)
                }
            }
            .sheet(item: $editingItem) { item in PurchaseItemEditorView(item: item) { saveItem($0) } }
        }
    }
    private var orderedSections: [PurchaseCategorySection] { session.sections.sorted { $0.displayOrder < $1.displayOrder } }
    private func items(in categoryID: LedgerCategoryID) -> [PurchaseItem] { session.items.filter { $0.categoryID == categoryID }.sorted { $0.displayOrder < $1.displayOrder } }
    private var canStart: Bool { !session.items.isEmpty && session.items.allSatisfy { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount > 0 && resolvedAccount(for: $0) != nil } }
    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first(where: { $0.id == id }) ?? SeedData.categories.last! }
    private func addItem() { editingItem = .init(id: UUID(), categoryID: store.state.categories.first?.id ?? .other, note: "", amount: 0, displayOrder: session.items.count, isCompleted: false, completedAt: nil, resolvedAccountID: nil, linkedTransactionID: nil) }
    private func saveItem(_ item: PurchaseItem) {
        var updated = item
        if updated.resolvedAccountID == nil { updated.resolvedAccountID = resolvedAccount(for: updated) }
        if let index = session.items.firstIndex(where: { $0.id == updated.id }) { session.items[index] = updated } else { session.items.append(updated) }
        if !session.sections.contains(where: { $0.categoryID == updated.categoryID }) { session.sections.append(.init(id: UUID(), categoryID: updated.categoryID, displayOrder: session.sections.count)) }
        session.sections = session.sections.filter { section in session.items.contains(where: { $0.categoryID == section.categoryID }) }
        editingItem = nil
    }
    private func resolvedAccount(for item: PurchaseItem) -> UUID? {
        if let accountID = item.resolvedAccountID, store.accounts.contains(where: { $0.id == accountID }) { return accountID }
        if let mapped = store.state.settings.defaultExpenseAccountByCategory[item.categoryID], store.accounts.contains(where: { $0.id == mapped }) { return mapped }
        return store.accounts.first?.id
    }
    private func startPurchase() {
        session.name = session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Purchase \(Date.now.formatted(date: .abbreviated, time: .omitted))" : session.name
        for index in session.items.indices { session.items[index].resolvedAccountID = resolvedAccount(for: session.items[index]) }
        session.status = .active; session.startedAt = .now
        store.savePurchaseSession(session); dismiss()
    }
    private func moveSections(from offsets: IndexSet, to destination: Int) {
        var values = orderedSections; values.move(fromOffsets: offsets, toOffset: destination)
        for index in values.indices { values[index].displayOrder = index }
        session.sections = values
    }
    private func moveItems(categoryID: LedgerCategoryID, offsets: IndexSet, destination: Int) {
        var values = items(in: categoryID); values.move(fromOffsets: offsets, toOffset: destination)
        for index in values.indices { values[index].displayOrder = index; if let original = session.items.firstIndex(where: { $0.id == values[index].id }) { session.items[original] = values[index] } }
    }
}

struct PurchaseItemEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var item: PurchaseItem
    let save: (PurchaseItem) -> Void
    init(item: PurchaseItem, save: @escaping (PurchaseItem) -> Void) { _item = State(initialValue: item); self.save = save }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $item.note)
                LabeledContent("Amount") { SensitiveNumericField(placeholder: "0", value: $item.amount, fractionDigits: 2, width: 130) }
                Picker("Category", selection: $item.categoryID) { ForEach(store.state.categories) { Text($0.name).tag($0.id) } }
                    .onChange(of: item.categoryID) { _, category in item.resolvedAccountID = store.state.settings.defaultExpenseAccountByCategory[category] }
                Picker("Expense Account", selection: $item.resolvedAccountID) { Text("Use Category Default").tag(Optional<UUID>.none); ForEach(store.accounts) { Text($0.account.name).tag(Optional($0.id)) } }
            }
            .navigationTitle("Purchase Item").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save(item); dismiss() }.disabled(item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.amount <= 0) } }
        }
    }
}

struct ActivePurchaseView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    private var session: PurchaseSession? { store.purchaseSessions.first(where: { $0.id == sessionID }) }
    var body: some View {
        NavigationStack {
            List {
                if let session {
                    ForEach(session.items.sorted { $0.displayOrder < $1.displayOrder }) { item in
                        Button {
                            let updated = store.setPurchaseItem(item.id, in: session.id, completed: !item.isCompleted)
                            HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
                            if updated?.status == .awaitingSummary { HapticFeedback.success(enabled: preferences.value.hapticFeedbackEnabled) }
                        } label: {
                            HStack { Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle"); Text(item.note).strikethrough(item.isCompleted); Spacer(); SensitiveMoneyText(amount: item.amount, currency: store.state.settings.baseCurrency) }
                        }
                    }
                }
            }
            .navigationTitle(session?.name ?? "Purchase").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
