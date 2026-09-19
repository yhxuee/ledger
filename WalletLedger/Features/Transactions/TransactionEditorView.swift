import SwiftUI

struct TransactionEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.dismiss) private var dismiss
    private let original: LedgerTransaction?
    @State private var type: LedgerTransactionType
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var currency: CurrencyCode
    @State private var categoryID: LedgerCategoryID
    @State private var occurredAt: Date
    @State private var note: String
    @State private var minorUnits: String
    @State private var showingCategoryEditor = false
    @State private var accountExplicitlyOverridden: Bool
    @State private var applyingDefaultAccount = false

    init(transaction: LedgerTransaction? = nil) {
        original = transaction
        _type = State(initialValue: transaction?.type ?? .expense)
        _accountID = State(initialValue: transaction?.accountID)
        _destinationID = State(initialValue: transaction?.destinationAccountID)
        _currency = State(initialValue: transaction?.currency ?? .HKD)
        _categoryID = State(initialValue: transaction?.categoryID ?? .food)
        _occurredAt = State(initialValue: transaction?.occurredAt ?? .now)
        _note = State(initialValue: transaction?.note ?? "")
        _minorUnits = State(initialValue: String(Int(((transaction?.amount ?? 0) * 100).rounded())))
        _accountExplicitlyOverridden = State(initialValue: transaction != nil)
    }

    private var amount: Double { (Double(minorUnits) ?? 0) / 100 }
    private var activeAccounts: [LedgerAccount] { store.accounts.map(\.account) }
    private var canSave: Bool { amount > 0 && accountID != nil && (type != .transfer || (destinationID != nil && destinationID != accountID)) }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 12) {
                        Picker("Transaction type", selection: $type) { ForEach(LedgerTransactionType.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented)
                        amountPanel
                        detailsPanel
                        keypad
                        if type != .transfer { categoryPicker }
                    }
                    .frame(minHeight: max(0, geometry.size.height - 20), alignment: .top)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .background(LedgerBackground())
            .navigationTitle(original == nil ? "Add Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave).fontWeight(.semibold) }
            }
        }
        .onAppear {
            if accountID == nil { applyDefaultAccount(for: categoryID) }
            if destinationID == nil { destinationID = activeAccounts.first(where: { $0.id != accountID })?.id }
        }
        .onChange(of: categoryID) { _, category in if type == .expense && !accountExplicitlyOverridden { applyDefaultAccount(for: category) } }
        .onChange(of: type) { _, value in if value == .expense && !accountExplicitlyOverridden { applyDefaultAccount(for: categoryID) } }
        .sheet(isPresented: $showingCategoryEditor) {
            CategoryEditorSheet { id in categoryID = id }
        }
    }

    private var amountPanel: some View {
        VStack(spacing: 8) {
            Picker("Currency", selection: $currency) { ForEach(store.availableCurrencies) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            SensitiveMoneyText(amount: amount, currency: currency).font(.system(size: 48, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 12).ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var detailsPanel: some View {
        VStack(spacing: 0) {
            LabeledContent(type == .transfer ? "From Account" : "Account") {
                Picker(type == .transfer ? "From Account" : "Account", selection: $accountID) {
                    ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .onChange(of: accountID) { _, newValue in
                if !applyingDefaultAccount { accountExplicitlyOverridden = true }
                if let account = activeAccounts.first(where: { $0.id == newValue }) { currency = account.currency }
                if destinationID == newValue { destinationID = activeAccounts.first(where: { $0.id != newValue })?.id }
            }
            if type == .transfer {
                Divider()
                LabeledContent("To Account") {
                    Picker("To Account", selection: $destinationID) {
                        ForEach(activeAccounts.filter { $0.id != accountID }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                TextField("Note (optional)", text: $note).textFieldStyle(.plain)
            }
            .padding(.vertical, 12)
            Divider()
            DatePicker("Date", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 9) {
            ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete.left"], id: \.self) { key in
                if key.isEmpty { Color.clear.frame(height: 68) }
                else {
                    Button { press(key) } label: {
                        Group { if key == "delete.left" { Image(systemName: key) } else { Text(key) } }.font(.title.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 68)
                    }.buttonStyle(.plain).ledgerGlass(interactive: true, in: Circle())
                }
            }
        }.frame(maxWidth: 380)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.state.categories) { category in
                    Button { withAnimation(.snappy) { categoryID = category.id } } label: {
                        VStack(spacing: 4) { CategoryIcon(category: category, font: .title3); Text(category.name).font(.caption.weight(.semibold)); Text(category.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            .frame(width: 112, height: 78)
                            .foregroundStyle(categoryID == category.id ? Color(hex: category.colorHex) : Color.primary)
                            .ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }.buttonStyle(.plain)
                }
                Button { showingCategoryEditor = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.title2)
                        Text("New Category").font(.caption.weight(.semibold))
                    }
                    .frame(width: 112, height: 78)
                    .ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
            }.padding(.vertical, 4)
        }
    }

    private func press(_ key: String) {
        HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
        if key == "delete.left" { minorUnits = minorUnits.count <= 1 ? "0" : String(minorUnits.dropLast()) }
        else {
            let next = minorUnits == "0" ? key : minorUnits + key
            if next.count <= 11 { minorUnits = next }
        }
    }

    private func applyDefaultAccount(for category: LedgerCategoryID) {
        let mapped = store.state.settings.defaultExpenseAccountByCategory[category]
        let resolved = mapped.flatMap { id in activeAccounts.first(where: { $0.id == id })?.id } ?? activeAccounts.first?.id
        applyingDefaultAccount = true
        accountID = resolved
        if let account = activeAccounts.first(where: { $0.id == resolved }) { currency = account.currency }
        DispatchQueue.main.async { applyingDefaultAccount = false }
    }

    private func save() {
        guard let accountID else { return }
        if var original {
            original.type = type; original.accountID = accountID; original.destinationAccountID = type == .transfer ? destinationID : nil
            original.amount = amount; original.currency = currency; original.categoryID = type == .transfer ? .other : categoryID
            original.occurredAt = occurredAt; original.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
            store.updateTransaction(original)
        } else {
            store.addTransaction(type: type, accountID: accountID, destinationAccountID: destinationID, amount: amount, currency: currency, categoryID: categoryID, occurredAt: occurredAt, note: note)
        }
        dismiss()
    }
}

private struct CategoryEditorSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var detail = ""
    @State private var mode = 0
    @State private var emoji = "🍽️"
    @State private var selectedSymbol = "cup.and.saucer.fill"
    @State private var color = LedgerPalette.coral
    let onAdd: (LedgerCategoryID) -> Void

    private let symbols = ["cup.and.saucer.fill", "cart.fill", "house.fill", "heart.fill", "gift.fill", "airplane", "gamecontroller.fill", "cross.case.fill", "graduationcap.fill", "pawprint.fill", "figure.run", "ellipsis.circle.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $detail)
                    ColorPicker("Color", selection: $color)
                }
                Section("Appearance") {
                    Picker("Type", selection: $mode) { Text("Emoji").tag(0); Text("Icon").tag(1) }.pickerStyle(.segmented)
                    if mode == 0 {
                        TextField("Emoji", text: $emoji).font(.title2)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                            ForEach(symbols, id: \.self) { symbol in
                                Button { selectedSymbol = symbol } label: {
                                    Image(systemName: symbol).font(.title3).frame(width: 42, height: 42)
                                        .background(selectedSymbol == symbol ? color.opacity(0.22) : Color.clear, in: Circle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let value = mode == 0 ? "emoji:\(String(emoji.prefix(1)))" : selectedSymbol
                        if let id = store.addCategory(name: name, detail: detail, symbol: value, colorHex: color.rgbHex) { onAdd(id); dismiss() }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == 0 && emoji.isEmpty))
                }
            }
        }
    }
}
