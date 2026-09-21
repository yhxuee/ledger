import SwiftUI

struct DefaultExpenseAccountsView: View {
    @EnvironmentObject private var store: LedgerStore

    private var expenseCategories: [LedgerCategory] {
        store.state.categories.filter { $0.kind == .expense && !$0.id.isSystemLinked && !store.state.settings.archivedCategoryIDs.contains($0.id) }
    }
    private var incomeCategories: [LedgerCategory] {
        store.state.categories.filter { $0.kind == .income && !$0.id.isSystemLinked && !store.state.settings.archivedCategoryIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Expense Categories") {
                    VStack(spacing: 0) {
                        ForEach(Array(expenseCategories.enumerated()), id: \.element.id) { index, category in
                            categoryRow(category)
                            if index < expenseCategories.count - 1 {
                                Divider()
                            }
                        }
                    }
                }

                if !incomeCategories.isEmpty {
                    SettingsGlassSection("Income Categories") {
                        VStack(spacing: 0) {
                            ForEach(Array(incomeCategories.enumerated()), id: \.element.id) { index, category in
                                categoryRow(category)
                                if index < incomeCategories.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Default Accounts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var availableAccounts: [AccountViewModel] {
        store.accounts.filter { $0.account.isAvailableForNewTransactions }
    }

    private func categoryRow(_ category: LedgerCategory) -> some View {
        let mappedID = store.state.settings.defaultExpenseAccountByCategory[category.id]
        let mappedAccount = mappedID.flatMap { id in store.state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) }

        return HStack(alignment: .center, spacing: 10) {
            CategoryIcon(
                category: category,
                font: .system(size: 17, weight: .semibold)
            )
            .frame(width: 32, height: 32, alignment: .center)

            Text(category.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    store.updateSettings { $0.defaultExpenseAccountByCategory[category.id] = nil }
                } label: {
                    if mappedID == nil {
                        Label("No Default", systemImage: "checkmark")
                    } else {
                        Text("No Default")
                    }
                }

                ForEach(availableAccounts) { item in
                    Button {
                        store.updateSettings { $0.defaultExpenseAccountByCategory[category.id] = item.id }
                    } label: {
                        if mappedID == item.id {
                            Label(item.account.name, systemImage: "checkmark")
                        } else {
                            Text(item.account.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let mappedAccount {
                        Text(mappedAccount.logo)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(mappedAccount.effectiveIsFrozen ? .secondary : .primary)
                        if mappedAccount.effectiveIsFrozen {
                            Text("Frozen")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    } else {
                        Text("No Default")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 50)
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
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Automatic Rates", footer: "Automatic mode uses Frankfurter, keeps the last successful values offline, and locks manual input.") {
                    Toggle("Automatic Daily Rates", isOn: automaticBinding)

                    Divider()

                    Button {
                        Task { await refresh(showConfirmation: true) }
                    } label: {
                        HStack {
                            Label(updating ? "Updating…" : "Update Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(updating)

                    if let date = store.state.settings.exchangeRatesUpdatedAt {
                        Divider()
                        LabeledContent("Last Updated", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                SettingsGlassSection("1 Unit Equals") {
                    if currencies.isEmpty {
                        Text("No currencies found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(currencies.enumerated()), id: \.element.code) { index, currency in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(currency.code.rawValue).font(.body.weight(.semibold))
                                        if !currency.name.isEmpty {
                                            Text(currency.name).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    SensitiveValueContent {
                                        TextField("Rate", value: rateBinding(currency.code), format: .number.precision(.fractionLength(0...8)))
                                            .keyboardType(.decimalPad)
                                            .multilineTextAlignment(.trailing)
                                            .frame(width: 112)
                                            .textFieldStyle(.roundedBorder)
                                            .focused($focusedRate, equals: currency.code)
                                            .disabled(automatic || currency.code.isUSDStablecoin)
                                    }
                                    Text(base.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)

                                if index < currencies.count - 1 {
                                    Divider().padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Exchange Rates")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Currency code or name")
        .scrollDismissesKeyboard(.interactively)
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
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Budget Mode", footer: "Category and account allocations are stored separately. Switching modes does not reinterpret identifiers or discard the other mode’s values.") {
                    Picker("Budget Mode", selection: modeBinding) {
                        ForEach(BudgetMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if store.state.settings.budgetPlan.mode == .category {
                    let cats = store.state.categories.filter { $0.kind == .expense && !$0.id.isSystemLinked && !store.state.settings.archivedCategoryIDs.contains($0.id) }
                    SettingsGlassSection("Monthly Category Budgets") {
                        VStack(spacing: 0) {
                            ForEach(Array(cats.enumerated()), id: \.element.id) { index, category in
                                HStack {
                                    CategoryIcon(category: category)
                                        .frame(width: 28, height: 28, alignment: .center)
                                    Text(category.displayName)
                                    Spacer()
                                    amountField(categoryAllocation(category.id), currency: store.state.settings.baseCurrency)
                                }
                                .padding(.vertical, 4)

                                if index < cats.count - 1 {
                                    Divider().padding(.vertical, 4)
                                }
                            }
                        }
                    }
                } else {
                    let accts = store.accounts
                    SettingsGlassSection("Monthly Account Budgets") {
                        VStack(spacing: 0) {
                            ForEach(Array(accts.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Text(item.account.name)
                                    Spacer()
                                    amountField(accountAllocation(item.id), currency: item.account.currency)
                                }
                                .padding(.vertical, 4)

                                if index < accts.count - 1 {
                                    Divider().padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
    }
    private var modeBinding: Binding<BudgetMode> { Binding(get: { store.state.settings.budgetPlan.mode }, set: { mode in store.updateSettings { $0.budgetPlan.mode = mode; $0.budgetPlan.updatedAt = .now } }) }
    private func categoryAllocation(_ id: LedgerCategoryID) -> Binding<Double> { Binding(get: { store.state.settings.budgetPlan.categoryAllocations[id] ?? 0 }, set: { value in store.updateSettings { $0.budgetPlan.categoryAllocations[id] = max(0, value); $0.budgetPlan.updatedAt = .now } }) }
    private func accountAllocation(_ id: UUID) -> Binding<Double> { Binding(get: { store.state.settings.budgetPlan.accountAllocations[id] ?? 0 }, set: { value in store.updateSettings { $0.budgetPlan.accountAllocations[id] = max(0, value); $0.budgetPlan.updatedAt = .now } }) }
    private func amountField(_ binding: Binding<Double>, currency: CurrencyCode) -> some View {
        HStack(spacing: 6) {
            SensitiveValueContent {
                TextField("0", value: binding, format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
            }
            Text(currency.symbol).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SwipeActionsEditorView: View {
    @EnvironmentObject private var preferences: AppPreferencesStore

    private var currentActions: [TransactionSwipeAction] {
        let actions = preferences.value.transactionSwipeActions
        return actions.count == 4 && Set(actions).count == 4 ? actions : AppPreferences.defaultSwipeActions
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection(
                    "Swipe Action Order",
                    footer: "Order: [1] Far Left [2] Near Left — ROW — [3] Near Right [4] Far Right.\nSwiping right reveals Near Left then Far Left. Swiping left reveals Near Right then Far Right."
                ) {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { index in
                            let action = currentActions[index]
                            HStack(spacing: 12) {
                                Image(systemName: action.systemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(actionColor(action))
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(slotDescription(for: index))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                HStack(spacing: 6) {
                                    Button {
                                        move(from: index, to: index - 1)
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(index > 0 ? .primary : .tertiary)
                                            .frame(width: 28, height: 28)
                                            .background(Color.primary.opacity(0.06), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)

                                    Button {
                                        move(from: index, to: index + 1)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(index < 3 ? .primary : .tertiary)
                                            .frame(width: 28, height: 28)
                                            .background(Color.primary.opacity(0.06), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == 3)
                                }
                            }
                            .padding(.vertical, 8)

                            if index < 3 {
                                Divider().padding(.vertical, 2)
                            }
                        }
                    }
                }

                SettingsGlassSection {
                    Button {
                        preferences.update { $0.transactionSwipeActions = AppPreferences.defaultSwipeActions }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Reset to Default Order")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Swipe Actions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func slotDescription(for index: Int) -> String {
        switch index {
        case 0: "Slot 1 · Far Left (Swipe Right)"
        case 1: "Slot 2 · Near Left (Swipe Right)"
        case 2: "Slot 3 · Near Right (Swipe Left)"
        case 3: "Slot 4 · Far Right (Swipe Left)"
        default: ""
        }
    }

    private func actionColor(_ action: TransactionSwipeAction) -> Color {
        switch action {
        case .reimburse: .purple
        case .refund: .blue
        case .delete: .red
        case .split: .teal
        }
    }

    private func move(from source: Int, to destination: Int) {
        guard source >= 0, source < 4, destination >= 0, destination < 4, source != destination else { return }
        var current = currentActions
        let item = current.remove(at: source)
        current.insert(item, at: destination)
        if current.count == 4 && Set(current).count == 4 {
            preferences.update { $0.transactionSwipeActions = current }
        }
    }
}

struct RecurringTransactionsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var showingNew = false
    @State private var editing: RecurringRule?
    @State private var showingCalendarImport = false
    @State private var importedDraft: RecurringImportDraft?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Actions") {
                    Button {
                        showingNew = true
                    } label: {
                        HStack {
                            Label("Add Recurring Transaction", systemImage: "calendar.badge.plus")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Button {
                        showingCalendarImport = true
                    } label: {
                        HStack {
                            Label("Import from Calendar", systemImage: "calendar.badge.arrowtriangle.forward")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                SettingsGlassSection("Recurring Rules") {
                    if store.recurringRules.isEmpty {
                        ContentUnavailableView("No Recurring Transactions", systemImage: "calendar.badge.clock")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.recurringRules.enumerated()), id: \.element.id) { index, rule in
                                HStack {
                                    Button {
                                        if rule.effectiveAmountKind == .fixed { editing = rule }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(rule.note?.isEmpty == false ? rule.note! : rule.type.title)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            HStack(spacing: 4) {
                                                Text("\(rule.interval.title) ·")
                                                if rule.effectiveAmountKind == .loanInterest {
                                                    SensitiveValueText("Dynamic interest")
                                                } else {
                                                    SensitiveMoneyText(amount: rule.amount, currency: rule.currency)
                                                }
                                                Text("· next \(rule.nextRunAt.formatted(date: .abbreviated, time: .omitted))")
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    Toggle("Enabled", isOn: Binding(
                                        get: { rule.isEnabled },
                                        set: { store.setRecurringRule(rule, enabled: $0) }
                                    ))
                                    .labelsHidden()

                                    if rule.effectiveAmountKind == .fixed {
                                        Button(role: .destructive) {
                                            store.deleteRecurringRule(rule)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.subheadline)
                                                .foregroundStyle(.red)
                                                .frame(width: 32, height: 32)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Delete rule")
                                    }
                                }
                                .padding(.vertical, 4)
                                .contextMenu {
                                    if rule.effectiveAmountKind == .fixed {
                                        Button("Edit") { editing = rule }
                                        Button("Delete", role: .destructive) { store.deleteRecurringRule(rule) }
                                    }
                                }

                                if index < store.recurringRules.count - 1 {
                                    Divider().padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Recurring")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNew) { RecurringRuleEditorView(rule: nil) }
        .sheet(item: $editing) { RecurringRuleEditorView(rule: $0) }
        .sheet(isPresented: $showingCalendarImport) { CalendarEventPickerView { draft in DispatchQueue.main.async { importedDraft = draft } } }
        .sheet(item: $importedDraft) { RecurringRuleEditorView(rule: nil, importDraft: $0) }
    }
}

struct RecurringRuleEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
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
                        CurrencyMenuButton(selection: $currency, codes: CurrencySelection.common, showsOther: true)
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
                    if type != .transfer { Picker("Category", selection: $categoryID) { ForEach(store.state.categories.filter { !$0.id.isSystemLinked && !store.state.settings.archivedCategoryIDs.contains($0.id) }) { Text($0.displayName).tag($0.id) } } }
                    TextField("Note (optional)", text: $note)
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $interval) { ForEach(RecurringInterval.allCases) { Text($0.title).tag($0) } }
                    if interval == .customDays { Stepper("Every \(customDays) days", value: $customDays, in: 1...365) }
                    DatePicker("Next Run", selection: $nextRunAt, displayedComponents: [.date, .hourAndMinute]); Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle(originalID == nil ? "New Recurring" : "Edit Recurring").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .disabled(!canSave)
                    .accessibilityLabel("Save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { amountFocused = false }
                }
            }
            .onAppear { if accountID == nil { accountID = accounts.first?.id; currency = accounts.first?.currency ?? .HKD }; if destinationID == nil { destinationID = accounts.first(where: { $0.id != accountID })?.id } }
            .onChange(of: accountID) { _, id in if let account = accounts.first(where: { $0.id == id }) { currency = account.currency }; if destinationID == id { destinationID = accounts.first(where: { $0.id != id })?.id } }
        }
    }
    private func save() {
        guard let accountID else { return }; let now = Date.now
        let resolvedSourcePocket = sourceAccount?.usesCurrencyPockets == true ? (accountCurrency ?? sourceAccount?.defaultPocket(for: currency)) : nil
        let resolvedDestinationPocket = destinationAccount?.usesCurrencyPockets == true ? (destinationCurrency ?? destinationAccount?.defaultPocket(for: currency)) : nil
        store.saveRecurringRule(.init(id: originalID ?? UUID(), userID: store.state.settings.userID, type: type, accountID: accountID, destinationAccountID: type == .transfer ? destinationID : nil, amount: amount, currency: currency, categoryID: type == .transfer ? .other : categoryID, note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note, accountCurrency: resolvedSourcePocket, destinationAccountCurrency: type == .transfer ? resolvedDestinationPocket : nil, interval: interval, customIntervalDays: max(1, customDays), nextRunAt: nextRunAt, isEnabled: isEnabled, createdAt: originalCreatedAt, updatedAt: now))
        store.processDueRecurring(); dismiss()
    }
}


struct LayoutSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferencesStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Overview Card Layout") {
                    Picker("Overview Card Layout", selection: Binding(
                        get: { preferences.value.overviewCardLayout },
                        set: { val in preferences.update { $0.overviewCardLayout = val } }
                    )) {
                        ForEach(AccountCardLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                SettingsGlassSection("Transaction Editor Layout") {
                    VStack(spacing: 0) {
                        ForEach(TransactionEditorLayout.allCases) { layout in
                            Button {
                                preferences.update { $0.transactionLayout = layout }
                            } label: {
                                HStack {
                                    Text(layout.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if preferences.value.transactionLayout == layout {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .frame(minHeight: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if layout != TransactionEditorLayout.allCases.last {
                                Divider()
                            }
                        }
                    }
                }

                SettingsGlassSection("Overview Metrics", footer: "Overview displays exactly two metric cards. Selecting a duplicate metric automatically swaps the existing card.") {
                    LabeledContent {
                        Picker("First Card", selection: Binding(
                            get: { preferences.value.overviewMetrics.first ?? .sixMonthTrend },
                            set: { val in preferences.update { $0.setOverviewMetric(at: 0, to: val) } }
                        )) {
                            ForEach(OverviewMetricKind.allCases) { kind in
                                Text(LocalizedStringKey(kind.title)).tag(kind)
                            }
                        }
                    } label: {
                        Text("First Card")
                    }

                    Divider()

                    LabeledContent {
                        Picker("Second Card", selection: Binding(
                            get: { preferences.value.overviewMetrics.count > 1 ? preferences.value.overviewMetrics[1] : .weekExpensePie },
                            set: { val in preferences.update { $0.setOverviewMetric(at: 1, to: val) } }
                        )) {
                            ForEach(OverviewMetricKind.allCases) { kind in
                                Text(LocalizedStringKey(kind.title)).tag(kind)
                            }
                        }
                    } label: {
                        Text("Second Card")
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountCardStyleSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferencesStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Card Surface Style", footer: "Choose how account cards are finished. Auto selects Glass for transparent cards and Metal for standard and opaque cards.") {
                    VStack(spacing: 0) {
                        ForEach(AccountCardMaterialStyle.allCases) { style in
                            Button {
                                preferences.update { $0.accountCardMaterialStyle = style }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(style.title)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(style.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if preferences.value.accountCardMaterialStyle == style {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if style != AccountCardMaterialStyle.allCases.last {
                                Divider().padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Style")
        .navigationBarTitleDisplayMode(.inline)
    }
}
