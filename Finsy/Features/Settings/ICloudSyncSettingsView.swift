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
                    Text("Sync ledgers across your iCloud devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Changes sync automatically when connected.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Keys stay on this device. Authorize other devices separately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                SettingsGlassSection("Sync") {
                    Button {
                        Task { await coordinator.maintenance(store: store, preferences: preferences) }
                    } label: { SettingsLabel("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud") }
                    .foregroundStyle(.primary)
                    .disabled(!preferences.value.iCloudSyncEnabled || coordinator.working || !store.canMutateLedger)
                }
                if coordinator.working {
                    SettingsGlassSection("Sync Progress") {
                        ProgressView(coordinator.phase)
                        if let start = coordinator.startedAt {
                            TimelineView(.periodic(from: start, by: 1)) { context in
                                Text("Elapsed: \(Int(context.date.timeIntervalSince(start))) seconds")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Button("Stop Sync") { Task { await coordinator.cancel() } }
                    }
                } else {
                    if let error = store.lastSyncError {
                        Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if let date = coordinator.lastCompletedAt {
                        LabeledContent("Last Synced", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
