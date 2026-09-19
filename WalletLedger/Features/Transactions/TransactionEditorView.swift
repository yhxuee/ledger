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
    /// Pocket the posting lands in. Nil means "use the account default", so changing the
    /// transaction currency re-resolves it instead of pinning a stale pocket.
    @State private var accountPocket: CurrencyCode?
    @State private var destinationPocket: CurrencyCode?
    @State private var accountAmountText: String
    @State private var destinationAmountText: String
    /// True once the user typed their own account-side amount: never recalculated afterwards.
    @State private var accountAmountOverridden = false
    @State private var destinationAmountOverridden = false
    @State private var sourceSuggestion: Double = 0
    @State private var destinationSuggestion: Double = 0

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
        _accountPocket = State(initialValue: transaction?.accountCurrency)
        _destinationPocket = State(initialValue: transaction?.destinationAccountCurrency)
        _accountAmountText = State(initialValue: transaction?.accountAmount.map(Self.amountText) ?? "")
        _destinationAmountText = State(initialValue: transaction?.destinationAmount.map(Self.amountText) ?? "")
    }

    private static func amountText(_ value: Double) -> String { String(format: "%.2f", value) }

    private var amount: Double { (Double(minorUnits) ?? 0) / 100 }
    private var activeAccounts: [LedgerAccount] { store.accounts.map(\.account) }
    private var canSave: Bool { amount > 0 && accountID != nil && (type != .transfer || (destinationID != nil && destinationID != accountID)) }

    private var sourceAccount: LedgerAccount? { accountID.flatMap { id in activeAccounts.first { $0.id == id } } }
    private var destinationAccount: LedgerAccount? { destinationID.flatMap { id in activeAccounts.first { $0.id == id } } }

    /// Pocket actually used on the source account. Defaults to the transaction currency when the
    /// account already holds it, otherwise to the account's primary currency.
    private var sourcePocket: CurrencyCode {
        guard let sourceAccount else { return currency }
        if let accountPocket, sourceAccount.pocketCurrencies.contains(accountPocket) { return accountPocket }
        return sourceAccount.defaultPocket(for: currency)
    }

    private var targetPocket: CurrencyCode {
        guard let destinationAccount else { return currency }
        if let destinationPocket, destinationAccount.pocketCurrencies.contains(destinationPocket) { return destinationPocket }
        return destinationAccount.defaultPocket(for: currency)
    }

    private var showsSourcePocket: Bool { sourceAccount?.hasMultiplePockets ?? false }
    private var showsDestinationPocket: Bool { type == .transfer && (destinationAccount?.hasMultiplePockets ?? false) }
    /// The account-side amount is only editable when it is not simply the transaction amount.
    private var showsSourceAmount: Bool { sourcePocket != currency }
    private var showsDestinationAmount: Bool { type == .transfer && targetPocket != currency }
    private var estimatedSourceAmount: Double { LedgerCalculations.convert(amount, from: currency, to: sourcePocket, rates: store.state.settings.rates) }
    private var estimatedDestinationAmount: Double { LedgerCalculations.convert(amount, from: currency, to: targetPocket, rates: store.state.settings.rates) }
    private var sourcePostingValue: Double { showsSourceAmount ? (Double(accountAmountText) ?? estimatedSourceAmount) : amount }
    private var destinationPostingValue: Double { showsDestinationAmount ? (Double(destinationAmountText) ?? estimatedDestinationAmount) : amount }

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
            if original == nil { syncAmountFields() } else { prefillStoredAmounts() }
        }
        .onChange(of: categoryID) { _, category in if type == .expense && !accountExplicitlyOverridden { applyDefaultAccount(for: category) } }
        .onChange(of: type) { _, value in if value == .expense && !accountExplicitlyOverridden { applyDefaultAccount(for: categoryID) } }
        .onChange(of: currency) { _, _ in
            // The pocket default depends on the denomination, so re-resolve it and drop stale guesses.
            accountPocket = nil
            destinationPocket = nil
            accountAmountOverridden = false
            destinationAmountOverridden = false
            syncAmountFields()
        }
        .onChange(of: amount) { _, _ in syncAmountFields() }
        .sheet(isPresented: $showingCategoryEditor) {
            CategoryEditorSheet { id in categoryID = id }
        }
    }

    private var amountPanel: some View {
        VStack(spacing: 8) {
            TransactionCurrencyPicker(selection: $currency)
            SensitiveMoneyText(amount: amount, currency: currency).font(.system(size: 48, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 12).ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var detailsPanel: some View {
        VStack(spacing: 0) {
            LabeledContent(type == .transfer ? "From Account" : "Account") {
                AccountSelectorMenu(accounts: activeAccounts, selection: $accountID, title: type == .transfer ? "From Account" : "Account")
            }
            .onChange(of: accountID) { _, newValue in
                if !applyingDefaultAccount { accountExplicitlyOverridden = true }
                accountPocket = nil
                accountAmountOverridden = false
                if let account = activeAccounts.first(where: { $0.id == newValue }) { currency = account.currency }
                if destinationID == newValue { destinationID = activeAccounts.first(where: { $0.id != newValue })?.id }
                syncAmountFields()
            }
            if showsSourcePocket {
                Divider()
                LabeledContent(type == .transfer ? "From Account Currency" : "Account Currency") {
                    AccountPocketPicker(account: sourceAccount ?? activeAccountPlaceholder, selection: sourcePocketBinding, title: "Account Currency")
                }
            }
            if showsSourceAmount {
                Divider()
                accountAmountRow(title: type == .transfer ? "From Account Amount" : "Account Amount",
                                 pocket: sourcePocket,
                                 text: $accountAmountText,
                                 overridden: $accountAmountOverridden,
                                 suggestion: $sourceSuggestion,
                                 estimated: estimatedSourceAmount)
            }
            if type == .transfer {
                Divider()
                LabeledContent("To Account") {
                    AccountSelectorMenu(accounts: activeAccounts.filter { $0.id != accountID }, selection: $destinationID, title: "To Account")
                }
                .onChange(of: destinationID) { _, _ in
                    destinationPocket = nil
                    destinationAmountOverridden = false
                    syncAmountFields()
                }
                if showsDestinationPocket {
                    Divider()
                    LabeledContent("To Account Currency") {
                        AccountPocketPicker(account: destinationAccount ?? activeAccountPlaceholder, selection: targetPocketBinding, title: "To Account Currency")
                    }
                }
                if showsDestinationAmount {
                    Divider()
                    accountAmountRow(title: "To Account Amount",
                                     pocket: targetPocket,
                                     text: $destinationAmountText,
                                     overridden: $destinationAmountOverridden,
                                     suggestion: $destinationSuggestion,
                                     estimated: estimatedDestinationAmount)
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

    /// Editable actual account-side amount. Prefilled from the cached FX rate, but a value the user
    /// types becomes authoritative and is never overwritten afterwards.
    private func accountAmountRow(title: String, pocket: CurrencyCode, text: Binding<String>, overridden: Binding<Bool>, suggestion: Binding<Double>, estimated: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                Spacer(minLength: 8)
                Text(pocket.rawValue).font(.caption).foregroundStyle(.secondary)
                SensitiveValueContent(maskLength: 8) {
                    TextField("0.00", text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }
            }
            if overridden.wrappedValue {
                Button {
                    overridden.wrappedValue = false
                    suggestion.wrappedValue = estimated
                    text.wrappedValue = Self.amountText(estimated)
                } label: {
                    Label("Reset to estimated \(LedgerFormat.money(estimated, currency: pocket))", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text("Estimated from current FX rate").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .onChange(of: text.wrappedValue) { _, newValue in
            // A value equal to the FX suggestion is still a suggestion, not a manual override.
            if let value = Double(newValue), abs(value - suggestion.wrappedValue) > 0.005 { overridden.wrappedValue = true }
            else if newValue.isEmpty { overridden.wrappedValue = false }
        }
    }

    private var sourcePocketBinding: Binding<CurrencyCode> {
        Binding(get: { sourcePocket }, set: { accountPocket = $0; syncAmountFields() })
    }

    private var targetPocketBinding: Binding<CurrencyCode> {
        Binding(get: { targetPocket }, set: { destinationPocket = $0; syncAmountFields() })
    }

    /// Placeholder account so the pocket picker has pockets to read before a selection exists.
    private var activeAccountPlaceholder: LedgerAccount {
        LedgerAccount(id: UUID(), userID: SeedData.localUserID, name: "", type: .checking, currency: currency, openingBalance: 0, budget: 0, includeInBudget: false, logo: "", cardStyle: .init(startHex: "86C5DA", endHex: "C6E7CF"), createdAt: .now, updatedAt: .now, deletedAt: nil, version: 0, syncStatus: .pending)
    }

    /// Refreshes the FX-estimated account amounts unless the user supplied their own value.
    private func syncAmountFields() {
        if !accountAmountOverridden {
            sourceSuggestion = estimatedSourceAmount
            accountAmountText = showsSourceAmount ? Self.amountText(estimatedSourceAmount) : ""
        }
        if !destinationAmountOverridden {
            destinationSuggestion = estimatedDestinationAmount
            destinationAmountText = showsDestinationAmount ? Self.amountText(estimatedDestinationAmount) : ""
        }
    }

    /// Existing transactions keep their stored account-side amounts until the user changes a field
    /// that invalidates them; nothing is re-priced from today's rate when the editor opens.
    private func prefillStoredAmounts() {
        accountAmountText = showsSourceAmount ? (original?.accountAmount.map(Self.amountText) ?? Self.amountText(estimatedSourceAmount)) : ""
        destinationAmountText = showsDestinationAmount ? (original?.destinationAmount.map(Self.amountText) ?? Self.amountText(estimatedDestinationAmount)) : ""
        sourceSuggestion = estimatedSourceAmount
        destinationSuggestion = estimatedDestinationAmount
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
        guard let accountID, let sourceAccount else { return }
        let sourceAccountCurrency = sourceAccount.usesCurrencyPockets ? sourcePocket : nil
        let destinationAccountCurrency = (type == .transfer && destinationAccount?.usesCurrencyPockets == true) ? targetPocket : nil
        if var original {
            original.type = type; original.accountID = accountID; original.destinationAccountID = type == .transfer ? destinationID : nil
            original.amount = amount; original.currency = currency; original.categoryID = type == .transfer ? .other : categoryID
            original.occurredAt = occurredAt; original.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
            // Actual account-side postings. A manually edited value is stored as-is.
            original.accountCurrency = sourceAccountCurrency
            original.accountAmount = sourcePostingValue
            original.destinationAccountCurrency = type == .transfer ? destinationAccountCurrency : nil
            original.destinationAmount = type == .transfer ? destinationPostingValue : nil
            store.updateTransaction(original)
        } else {
            store.addTransaction(type: type, accountID: accountID, destinationAccountID: destinationID, amount: amount, currency: currency, categoryID: categoryID, occurredAt: occurredAt, note: note, accountCurrency: sourceAccountCurrency, accountAmount: sourcePostingValue, destinationAccountCurrency: destinationAccountCurrency, destinationAmount: type == .transfer ? destinationPostingValue : nil)
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
