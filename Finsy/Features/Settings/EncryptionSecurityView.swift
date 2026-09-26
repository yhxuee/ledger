import SwiftUI
import CryptoKit

struct EncryptionSecurityView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var preferences: AppPreferencesStore

    @State private var confirmingDisableE2EE = false
    @State private var working = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var activeBook: LedgerBook { store.activeBook }
    private var ledgerID: UUID { activeBook.id }

    private var localKey: SymmetricKey? {
        try? LedgerKeyStore.loadKey(for: ledgerID)
    }

    private var hasLocalKey: Bool {
        localKey != nil
    }

    private var isParticipant: Bool {
        activeBook.effectiveStorageKind == .cloudParticipant
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                encryptionSection
                devicesSection
                keySafetySection
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Encryption & Devices")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if working {
                ProgressView()
                    .padding(20)
                    .ledgerGlass(in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .confirmationDialog("Turn Off End-to-End Encryption?", isPresented: $confirmingDisableE2EE, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                disableE2EE()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New unencrypted ledgers will no longer be encrypted automatically. Existing encrypted ledgers, their sync, sharing, and backups remain encrypted.")
        }
        .alert("End-to-End Encryption", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
        .alert(activeBook.effectiveEncryptionState == .migrationFailed ? "Encryption Migration Failed" : "End-to-End Encryption Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var encryptionSection: some View {
        SettingsGlassSection("End-to-End Encryption") {
            Toggle("End-to-End Encryption", isOn: e2eeBinding)
                .disabled(working)
            Text("Applies to all ledgers on this device, including existing records, iCloud Sync, sharing, and new backups.")
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Encrypted Ledgers", value: "\(store.books.filter { $0.isEncrypted == true }.count) / \(store.books.filter { $0.isImplicitPlaceholder != true }.count)")

            Divider()

            if activeBook.effectiveEncryptionState == .migrationFailed {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Migration Failed")
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                    }

                    if let error = errorMessage ?? store.lastSyncError, !error.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Diagnostics")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)

                            Text(error)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                    }

                    Button {
                        Task { await enableE2EE() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Retry Migration")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(working)
                    .padding(.top, 4)
                }
            } else {
                LabeledContent("Status", value: statusText)
            }

            Divider()

            LabeledContent("Encryption Key", value: keyStatusText)
        }
    }

    private var devicesSection: some View {
        SettingsGlassSection("Devices") {
            LabeledContent("This Device", value: thisDeviceStatusText)

            Divider()

            NavigationLink {
                DeviceAuthorizationView()
            } label: {
                SettingsLinkRow("Device Authorization", systemImage: "key.horizontal", detail: nil)
            }
            .foregroundStyle(.primary)
        }
    }

    private var keySafetySection: some View {
        SettingsGlassSection("Key Safety") {
            Text("Finsy cannot recover an encrypted ledger if every authorized copy of its encryption key is lost. Keep at least one authorized device or transfer the key when replacing devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch activeBook.effectiveEncryptionState {
        case .enabled:
            return String(localized: "Enabled")
        case .disabled:
            return String(localized: "Disabled")
        case .authorizationRequired:
            return String(localized: "Authorization Required")
        case .enabling:
            return String(localized: "Enabling…")
        case .disabling:
            return String(localized: "Disabling…")
        case .migrationFailed:
            return String(localized: "Migration Failed")
        }
    }

    private var keyStatusText: String {
        hasLocalKey ? String(localized: "Available") : String(localized: "Missing")
    }

    private var thisDeviceStatusText: String {
        if activeBook.effectiveEncryptionState == .enabled && hasLocalKey {
            return String(localized: "Authorized")
        }
        if activeBook.effectiveEncryptionState == .authorizationRequired || (activeBook.effectiveEncryptionState == .enabled && !hasLocalKey) {
            return String(localized: "Authorization Required")
        }
        if hasLocalKey {
            return String(localized: "Key Available")
        }
        return String(localized: "Missing")
    }

    private var e2eeBinding: Binding<Bool> {
        Binding(
            get: { preferences.value.endToEndEncryptionEnabled },
            set: { enabled in
                if enabled {
                    Task { await enableE2EE() }
                } else {
                    confirmingDisableE2EE = true
                }
            }
        )
    }

    private func enableE2EE() async {
        guard await privacy.authorizeSensitiveChange(
            reason: "Authenticate to enable End-to-End Encryption.",
            protectionEnabled: preferences.value.biometricLockEnabled
        ) else { return }

        working = true
        defer { working = false }
        do {
            try await store.enableEncryptionForAllBooks()
            errorMessage = nil
            statusMessage = "End-to-End Encryption enabled for all ledgers."
        } catch {
            let desc = error.localizedDescription
            errorMessage = desc
            store.presentedError = desc
            store.lastSyncError = desc
        }
    }

    private func disableE2EE() {
        preferences.update { $0.endToEndEncryptionEnabled = false }
        statusMessage = "Automatic encryption disabled. Existing encrypted ledgers remain protected."
    }
}

