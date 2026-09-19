import CloudKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @EnvironmentObject private var privacy: PrivacyController
    @State private var confirmingReset = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: BackupDocument?
    @State private var cloudShare: CKShare?
    @State private var showingCloudSharing = false
    @State private var working = false
    @State private var activeImportPreview: ImportPreview?
    @State private var showingImportPreview = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Basic") {
                    NavigationLink { DefaultExpenseAccountsView() } label: { SettingsLinkRow("Default Accounts", systemImage: "arrow.triangle.branch", detail: "By category") }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { LayoutSettingsView() } label: {
                        SettingsLinkRow("Layout", systemImage: "rectangle.grid.1x2", detail: preferences.value.transactionLayout.title)
                    }.foregroundStyle(.primary)
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
                    LabeledContent {
                        Menu {
                            ForEach(CurrencyCode.allCases) { currency in
                                Button {
                                    store.updateBaseCurrency(currency)
                                } label: {
                                    if store.state.settings.baseCurrency == currency {
                                        Label("\(currency.rawValue) (\(currency.symbol))", systemImage: "checkmark")
                                    } else {
                                        Text("\(currency.rawValue) (\(currency.symbol))")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(store.state.settings.baseCurrency.rawValue)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    } label: {
                        SettingsLabel("Base Currency", systemImage: "coloncurrencysign.circle")
                    }
                }
                SettingsGlassSection("Functions") {
                    NavigationLink { ExchangeRateEditorView() } label: { SettingsLinkRow("Exchange Rates", systemImage: "arrow.left.arrow.right", detail: store.state.settings.automaticRates ? "Automatic" : "Manual") }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { BudgetEditorView() } label: { SettingsLinkRow("Budget", systemImage: "chart.pie", detail: store.state.settings.budgetPlan.mode.title) }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { RecurringTransactionsView() } label: { SettingsLinkRow("Recurring Transactions", systemImage: "calendar.badge.clock", detail: "\(store.recurringRules.count)") }.foregroundStyle(.primary)
                    Divider()
                    NavigationLink { SwipeActionsEditorView() } label: { SettingsLinkRow("Swipe Actions", systemImage: "hand.draw", detail: nil) }.foregroundStyle(.primary)
                    Divider()
                    Toggle(isOn: preferenceBinding(\.hapticFeedbackEnabled)) { SettingsLabel("Haptic Feedback", systemImage: "waveform") }
                    Divider()
                    NavigationLink { MarketDataSettingsView() } label: { SettingsLinkRow("Alpha Vantage API Key", systemImage: "key", detail: nil) }.foregroundStyle(.primary)
                }
                SettingsGlassSection("Security") {
                    Toggle(isOn: biometricBinding) { SettingsLabel("Face ID / Touch ID", systemImage: "faceid") }
                    Divider()
                    Button(role: .destructive) { confirmingReset = true } label: { SettingsLabel("Reset App Data", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading) }
                }
                SettingsGlassSection("Data") {
                    LedgerBookSummaryView()
                    Divider()
                    Button { Task { await shareLedger() } } label: { SettingsLabel(store.activeBook.effectiveStorageKind == .local ? "Share Ledger" : "Manage Sharing", systemImage: "person.2.badge.gearshape").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary).disabled(working)
                    Divider()
                    Button { Task { await backupToICloud() } } label: { SettingsLabel("Back Up Now", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary).disabled(working)
                    Divider()
                    Button { Task { await restoreFromICloud() } } label: { SettingsLabel("Restore", systemImage: "icloud.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary).disabled(working)
                    Divider()
                    Button { exportDocument = BackupDocument(envelope: store.backupEnvelope()); showingExporter = true } label: { SettingsLabel("Export Backup", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary)
                    Divider()
                    Button { showingImporter = true } label: { SettingsLabel("Import Backup", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }.foregroundStyle(.primary)
                }
                Text("Finsy · Multi-Currency Double-Entry Ledger").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 4).padding(.bottom, 24)
            }.padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Settings")
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .walletLedgerBackup, defaultFilename: "ledger-\(Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))).walletledger") { result in
            if case .failure(let error) = result { store.presentedError = error.localizedDescription }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.walletLedgerBackup, .json]) { result in
            switch result {
            case .success(let url):
                do {
                    activeImportPreview = try store.previewBackup(at: url)
                    showingImportPreview = true
                } catch {
                    store.presentedError = error.localizedDescription
                }
            case .failure(let error):
                store.presentedError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingCloudSharing) { if let cloudShare { CloudSharingView(share: cloudShare, container: CKContainer(identifier: "iCloud.com.finsy.app")) } }
        .sheet(isPresented: $showingImportPreview) {
            if let activeImportPreview {
                ImportPreviewView(preview: activeImportPreview) {
                    do { try store.applyImportPreview(activeImportPreview); showingImportPreview = false }
                    catch { store.presentedError = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Reset App Data?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Erase All Books and Start Fresh", role: .destructive) { store.resetAllData() }
        } message: { Text("This will delete all books, transactions, accounts, and budgets from this device.") }
    }

    private func preferenceBinding<T>(_ keyPath: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(get: { preferences.value[keyPath: keyPath] }, set: { value in preferences.update { $0[keyPath: keyPath] = value } })
    }
    private var dateFormatBinding: Binding<AppDateFormat> {
        Binding(get: { preferences.value.dateFormat }, set: { value in preferences.update { $0.dateFormat = value } })
    }
    private var biometricBinding: Binding<Bool> {
        Binding(get: { preferences.value.biometricLockEnabled }, set: { enabled in
            Task {
                if enabled {
                    let success = await privacy.requestEnrollmentAuthentication()
                    if success { preferences.update { $0.biometricLockEnabled = true } }
                } else {
                    let success = await privacy.requestEnrollmentAuthentication()
                    if success { preferences.update { $0.biometricLockEnabled = false } }
                }
            }
        })
    }
    private func backupToICloud() async {
        working = true; defer { working = false }
        do { try await store.backupToICloud() }
        catch { store.presentedError = error.localizedDescription }
    }
    private func restoreFromICloud() async {
        working = true; defer { working = false }
        do { try await store.restoreFromICloud() }
        catch { store.presentedError = error.localizedDescription }
    }
    private func shareLedger() async {
        working = true; defer { working = false }
        do {
            cloudShare = try await store.prepareCloudShare()
            showingCloudSharing = true
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
                if !preview.warnings.isEmpty { Section("Review") { ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") } } }
            }
            .navigationTitle("Import Ledger")
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
                    Button(action: confirm) {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Save")
                }
            }
        }
    }
}
