import CloudKit
import UIKit

extension Notification.Name { static let acceptedCloudLedger = Notification.Name("WalletLedgerAcceptedCloudLedger") }

final class CloudShareAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MarketRefreshBackground.register()
        return true
    }
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task {
            do {
                let book = try await CloudLedgerService.shared.accept(cloudKitShareMetadata)
                await MainActor.run { NotificationCenter.default.post(name: .acceptedCloudLedger, object: book) }
            } catch {
                await MainActor.run { NotificationCenter.default.post(name: .acceptedCloudLedger, object: error) }
            }
        }
    }
}
