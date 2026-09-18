import SwiftUI

struct TransactionEditorView: View {
    @EnvironmentObject private var store: LedgerStore
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
    @State private var showDeleteConfirmation = false

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
                        if original != nil {
                            Button("Delete Transaction", role: .destructive) { showDeleteConfirmation = true }.frame(maxWidth: .infinity).padding(.top, 4)
                        }
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
            .confirmationDialog("Delete this transaction?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Transaction", role: .destructive) { if let original { store.deleteTransaction(original) }; dismiss() }
            }
        }
        .onAppear {
            if accountID == nil { accountID = activeAccounts.first?.id; currency = activeAccounts.first?.currency ?? store.state.settings.baseCurrency }
            if destinationID == nil { destinationID = activeAccounts.first(where: { $0.id != accountID })?.id }
        }
    }

    private var amountPanel: some View {
        VStack(spacing: 8) {
            Picker("Currency", selection: $currency) { ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            Text(LedgerFormat.money(amount, currency: currency)).font(.system(size: 48, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1)
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
                if key.isEmpty { Color.clear.frame(height: 56) }
                else {
                    Button { press(key) } label: {
                        Group { if key == "delete.left" { Image(systemName: key) } else { Text(key) } }.font(.title2.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
                    }.buttonStyle(.plain).ledgerGlass(interactive: true, in: Circle())
                }
            }
        }.frame(maxWidth: 350)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.state.categories) { category in
                    Button { withAnimation(.snappy) { categoryID = category.id } } label: {
                        VStack(spacing: 4) { Image(systemName: category.symbol).font(.title3); Text(category.name).font(.caption.weight(.semibold)); Text(category.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            .frame(width: 112, height: 78)
                            .foregroundStyle(categoryID == category.id ? LedgerPalette.category(category.id) : .primary)
                            .ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 4)
        }
    }

    private func press(_ key: String) {
        if key == "delete.left" { minorUnits = minorUnits.count <= 1 ? "0" : String(minorUnits.dropLast()) }
        else {
            let next = minorUnits == "0" ? key : minorUnits + key
            if next.count <= 11 { minorUnits = next }
        }
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
