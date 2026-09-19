import SwiftUI
import UniformTypeIdentifiers
import CloudKit

struct SettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @EnvironmentObject private var privacy: PrivacyController
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: BackupDocument?
    @State private var importPreview: ImportPreview?
    @State private var working = false
    @State private var statusMessage: String?
    @State private var confirmingReset = false
    @State private var cloudShare: CKShare?
    @State private var showingCloudSharing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Basic") {
                    NavigationLink { DefaultExpenseAccountsView() } label: { SettingsLinkRow("Default Expense Accounts", systemImage: "arrow.triangle.branch", detail: "By category") }.foregroundStyle(.primary)
                    Divider()
                    SettingsLinkRow("Language", systemImage: "globe", detail: "English · Not configurable yet")
                    Divider()
                    LabeledContent("Date Format") {
                        Picker("Date Format", selection: dateFormatBinding) {
                            ForEach(AppDateFormat.allCases) { format in Text(format.title).tag(format) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .foregroundStyle(.primary)
                    }
                }
                SettingsGlassSection("Functions") {
                    LabeledContent("Base Currency") {
                        CurrencyMenuButton(selection: Binding(get: { store.state.settings.baseCurrency },
                                                              set: { code in store.updateSettings { $0.baseCurrency = code } }),
                                           codes: CurrencySelection.common, title: "Base Currency",
                                           showsOther: true, showsStablecoinNames: false)
                    }
                    Divider()
                    NavigationLink { ExchangeRateEditorView() } label: { SettingsLinkRow("Exchange Rates", systemImage: "arrow.left.arrow.right", detail: store.state.settings.automaticRates ? "Automatic" : "Manual") }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { BudgetEditorView() } label: { SettingsLinkRow("Budget", systemImage: "chart.pie", detail: store.state.settings.budgetPlan.mode.title) }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { RecurringTransactionsView() } label: { SettingsLinkRow("Recurring Transactions", systemImage: "calendar.badge.clock", detail: "\(store.recurringRules.count)") }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { SwipeActionsEditorView() } label: { SettingsLinkRow("Swipe Actions", systemImage: "hand.draw", detail: nil) }.foregroundStyle(.primary)
                    Divider()
                    Toggle(isOn: preferenceBinding(\.hapticFeedbackEnabled)) { Label("Haptic Feedback", systemImage: "waveform") }
                    Divider()
                    NavigationLink { MarketDataSettingsView() } label: { SettingsLinkRow("Alpha Vantage API Key", systemImage: "key", detail: nil) }.foregroundStyle(.primary)
                }
                SettingsGlassSection("Privacy") {
                    Toggle(isOn: biometricBinding) { Label("Face ID / Touch ID", systemImage: "faceid") }
                    Divider()
                    Button(role: .destructive) { confirmingReset = true } label: { Label("Reset App Data", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading) }
                    Text("Sensitive values are protected on this device only. This preference is never included in ledger backups.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Share & Backup") {
                    Button { Task { await shareLedger() } } label: { Label(store.activeBook.effectiveStorageKind == .local ? "Share Ledger" : "Manage Sharing", systemImage: "person.2.badge.gearshape").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary).disabled(working)
                    Divider()
                    Button { Task { await backupToICloud() } } label: { Label("Back Up Now", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary).disabled(working)
                    Divider()
                    Button { Task { await restoreFromICloud() } } label: { Label("Restore", systemImage: "icloud.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary).disabled(working)
                    Divider()
                    Button { exportDocument = BackupDocument(envelope: store.backupEnvelope()); showingExporter = true } label: { Label("Export Backup", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary)
                    Divider()
                    Button { showingImporter = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary)
                    Divider()
                    Toggle("Backup Reminders", isOn: remindersBinding)
                    LabeledContent("Last Backup", value: store.state.settings.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
            }.padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() } }
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
        .sheet(isPresented: $showingCloudSharing) { if let cloudShare { CloudSharingView(share: cloudShare, container: CKContainer(identifier: "iCloud.org.medx.WalletLedger")) } }
        .overlay { if working { ProgressView().controlSize(.large).padding(24).ledgerGlass(in: RoundedRectangle(cornerRadius: 22)) } }
        .alert("Backup", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) { Button("OK") { statusMessage = nil } } message: { Text(statusMessage ?? "") }
        .confirmationDialog("Reset App Data?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Local App Data", role: .destructive) { Task { await resetAppData() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This clears local ledgers, receipts, caches, and device preferences. It does not delete CloudKit ledgers owned by or shared with other people.") }
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<AppPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.value[keyPath: keyPath] }, set: { value in preferences.update { $0[keyPath: keyPath] = value } })
    }
    private var dateFormatBinding: Binding<AppDateFormat> {
        Binding(get: { preferences.value.dateFormat }, set: { value in preferences.update { $0.dateFormat = value } })
    }
    private var biometricBinding: Binding<Bool> {
        Binding(get: { preferences.value.biometricLockEnabled }, set: { enabled in
            if enabled {
                preferences.update { $0.biometricLockEnabled = true }
                privacy.lockIfNeeded(protectionEnabled: true)
                Task { await privacy.unlockIfNeeded(protectionEnabled: true) }
            } else {
                Task {
                    guard await privacy.authorizeDisablingProtection() else { return }
                    preferences.update { $0.biometricLockEnabled = false }
                    privacy.protectionWasDisabled()
                }
            }
        })
    }
    private var remindersBinding: Binding<Bool> { Binding(get: { store.state.settings.backupReminders }, set: { value in store.updateSettings { $0.backupReminders = value } }) }
    private var backupFileName: String {
        let values = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "WalletLedger-%04d-%02d-%02d.walletledger", values.year ?? 0, values.month ?? 0, values.day ?? 0)
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
    private func resetAppData() async {
        guard await privacy.authorizeSensitiveChange(reason: "Authenticate to reset local app data.", protectionEnabled: preferences.value.biometricLockEnabled) else { return }
        do {
            try store.resetLocalData()
            preferences.reset()
            privacy.protectionWasDisabled()
            statusMessage = "Local app data was reset. Shared CloudKit data was not deleted."
        } catch { store.presentedError = error.localizedDescription }
    }
    private func shareLedger() async {
        working = true; defer { working = false }
        do {
            let share = try await CloudLedgerService.shared.share(book: store.activeBook)
            cloudShare = share
            if store.activeBook.effectiveStorageKind == .local { store.markActiveBookCloudOwner(zoneName: share.recordID.zoneID.zoneName) }
            showingCloudSharing = true
        } catch { store.presentedError = error.localizedDescription }
    }
}

struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    let detail: String?
    init(_ title: String, systemImage: String, detail: String?) { self.title = title; self.systemImage = systemImage; self.detail = detail }
    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }.contentShape(Rectangle())
    }
}

struct SettingsGlassSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.7)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: ImportPreview
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("File") { LabeledContent("Name", value: preview.sourceName); LabeledContent("Base Currency", value: preview.envelope.data.settings.baseCurrency.rawValue) }
                Section("Contents") { LabeledContent("Accounts", value: "\(preview.envelope.metadata.accountCount)"); LabeledContent("Transactions", value: "\(preview.envelope.metadata.transactionCount)"); LabeledContent("Categories", value: "\(preview.envelope.metadata.categoryCount)") }
                if !preview.warnings.isEmpty { Section("Review") { ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") } } }
                Section { Text("Import replaces the current private local ledger. While viewing a shared ledger, it creates a separate local ledger and never overwrites collaborators’ CloudKit data.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Import Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Import", action: confirm).fontWeight(.semibold) } }
        }.presentationDetents([.medium, .large])
    }
}
