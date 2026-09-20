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
    @State private var showingNewBook = false
    @State private var showingPurchaseMode = false

    var body: some View {
        Menu {
            Button { showingPurchaseMode = true } label: { Label("Purchase Mode", systemImage: "cart") }
            Divider()
            ForEach(store.books) { book in
                Button { store.switchBook(to: book.id) } label: {
                    Label(book.name, systemImage: store.activeBookID == book.id ? "checkmark.circle.fill" : "book.closed")
                }
            }
            Divider()
            Button { showingNewBook = true } label: { Label("Add New Ledger", systemImage: "plus") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .accessibilityLabel("Choose ledger")
        .sheet(isPresented: $showingNewBook) { NewLedgerSheet() }
        .sheet(isPresented: $showingPurchaseMode) { PurchaseModeView() }
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
    @Environment(\.scenePhase) private var scenePhase
    private let financialClock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: AppSection = .overview
    @State private var selectedAccountID: UUID?

    var body: some View {
        ZStack { LedgerBackground(); content }
            .alert("Wallet Ledger", isPresented: Binding(get: { store.presentedError != nil }, set: { if !$0 { store.presentedError = nil } })) { Button("OK") { store.presentedError = nil } } message: { Text(store.presentedError ?? "") }
            .overlay(alignment: .bottom) { undoToast }
            .onReceive(financialClock) { store.refreshDueInstallments(now: $0) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { store.refreshDueInstallments() } }
            .onChange(of: store.activeBookID) { _, _ in selectedAccountID = nil }
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
                                HStack { Text(item.account.logo).font(.caption.bold()).frame(width: 32); VStack(alignment: .leading) { Text(item.account.name).lineLimit(1); SensitiveMoneyText(amount: item.balance, currency: item.account.currency).font(.caption).foregroundStyle(.secondary) } }
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
            .animation(.easeInOut(duration: 0.24), value: section)
        }
    }

    private var animatedSection: Binding<AppSection> {
        Binding(get: { section }, set: { newValue in withAnimation(.easeInOut(duration: 0.24)) { section = newValue } })
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

    @ViewBuilder private var undoToast: some View {
        if let message = store.undoMessage {
            HStack { Text(message).font(.subheadline.weight(.semibold)); Button("Undo") { store.undoDelete() }.font(.subheadline.bold()) }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .ledgerGlass(interactive: true, in: Capsule())
                .padding(.bottom, sizeClass == .compact ? 62 : 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
