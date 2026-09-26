import CloudKit
import SwiftUI
import UIKit

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss, zoneID: share.recordID.zoneID) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let dismiss: DismissAction
        let zoneID: CKRecordZone.ID
        init(dismiss: DismissAction, zoneID: CKRecordZone.ID) { self.dismiss = dismiss; self.zoneID = zoneID }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Finsy" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { dismiss() }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { dismiss() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            let store = LedgerStore.shared
            for book in store.books where book.effectiveStorageKind == .cloudOwner && book.cloudZoneName == zoneID.zoneName {
                store.markLedgerShared(book.id, shared: false)
            }
            dismiss()
        }
    }
}
