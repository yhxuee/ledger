import ActivityKit
import SwiftUI
import UIKit
import XCTest
@testable import WalletLedger

@MainActor
final class PurchaseRenderingTests: XCTestCase {
    func testPurchaseAndPortfolioRenderOnPhoneAndIPadWithPrivacy() async throws {
        let state = SeedData.makeEmpty()
        var session = PurchaseSession(id: UUID(), ledgerBookID: UUID(), name: "Weekly Shopping", status: .draft, sections: [], items: [
            .init(id: UUID(), categoryID: .food, note: "Milk", amount: 30, displayOrder: 0, isCompleted: false, completedAt: nil, linkedTransactionID: nil),
            .init(id: UUID(), categoryID: .food, note: "Bread", amount: 20, displayOrder: 1, isCompleted: false, completedAt: nil, linkedTransactionID: nil),
            .init(id: UUID(), categoryID: .transport, note: "Train", amount: 50, displayOrder: 2, isCompleted: false, completedAt: nil, linkedTransactionID: nil)
        ], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil, currency: .USDT, accountID: state.accounts[0].id)
        session.normalizeSections()
        for width: CGFloat in [393, 1024] {
            for locked in [false, true] {
                let privacy = PrivacyController()
                privacy.lockIfNeeded(protectionEnabled: locked)
                let store = LedgerStore(stateForTesting: state)
                store.savePurchaseSession(session)
                try await render(AnyView(PurchaseSessionEditorView(session: session)), name: "Purchase-\(Int(width))-\(locked)", store: store, privacy: privacy, width: width)
                try await render(AnyView(NavigationStack { AccountsView() }), name: "Accounts-\(Int(width))-\(locked)", store: store, privacy: privacy, width: width)
            }
        }
        session.status = .active
        session.items[0].isCompleted = true
        let store = LedgerStore(stateForTesting: state)
        store.savePurchaseSession(session)
        try await render(AnyView(ActivePurchaseView(sessionID: session.id)), name: "Active-Purchase", store: store, privacy: PrivacyController(), width: 393)
    }

    func testRealActivityRequestEnvironmentDiagnostic() async throws {
        let session = PurchaseSession(id: UUID(), ledgerBookID: UUID(), name: "CI Activity Probe", status: .active, sections: [], items: [],
            createdAt: .now, startedAt: .now, completedAt: nil, receiptAttachmentID: nil, currency: .USD, accountID: UUID())
        var report = "Live Activity environment diagnostic (not a Dynamic Island visual test)\n"
        report += "App state: \(UIApplication.shared.applicationState.rawValue)\n"
        report += "Activities enabled: \(ActivityAuthorizationInfo().areActivitiesEnabled)\n"
        report += "App Group URL available: \(PurchaseSharedStateStore.url(sessionID: session.id) != nil)\n"
        report += "App Group diagnostics:\n\(PurchaseSharedStateStore.diagnostics().report)\n"
        let result = await PurchaseLiveActivityController.shared.start(session: session)
        report += "Production controller result: \(result)\n"
        await PurchaseLiveActivityController.shared.end(sessionID: session.id)
        // Independently report OS authorization even if App Group provisioning blocked the production path.
        do {
            let attributes = PurchaseActivityAttributes(sessionID: session.id, title: session.name, currencyCode: session.currency.rawValue)
            let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: .make(session: session, interactiveCompletionAvailable: true), staleDate: nil), pushType: nil)
            report += "Isolated real Activity.request: succeeded (\(activity.id))\n"
            await activity.end(nil, dismissalPolicy: .immediate)
        } catch {
            let error = error as NSError
            report += "Isolated real Activity.request: \(error.domain) (\(error.code)): \(error.localizedDescription)\n"
        }
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "LiveActivity-Environment-Diagnostic"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func render(_ view: AnyView, name: String, store: LedgerStore, privacy: PrivacyController, width: CGFloat) async throws {
        let controller = UIHostingController(rootView: view
            .environmentObject(store)
            .environmentObject(privacy)
            .environmentObject(AppPreferencesStore()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: width > 500 ? 1024 : 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(controller.view.window)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        window.rootViewController = nil
    }
}

