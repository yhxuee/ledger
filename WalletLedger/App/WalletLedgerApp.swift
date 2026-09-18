import SwiftUI

@main
struct WalletLedgerApp: App {
    @StateObject private var store = LedgerStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(nil)
                .task(id: store.activeBookID) { try? await store.refreshExchangeRatesIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    store.processDueRecurring()
                    Task { try? await store.refreshExchangeRatesIfNeeded() }
                }
        }
    }
}
