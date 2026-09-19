import SwiftUI

struct DefaultExpenseAccountsView: View {
    @EnvironmentObject private var store: LedgerStore
    var body: some View {
        List {
            Section {
                ForEach(store.state.categories) { category in
                    Picker(selection: mappingBinding(category.id)) {
                        Text("No Default").tag(Optional<UUID>.none)
                        ForEach(store.accounts) { item in Text(item.account.name).tag(Optional(item.id)) }
                    } label: {
                        HStack { CategoryIcon(category: category); Text(category.name) }
                    }
                }
            } footer: { Text("New expenses automatically use the mapped account until you explicitly choose another account in that edit.") }
        }
        .navigationTitle("Default Accounts").navigationBarTitleDisplayMode(.inline)
    }
    private func mappingBinding(_ categoryID: LedgerCategoryID) -> Binding<UUID?> {
        Binding(get: { store.state.settings.defaultExpenseAccountByCategory[categoryID] }, set: { accountID in
            store.updateSettings { $0.defaultExpenseAccountByCategory[categoryID] = accountID }
        })
    }
}

struct ExchangeRateEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var query = ""
    @State private var updating = false
    @State private var statusMessage: String?
    @FocusState private var focusedRate: CurrencyCode?
    private var base: CurrencyCode { store.state.settings.baseCurrency }
    private var automatic: Bool { store.state.settings.automaticRates }
    private var currencies: [CurrencyDescriptor] {
        store.currencyCatalog.filter { item in item.code != base && (query.isEmpty || item.code.rawValue.localizedCaseInsensitiveContains(query) || item.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            Section {
                Toggle("Automatic Daily Rates", isOn: automaticBinding)
                Button { Task { await refresh(showConfirmation: true) } } label: { Label(updating ? "Updating…" : "Update Now", systemImage: "arrow.triangle.2.circlepath") }.disabled(updating)
                if let date = store.state.settings.exchangeRatesUpdatedAt { LabeledContent("Last Updated", value: date.formatted(date: .abbreviated, time: .shortened)) }
            } footer: { Text("Automatic mode uses Frankfurter, keeps the last successful values offline, and locks manual input.") }
            Section("1 unit equals") {
                ForEach(currencies) { currency in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) { Text(currency.code.rawValue).font(.body.weight(.semibold)) }
                        Spacer(minLength: 8)
                        SensitiveValueContent {
                            TextField("Rate", value: rateBinding(currency.code), format: .number.precision(.fractionLength(0...8)))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 112)
                                .focused($focusedRate, equals: currency.code).disabled(automatic || currency.code.isUSDStablecoin)
                        }
                        Text(base.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Exchange Rates").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Currency code or name").scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedRate = nil } } }
        .alert("Exchange Rates", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) { Button("OK") { statusMessage = nil } } message: { Text(statusMessage ?? "") }
    }
    private var automaticBinding: Binding<Bool> {
        Binding(get: { automatic }, set: { value in focusedRate = nil; store.updateSettings { $0.automaticRates = value }; if value { Task { await refresh(showConfirmation: false) } } })
    }
    private func rateBinding(_ currency: CurrencyCode) -> Binding<Double> {
        Binding(get: { (CurrencyRates.reference(currency, in: store.state.settings.rates) ?? 1) / (CurrencyRates.reference(base, in: store.state.settings.rates) ?? 1) }, set: { shown in
            guard !automatic, !currency.isUSDStablecoin else { return }
            store.updateSettings {
                let safe = max(0.00000001, shown)
                if currency == .HKD && base != .HKD { $0.rates[base.referenceCurrency] = 1 / safe }
                else { $0.rates[currency] = safe * (CurrencyRates.reference(base, in: $0.rates) ?? 1) }
                $0.rates[.HKD] = 1
            }
        })
    }
    @MainActor private func refresh(showConfirmation: Bool) async {
        guard !updating else { return }
        focusedRate = nil; updating = true; defer { updating = false }
        do {
            try await store.refreshCurrencyCatalogIfNeeded(force: true)
            let date = try await store.refreshExchangeRatesIfNeeded(force: true) ?? "the latest available date"
            if showConfirmation { statusMessage = "Reference rates updated for \(date)." }
        } catch { store.presentedError = "Exchange-rate update failed: \(error.localizedDescription)" }
    }
}

struct BudgetEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @FocusState private var focused: Bool
    var body: some View {
        List {
            Section {
                Picker("Budget Mode", selection: modeBinding) { ForEach(BudgetMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            } footer: { Text("Category and account allocations are stored separately. Switching modes does not reinterpret identifiers or discard the other mode’s values.") }
            if store.state.settings.budgetPlan.mode == .category {
                Section("Monthly Category Budgets") {
                    ForEach(store.state.categories) { category in
                        LabeledContent { amountField(categoryAllocation(category.id), currency: store.state.settings.baseCurrency) } label: { HStack { CategoryIcon(category: category); Text(category.name) } }
                    }
                }
            } else {
                Section("Monthly Account Budgets") {
                    ForEach(store.accounts) { item in
                        LabeledContent { amountField(accountAllocation(item.id), currency: item.account.currency) } label: { Text(item.account.name) }
                    }
                }
            }
        }
        .navigationTitle("Budget").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
    }
    private var modeBinding: Binding<BudgetMode> { Binding(get: { store.state.settings.budgetPlan.mode }, set: { mode in store.updateSettings { $0.budgetPlan.mode = mode; $0.budgetPlan.updatedAt = .now } }) }
    private func categoryAllocation(_ id: LedgerCategoryID) -> Binding<Double> { Binding(get: { store.state.settings.budgetPlan.categoryAllocations[id] ?? 0 }, set: { value in store.updateSettings { $0.budgetPlan.categoryAllocations[id] = max(0, value); $0.budgetPlan.updatedAt = .now } }) }
    private func accountAllocation(_ id: UUID) -> Binding<Double> { Binding(get: { store.state.settings.budgetPlan.accountAllocations[id] ?? 0 }, set: { value in store.updateSettings { $0.budgetPlan.accountAllocations[id] = max(0, value); $0.budgetPlan.updatedAt = .now } }) }
    private func amountField(_ binding: Binding<Double>, currency: CurrencyCode) -> some View {
        HStack { SensitiveValueContent { TextField("0", value: binding, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110).focused($focused) }; Text(currency.symbol).font(.caption).foregroundStyle(.secondary) }
    }
}

struct SwipeActionsEditorView: View {
    @EnvironmentObject private var preferences: AppPreferencesStore
    var body: some View {
        List {
            Section {
                ForEach(SwipeActionOrientation.allCases) { option in
                    Button { preferences.update { $0.swipeActionOrientation = option } } label: {
                        HStack { Text(option.title); Spacer(); if preferences.value.swipeActionOrientation == option { Image(systemName: "checkmark").fontWeight(.semibold) } }
                    }
                }
            } footer: { Text("Leading means swiping right. Trailing means swiping left.") }
        }.navigationTitle("Swipe Actions").navigationBarTitleDisplayMode(.inline)
    }
}

struct RecurringTransactionsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var showingNew = false
    @State private var editing: RecurringRule?
    @State private var showingCalendarImport = false
    @State private var importedDraft: RecurringImportDraft?
    var body: some View {
        List {
            Section {
                Button { showingNew = true } label: { Label("Add Recurring Transaction", systemImage: "calendar.badge.plus") }
                Button { showingCalendarImport = true } label: { Label("Import from Calendar", systemImage: "calendar.badge.arrowtriangle.forward") }
            }
            Section {
                ForEach(store.recurringRules) { rule in
                    Button { if rule.effectiveAmountKind == .fixed { editing = rule } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.note?.isEmpty == false ? rule.note! : rule.type.title).font(.body.weight(.semibold))
                                HStack(spacing: 4) {
                                    Text("\(rule.interval.title) ·")
                                    if rule.effectiveAmountKind == .loanInterest { SensitiveValueText("Dynamic interest") }
                                    else { SensitiveMoneyText(amount: rule.amount, currency: rule.currency) }
                                    Text("· next \(rule.nextRunAt.formatted(date: .abbreviated, time: .omitted))")
                                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(get: { rule.isEnabled }, set: { store.setRecurringRule(rule, enabled: $0) })).labelsHidden()
                        }
                    }.buttonStyle(.plain)
                    .swipeActions { if rule.effectiveAmountKind == .fixed { Button("Delete", role: .destructive) { store.deleteRecurringRule(rule) } } }
                }
                if store.recurringRules.isEmpty { ContentUnavailableView("No Recurring Transactions", systemImage: "calendar.badge.clock") }
            }
        }
        .navigationTitle("Recurring").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNew) { RecurringRuleEditorView(rule: nil) }
        .sheet(item: $editing) { RecurringRuleEditorView(rule: $0) }
        .sheet(isPresented: $showingCalendarImport) { CalendarEventPickerView { draft in DispatchQueue.main.async { importedDraft = draft } } }
        .sheet(item: $importedDraft) { RecurringRuleEditorView(rule: nil, importDraft: $0) }
    }
}

struct RecurringRuleEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    private let originalID: UUID?
    private let originalCreatedAt: Date
    @State private var type: LedgerTransactionType
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var amount: Double
    @State private var currency: CurrencyCode
    @State private var accountCurrency: CurrencyCode?
    @State private var destinationCurrency: CurrencyCode?
    @State private var categoryID: LedgerCategoryID
    @State private var note: String
    @State private var interval: RecurringInterval
    @State private var customDays: Int
    @State private var nextRunAt: Date
    @State private var isEnabled: Bool
    @FocusState private var amountFocused: Bool

    init(rule: RecurringRule?, importDraft: RecurringImportDraft? = nil) {
        originalID = rule?.id; originalCreatedAt = rule?.createdAt ?? .now
        _type = State(initialValue: rule?.type ?? .expense); _accountID = State(initialValue: rule?.accountID); _destinationID = State(initialValue: rule?.destinationAccountID)
        _amount = State(initialValue: rule?.amount ?? 0); _currency = State(initialValue: rule?.currency ?? .HKD); _categoryID = State(initialValue: rule?.categoryID ?? .food)
        _accountCurrency = State(initialValue: rule?.accountCurrency); _destinationCurrency = State(initialValue: rule?.destinationAccountCurrency)
        _note = State(initialValue: rule?.note ?? importDraft?.title ?? ""); _interval = State(initialValue: rule?.interval ?? importDraft?.interval ?? .monthly); _customDays = State(initialValue: rule?.customIntervalDays ?? importDraft?.customDays ?? 14)
        _nextRunAt = State(initialValue: rule?.nextRunAt ?? importDraft?.nextRunAt ?? .now); _isEnabled = State(initialValue: rule?.isEnabled ?? true)
    }
    private var accounts: [LedgerAccount] { store.accounts.map(\.account) }
    private var sourceAccount: LedgerAccount? { accountID.flatMap { id in accounts.first { $0.id == id } } }
    private var destinationAccount: LedgerAccount? { destinationID.flatMap { id in accounts.first { $0.id == id } } }
    private var canSave: Bool { amount > 0 && accountID != nil && (type != .transfer || (destinationID != nil && destinationID != accountID)) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    Picker("Type", selection: $type) { ForEach(LedgerTransactionType.allCases) { Text($0.title).tag($0) } }
                    Picker(type == .transfer ? "From Account" : "Account", selection: $accountID) { ForEach(accounts) { Text($0.name).tag(Optional($0.id)) } }
                    if type == .transfer { Picker("To Account", selection: $destinationID) { ForEach(accounts.filter { $0.id != accountID }) { Text($0.name).tag(Optional($0.id)) } } }
                    LabeledContent("Amount") { SensitiveValueContent { TextField("0", value: $amount, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($amountFocused) } }
                    LabeledContent("Currency") {
                        PopupSelectionButton(title: "Currency",
                                                 codes: CurrencySelection.common,
                                                 selection: currency,
                                                 otherCurrencies: true,
                                                 onSelect: { currency = $0 }) {
                            HStack(spacing: 6) {
                                Text(currency.rawValue).foregroundStyle(.secondary)
                                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let sourceAccount, sourceAccount.hasMultiplePockets {
                        LabeledContent(type == .transfer ? "From Account Currency" : "Account Currency") {
                            AccountPocketPicker(account: sourceAccount,
                                                selection: Binding(get: { accountCurrency ?? sourceAccount.defaultPocket(for: currency) }, set: { accountCurrency = $0 }),
                                                title: "Account Currency")
                        }
                    }
                    if type == .transfer, let destinationAccount, destinationAccount.hasMultiplePockets {
                        LabeledContent("To Account Currency") {
                            AccountPocketPicker(account: destinationAccount,
                                                selection: Binding(get: { destinationCurrency ?? destinationAccount.defaultPocket(for: currency) }, set: { destinationCurrency = $0 }),
                                                title: "To Account Currency")
                        }
                    }
                    if type != .transfer { Picker("Category", selection: $categoryID) { ForEach(store.state.categories) { Text($0.name).tag($0.id) } } }
                    TextField("Note (optional)", text: $note)
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $interval) { ForEach(RecurringInterval.allCases) { Text($0.title).tag($0) } }
                    if interval == .customDays { Stepper("Every \(customDays) days", value: $customDays, in: 1...365) }
                    DatePicker("Next Run", selection: $nextRunAt, displayedComponents: [.date, .hourAndMinute]); Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle(originalID == nil ? "New Recurring" : "Edit Recurring").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave).fontWeight(.semibold) }; ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { amountFocused = false } } }
            .onAppear { if accountID == nil { accountID = accounts.first?.id; currency = accounts.first?.currency ?? .HKD }; if destinationID == nil { destinationID = accounts.first(where: { $0.id != accountID })?.id } }
            .onChange(of: accountID) { _, id in if let account = accounts.first(where: { $0.id == id }) { currency = account.currency }; if destinationID == id { destinationID = accounts.first(where: { $0.id != id })?.id } }
        }
        .anchoredCurrencyDropdownLayer()
    }
    private func save() {
        guard let accountID else { return }; let now = Date.now
        let resolvedSourcePocket = sourceAccount?.usesCurrencyPockets == true ? (accountCurrency ?? sourceAccount?.defaultPocket(for: currency)) : nil
        let resolvedDestinationPocket = destinationAccount?.usesCurrencyPockets == true ? (destinationCurrency ?? destinationAccount?.defaultPocket(for: currency)) : nil
        store.saveRecurringRule(.init(id: originalID ?? UUID(), userID: store.state.settings.userID, type: type, accountID: accountID, destinationAccountID: type == .transfer ? destinationID : nil, amount: amount, currency: currency, categoryID: type == .transfer ? .other : categoryID, note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note, accountCurrency: resolvedSourcePocket, destinationAccountCurrency: type == .transfer ? resolvedDestinationPocket : nil, interval: interval, customIntervalDays: max(1, customDays), nextRunAt: nextRunAt, isEnabled: isEnabled, createdAt: originalCreatedAt, updatedAt: now))
        store.processDueRecurring(); dismiss()
    }
}
