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

    var body: some View {
        Menu {
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
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .ledgerGlass(interactive: true, in: Circle())
        .accessibilityLabel("Choose ledger")
        .sheet(isPresented: $showingNewBook) { NewLedgerSheet() }
    }
}

private struct NewLedgerSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Ledger name", text: $name) }
                .navigationTitle("New Ledger")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Add") { store.createBook(named: name); dismiss() } }
                }
        }
        .presentationDetents([.medium])
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: AppSection = .overview
    @State private var selectedAccountID: UUID?

    var body: some View {
        ZStack { LedgerBackground(); content }
            .alert("Wallet Ledger", isPresented: Binding(get: { store.presentedError != nil }, set: { if !$0 { store.presentedError = nil } })) { Button("OK") { store.presentedError = nil } } message: { Text(store.presentedError ?? "") }
            .overlay(alignment: .bottom) { undoToast }
            .onChange(of: store.activeBookID) { _, _ in selectedAccountID = nil }
    }

    @ViewBuilder private var content: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List {
                    Section {
                        ForEach(AppSection.allCases) { item in
                            Button { section = item } label: { Label(item.rawValue, systemImage: item.symbol).fontWeight(section == item ? .semibold : .regular) }
                        }
                    }
                    Section("Accounts") {
                        Button { selectedAccountID = nil; section = .overview } label: { Label("All Accounts", systemImage: "square.grid.2x2") }
                        ForEach(store.accounts) { item in
                            Button { selectedAccountID = item.id; section = .overview } label: {
                                HStack { Text(item.account.logo).font(.caption.bold()).frame(width: 32); VStack(alignment: .leading) { Text(item.account.name).lineLimit(1); Text(LedgerFormat.money(item.balance, currency: item.account.currency)).font(.caption).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                }
                .navigationTitle("Ledger")
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 290)
            } detail: {
                NavigationStack { destination }
            }
        } else {
            TabView(selection: $section) {
                NavigationStack { OverviewView(section: $section, selectedAccountID: $selectedAccountID) }.tabItem { Label("Overview", systemImage: "house") }.tag(AppSection.overview)
                NavigationStack { LedgerView() }.tabItem { Label("Ledger", systemImage: "creditcard") }.tag(AppSection.ledger)
                NavigationStack { AnalyticsView() }.tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }.tag(AppSection.analytics)
                NavigationStack { AccountsView() }.tabItem { Label("Accounts", systemImage: "wallet.bifold") }.tag(AppSection.accounts)
                NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppSection.settings)
            }
        }
    }

    @ViewBuilder private var destination: some View {
        switch section {
        case .overview: OverviewView(section: $section, selectedAccountID: $selectedAccountID)
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
