import SwiftUI

@main
struct WalletLedgerApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    @StateObject private var store = LedgerStore()
    @StateObject private var preferences = AppPreferencesStore()
    @StateObject private var privacy = PrivacyController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(preferences)
                .environmentObject(privacy)
                .preferredColorScheme(nil)
                .onOpenURL { store.handleDeepLink($0) }
                .onReceive(NotificationCenter.default.publisher(for: .acceptedCloudLedger)) { notification in
                    if let book = notification.object as? LedgerBook { store.addOrMergeCloudBook(book) }
                    else if let error = notification.object as? Error { store.presentedError = error.localizedDescription }
                }
                .task(id: store.activeBookID) {
                    await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
                    _ = try? await store.refreshCurrencyCatalogIfNeeded()
                    _ = try? await store.refreshExchangeRatesIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.reconcileSharedActivePurchases()
                        store.processDueRecurring()
                        Task {
                            await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
                            _ = try? await store.refreshExchangeRatesIfNeeded()
                        }
                    } else {
                        privacy.lockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
                    }
                }
        }
    }
}
