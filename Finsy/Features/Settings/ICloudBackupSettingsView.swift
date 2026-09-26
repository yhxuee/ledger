import SwiftUI

struct ICloudBackupSettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @ObservedObject private var coordinator = ICloudLibraryCoordinator.shared
    @State private var preview: ICloudLibraryRestorePreview?
    @State private var message: String?
    @State private var restoring = false

    private var busy: Bool { coordinator.working || restoring }
    private var enabled: Binding<Bool> {
        Binding(get: { preferences.value.iCloudBackupEnabled }, set: { value in
            // Re-enabling must discover remote deletions before sending offline edits.
            store.iCloudSyncReady = false
            preferences.update { $0.iCloudBackupEnabled = value }
            ICloudBackupBackground.schedule(preferences: preferences.value)
            Task {
                do { try await CloudLedgerService.shared.updateICloudPreference() }
                catch { message = error.localizedDescription }
                if value { await coordinator.maintenance(store: store, preferences: preferences) }
            }
        })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("iCloud Backup") {
                    Toggle("iCloud Backup", isOn: enabled)
                        .disabled(busy || !store.canMutateLedger)
                    Text("Sync all your ledgers across devices using the same iCloud account. Changes sync automatically while iCloud Backup is enabled.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Encrypted ledgers use iCloud Keychain to securely sync their keys between your devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Backup Frequency") {
                    Picker("Backup Frequency", selection: Binding(get: { preferences.value.iCloudBackupInterval }, set: { value in
                        preferences.update { $0.iCloudBackupInterval = value }
                        ICloudBackupBackground.schedule(preferences: preferences.value)
                    })) {
                        ForEach(ICloudBackupInterval.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(busy)
                    Text("D · Daily   W · Weekly   M · Monthly")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Backups include all ledgers. If a scheduled backup is missed, Finsy catches up when you next open the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Backup & Restore") {
                    Button {
                        Task {
                            do {
                                try await coordinator.backupNow(store: store, preferences: preferences)
                                message = "All ledgers backed up to iCloud Drive."
                            } catch { message = error.localizedDescription }
                        }
                    } label: { SettingsLabel("Back Up Now", systemImage: "icloud.and.arrow.up") }
                    .foregroundStyle(.primary)
                    .disabled(!preferences.value.iCloudBackupEnabled || busy || !store.canMutateLedger)
                    if let date = preferences.value.iCloudLastBackupAt {
                        Text("Last Backup · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Last Backup · Never").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Button {
                        Task {
                            do { preview = try await coordinator.restorePreview(store: store, preferences: preferences) }
                            catch { message = error.localizedDescription }
                        }
                    } label: { SettingsLabel("Restore", systemImage: "icloud.and.arrow.down") }
                    .foregroundStyle(.primary)
                    .disabled(!preferences.value.iCloudBackupEnabled || busy || !store.canMutateLedger)
                }
                if busy { ProgressView("Updating iCloud…") }
                if let error = coordinator.lastError ?? store.lastSyncError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("iCloud Backup")
        .navigationBarTitleDisplayMode(.inline)
        .alert("iCloud Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .sheet(item: $preview) { snapshot in
            NavigationStack {
                Form {
                    Section("Backup") {
                        LabeledContent("Ledgers", value: "\(snapshot.library.books.count)")
                        LabeledContent("Transactions", value: "\(snapshot.transactionCount)")
                        ForEach(snapshot.library.books) { book in
                            LabeledContent(book.name, value: "\(book.state.transactions.filter { $0.deletedAt == nil }.count)")
                        }
                    }
                    Section {
                        Text("Restore adds missing ledgers and merges newer records. Existing ledgers are kept. Ledgers shared with you are kept unchanged or restored as separate copies.")
                            .font(.footnote)
                        Button("Restore All Ledgers") {
                            restoring = true
                            Task {
                                defer { restoring = false }
                                do {
                                    guard preferences.value.iCloudBackupEnabled else { throw ICloudLibraryError.disabled }
                                    try await store.restoreLibrary(snapshot.library)
                                    preview = nil
                                    message = "Ledgers restored."
                                    await coordinator.maintenance(store: store, preferences: preferences)
                                } catch { preview = nil; message = error.localizedDescription }
                            }
                        }
                        .disabled(restoring || !preferences.value.iCloudBackupEnabled)
                    }
                }
                .navigationTitle("Restore Preview")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { preview = nil }.disabled(restoring) } }
                .interactiveDismissDisabled(restoring)
            }
        }
    }
}
