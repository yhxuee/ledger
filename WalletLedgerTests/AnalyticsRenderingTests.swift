import SwiftUI
import UIKit
import XCTest
@testable import WalletLedger

@MainActor
final class AnalyticsRenderingTests: XCTestCase {
    func testAnalyticsRendersSeededEmptyAndLockedStates() async throws {
        for state in [SeedData.make(), SeedData.makeEmpty()] {
            for locked in [false, true] {
                let privacy = PrivacyController()
                privacy.lockIfNeeded(protectionEnabled: locked)
                let controller = UIHostingController(rootView:
                    NavigationStack { AnalyticsView() }
                        .environmentObject(LedgerStore(stateForTesting: state))
                        .environmentObject(privacy)
                        .environmentObject(AppPreferencesStore())
                )
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .seconds(1))
                XCTAssertGreaterThan(controller.view.bounds.width, 0)
                XCTAssertNotNil(controller.view.window)
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }
}
