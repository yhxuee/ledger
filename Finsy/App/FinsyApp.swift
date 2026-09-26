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
                .tint(Color(hex: preferences.value.statementThemeColorHex))
                .task(id: WalletPassRefreshKey(bookID: store.activeBookID, modifiedAt: store.state.lastModifiedAt, preferences: preferences.value)) {
                    await WalletPassManager.shared.refreshInstalledPasses(store: store, preferences: preferences.value)
                }
                .onOpenURL {
                    CloudShareSceneDelegate.open($0)
                    store.handleDeepLink($0)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { CloudShareSceneDelegate.open(url) }
                }
                .onChange(of: preferences.value.statementThemeColorHex) { _, _ in
                    Task {
                        for session in store.purchaseSessions where session.status == .active || session.status == .awaitingSummary {
                            await store.publish(session: session, requestActivity: false)
                        }
                    }
                }
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
                        Task {
                            await WalletPassManager.shared.refreshInstalledPasses(store: store, preferences: preferences.value, force: true)
                        }
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
