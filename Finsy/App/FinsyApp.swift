import SwiftUI

@main
struct FinsyApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    @StateObject private var store = LedgerStore.shared
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
                    await FinsyMaintenanceCoordinator.shared.performLaunchMaintenance(
                        store: store,
                        preferences: preferences,
                        privacy: privacy
                    )
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        FinsyMaintenanceCoordinator.shared.performForegroundMaintenance(
                            store: store,
                            preferences: preferences,
                            privacy: privacy
                        )
                    } else {
                        privacy.lockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
                        OverviewWidgetRelay.updateSnapshot(store: store, preferences: preferences.value)
                    }
                }
        }
    }
}
