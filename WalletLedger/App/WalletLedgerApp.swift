import SwiftUI

@main
struct WalletLedgerApp: App {
    @StateObject private var store = LedgerStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(nil)
        }
    }
}
