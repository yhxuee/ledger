import SwiftUI

struct ICloudSyncSettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @ObservedObject private var coordinator = ICloudSyncCoordinator.shared

    private var enabled: Binding<Bool> {
        Binding(get: { preferences.value.iCloudSyncEnabled }, set: { value in
            store.iCloudSyncReady = false
            preferences.update { $0.iCloudSyncEnabled = value }
            Task {
                do { try await CloudLedgerService.shared.updateICloudPreference() }
                catch { store.lastSyncError = error.localizedDescription }
                if value { await coordinator.maintenance(store: store, preferences: preferences) }
            }
        })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("iCloud Sync") {
                    Toggle("iCloud Sync", isOn: enabled)
                        .disabled(coordinator.working || !store.canMutateLedger)
                    Text("Keep all your ledgers up to date across devices using the same iCloud account. Saved changes are sent automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Other devices receive changes through CloudKit notifications. Finsy also checks when you open the app. Background delivery may be delayed by iOS or your connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Encrypted ledgers use iCloud Keychain to securely sync their keys between your devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("iCloud Backup saves separate snapshots on its own schedule.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Sync") {
                    Button {
                        Task { await coordinator.maintenance(store: store, preferences: preferences) }
                    } label: { SettingsLabel("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud") }
                    .foregroundStyle(.primary)
                    .disabled(!preferences.value.iCloudSyncEnabled || coordinator.working || !store.canMutateLedger)
                }
                if coordinator.working { ProgressView("Syncing…") }
                if let error = store.lastSyncError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
