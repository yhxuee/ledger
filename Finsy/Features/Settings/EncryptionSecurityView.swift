import SwiftUI
import CryptoKit

struct EncryptionSecurityView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var preferences: AppPreferencesStore

    @State private var confirmingDisableE2EE = false
    @State private var working = false
    @State private var statusMessage: String?

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
            Text("Future CloudKit records and backups for this ledger will no longer use the ledger encryption key. Existing encrypted backup files remain encrypted.")
        }
        .alert("End-to-End Encryption", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private var encryptionSection: some View {
        SettingsGlassSection("End-to-End Encryption") {
            if isParticipant {
                HStack {
                    Text("End-to-End Encryption")
                    Spacer()
                    Text("Required by Owner")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if activeBook.effectiveEncryptionState == .authorizationRequired {
                HStack {
                    Text("End-to-End Encryption")
                    Spacer()
                    Text("Locked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle("End-to-End Encryption", isOn: e2eeBinding)
                    .disabled(working || activeBook.effectiveEncryptionState == .enabling || activeBook.effectiveEncryptionState == .disabling)
            }

            Divider()

            if activeBook.effectiveEncryptionState == .migrationFailed {
                LabeledContent {
                    Text("Migration Failed")
                        .foregroundStyle(.red)
                } label: {
                    Text("Status")
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
            get: { activeBook.effectiveEncryptionState == .enabled },
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
            let (key, fp) = try LedgerKeyStore.generateAndSaveKey(for: store.activeBook.id)
            store.markActiveBookEncrypted(fingerprint: fp)
            if store.activeBook.effectiveStorageKind != .local {
                try await CloudLedgerService.shared.migrateToEncrypted(book: store.activeBook, key: key)
            }
            statusMessage = "End-to-End Encryption enabled for this ledger."
        } catch {
            store.presentedError = error.localizedDescription
        }
    }

    private func disableE2EE() {
        store.markActiveBookUnencrypted()
        statusMessage = "End-to-End Encryption disabled. Existing encrypted backups remain readable."
    }
}

