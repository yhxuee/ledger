import CloudKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

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
    @State private var confirmingPendingCloud = false
    @State private var cloudShare: CKShare?
    @State private var showingCloudSharing = false

    var body: some View {
        scrollContent
            .background(LedgerBackground())
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() } }
            .modifier(fileTransferModifier)
            .modifier(alertsModifier)
            .overlay { progressOverlay }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                basicSection
                functionsSection
                securitySection
                shareAndBackupSection
                diagnosticsSection
                footer
            }
            .padding()
        }
    }

    private var fileTransferModifier: SettingsFileTransferModifier {
        SettingsFileTransferModifier(
            store: store,
            showingExporter: $showingExporter,
            showingImporter: $showingImporter,
            exportDocument: exportDocument,
            backupFileName: backupFileName,
            importPreview: $importPreview,
            showingCloudSharing: $showingCloudSharing,
            cloudShare: cloudShare
        )
    }

    private var alertsModifier: SettingsAlertsModifier {
        SettingsAlertsModifier(
            statusMessage: $statusMessage,
            confirmingReset: $confirmingReset,
            confirmingPendingCloud: $confirmingPendingCloud,
            onReset: { Task { await resetAppData() } },
            onContinuePendingCloud: { executePendingBackupAction() }
        )
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if working {
            ProgressView()
                .controlSize(.large)
                .padding(24)
                .ledgerGlass(in: RoundedRectangle(cornerRadius: 22))
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

            Divider()

            ColorPicker(selection: statementColorBinding, supportsOpacity: false) {
                SettingsLabel("Theme Color", systemImage: "paintpalette")
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
                CashFlowForecastSettingsView()
            } label: {
                SettingsLinkRow("Cash Flow Forecast", systemImage: "chart.line.uptrend.xyaxis", detail: preferences.value.cashFlowForecastEnabled ? "On" : "Off")
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                RecordingReminderSettingsView()
            } label: {
                SettingsLinkRow(
                    "Bookkeeping Reminders",
                    systemImage: "bell.badge",
                    detail: activeReminderCount > 0 ? "\(activeReminderCount) active" : "Off"
                )
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
                SettingsLinkRow("Market Data", systemImage: "key", detail: nil)
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                WalletSettingsView()
            } label: {
                SettingsLinkRow("Apple Wallet", systemImage: "wallet.pass", detail: nil)
            }
            .foregroundStyle(.primary)
        }
    }

    private var securitySection: some View {
        SettingsGlassSection("Security") {
            Toggle(isOn: biometricBinding) {
                SettingsLabel(privacy.biometricName, systemImage: privacy.biometricSymbol)
            }

            Divider()

            NavigationLink {
                EncryptionSecurityView()
            } label: {
                SettingsLinkRow(
                    "Encryption & Devices",
                    systemImage: "lock.shield",
                    detail: encryptionStatusText
                )
            }
            .foregroundStyle(.primary)

            Divider()

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                SettingsLabel("Reset App Data", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lastBackupText: String {
        guard let date = store.state.settings.lastBackupAt else {
            return "Last Backup · Never"
        }
        return "Last Backup · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var shareAndBackupSection: some View {
        SettingsGlassSection("Share & Backup") {
            Button {
                Task { await shareLedger() }
            } label: {
                SettingsLabel("Share Ledger", systemImage: "person.2.badge.gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .disabled(working)

            Divider()

            NavigationLink {
                ICloudSyncSettingsView()
            } label: {
                SettingsLinkRow("iCloud Sync", systemImage: "arrow.triangle.2.circlepath.icloud", detail: preferences.value.iCloudSyncEnabled ? "On" : "Off")
            }
            .foregroundStyle(.primary)

            Divider()

            NavigationLink {
                ICloudBackupSettingsView()
            } label: {
                SettingsLinkRow("iCloud Backup", systemImage: "icloud", detail: preferences.value.iCloudBackupEnabled ? "On" : "Off")
            }
            .foregroundStyle(.primary)

            Divider()

            Button {
                prepareExportBackup()
            } label: {
                SettingsLabel("Export Backup", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .disabled(working)

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
        }
    }

    private var diagnosticsSection: some View {
        SettingsGlassSection("About") {
            NavigationLink {
                DiagnosticsSettingsView()
            } label: {
                SettingsLinkRow("About", systemImage: "wrench.and.screwdriver", detail: nil)
            }
            .foregroundStyle(.primary)
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

    private var activeReminderCount: Int {
        preferences.value.recordingReminderSlots.filter(\.isEnabled).count
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
    private var statementColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(hex: preferences.value.statementThemeColorHex)
            },
            set: { newColor in
                preferences.update {
                    $0.statementThemeColorHex = newColor.rgbHex
                }
            }
        )
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
        return String(format: "Finsy-%04d-%02d-%02d.fsy", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private var encryptionStatusText: String {
        let state = store.activeBook.effectiveEncryptionState
        let hasKey = (try? LedgerKeyStore.loadKey(for: store.activeBook.id)) != nil
        switch state {
        case .enabled:
            return hasKey ? "On" : "Authorization Required"
        case .disabled:
            return "Off"
        case .authorizationRequired:
            return "Authorization Required"
        case .enabling, .disabling:
            return "Updating…"
        case .migrationFailed:
            return "Attention"
        }
    }

    @State private var pendingBackupAction: (() -> Void)? = nil

    private func executePendingBackupAction() {
        let action = pendingBackupAction
        pendingBackupAction = nil
        action?()
    }

    private func prepareExportBackup() {
        // Export the complete, currently available local snapshot. Cloud sync runs
        // independently; exporting must not fetch or upload the entire remote zone.
        guard !working else { return }
        performExportBackup(book: store.activeBook)
    }

    private func performExportBackup(book: LedgerBook) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let key = try CloudRecordMapper.encryptionKey(for: book)
                    return try BackupCodec.encodeFsy(envelope: BackupCodec.envelope(for: book.state), ledgerID: book.id, key: key)
                }.value
                exportDocument = BackupDocument(data: data)
                showingExporter = true
            } catch { store.presentedError = error.localizedDescription }
        }
    }

    private func shareLedger() async {
        working = true; defer { working = false }
        do {
            let share = try await CloudLedgerService.shared.share(book: store.activeBook)
            store.markLedgerShared(store.activeBookID)
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
            try await store.resetLocalData()
            preferences.reset()
            privacy.protectionWasDisabled()
            statusMessage = "Local app data was reset. Shared CloudKit data was not deleted."
        } catch {
            store.presentedError = error.localizedDescription
        }
    }
}

private struct SettingsFileTransferModifier: ViewModifier {
    @ObservedObject var store: LedgerStore
    @Binding var showingExporter: Bool
    @Binding var showingImporter: Bool
    let exportDocument: BackupDocument?
    let backupFileName: String
    @Binding var importPreview: ImportPreview?
    @Binding var showingCloudSharing: Bool
    let cloudShare: CKShare?

    @State private var lockedBackup: LockedBackupImport?
    @State private var askingBackupAuthorization = false
    @State private var backupAuthorization: LockedBackupImport?
    @State private var authorizedPreview: ImportPreview?

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .fsyBackup,
                defaultFilename: backupFileName
            ) { result in
                if case .failure(let error) = result {
                    store.presentedError = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: BackupDocument.readableContentTypes
            ) { result in
                handleImport(result: result)
            }
            .alert("Backup Cannot Be Decrypted", isPresented: $askingBackupAuthorization) {
                Button("Exit", role: .cancel) { lockedBackup = nil }
                Button("Request Authorization") { backupAuthorization = lockedBackup }
            } message: {
                Text("This device needs the backup's encryption key. Request migration from the original device; after confirmation, the original device's key for this ledger is revoked.")
            }
            .sheet(item: $backupAuthorization, onDismiss: {
                if let authorizedPreview { importPreview = authorizedPreview }
                authorizedPreview = nil
                lockedBackup = nil
            }) { backup in
                NavigationStack {
                    DeviceAuthorizationView(targetLedgerID: backup.ledgerID, targetName: backup.sourceName,
                        targetFingerprint: backup.fingerprint, requestPurpose: .migration, onAuthorized: {
                            do {
                                authorizedPreview = try BackupCodec.decode(backup.data, sourceName: backup.sourceName, existingState: store.state)
                            } catch { store.presentedError = error.localizedDescription }
                        })
                }
            }
            .sheet(item: $importPreview) { preview in
                ImportPreviewView(preview: preview) {
                    store.replace(with: preview.envelope)
                    importPreview = nil
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showingCloudSharing) {
                if let cloudShare {
                    CloudSharingView(share: cloudShare, container: CKContainer(identifier: "iCloud.com.finsy.app"))
                }
            }
    }

    private func handleImport(result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            do {
                importPreview = try BackupCodec.decode(data, sourceName: url.lastPathComponent, existingState: store.state)
            } catch LedgerCryptoError.authorizationRequired(let ledgerID, let fingerprint) {
                lockedBackup = LockedBackupImport(ledgerID: ledgerID, fingerprint: fingerprint,
                    data: data, sourceName: url.lastPathComponent)
                askingBackupAuthorization = true
            }
        } catch { store.presentedError = error.localizedDescription }
    }
}

private struct SettingsAlertsModifier: ViewModifier {
    @Binding var statusMessage: String?
    @Binding var confirmingReset: Bool
    @Binding var confirmingPendingCloud: Bool
    let onReset: () -> Void
    let onContinuePendingCloud: () -> Void

    private var isStatusAlertPresented: Binding<Bool> {
        Binding(
            get: { statusMessage != nil },
            set: { isPresent in
                if !isPresent {
                    statusMessage = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert("Backup", isPresented: isStatusAlertPresented) {
                Button("OK") { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
            .confirmationDialog("Reset App Data?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset Local App Data", role: .destructive) {
                    onReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears local ledgers, receipts, caches, and device preferences. It does not delete CloudKit ledgers owned by or shared with other people.")
            }
            .confirmationDialog("Cloud Changes Pending", isPresented: $confirmingPendingCloud, titleVisibility: .visible) {
                Button("Continue Anyway") {
                    onContinuePendingCloud()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cloud changes may still be pending. This backup will contain the latest data currently available on this device.")
            }
    }
}

struct SettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    init(_ title: LocalizedStringKey, systemImage: String) { self.title = title; self.systemImage = systemImage }
    init(_ title: String, systemImage: String) { self.title = LocalizedStringKey(title); self.systemImage = systemImage }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
            Text(title)
        }
    }
}

struct SettingsLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String?
    init(_ title: LocalizedStringKey, systemImage: String, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }
    init(_ title: String, systemImage: String, detail: String? = nil) {
        self.title = LocalizedStringKey(title)
        self.systemImage = systemImage
        self.detail = detail
    }
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
    let title: LocalizedStringKey?
    let footer: LocalizedStringKey?
    let content: Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    init(_ title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title.map { LocalizedStringKey($0) }
        self.footer = footer.map { LocalizedStringKey($0) }
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
            }
            content
            if let footer {
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
    @EnvironmentObject private var store: LedgerStore
    let preview: ImportPreview
    let confirm: () -> Void
    @State private var confirmingStaleBackup = false

    private var isLocalNewer: Bool {
        store.state.lastModifiedAt > preview.envelope.data.lastModifiedAt
    }

    private var localUpdatedAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: store.state.lastModifiedAt, relativeTo: .now)
    }

    private var backupUpdatedAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: preview.envelope.data.lastModifiedAt, relativeTo: .now)
    }

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
                    Button("Import") {
                        if isLocalNewer {
                            confirmingStaleBackup = true
                        } else {
                            confirm()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Newer Local Data", isPresented: $confirmingStaleBackup, titleVisibility: .visible) {
                Button("Replace Anyway", role: .destructive) {
                    confirm()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your current ledger is newer (updated \(localUpdatedAgo)).\nThis backup was last updated \(backupUpdatedAgo).\n\nReplacing the current ledger may discard newer transactions.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @State private var diagnostics: OverviewWidgetBridgeDiagnostics = OverviewWidgetSnapshotStore.diagnostics()
    @State private var refreshMessage: String?
    @State private var isRefreshing = false
    @State private var storageBytes: Int64 = 0
    @State private var cloudStatus = "Checking…"
    @State private var walletStatus = "Checking…"
    @State private var exchangeStatus = "Checking…"
    @State private var marketStatus = "Checking…"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Finsy") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Last Updated", value: buildDate)
                    LabeledContent("Storage Used", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                }
                SettingsGlassSection("Connections") {
                    LabeledContent("iCloud", value: cloudStatus)
                    LabeledContent("Wallet Server", value: walletStatus)
                    LabeledContent("Exchange Rate API", value: exchangeStatus)
                    LabeledContent("Market Data API", value: marketStatus)
                }
                SettingsGlassSection("Diagnostics · Sync & Wallet") {
                    LabeledContent("Ledger Sync", value: store.iCloudSyncReady ? "Ready" : "Inactive")
                    LabeledContent("Automatic Sync", value: preferences.value.iCloudSyncEnabled ? "On" : "Off")
                    LabeledContent("Automatic Backup", value: preferences.value.iCloudBackupEnabled ? "On" : "Off")
                    LabeledContent("Account Pass", value: WalletPassManager.shared.isAccountPassInstalled() ? "Installed" : "Not Added")
                    LabeledContent("Pass Updates", value: WalletPassManager.shared.refreshStatus ?? "Not refreshed this session")
                    if let error = store.lastSyncError { Text(error).font(.caption).textSelection(.enabled) }
                    if let warning = store.purchaseSyncWarning { Text(warning).font(.caption).textSelection(.enabled) }
                    if let error = ICloudLibraryCoordinator.shared.lastError { Text(error).font(.caption).textSelection(.enabled) }
                    LabeledContent("Storage", value: store.canMutateLedger ? "Writable" : "Recovery · Read Only")
                    if let status = StockQuoteRefreshService.shared.status { Text(status).font(.caption).textSelection(.enabled) }
                }
                widgetDataSection
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            diagnostics = OverviewWidgetSnapshotStore.diagnostics()
            await refreshConnections()
        }
        .alert("Widget Data", isPresented: Binding(get: { refreshMessage != nil }, set: { if !$0 { refreshMessage = nil } })) {
            Button("OK") { refreshMessage = nil }
        } message: {
            Text(refreshMessage ?? "")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }

    private var buildDate: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "FinsyBuildDate") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return "Unavailable" }
        return value
    }

    @MainActor
    private func refreshConnections() async {
        async let bytes = Task.detached(priority: .utility) { () -> Int64 in
            AboutStorageMeasurement.bytes()
        }.value
        async let cloud: String = probeCloud()
        async let wallet: String = probeWallet()
        async let exchange: String = probeExchange()
        async let market: String = probeMarket()
        (storageBytes, cloudStatus, walletStatus, exchangeStatus, marketStatus) = await (bytes, cloud, wallet, exchange, market)
    }

    private func probeCloud() async -> String {
        do {
            let status = try await CKContainer(identifier: "iCloud.com.finsy.app").accountStatus()
            switch status {
            case .available: return "Connected"
            case .noAccount: return "Not Signed In"
            case .restricted: return "Restricted"
            default: return "Unavailable"
            }
        } catch { return "Unavailable" }
    }

    private func probeWallet() async -> String {
        guard let base = WalletPassConfiguration.issuerURL else { return "Not Configured" }
        do {
            let request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 && String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" ? "Connected" : "Unavailable"
        } catch { return "Unavailable" }
    }

    private func probeExchange() async -> String {
        do { _ = try await FrankfurterRateService.shared.latest(); return "Connected" }
        catch { return "Unavailable" }
    }

    private func probeMarket() async -> String {
        guard (try? MarketDataKeychain.read()) != nil else { return "Not Configured" }
        do { _ = try await AlphaVantageService.shared.marketStatus(); return "Connected" }
        catch { return "Unavailable" }
    }

    private var widgetDataSection: some View {
        SettingsGlassSection("WIDGET DATA") {
            LabeledContent {
                Text(diagnostics.containerReachable ? "Available" : "Unavailable")
                    .font(.body.weight(.medium))
                    .foregroundStyle(diagnostics.containerReachable ? .green : .red)
            } label: {
                SettingsLabel("App Group", systemImage: "person.2.circle")
            }

            Divider()

            LabeledContent {
                Text(snapshotStatusText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(snapshotStatusColor)
            } label: {
                SettingsLabel("Snapshot", systemImage: "doc.text")
            }

            Divider()

            LabeledContent {
                Text(updatedText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            } label: {
                SettingsLabel("Updated", systemImage: "clock")
            }

            Divider()

            LabeledContent {
                Text(sizeText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            } label: {
                SettingsLabel("Size", systemImage: "internaldrive")
            }

            Divider()

            LabeledContent {
                Text(reloadStatusText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(reloadStatusColor)
            } label: {
                SettingsLabel("Widget Reload", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                isRefreshing = true
                diagnostics = OverviewWidgetRelay.refreshWidgetData(store: store, preferences: preferences.value)
                isRefreshing = false
                refreshMessage = diagnostics.state == .available ? "Widget data refreshed and verified." : "Widget data refresh completed with state: \(diagnostics.state)"
            } label: {
                HStack {
                    SettingsLabel("Refresh Widget Data", systemImage: "arrow.clockwise")
                    Spacer()
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
        }
    }

    private var snapshotStatusText: String {
        switch diagnostics.state {
        case .available:
            return "Available"
        case .snapshotMissing:
            return "Missing"
        case .containerUnavailable:
            return "Unavailable"
        case .snapshotIncompatible, .decodeFailed, .readFailed, .writeFailed:
            return "Invalid"
        }
    }

    private var snapshotStatusColor: Color {
        switch diagnostics.state {
        case .available:
            return .green
        case .snapshotMissing:
            return .orange
        case .containerUnavailable, .snapshotIncompatible, .decodeFailed, .readFailed, .writeFailed:
            return .red
        }
    }

    private var reloadStatusText: String {
        diagnostics.containerReachable && diagnostics.state == .available ? "Available" : "Unavailable"
    }

    private var reloadStatusColor: Color {
        diagnostics.containerReachable && diagnostics.state == .available ? .green : .secondary
    }

    private var updatedText: String {
        guard let date = diagnostics.snapshotFileModifiedAt else {
            return "Never"
        }
        if abs(date.timeIntervalSinceNow) < 60 {
            return "just now"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var sizeText: String {
        guard let bytes = diagnostics.snapshotFileSize else {
            return "—"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

private struct LockedBackupImport: Identifiable {
    var id: UUID { ledgerID }
    var ledgerID: UUID
    var fingerprint: String?
    var data: Data
    var sourceName: String
}

private enum AboutStorageMeasurement {
    static func bytes() -> Int64 {
        let manager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [.applicationSupportDirectory, .cachesDirectory, .documentDirectory]
        var roots = directories.compactMap { manager.urls(for: $0, in: .userDomainMask).first }
        roots.append(Bundle.main.bundleURL)
        if let shared = manager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.finsy.app") { roots.append(shared) }
        var total: Int64 = 0
        for root in roots {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
