import CloudKit
import SwiftUI
import UIKit

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Finsy" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { dismiss() }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { dismiss() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { dismiss() }
    }
}
