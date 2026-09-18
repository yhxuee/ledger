import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview", ledger = "Ledger", analytics = "Analytics", accounts = "Accounts", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: "house"; case .ledger: "creditcard"; case .analytics: "chart.bar.xaxis"; case .accounts: "wallet.bifold"; case .settings: "gearshape" }
    }
}

struct AppSectionMenu: View {
    @Binding var selection: AppSection

    var body: some View {
        Menu {
            ForEach(AppSection.allCases) { destination in
                Button { selection = destination } label: {
                    Label(destination.rawValue, systemImage: selection == destination ? "checkmark.circle.fill" : destination.symbol)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .accessibilityLabel("Choose page")
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
                NavigationStack { LedgerView(section: $section) }.tabItem { Label("Ledger", systemImage: "creditcard") }.tag(AppSection.ledger)
                NavigationStack { AnalyticsView(section: $section) }.tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }.tag(AppSection.analytics)
                NavigationStack { AccountsView(section: $section) }.tabItem { Label("Accounts", systemImage: "wallet.bifold") }.tag(AppSection.accounts)
                NavigationStack { SettingsView(section: $section) }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppSection.settings)
            }
        }
    }

    @ViewBuilder private var destination: some View {
        switch section {
        case .overview: OverviewView(section: $section, selectedAccountID: $selectedAccountID)
        case .ledger: LedgerView(section: $section)
        case .analytics: AnalyticsView(section: $section)
        case .accounts: AccountsView(section: $section)
        case .settings: SettingsView(section: $section)
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
