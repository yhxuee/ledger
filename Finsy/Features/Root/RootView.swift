import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview", ledger = "Ledger", analytics = "Analytics", accounts = "Accounts", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: "house"; case .ledger: "creditcard"; case .analytics: "chart.bar.xaxis"; case .accounts: "wallet.bifold"; case .settings: "gearshape" }
    }
}

struct LedgerBookMenu: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @State private var showingNewBook = false
    @State private var showingPurchaseMode = false
    @State private var deletingBook: LedgerBook?
    @State private var deleting = false

    var body: some View {
        Menu {
            Button { showingPurchaseMode = true } label: { Label("Purchase Mode", systemImage: "cart") }
            Divider()
            ForEach(store.books) { book in
                Button { store.switchBook(to: book.id) } label: {
                    HStack {
                        storageIcon(for: book)
                        Text(book.name)
                        if store.activeBookID == book.id { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button { showingNewBook = true } label: { Label("Add New Ledger", systemImage: "plus") }
            Button(role: .destructive) { deletingBook = store.activeBook } label: {
                Label(store.activeBook.effectiveStorageKind == .cloudParticipant ? "Leave Shared Ledger" : "Delete Ledger", systemImage: "trash")
            }
            .disabled(deleting || !store.canMutateLedger)
        } label: {
            HStack(spacing: 6) {
                storageIcon(for: store.activeBook)
                Image(systemName: "ellipsis")
            }
                .font(.body.weight(.semibold))
                .frame(height: 28)
                .contentShape(Circle())
        }
        .accessibilityLabel("Choose ledger")
        .sheet(isPresented: $showingNewBook) { NewLedgerSheet() }
        .sheet(isPresented: $showingPurchaseMode) { PurchaseModeView() }
        .confirmationDialog("Delete Ledger", isPresented: Binding(get: { deletingBook != nil }, set: { if !$0 { deletingBook = nil } }), titleVisibility: .visible) {
            if let book = deletingBook {
                Button(book.effectiveStorageKind == .cloudParticipant ? "Leave Shared Ledger" : "Delete Ledger", role: .destructive) {
                    deleting = true
                    Task { @MainActor in
                        defer { deleting = false }
                        do { try await store.deleteBook(book.id) }
                        catch { store.presentedError = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { deletingBook = nil }
        } message: {
            if let book = deletingBook {
                Text(book.effectiveStorageKind == .cloudParticipant
                     ? "Leave \(book.name)? Other participants keep their data."
                     : "Delete \(book.name) and its records? Synced copies and sharing access are also removed when iCloud Sync is enabled and connected.")
            }
        }
    }
    @ViewBuilder private func storageIcon(for book: LedgerBook) -> some View {
        if book.effectiveStorageKind == .cloudParticipant || store.sharedLedgerIDs.contains(book.id.uuidString) {
            Image(systemName: "person.2.fill").accessibilityLabel("Shared ledger")
        } else if preferences.value.iCloudSyncEnabled || preferences.value.iCloudBackupEnabled {
            let synced = preferences.value.iCloudSyncEnabled && (store.cloudSyncDates[book.id.uuidString].map { $0 >= book.updatedAt } ?? false)
            let backedUp = preferences.value.iCloudBackupEnabled && (preferences.value.iCloudLastBackupAt.map { $0 >= book.updatedAt } ?? false)
            if synced || backedUp {
                Image(systemName: "cloud.fill").accessibilityLabel("Saved to iCloud")
            } else {
                PendingCloudShape().stroke(style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                    .frame(width: 20, height: 14).accessibilityLabel("Waiting for iCloud")
            }
        } else {
            Image(systemName: "externaldrive").accessibilityLabel("Local ledger")
        }
    }
}

private struct PendingCloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.25, y: rect.height * 0.9))
        path.addCurve(to: CGPoint(x: rect.width * 0.22, y: rect.height * 0.35), control1: CGPoint(x: 0, y: rect.height), control2: CGPoint(x: 0, y: rect.height * 0.3))
        path.addCurve(to: CGPoint(x: rect.width * 0.8, y: rect.height * 0.4), control1: CGPoint(x: rect.width * 0.3, y: -rect.height * 0.2), control2: CGPoint(x: rect.width * 0.8, y: -rect.height * 0.1))
        path.addCurve(to: CGPoint(x: rect.width * 0.8, y: rect.height * 0.9), control1: CGPoint(x: rect.width * 1.08, y: rect.height * 0.3), control2: CGPoint(x: rect.width * 1.08, y: rect.height))
        path.closeSubpath()
        return path
    }

}

private struct NewLedgerSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Ledger name", text: $name) }
                .navigationTitle("New Ledger")
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
                        Button {
                            store.createBook(named: name)
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .tint(primaryActionColor)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Save")
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: AppSection = .overview
    @State private var selectedAccountID: UUID?
    @State private var sessionDismissedForecastWarning = false
    @State private var launchForecast: CashFlowForecast? = nil
    @State private var showingForecastBudgetDetail = false

    var body: some View {
        ZStack { LedgerBackground(); content }
            .alert("Finsy", isPresented: Binding(get: { store.presentedError != nil }, set: { if !$0 { store.presentedError = nil } })) { Button("OK") { store.presentedError = nil } } message: { Text(store.presentedError ?? "") }
            .overlay(alignment: .bottom) { bottomOverlays }
            .overlay {
                if store.acceptingCloudShare {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Opening shared ledger?").font(.subheadline)
                    }
                    .padding(24)
                    .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .onChange(of: store.activeBookID) { _, _ in selectedAccountID = nil }
            .onReceive(store.$activeRoute) { route in
                switch route {
                case .account(let id):
                    selectedAccountID = id
                    section = .overview
                    store.activeRoute = nil
                case .ledger:
                    section = .ledger
                    store.activeRoute = nil
                case .overview:
                    selectedAccountID = nil
                    section = .overview
                    store.activeRoute = nil
                default:
                    break
                }
            }
            .task {
                evaluateLaunchForecast()
            }
            .sheet(item: $store.incomingDeviceAuthorization) { incoming in
                NavigationStack { DeviceAuthorizationView(incomingData: incoming.data) }
            }
            .sheet(isPresented: $showingForecastBudgetDetail) {
                if let launchForecast {
                    BudgetDetailView(forecast: launchForecast)
                }
            }
            .sheet(isPresented: Binding(get: { store.activeRoute == .addTransaction }, set: { if !$0 && store.activeRoute == .addTransaction { store.activeRoute = nil } })) {
                TransactionEditorView()
            }
            .sheet(isPresented: Binding(get: { store.routedPurchaseID != nil }, set: { if !$0 { store.routedPurchaseID = nil; if case .purchase = store.activeRoute { store.activeRoute = nil } } })) {
                if let id = store.routedPurchaseID { PurchaseSessionFlowView(sessionID: id) }
            }
    }

    @ViewBuilder private var content: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List {
                    Section {
                        ForEach(AppSection.allCases) { item in
                            Button { withAnimation(.easeInOut(duration: 0.24)) { section = item } } label: { Label(item.rawValue, systemImage: item.symbol).fontWeight(section == item ? .semibold : .regular) }
                        }
                    }
                    Section("Accounts") {
                        Button { selectedAccountID = nil; section = .overview } label: { Label("Net Worth", systemImage: "square.grid.2x2") }
                        ForEach(store.accounts) { item in
                            Button { selectedAccountID = item.id; section = .overview } label: {
                                HStack { Text(item.account.logo).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.65).frame(width: 40); VStack(alignment: .leading) { Text(item.account.name).lineLimit(1); SensitiveMoneyText(amount: item.balance, currency: item.account.currency).font(.caption).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                }
                .navigationTitle("Ledger")
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 290)
            } detail: {
                NavigationStack { destination.id(section).transition(.opacity.combined(with: .move(edge: .trailing))) }
                    .animation(.easeInOut(duration: 0.24), value: section)
            }
        } else {
            TabView(selection: $section) {
                NavigationStack { OverviewView(section: animatedSection, selectedAccountID: $selectedAccountID) }.tabItem { Label("Overview", systemImage: "house") }.tag(AppSection.overview)
                NavigationStack { LedgerView() }.tabItem { Label("Ledger", systemImage: "creditcard") }.tag(AppSection.ledger)
                NavigationStack { AnalyticsView() }.tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }.tag(AppSection.analytics)
                NavigationStack { AccountsView() }.tabItem { Label("Accounts", systemImage: "wallet.bifold") }.tag(AppSection.accounts)
                NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppSection.settings)
            }
        }
    }

    private var animatedSection: Binding<AppSection> {
        Binding(get: { section }, set: { section = $0 })
    }

    @ViewBuilder private var destination: some View {
        switch section {
        case .overview: OverviewView(section: animatedSection, selectedAccountID: $selectedAccountID)
        case .ledger: LedgerView()
        case .analytics: AnalyticsView()
        case .accounts: AccountsView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder private var bottomOverlays: some View {
        VStack(spacing: 8) {
            if let forecast = launchForecast, !sessionDismissedForecastWarning {
                ForecastRiskBanner(
                    forecast: forecast,
                    onDismiss: {
                        withAnimation(.snappy) {
                            sessionDismissedForecastWarning = true
                        }
                    },
                    onSelect: {
                        showingForecastBudgetDetail = true
                    }
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let message = store.undoMessage {
                HStack { Text(message).font(.subheadline.weight(.semibold)); Button("Undo") { store.undoDelete() }.font(.subheadline.bold()) }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .ledgerGlass(interactive: true, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, sizeClass == .compact ? 62 : 18)
    }

    private func evaluateLaunchForecast() {
        guard preferences.value.cashFlowForecastEnabled else { return }
        let result = CashFlowForecastEngine.evaluate(state: store.state, preferences: preferences.value)
        if result.eligible && !result.budgetRisks.isEmpty {
            withAnimation(.snappy) {
                launchForecast = result
            }
        }
    }
}
