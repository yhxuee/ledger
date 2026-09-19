import Foundation

enum SwipeActionOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case refundLeadingDeleteTrailing
    case deleteLeadingRefundTrailing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .refundLeadingDeleteTrailing: "Refund Right / Delete Left"
        case .deleteLeadingRefundTrailing: "Delete Right / Refund Left"
        }
    }
}

struct AppPreferences: Codable, Hashable, Sendable {
    var schemaVersion: Int = 1
    var languageCode: String = "en"
    var biometricLockEnabled: Bool = false
    var swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing
    var hapticFeedbackEnabled: Bool = true
}
