import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var section: AppSection
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: BackupDocument?
    @State private var importPreview: ImportPreview?
    @State private var working = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Currency") {
                Picker("Base Currency", selection: baseCurrencyBinding) { ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Automatic Exchange Rates", isOn: automaticRatesBinding)
                Text("Automatic rates are reserved for a future authenticated provider.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Exchange Rates") {
                ForEach(CurrencyCode.allCases.filter { $0 != store.state.settings.baseCurrency }) { currency in
                    LabeledContent("1 \(currency.rawValue)") {
                        TextField("Rate", value: rateBinding(currency), format: .number.precision(.fractionLength(4))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text(store.state.settings.baseCurrency.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Reset Reference Rates") { store.updateSettings { $0.rates = SeedData.rates } }
            }
            Section("Data") {
                Button { exportDocument = BackupDocument(envelope: store.backupEnvelope()); showingExporter = true } label: { Label("Export Backup", systemImage: "square.and.arrow.up") }
                Button { showingImporter = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
            }
            Section("iCloud Backup") {
                Toggle("Backup Reminders", isOn: remindersBinding)
                Button { Task { await backupToICloud() } } label: { Label("Back Up Now", systemImage: "icloud.and.arrow.up") }.disabled(working)
                Button { Task { await restoreFromICloud() } } label: { Label("Restore Latest Backup", systemImage: "icloud.and.arrow.down") }.disabled(working)
                LabeledContent("Last Backup", value: store.state.settings.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Text("Requires the iCloud Documents capability and the container configured in WalletLedger.entitlements.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Local Mode", value: "Application Support")
                LabeledContent("Schema", value: "v\(store.state.schemaVersion)")
                Text("Balances and analytics are recalculated from the local transaction ledger; they are never stored as independent mutable totals.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AppSectionMenu(selection: $section) } }
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
        .overlay { if working { ProgressView().controlSize(.large).padding(24).ledgerGlass(in: RoundedRectangle(cornerRadius: 22)) } }
        .alert("Backup", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) { Button("OK") { statusMessage = nil } } message: { Text(statusMessage ?? "") }
    }

    private var baseCurrencyBinding: Binding<CurrencyCode> { Binding(get: { store.state.settings.baseCurrency }, set: { value in store.updateSettings { $0.baseCurrency = value } }) }
    private var automaticRatesBinding: Binding<Bool> { Binding(get: { store.state.settings.automaticRates }, set: { value in store.updateSettings { $0.automaticRates = value } }) }
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
