import UIKit

enum HapticFeedback {
    static func selection(enabled: Bool) {
        guard enabled else { return }
        Task { @MainActor in UISelectionFeedbackGenerator().selectionChanged() }
    }
    static func warning(enabled: Bool) {
        guard enabled else { return }
        Task { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }
    static func success(enabled: Bool) {
        guard enabled else { return }
        Task { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}
