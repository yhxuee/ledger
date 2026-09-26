import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class PrivacyController: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var biometryType: LABiometryType = .none
    private var needsAutomaticUnlock = false
    private var lockRevision: UInt64 = 0

    init() {
        lockIfNeeded(protectionEnabled: AppPreferencesStore.shared.value.biometricLockEnabled)
        refreshBiometryType()
    }

    var biometricName: String {
        switch biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        default: "Biometric Protection"
        }
    }

    var biometricSymbol: String {
        switch biometryType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        default: "lock.shield"
        }
    }

    func refreshBiometryType() {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        if biometryType != context.biometryType { biometryType = context.biometryType }
    }

    func lockIfNeeded(protectionEnabled: Bool) {
        lockRevision &+= 1
        isLocked = protectionEnabled
        needsAutomaticUnlock = protectionEnabled
    }

    func unlockIfNeeded(protectionEnabled: Bool) async {
        refreshBiometryType()
        guard protectionEnabled else { protectionWasDisabled(); return }
        guard isLocked, needsAutomaticUnlock, !isAuthenticating else { return }
        // Consume before presenting the system UI. Returning from that UI must
        // not start another automatic attempt, including after cancellation.
        needsAutomaticUnlock = false
        let revision = lockRevision
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticate(reason: "Unlock your financial information."), revision == lockRevision {
            isLocked = false
        }
    }

    func authorizeDisablingProtection() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return true }
        return await evaluate(context: context, reason: "Authenticate to turn off biometric protection.")
    }

    func protectionWasDisabled() {
        lockRevision &+= 1
        needsAutomaticUnlock = false
        isLocked = false
    }

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
