import SwiftUI

@main
struct FinsyApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    @StateObject private var store = LedgerStore.shared
    @StateObject private var preferences = AppPreferencesStore.shared
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
                .task {
                    await FinsyMaintenanceCoordinator.shared.performAppLaunchMaintenance(
                        store: store,
                        preferences: preferences,
                        privacy: privacy
                    )
                }
                .onChange(of: store.activeBookID) { _, newBookID in
                    FinsyMaintenanceCoordinator.shared.scheduleLedgerSwitchMaintenance(
                        store: store,
                        preferences: preferences,
                        expectedBookID: newBookID
                    )
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        FinsyMaintenanceCoordinator.shared.performForegroundMaintenance(
                            store: store,
                            preferences: preferences,
                            privacy: privacy
                        )
                    } else if phase == .background {
                        // Authentication dialogs can make the scene inactive.
                        // Re-lock only after actually leaving the foreground.
                        ICloudBackupBackground.schedule(preferences: preferences.value)
                        privacy.lockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
                        OverviewWidgetRelay.updateSnapshot(store: store, preferences: preferences.value)
                    }
                }
        }
    }
}
