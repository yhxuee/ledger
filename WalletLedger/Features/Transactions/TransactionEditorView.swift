import SwiftUI
import UIKit

struct TransactionEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    private let original: LedgerTransaction?
    @State private var type: LedgerTransactionType
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var currency: CurrencyCode
    @State private var categoryID: LedgerCategoryID
    @State private var occurredAt: Date
    @State private var note: String
    @State private var minorUnits: String
    @State private var isNegative: Bool
    @State private var showingCategoryEditor = false
    @State private var accountExplicitlyOverridden: Bool
    @State private var applyingDefaultAccount = false
    @State private var accountAmountText: String
    @State private var destinationAmountText: String
    /// True once the user typed their own account-side amount: never recalculated afterwards.
    @State private var accountAmountOverridden = false
    @State private var destinationAmountOverridden = false
    @State private var sourceSuggestion: Double = 0
    @State private var destinationSuggestion: Double = 0
    @State private var showingDatePicker = false
    @State private var showingCamera = false
    @State private var noteImage: UIImage?
    @State private var noteImageChanged = false
    @State private var noteAttachmentID: String?
    @State private var removedAttachmentID: String?
    @State private var saving = false
    @State private var showingNoteEditor: Bool
    @State private var taxRate: Double?
    @State private var taxInputMode: TaxInputMode
    @State private var isTaxExempt: Bool
    @State private var taxChanged = false
    @FocusState private var noteFocused: Bool

    init(transaction: LedgerTransaction? = nil) {
        original = transaction
        _showingNoteEditor = State(initialValue: transaction != nil)
        let initialType = transaction?.type ?? .expense
        _type = State(initialValue: initialType)
        _accountID = State(initialValue: transaction?.accountID)
        _destinationID = State(initialValue: transaction?.destinationAccountID)
        _currency = State(initialValue: transaction?.currency ?? .HKD)
        let defaultCat: LedgerCategoryID = (initialType == .income) ? .salary : .food
        _categoryID = State(initialValue: transaction?.categoryID ?? defaultCat)
        _occurredAt = State(initialValue: transaction?.occurredAt ?? .now)
        _note = State(initialValue: transaction?.note ?? "")
        _taxRate = State(initialValue: initialType == .transfer ? nil : transaction?.taxRate)
        _taxInputMode = State(initialValue: initialType == .transfer ? .finalAmount : (transaction?.taxInputMode ?? .finalAmount))
        _isTaxExempt = State(initialValue: initialType == .transfer ? false : (transaction?.isTaxExempt ?? false))
        let rawAmount = initialType != .transfer && transaction?.taxInputMode == .beforeTax
            ? (transaction?.taxBaseAmount ?? transaction?.amount ?? 0) : (transaction?.amount ?? 0)
        _isNegative = State(initialValue: rawAmount < 0)
        _minorUnits = State(initialValue: String(Int((abs(rawAmount) * 100).rounded())))
        _accountExplicitlyOverridden = State(initialValue: transaction != nil)
        _accountAmountText = State(initialValue: transaction?.accountAmount.map(Self.amountText) ?? "")
        _destinationAmountText = State(initialValue: transaction?.destinationAmount.map(Self.amountText) ?? "")
        _noteAttachmentID = State(initialValue: transaction?.noteAttachmentID)
    }

    private static func amountText(_ value: Double) -> String { String(format: "%.2f", value) }

    private var enteredAmount: Double {
        let val = (Double(minorUnits) ?? 0) / 100
        return isNegative ? -val : val
    }
    private var taxSnapshot: TaxSnapshot? {
        guard type != .transfer else { return nil }
        if !taxChanged, let original { return original.taxSnapshot }
        guard let taxRate else { return nil }
        return TaxCalculations.resolve(entered: enteredAmount, type: type, rate: taxRate,
                                       mode: taxInputMode, exempt: isTaxExempt)
    }
    private var amount: Double {
        guard type != .transfer else { return enteredAmount }
        if !taxChanged, let original { return original.amount }
        return (isNegative ? -1 : 1) * TaxCalculations.rounded(taxSnapshot?.finalAmount ?? abs(enteredAmount))
    }
    private func reloadTaxRate() {
        taxChanged = true
        if type == .transfer {
            taxRate = nil
            taxInputMode = .finalAmount
            isTaxExempt = false
        } else {
            if original == nil {
                taxInputMode = store.state.settings.defaultTaxInputMode
            }
            if let category = availableCategories.first(where: { $0.id == categoryID }) {
                taxRate = store.state.settings.taxRate(for: category)
            }
        }
    }

    private var activeAccounts: [LedgerAccount] { store.accounts.map(\.account) }
    private var canSave: Bool { abs(amount) > 0 && accountID != nil && (type != .transfer || (destinationID != nil && destinationID != accountID)) }
    private var hasNote: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || noteImage != nil || noteAttachmentID != nil
    }

    private var sourceAccount: LedgerAccount? { accountID.flatMap { id in activeAccounts.first { $0.id == id } } }
    private var destinationAccount: LedgerAccount? { destinationID.flatMap { id in activeAccounts.first { $0.id == id } } }

    private var activeKind: LedgerCategoryKind { type == .income ? .income : .expense }
    private var availableCategories: [LedgerCategory] { store.state.categories.filter { $0.kind == activeKind } }

    /// Pocket actually used on the source account. Defaults to the transaction currency when the
    /// account already holds it, otherwise to the account's primary currency.
    private var sourcePocket: CurrencyCode {
        guard let sourceAccount else { return currency }
        if let original,
           type == original.type,
           accountID == original.accountID,
           currency == original.currency,
           let stored = original.accountCurrency,
           sourceAccount.pocketCurrencies.contains(stored) {
            return stored
        }
        return sourceAccount.defaultPocket(for: currency)
    }

    private var targetPocket: CurrencyCode {
        guard let destinationAccount else { return currency }
        if let original,
           type == original.type,
           destinationID == original.destinationAccountID,
           currency == original.currency,
           let stored = original.destinationAccountCurrency,
           destinationAccount.pocketCurrencies.contains(stored) {
            return stored
        }
        return destinationAccount.defaultPocket(for: currency)
    }

    /// The account-side amount is only editable when it is not simply the transaction amount.
    private var showsSourceAmount: Bool { sourcePocket != currency }
    private var showsDestinationAmount: Bool { type == .transfer && targetPocket != currency }
    private var estimatedSourceAmount: Double { LedgerCalculations.convert(abs(amount), from: currency, to: sourcePocket, rates: store.state.settings.rates) }
    private var estimatedDestinationAmount: Double { LedgerCalculations.convert(abs(amount), from: currency, to: targetPocket, rates: store.state.settings.rates) }
    private var sourcePostingValue: Double {
        if let original,
           type == original.type,
           accountID == original.accountID,
           currency == original.currency,
           amount == original.amount,
           !accountAmountOverridden,
           let stored = original.accountAmount {
            return stored
        }
        return (showsSourceAmount ? (Double(accountAmountText) ?? estimatedSourceAmount) : abs(amount)) * (isNegative ? -1 : 1)
    }
    private var destinationPostingValue: Double {
        if let original,
           type == original.type,
           destinationID == original.destinationAccountID,
           currency == original.currency,
           amount == original.amount,
           !destinationAmountOverridden,
           let stored = original.destinationAmount {
            return stored
        }
        return (showsDestinationAmount ? (Double(destinationAmountText) ?? estimatedDestinationAmount) : abs(amount)) * (isNegative ? -1 : 1)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 12) {
                        editorContent
                    }
                    .frame(minHeight: max(0, geometry.size.height - 20), alignment: .top)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .background(LedgerBackground())
            .navigationTitle(original == nil ? "Add Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
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
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .disabled(!canSave || saving)
                    .accessibilityLabel("Save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if noteFocused {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { noteFocused = false; showingCamera = true } label: { Image(systemName: "camera") }
                        }
                        Spacer()
                        Button("Done") {
                            noteFocused = false
                            if type != .transfer {
                                withAnimation(.snappy) {
                                    showingNoteEditor = false
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if original == nil {
                taxInputMode = store.state.settings.defaultTaxInputMode
                reloadTaxRate()
            }
            if accountID == nil { applyDefaultAccount(for: categoryID) }
            if destinationID == nil { destinationID = activeAccounts.first(where: { $0.id != accountID })?.id }
            if original == nil { syncAmountFields() } else { prefillStoredAmounts() }
            if let identifier = noteAttachmentID {
                Task { noteImage = await AttachmentStore.shared.loadTransactionNote(identifier: identifier) }
            }
        }
        .onChange(of: categoryID) { _, category in
            reloadTaxRate()
            if (type == .expense || type == .income) && !accountExplicitlyOverridden {
                applyDefaultAccount(for: category)
            }
        }
        .onChange(of: type) { _, newType in
            let newKind: LedgerCategoryKind = (newType == .income) ? .income : .expense
            let matching = store.state.categories.filter { $0.kind == newKind }
            if !matching.contains(where: { $0.id == categoryID }) {
                if let first = matching.first { categoryID = first.id }
            }
            if (newType == .expense || newType == .income) && !accountExplicitlyOverridden {
                applyDefaultAccount(for: categoryID)
            }
            if original == nil {
                taxInputMode = store.state.settings.defaultTaxInputMode
            }
            reloadTaxRate()
            accountAmountOverridden = false
            destinationAmountOverridden = false
            syncAmountFields()
        }
        .onChange(of: currency) { _, _ in
            taxChanged = true
            accountAmountOverridden = false
            destinationAmountOverridden = false
            syncAmountFields()
        }
        .onChange(of: enteredAmount) { _, _ in taxChanged = true }
        .onChange(of: taxInputMode) { _, _ in
            taxChanged = true
            if taxRate == nil && type != .transfer { reloadTaxRate() }
        }
        .onChange(of: store.state.settings.taxSettings) { _, _ in
            if original == nil {
                taxInputMode = store.state.settings.defaultTaxInputMode
                reloadTaxRate()
            } else if original?.categoryID != categoryID || original?.type != type {
                reloadTaxRate()
            }
        }
        .onChange(of: amount) { _, _ in syncAmountFields() }
        .sheet(isPresented: $showingCategoryEditor) {
            CategoryEditorSheet(initialKind: activeKind) { id in categoryID = id }
        }
        .sheet(isPresented: $showingDatePicker) { datePickerSheet }
        .fullScreenCover(isPresented: $showingCamera) {
            TransactionNoteCamera(image: $noteImage, imageChanged: $noteImageChanged)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private var editorContent: some View {
        Picker("Transaction type", selection: $type) {
            ForEach(LedgerTransactionType.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        if preferences.value.transactionLayout == .categoryFirst && type != .transfer {
            categoryPicker
            amountPanel
            accountAndDateRow
            detailsPanel
            if showingNoteEditor {
                noteEditor
            }
            keypad
        } else {
            amountPanel
            if type == .transfer {
                transferRow
            } else {
                accountAndDateRow
            }
            detailsPanel
            if type == .transfer {
                noteEditor
            } else if showingNoteEditor {
                noteEditor
            }
            keypad
            if type != .transfer {
                categoryPicker
            }
        }
    }

    private var effectiveDisplayTaxRate: Double {
        if let taxRate { return taxRate }
        if let category = availableCategories.first(where: { $0.id == categoryID }) {
            return store.state.settings.taxRate(for: category)
        }
        return type == .expense ? 0.09 : 0.15
    }

    private var amountPanel: some View {
        VStack(spacing: 8) {
            TransactionCurrencyPicker(selection: $currency)
            SensitiveMoneyText(amount: enteredAmount, currency: currency)
                .font(.system(size: 58, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if type != .transfer {
                taxSummaryLine
                if taxInputMode == .beforeTax {
                    taxTotalLine
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var taxSummaryLine: some View {
        Button {
            if taxRate == nil { reloadTaxRate() }
            isTaxExempt.toggle()
            taxChanged = true
            HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
        } label: {
            HStack(spacing: 5) {
                Text("Tax \(TaxCalculations.percent(effectiveDisplayTaxRate)) \u{00B7}")
                SensitiveValueText(LedgerMoneyFormat.code(taxSnapshot?.hypotheticalTax ?? 0, currency: currency))
                if isTaxExempt {
                    Text("Tax Free")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .strikethrough(isTaxExempt)
            .opacity(isTaxExempt ? 0.65 : 1.0)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tax Free")
        .accessibilityValue(isTaxExempt ? "On" : "Off")
    }

    private var taxTotalLine: some View {
        HStack(spacing: 6) {
            Text(type == .income ? "Net Received" : "Total")
                .foregroundStyle(.secondary)
            SensitiveMoneyText(amount: amount, currency: currency)
                .fontWeight(.semibold)
        }
        .font(.caption)
    }

    private var accountAndDateRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "creditcard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .layoutPriority(1)
                    AccountSelectorMenu(accounts: activeAccounts, selection: $accountID,
                                        title: "Account", display: .logo,
                                        valueAlignment: .center)
                        .layoutPriority(0)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 10)
                .clipped()
                .onChange(of: accountID) { _, newValue in
                    if !applyingDefaultAccount { accountExplicitlyOverridden = true }
                    accountAmountOverridden = false
                    if let account = activeAccounts.first(where: { $0.id == newValue }) { currency = account.currency }
                    if destinationID == newValue { destinationID = activeAccounts.first(where: { $0.id != newValue })?.id }
                    syncAmountFields()
                }

                Divider().frame(height: 20)
                compactDateButton
            }
            .frame(height: 50)
            .ledgerGlass(in: Capsule())

            Button {
                withAnimation(.snappy) {
                    showingNoteEditor.toggle()
                    if showingNoteEditor {
                        noteFocused = true
                    } else {
                        noteFocused = false
                    }
                }
            } label: {
                Image(systemName: hasNote ? "square.and.pencil.circle.fill" : "square.and.pencil")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(hasNote ? primaryActionColor : .secondary)
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.plain)
            .ledgerGlass(interactive: true, in: Circle())
            .accessibilityLabel("Note")
        }
        .frame(maxWidth: .infinity)
    }

    private var transferRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .layoutPriority(1)
                AccountSelectorMenu(accounts: activeAccounts, selection: $accountID,
                                    title: "From Account",
                                    display: .logo,
                                    valueAlignment: .center)
                    .layoutPriority(0)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 8)
            .frame(height: 50)
            .clipped()
            .ledgerGlass(in: Capsule())
            .onChange(of: accountID) { _, newValue in
                if !applyingDefaultAccount { accountExplicitlyOverridden = true }
                accountAmountOverridden = false
                if let account = activeAccounts.first(where: { $0.id == newValue }) { currency = account.currency }
                if destinationID == newValue { destinationID = activeAccounts.first(where: { $0.id != newValue })?.id }
                syncAmountFields()
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .layoutPriority(1)
                AccountSelectorMenu(accounts: activeAccounts.filter { $0.id != accountID }, selection: $destinationID,
                                    title: "To Account",
                                    display: .logo,
                                    valueAlignment: .center)
                    .layoutPriority(0)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 8)
            .frame(height: 50)
            .clipped()
            .ledgerGlass(in: Capsule())
            .onChange(of: destinationID) { _, _ in
                destinationAmountOverridden = false
                syncAmountFields()
            }

            compactDateButton
                .ledgerGlass(in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    @ScaledMetric(relativeTo: .body) private var scaledDateWidth: CGFloat = 110

    private var compactDateButton: some View {
        Button { showingDatePicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(preferences.value.dateFormat.compactString(from: occurredAt))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: min(max(scaledDateWidth, 105), 120), height: 50, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Date")
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .focused($noteFocused)
                    .accessibilityLabel("Note")
            }
            if let noteImage {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: noteImage)
                        .resizable().scaledToFill()
                        .frame(width: 88, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button { removeNotePhoto() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                    .accessibilityLabel("Remove note photo")
                }
            }
        }
        .padding(14)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var detailsPanel: some View {
        if showsSourceAmount || showsDestinationAmount {
            VStack(spacing: 0) {
                if showsSourceAmount {
                    accountAmountRow(title: type == .transfer ? "From Amount" : "Amount",
                                     pocket: sourcePocket,
                                     text: $accountAmountText,
                                     overridden: $accountAmountOverridden,
                                     suggestion: $sourceSuggestion,
                                     estimated: estimatedSourceAmount)
                }
                if showsDestinationAmount {
                    if showsSourceAmount {
                        Divider()
                    }
                    accountAmountRow(title: "To Amount",
                                     pocket: targetPocket,
                                     text: $destinationAmountText,
                                     overridden: $destinationAmountOverridden,
                                     suggestion: $destinationSuggestion,
                                     estimated: estimatedDestinationAmount)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: dateOnlyBinding, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(.horizontal)
                .navigationTitle("Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            showingDatePicker = false
                        } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .tint(primaryActionColor)
                        .accessibilityLabel("Done")
                    }
                }
        }
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
    }

    private var dateOnlyBinding: Binding<Date> {
        Binding(get: { occurredAt }, set: { newDate in
            let calendar = Calendar.current
            let day = calendar.dateComponents([.year, .month, .day], from: newDate)
            let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: occurredAt)
            var merged = DateComponents()
            merged.year = day.year; merged.month = day.month; merged.day = day.day
            merged.hour = time.hour; merged.minute = time.minute; merged.second = time.second; merged.nanosecond = time.nanosecond
            if let value = calendar.date(from: merged) { occurredAt = value }
        })
    }

    private func removeNotePhoto() {
        if let noteAttachmentID { removedAttachmentID = noteAttachmentID }
        noteAttachmentID = nil
        noteImage = nil
        noteImageChanged = false
    }

    /// Editable actual account-side amount. Prefilled from the cached FX rate, but a value the user
    /// types becomes authoritative and is never overwritten afterwards.
    private func accountAmountRow(title: LocalizedStringKey, pocket: CurrencyCode, text: Binding<String>, overridden: Binding<Bool>, suggestion: Binding<Double>, estimated: Double) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            if overridden.wrappedValue {
                Button {
                    overridden.wrappedValue = false
                    suggestion.wrappedValue = estimated
                    text.wrappedValue = Self.amountText(estimated)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset to estimated amount")
            }
            HStack(spacing: 6) {
                Text(pocket.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SensitiveValueContent(maskLength: 8) {
                    TextField("0.00", text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.vertical, 8)
        .onChange(of: text.wrappedValue) { _, newValue in
            // A value equal to the FX suggestion is still a suggestion, not a manual override.
            if let value = Double(newValue), abs(value - suggestion.wrappedValue) > 0.005 { overridden.wrappedValue = true }
            else if newValue.isEmpty { overridden.wrappedValue = false }
        }
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "±", "0", "delete.left"], id: \.self) { key in
                Button { press(key) } label: {
                    Group {
                        if key == "delete.left" {
                            Image(systemName: key)
                        } else {
                            Text(key)
                        }
                    }
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 76)
                }
                .buttonStyle(.plain)
                .ledgerGlass(interactive: true, in: Circle())
            }
        }
        .frame(maxWidth: 380)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableCategories) { category in
                    Button { withAnimation(.snappy) { categoryID = category.id } } label: {
                        VStack(spacing: 4) {
                            CategoryIcon(category: category, font: .title3)
                            Text(category.name).font(.caption.weight(.semibold))
                        }
                        .frame(width: 112, height: 78)
                        .foregroundStyle(categoryID == category.id ? Color(hex: category.colorHex) : Color.primary)
                        .ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
            }
            .padding(.vertical, 4)
        }
    }

    private func press(_ key: String) {
        HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
        if key == "±" {
            isNegative.toggle()
        } else if key == "delete.left" {
            minorUnits = minorUnits.count <= 1 ? "0" : String(minorUnits.dropLast())
        } else {
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

    @MainActor private func save() async {
        guard let accountID, let sourceAccount else { return }
        saving = true
        defer { saving = false }
        let sourceAccountCurrency = sourceAccount.usesCurrencyPockets ? sourcePocket : nil
        let destinationAccountCurrency = (type == .transfer && destinationAccount?.usesCurrencyPockets == true) ? targetPocket : nil
        var savedAttachmentID = noteAttachmentID
        do {
            if noteImageChanged, let noteImage {
                savedAttachmentID = try await AttachmentStore.shared.saveTransactionNote(noteImage)
            }
        } catch {
            store.presentedError = error.localizedDescription
            return
        }
        if var original {
            original.type = type; original.accountID = accountID; original.destinationAccountID = type == .transfer ? destinationID : nil
            original.amount = amount; original.currency = currency; original.categoryID = type == .transfer ? .other : categoryID
            original.occurredAt = occurredAt; original.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
            original.noteAttachmentID = savedAttachmentID
            // Actual account-side postings. A manually edited value is stored as-is.
            original.accountCurrency = sourceAccountCurrency
            original.accountAmount = sourcePostingValue
            original.destinationAccountCurrency = type == .transfer ? destinationAccountCurrency : nil
            original.destinationAmount = type == .transfer ? destinationPostingValue : nil
            if taxChanged || type == .transfer { original.applyTax(taxSnapshot) }
            store.updateTransaction(original)
        } else {
            guard store.addTransaction(type: type, accountID: accountID, destinationAccountID: destinationID, amount: amount, currency: currency, categoryID: categoryID, occurredAt: occurredAt, note: note, noteAttachmentID: savedAttachmentID, accountCurrency: sourceAccountCurrency, accountAmount: sourcePostingValue, destinationAccountCurrency: destinationAccountCurrency, destinationAmount: type == .transfer ? destinationPostingValue : nil, taxSnapshot: taxSnapshot) != nil else {
                if noteImageChanged, let savedAttachmentID { try? await AttachmentStore.shared.delete(identifier: savedAttachmentID) }
                store.presentedError = "The transaction could not be saved."
                return
            }
        }
        if let oldIdentifier = removedAttachmentID ?? (noteImageChanged ? noteAttachmentID : nil), oldIdentifier != savedAttachmentID {
            try? await AttachmentStore.shared.delete(identifier: oldIdentifier)
        }
        dismiss()
    }
}

private struct TransactionNoteCamera: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?
    @Binding var imageChanged: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: TransactionNoteCamera
        init(parent: TransactionNoteCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.imageChanged = parent.image != nil
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

private struct CategoryEditorSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    @State private var name = ""
    @State private var detail = ""
    @State private var kind: LedgerCategoryKind
    @State private var mode = 0
    @State private var emoji = "🍽️"
    @State private var selectedSymbol = "cup.and.saucer.fill"
    @State private var color = LedgerPalette.coral
    let onAdd: (LedgerCategoryID) -> Void

    init(initialKind: LedgerCategoryKind = .expense, onAdd: @escaping (LedgerCategoryID) -> Void) {
        _kind = State(initialValue: initialKind)
        self.onAdd = onAdd
    }

    private let symbols = ["cup.and.saucer.fill", "cart.fill", "house.fill", "heart.fill", "gift.fill", "airplane", "gamecontroller.fill", "cross.case.fill", "graduationcap.fill", "pawprint.fill", "figure.run", "ellipsis.circle.fill", "banknote.fill", "chart.line.uptrend.xyaxis", "percent"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Category Type", selection: $kind) {
                        Text("Expense").tag(LedgerCategoryKind.expense)
                        Text("Income").tag(LedgerCategoryKind.income)
                    }
                    .pickerStyle(.segmented)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let value = mode == 0 ? "emoji:\(String(emoji.prefix(1)))" : selectedSymbol
                        if let id = store.addCategory(name: name, detail: detail, symbol: value, colorHex: color.rgbHex, kind: kind) { onAdd(id); dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == 0 && emoji.isEmpty))
                    .accessibilityLabel("Save")
                }
            }
        }
    }
}
