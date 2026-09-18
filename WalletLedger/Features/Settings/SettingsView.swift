import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: BackupDocument?
    @State private var importPreview: ImportPreview?
    @State private var working = false
    @State private var updatingRates = false
    @State private var statusMessage: String?
    @State private var showingNewRecurring = false
    @State private var editingRecurring: RecurringRule?
    @FocusState private var focusedRate: CurrencyCode?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Currency") {
                    Picker("Base Currency", selection: baseCurrencyBinding) { ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) } }
                    Divider()
                    Toggle("Automatic Daily Rates", isOn: automaticRatesBinding)
                    Text("Daily reference rates supplied by Frankfurter; manual values remain available offline.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Exchange Rates") {
                    ForEach(displayedCurrencies) { currency in
                        LabeledContent("1 \(currency.rawValue)") {
                            TextField("Rate", value: rateBinding(currency), format: .number.precision(.fractionLength(4))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focusedRate, equals: currency)
                            Text(store.state.settings.baseCurrency.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    Button { Task { await refreshRates(showConfirmation: true) } } label: { Label(updatingRates ? "Updating…" : "Update from Frankfurter", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, alignment: .leading) }.disabled(updatingRates)
                    if let updated = store.state.settings.exchangeRatesUpdatedAt { Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    Button("Reset Reference Rates") { store.updateSettings { $0.rates = SeedData.rates; $0.exchangeRatesUpdatedAt = nil } }
                }
                SettingsGlassSection("Recurring Transactions") {
                    Button { showingNewRecurring = true } label: { Label("Add Recurring Transaction", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }
                    if store.recurringRules.isEmpty {
                        Text("Weekly, monthly, yearly, or custom-day income, expenses, and transfers will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.recurringRules) { rule in
                        Divider()
                        HStack(spacing: 12) {
                            Button { editingRecurring = rule } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.note?.isEmpty == false ? rule.note! : rule.type.title).font(.body.weight(.semibold))
                                    Text("\(rule.interval.title) · \(LedgerFormat.money(rule.amount, currency: rule.currency)) · next \(rule.nextRunAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Toggle("Enabled", isOn: Binding(get: { rule.isEnabled }, set: { store.setRecurringRule(rule, enabled: $0) })).labelsHidden()
                            Button(role: .destructive) { store.deleteRecurringRule(rule) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete recurring transaction")
                        }
                    }
                }
                SettingsGlassSection("Data") {
                    Button { exportDocument = BackupDocument(envelope: store.backupEnvelope()); showingExporter = true } label: { Label("Export Backup", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading) }
                    Divider()
                    Button { showingImporter = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }
                }
                SettingsGlassSection("iCloud Backup") {
                    Toggle("Backup Reminders", isOn: remindersBinding)
                    Divider()
                    Button { Task { await backupToICloud() } } label: { Label("Back Up Now", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading) }.disabled(working)
                    Divider()
                    Button { Task { await restoreFromICloud() } } label: { Label("Restore Latest Backup", systemImage: "icloud.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }.disabled(working)
                    Divider()
                    LabeledContent("Last Backup", value: store.state.settings.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    Text("Requires the iCloud Documents capability and the container configured in WalletLedger.entitlements.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Storage") {
                    LabeledContent("Local Mode", value: "Application Support")
                    Divider()
                    LabeledContent("Schema", value: "v\(store.state.schemaVersion)")
                    Text("Balances and analytics are recalculated from the local transaction ledger; they are never stored as independent mutable totals.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding()
        }
        .background(LedgerBackground())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedRate = nil } }
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .walletLedgerBackup, defaultFilename: backupFileName) { result in if case .failure(let error) = result { store.presentedError = error.localizedDescription } }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.walletLedgerBackup, .json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                importPreview = try BackupCodec.decode(Data(contentsOf: url), sourceName: url.lastPathComponent)
            } catch { store.presentedError = error.localizedDescription }
        }
        .sheet(item: $importPreview) { preview in ImportPreviewView(preview: preview) { store.replace(with: preview.envelope); importPreview = nil } }
        .sheet(isPresented: $showingNewRecurring) { RecurringRuleEditorView(rule: nil) }
        .sheet(item: $editingRecurring) { RecurringRuleEditorView(rule: $0) }
        .overlay { if working { ProgressView().controlSize(.large).padding(24).ledgerGlass(in: RoundedRectangle(cornerRadius: 22)) } }
        .alert("Backup", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) { Button("OK") { statusMessage = nil } } message: { Text(statusMessage ?? "") }
    }

    private var baseCurrencyBinding: Binding<CurrencyCode> { Binding(get: { store.state.settings.baseCurrency }, set: { value in store.updateSettings { $0.baseCurrency = value } }) }
    private var automaticRatesBinding: Binding<Bool> { Binding(get: { store.state.settings.automaticRates }, set: { value in store.updateSettings { $0.automaticRates = value }; if value { Task { await refreshRates(showConfirmation: false) } } }) }
    private var displayedCurrencies: [CurrencyCode] { CurrencyCode.allCases.filter { $0 != .HKD && $0 != store.state.settings.baseCurrency } }
    private var remindersBinding: Binding<Bool> { Binding(get: { store.state.settings.backupReminders }, set: { value in store.updateSettings { $0.backupReminders = value } }) }
    private var backupFileName: String {
        let values = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "WalletLedger-%04d-%02d-%02d.walletledger", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
    private func rateBinding(_ currency: CurrencyCode) -> Binding<Double> {
        let base = store.state.settings.baseCurrency
        return Binding(get: { (store.state.settings.rates[currency] ?? 1) / (store.state.settings.rates[base] ?? 1) }, set: { shown in
            store.updateSettings {
                let safe = max(0.000001, shown)
                if currency == .HKD && base != .HKD { $0.rates[base] = 1 / safe }
                else { $0.rates[currency] = safe * ($0.rates[base] ?? 1) }
                $0.rates[.HKD] = 1
            }
        })
    }

    @MainActor private func refreshRates(showConfirmation: Bool) async {
        guard !updatingRates else { return }
        updatingRates = true; defer { updatingRates = false }
        do {
            let sourceDate = try await store.refreshExchangeRatesIfNeeded(force: true) ?? "the latest available date"
            if showConfirmation { statusMessage = "Reference rates updated for \(sourceDate)." }
        } catch { store.presentedError = "Exchange-rate update failed: \(error.localizedDescription)" }
    }

    private func backupToICloud() async {
        working = true; defer { working = false }
        do { let date = try await ICloudBackupService.shared.backup(store.backupEnvelope()); store.updateSettings { $0.lastBackupAt = date }; statusMessage = "Backup saved to iCloud Drive." }
        catch { store.presentedError = error.localizedDescription }
    }

    private func restoreFromICloud() async {
        working = true; defer { working = false }
        do { importPreview = try await ICloudBackupService.shared.restoreLatest() }
        catch { store.presentedError = error.localizedDescription }
    }
}

private struct RecurringRuleEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    private let originalID: UUID?
    private let originalCreatedAt: Date
    @State private var type: LedgerTransactionType
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var amount: Double
    @State private var currency: CurrencyCode
    @State private var categoryID: LedgerCategoryID
    @State private var note: String
    @State private var interval: RecurringInterval
    @State private var customDays: Int
    @State private var nextRunAt: Date
    @State private var isEnabled: Bool
    @FocusState private var amountFocused: Bool

    init(rule: RecurringRule?) {
        originalID = rule?.id
        originalCreatedAt = rule?.createdAt ?? .now
        _type = State(initialValue: rule?.type ?? .expense)
        _accountID = State(initialValue: rule?.accountID)
        _destinationID = State(initialValue: rule?.destinationAccountID)
        _amount = State(initialValue: rule?.amount ?? 0)
        _currency = State(initialValue: rule?.currency ?? .HKD)
        _categoryID = State(initialValue: rule?.categoryID ?? .food)
        _note = State(initialValue: rule?.note ?? "")
        _interval = State(initialValue: rule?.interval ?? .monthly)
        _customDays = State(initialValue: rule?.customIntervalDays ?? 14)
        _nextRunAt = State(initialValue: rule?.nextRunAt ?? .now)
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
    }

    private var accounts: [LedgerAccount] { store.accounts.map(\.account) }
    private var canSave: Bool { amount > 0 && accountID != nil && (type != .transfer || (destinationID != nil && destinationID != accountID)) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    Picker("Type", selection: $type) { ForEach(LedgerTransactionType.allCases) { Text($0.title).tag($0) } }
                    Picker(type == .transfer ? "From Account" : "Account", selection: $accountID) { ForEach(accounts) { Text($0.name).tag(Optional($0.id)) } }
                    if type == .transfer { Picker("To Account", selection: $destinationID) { ForEach(accounts.filter { $0.id != accountID }) { Text($0.name).tag(Optional($0.id)) } } }
                    LabeledContent("Amount") { TextField("0", value: $amount, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($amountFocused) }
                    Picker("Currency", selection: $currency) { ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) } }
                    if type != .transfer { Picker("Category", selection: $categoryID) { ForEach(store.state.categories) { Text($0.name).tag($0.id) } } }
                    TextField("Note (optional)", text: $note)
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $interval) { ForEach(RecurringInterval.allCases) { Text($0.title).tag($0) } }
                    if interval == .customDays { Stepper("Every \(customDays) days", value: $customDays, in: 1...365) }
                    DatePicker("Next Run", selection: $nextRunAt, displayedComponents: [.date, .hourAndMinute])
                    Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle(originalID == nil ? "New Recurring" : "Edit Recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave).fontWeight(.semibold) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { amountFocused = false } }
            }
            .onAppear {
                if accountID == nil { accountID = accounts.first?.id; currency = accounts.first?.currency ?? .HKD }
                if destinationID == nil { destinationID = accounts.first(where: { $0.id != accountID })?.id }
            }
            .onChange(of: accountID) { _, id in
                if let account = accounts.first(where: { $0.id == id }) { currency = account.currency }
                if destinationID == id { destinationID = accounts.first(where: { $0.id != id })?.id }
            }
        }
    }

    private func save() {
        guard let accountID else { return }
        let now = Date.now
        store.saveRecurringRule(.init(id: originalID ?? UUID(), userID: store.state.settings.userID, type: type, accountID: accountID, destinationAccountID: type == .transfer ? destinationID : nil, amount: amount, currency: currency, categoryID: type == .transfer ? .other : categoryID, note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note, interval: interval, customIntervalDays: max(1, customDays), nextRunAt: nextRunAt, isEnabled: isEnabled, createdAt: originalCreatedAt, updatedAt: now))
        store.processDueRecurring()
        dismiss()
    }
}

private struct SettingsGlassSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.7)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: ImportPreview
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("File") { LabeledContent("Name", value: preview.sourceName); LabeledContent("Base Currency", value: preview.envelope.data.settings.baseCurrency.rawValue) }
                Section("Contents") { LabeledContent("Accounts", value: "\(preview.envelope.metadata.accountCount)"); LabeledContent("Transactions", value: "\(preview.envelope.metadata.transactionCount)"); LabeledContent("Categories", value: "\(preview.envelope.metadata.categoryCount)") }
                if !preview.warnings.isEmpty { Section("Review") { ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") } } }
                Section { Text("Import replaces the current local ledger. Export a backup first if you may need to restore it.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Import Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Import", action: confirm).fontWeight(.semibold) } }
        }.presentationDetents([.medium, .large])
    }
}
