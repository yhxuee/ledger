import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class PrivacyController: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false

    func lockIfNeeded(protectionEnabled: Bool) {
        isLocked = protectionEnabled
    }

    func unlockIfNeeded(protectionEnabled: Bool) async {
        guard protectionEnabled else { isLocked = false; return }
        guard !isAuthenticating else { return }
        isLocked = true
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticate(reason: "Unlock your financial information.") { isLocked = false }
    }

    func authorizeDisablingProtection() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return true }
        return await evaluate(context: context, reason: "Authenticate to turn off biometric protection.")
    }

    func protectionWasDisabled() { isLocked = false }

    func authorizeSensitiveChange(reason: String, protectionEnabled: Bool) async -> Bool {
        guard protectionEnabled else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await evaluate(context: context, policy: .deviceOwnerAuthentication, reason: reason)
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Keep Locked"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return false }
        return await evaluate(context: context, policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason)
    }

    private func evaluate(context: LAContext, policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in continuation.resume(returning: success) }
        }
    }
}
