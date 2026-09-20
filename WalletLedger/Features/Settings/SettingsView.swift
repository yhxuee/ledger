import CloudKit
import SwiftUI
import UniformTypeIdentifiers

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
                basicSection
                functionsSection
                securitySection
                shareAndBackupSection
                footer
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() } }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .walletLedgerBackup, defaultFilename: backupFileName) { result in
            if case .failure(let error) = result { store.presentedError = error.localizedDescription }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.walletLedgerBackup, .json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                importPreview = try BackupCodec.decode(Data(contentsOf: url), sourceName: url.lastPathComponent)
            } catch { store.presentedError = error.localizedDescription }
        }
        .sheet(item: $importPreview) { preview in
            ImportPreviewView(preview: preview) {
                store.replace(with: preview.envelope)
                importPreview = nil
            }
        }
        .sheet(isPresented: $showingCloudSharing) {
            if let cloudShare {
                CloudSharingView(share: cloudShare, container: CKContainer(identifier: "iCloud.com.finsy.app"))
            }
        }
        .overlay {
            if working {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .ledgerGlass(in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .alert("Backup", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
        .confirmationDialog("Reset App Data?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Local App Data", role: .destructive) {
                Task { await resetAppData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears local ledgers, receipts, caches, and device preferences. It does not delete CloudKit ledgers owned by or shared with other people.")
        }
    }

    private var basicSection: some View {
        SettingsGlassSection("Basic") {
            NavigationLink {
                DefaultExpenseAccountsView()
            } label: {
                SettingsLinkRow("Default Accounts", systemImage: "arrow.triangle.branch", detail: "By category")
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                LayoutSettingsView()
            } label: {
                SettingsLinkRow("Layout", systemImage: "rectangle.grid.1x2", detail: nil)
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                AccountCardStyleSettingsView()
            } label: {
                SettingsLinkRow("Style", systemImage: "sparkles", detail: preferences.value.accountCardMaterialStyle.title)
            }
            .foregroundStyle(.primary)

            Divider()

            LabeledContent {
                Menu {
                    ForEach(AppDateFormat.allCases) { format in
                        Button {
                            dateFormatBinding.wrappedValue = format
                        } label: {
                            if dateFormatBinding.wrappedValue == format {
                                Label(format.title, systemImage: "checkmark")
                            } else {
                                Text(format.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(dateFormatBinding.wrappedValue.title)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } label: {
                SettingsLabel("Date Format", systemImage: "calendar")
            }
        }
    }

    private var functionsSection: some View {
        SettingsGlassSection("Functions") {
            LabeledContent {
                CurrencyMenuButton(
                    selection: baseCurrencyBinding,
                    codes: CurrencySelection.common,
                    title: "Base Currency",
                    showsOther: true
                )
            } label: {
                SettingsLabel("Base Currency", systemImage: "coloncurrencysign.circle")
            }

            Divider()

            NavigationLink {
                ExchangeRateEditorView()
            } label: {
                SettingsLinkRow("Exchange Rates", systemImage: "arrow.left.arrow.right", detail: store.state.settings.automaticRates ? "Automatic" : "Manual")
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                TaxRateEditorView()
            } label: {
                SettingsLinkRow("Tax Rates", systemImage: "percent", detail: store.state.settings.isTaxInclusive ? "Tax-inclusive" : "Before-tax")
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                BudgetEditorView()
            } label: {
                SettingsLinkRow("Budget", systemImage: "chart.pie", detail: store.state.settings.budgetPlan.mode.title)
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                RecurringTransactionsView()
            } label: {
                SettingsLinkRow("Recurring Transactions", systemImage: "calendar.badge.clock", detail: "\(store.recurringRules.count)")
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                SwipeActionsEditorView()
            } label: {
                SettingsLinkRow("Swipe Actions", systemImage: "hand.draw", detail: nil)
            }
            .foregroundStyle(.primary)

            Divider()

            Toggle(isOn: preferenceBinding(\.hapticFeedbackEnabled)) {
                SettingsLabel("Haptic Feedback", systemImage: "waveform")
            }

            Divider()

            NavigationLink {
                MarketDataSettingsView()
            } label: {
                SettingsLinkRow("Alpha Vantage API Key", systemImage: "key", detail: nil)
            }
            .foregroundStyle(.primary)
        }
    }

    private var securitySection: some View {
        SettingsGlassSection("Security") {
            Toggle(isOn: biometricBinding) {
                SettingsLabel("Face ID / Touch ID", systemImage: "faceid")
            }

            Divider()

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                SettingsLabel("Reset App Data", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Sensitive values are protected on this device only. This preference is never included in ledger backups.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shareAndBackupSection: some View {
        SettingsGlassSection("Share & Backup") {
            Button {
                Task { await shareLedger() }
            } label: {
                SettingsLabel(store.activeBook.effectiveStorageKind == .local ? "Share Ledger" : "Manage Sharing", systemImage: "person.2.badge.gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .disabled(working)

            Divider()

            Button {
                Task { await performICloudBackup() }
            } label: {
                SettingsLabel("Back Up Now", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .disabled(working)

            Divider()

            Button {
                Task { await performICloudRestore() }
            } label: {
                SettingsLabel("Restore", systemImage: "icloud.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .disabled(working)

            Divider()

            Button {
                exportDocument = BackupDocument(envelope: store.backupEnvelope())
                showingExporter = true
            } label: {
                SettingsLabel("Export Backup", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)

            Divider()

            Button {
                showingImporter = true
            } label: {
                SettingsLabel("Import Backup", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)

            Divider()

            Toggle(isOn: remindersBinding) {
                Text("Backup Reminders")
            }

            LabeledContent("Last Backup", value: store.state.settings.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
        }
    }

    private var footer: some View {
        Text("Finsy · Multi-Currency Double-Entry Ledger")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
            .padding(.bottom, 24)
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<AppPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.value[keyPath: keyPath] }, set: { value in preferences.update { $0[keyPath: keyPath] = value } })
    }
    private var baseCurrencyBinding: Binding<CurrencyCode> {
        Binding(
            get: {
                store.state.settings.baseCurrency
            },
            set: { currency in
                store.updateSettings {
                    $0.baseCurrency = currency
                }
            }
        )
    }
    private var dateFormatBinding: Binding<AppDateFormat> {
        Binding(get: { preferences.value.dateFormat }, set: { value in preferences.update { $0.dateFormat = value } })
    }
    private var remindersBinding: Binding<Bool> {
        Binding(get: { store.state.settings.backupReminders }, set: { value in store.updateSettings { $0.backupReminders = value } })
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
    private var backupFileName: String {
        let values = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "Finsy-%04d-%02d-%02d.walletledger", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
    private func performICloudBackup() async {
        working = true; defer { working = false }
        do {
            let date = try await ICloudBackupService.shared.backup(store.backupEnvelope())
            store.updateSettings { $0.lastBackupAt = date }
            statusMessage = "Backup saved to iCloud Drive."
        } catch {
            store.presentedError = error.localizedDescription
        }
    }
    private func performICloudRestore() async {
        working = true; defer { working = false }
        do {
            importPreview = try await ICloudBackupService.shared.restoreLatest()
        } catch {
            store.presentedError = error.localizedDescription
        }
    }
    private func shareLedger() async {
        working = true; defer { working = false }
        do {
            let share = try await CloudLedgerService.shared.share(book: store.activeBook)
            cloudShare = share
            if store.activeBook.effectiveStorageKind == .local {
                store.markActiveBookCloudOwner(zoneName: share.recordID.zoneID.zoneName)
            }
            showingCloudSharing = true
        } catch {
            store.presentedError = error.localizedDescription
        }
    }
    private func resetAppData() async {
        guard await privacy.authorizeSensitiveChange(
            reason: "Authenticate to reset local app data.",
            protectionEnabled: preferences.value.biometricLockEnabled
        ) else { return }
        do {
            try store.resetLocalData()
            preferences.reset()
            privacy.protectionWasDisabled()
            statusMessage = "Local app data was reset. Shared CloudKit data was not deleted."
        } catch {
            store.presentedError = error.localizedDescription
        }
    }
}

struct SettingsLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
            Text(title)
        }
    }
}

struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    let detail: String?
    init(_ title: String, systemImage: String, detail: String?) { self.title = title; self.systemImage = systemImage; self.detail = detail }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
            Text(title)
            Spacer()
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
    }
}

struct SettingsGlassSection<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
            }
            content
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
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
                Section("File") {
                    LabeledContent("Name", value: preview.sourceName)
                    LabeledContent("Base Currency", value: preview.envelope.data.settings.baseCurrency.rawValue)
                }
                Section("Contents") {
                    LabeledContent("Accounts", value: "\(preview.envelope.metadata.accountCount)")
                    LabeledContent("Transactions", value: "\(preview.envelope.metadata.transactionCount)")
                    LabeledContent("Categories", value: "\(preview.envelope.metadata.categoryCount)")
                }
                if !preview.warnings.isEmpty {
                    Section("Review") {
                        ForEach(preview.warnings, id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                Section {
                    Text("Import replaces the current private local ledger. While viewing a shared ledger, it creates a separate local ledger and never overwrites collaborators’ CloudKit data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import Preview")
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
                    Button("Import", action: confirm)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
