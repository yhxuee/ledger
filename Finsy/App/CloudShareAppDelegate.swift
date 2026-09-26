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
        if let metadata = options.cloudKitShareMetadata { CloudShareSceneDelegate.accept(metadata) }
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

    static func open(_ url: URL) {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "icloud.com" || host.hasSuffix(".icloud.com"),
              url.pathComponents.contains("share") else { return }
        Task { @MainActor in
            do {
                let metadata = try await CKContainer(identifier: "iCloud.com.finsy.app").shareMetadata(for: url)
                accept(metadata)
            } catch { LedgerStore.shared.presentedError = error.localizedDescription }
        }
    }

    static func accept(_ metadata: CKShare.Metadata) {
        let id = metadata.share.recordID
        guard accepting.insert(id).inserted else { return }
        Task { @MainActor in
            let store = LedgerStore.shared
            store.acceptingCloudShare = true
            defer {
                accepting.remove(id)
                store.acceptingCloudShare = !accepting.isEmpty
            }
            LedgerDiagnostics.cloud.info("Accepting shared-ledger invitation")
            do {
                let book = try await CloudLedgerService.shared.accept(metadata)
                guard store.addOrMergeCloudBook(book) else {
                    store.presentedError = store.lastSyncError ?? "The shared ledger could not be added."
                    return
                }
                store.switchBook(to: book.id)
                store.activeRoute = .ledger
                try await store.persistDurableAsync()
            } catch {
                LedgerDiagnostics.failure(error, operation: "share-accept", logger: LedgerDiagnostics.cloud)
                store.presentedError = error.localizedDescription
            }
        }
    }
}
