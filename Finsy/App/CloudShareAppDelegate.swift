import CloudKit
import UIKit

extension Notification.Name { static let acceptedCloudLedger = Notification.Name("FinsyAcceptedCloudLedger") }

final class CloudShareAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MarketRefreshBackground.register()
        ICloudBackupBackground.register()
        FinsyNotificationScheduler.shared.configure()
        // CloudKit subscriptions use silent pushes to wake the sync engine.
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CloudShareSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudShareSceneDelegate.accept(metadata)
    }
}

@MainActor
final class CloudShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    private static var accepting = Set<CKRecord.ID>()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { Self.accept(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Self.accept(metadata)
    }

    static func accept(_ metadata: CKShare.Metadata) {
        let id = metadata.share.recordID
        guard accepting.insert(id).inserted else { return }
        Task { @MainActor in
            defer { accepting.remove(id) }
            let store = LedgerStore.shared
            do {
                let book = try await CloudLedgerService.shared.accept(metadata)
                guard store.addOrMergeCloudBook(book) else {
                    store.presentedError = store.lastSyncError ?? "The shared ledger could not be added."
                    return
                }
                store.switchBook(to: book.id)
                store.activeRoute = .ledger
                try await store.persistDurableAsync()
            } catch { store.presentedError = error.localizedDescription }
        }
    }
}
