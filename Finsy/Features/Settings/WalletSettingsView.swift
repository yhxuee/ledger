import PassKit
import SwiftUI

struct WalletSettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @StateObject private var walletManager = WalletPassManager.shared

    @State private var passToPresent: PKPass?
    @State private var showingAddPassSheet = false
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    // Add Location Sheet
    @State private var showingAddLocationSheet = false
    @State private var newLocationLat = ""
    @State private var newLocationLon = ""
    @State private var newLocationText = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "wallet.pass.fill")
                        .font(.title)
                        .foregroundStyle(Color.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Wallet Account Pass")
                            .font(.headline)
                        Text("Updates automatically while Finsy is open.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !walletManager.isIssuerConfigured {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Wallet Pass Issuer Not Configured", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Pass Source") {
                Picker("Source Account", selection: Binding(
                    get: { preferences.value.walletAccountPassSource },
                    set: { newSource in
                        preferences.update { $0.walletAccountPassSource = newSource }
                    }
                )) {
                    Text("All").tag(WalletAccountPassSource.allAccounts)
                    ForEach(store.state.accounts.filter { $0.deletedAt == nil }) { account in
                        Text(account.name).tag(WalletAccountPassSource.specificAccount(account.id))
                    }
                }
            }

            Section {
                ForEach(preferences.value.walletPassLocations) { loc in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.relevantText.isEmpty ? "Location" : loc.relevantText)
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: "%.4f, %.4f", loc.latitude, loc.longitude))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { indexSet in
                    preferences.update { prefs in
                        prefs.walletPassLocations.remove(atOffsets: indexSet)
                    }
                }

                if preferences.value.walletPassLocations.count < 10 {
                    Button {
                        showingAddLocationSheet = true
                    } label: {
                        Label("Add Relevant Location", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text(String(format: String(localized: "Relevant Locations (%lld/10)"), Int64(preferences.value.walletPassLocations.count)))
            } footer: {
                Text("Apple Wallet can display the pass on your Lock Screen when you are near up to 10 configured locations.")
            }

            Section {
                if walletManager.isAccountPassInstalled() {
                    Button {
                        Task { await refreshPassInWallet() }
                    } label: {
                        HStack {
                            Label("Update Pass in Wallet", systemImage: "arrow.clockwise")
                            if isRefreshing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing || !walletManager.isIssuerConfigured)
                } else {
                    Button {
                        Task { await addPassToWallet() }
                    } label: {
                        HStack {
                            Label("Add to Apple Wallet", systemImage: "plus")
                            if isRefreshing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing || !walletManager.isIssuerConfigured)
                }
            }
        }
        .navigationTitle("Apple Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddPassSheet) {
            if let pass = passToPresent {
                AddPassSheetView(pass: pass) {
                    passToPresent = nil
                }
            }
        }
        .sheet(isPresented: $showingAddLocationSheet) {
            NavigationStack {
                Form {
                    Section("Location Coordinates") {
                        TextField("Latitude (e.g. 37.3346)", text: $newLocationLat)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Longitude (e.g. -122.0090)", text: $newLocationLon)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    Section("Lock Screen Notification Text") {
                        TextField("Relevant Text (e.g. Near Supermarket)", text: $newLocationText)
                    }
                }
                .navigationTitle("New Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddLocationSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let lat = Double(newLocationLat.trimmingCharacters(in: .whitespaces)),
                               let lon = Double(newLocationLon.trimmingCharacters(in: .whitespaces)) {
                                let loc = WalletRelevantLocation(
                                    latitude: lat,
                                    longitude: lon,
                                    relevantText: newLocationText.trimmingCharacters(in: .whitespaces)
                                )
                                preferences.update { prefs in
                                    if prefs.walletPassLocations.count < 10 {
                                        prefs.walletPassLocations.append(loc)
                                    }
                                }
                            }
                            newLocationLat = ""
                            newLocationLon = ""
                            newLocationText = ""
                            showingAddLocationSheet = false
                        }
                        .disabled(Double(newLocationLat.trimmingCharacters(in: .whitespaces)) == nil ||
                                  Double(newLocationLon.trimmingCharacters(in: .whitespaces)) == nil)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Apple Wallet", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Pass Updated", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private func addPassToWallet() async {
        guard walletManager.canAddPasses else {
            errorMessage = WalletPassError.libraryUnavailable.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = walletManager.buildAccountPassSnapshot(
            store: store,
            source: preferences.value.walletAccountPassSource,
            locations: preferences.value.walletPassLocations
        )

        do {
            let pass = try await walletManager.issuer.issueAccountPass(snapshot: snapshot)
            passToPresent = pass
            showingAddPassSheet = true
            preferences.update { $0.walletPassLastRefreshedAt = .now }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPassInWallet() async {
        guard walletManager.isPassLibraryAvailable else {
            errorMessage = WalletPassError.libraryUnavailable.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = walletManager.buildAccountPassSnapshot(
            store: store,
            source: preferences.value.walletAccountPassSource,
            locations: preferences.value.walletPassLocations
        )

        do {
            let pass = try await walletManager.issuer.issueAccountPass(snapshot: snapshot)
            let replaced = walletManager.replaceAccountPass(with: pass)
            preferences.update { $0.walletPassLastRefreshedAt = .now }
            if replaced {
                statusMessage = "Apple Wallet Account Pass has been updated with your latest ledger balance."
            } else {
                passToPresent = pass
                showingAddPassSheet = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
