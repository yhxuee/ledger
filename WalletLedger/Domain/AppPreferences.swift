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

enum AppDateFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthDay
    case dayMonth

    var id: String { rawValue }
    var title: String { self == .monthDay ? "MM/DD" : "DD/MM" }

    func compactString(from date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        let components = calendar.dateComponents([.month, .day], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        return self == .monthDay ? String(format: "%02d/%02d", month, day) : String(format: "%02d/%02d", day, month)
    }
}

struct AppPreferences: Codable, Hashable, Sendable {
    var schemaVersion: Int = 1
    var languageCode: String = "en"
    var biometricLockEnabled: Bool = false
    var swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing
    var hapticFeedbackEnabled: Bool = true
    var dateFormat: AppDateFormat = .monthDay

    enum CodingKeys: String, CodingKey {
        case schemaVersion, languageCode, biometricLockEnabled, swipeActionOrientation, hapticFeedbackEnabled, dateFormat
    }

    init(schemaVersion: Int = 1, languageCode: String = "en", biometricLockEnabled: Bool = false,
         swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing,
         hapticFeedbackEnabled: Bool = true, dateFormat: AppDateFormat = .monthDay) {
        self.schemaVersion = schemaVersion
        self.languageCode = languageCode
        self.biometricLockEnabled = biometricLockEnabled
        self.swipeActionOrientation = swipeActionOrientation
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.dateFormat = dateFormat
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode) ?? "en"
        biometricLockEnabled = try values.decodeIfPresent(Bool.self, forKey: .biometricLockEnabled) ?? false
        swipeActionOrientation = try values.decodeIfPresent(SwipeActionOrientation.self, forKey: .swipeActionOrientation) ?? .refundLeadingDeleteTrailing
        hapticFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .hapticFeedbackEnabled) ?? true
        dateFormat = try values.decodeIfPresent(AppDateFormat.self, forKey: .dateFormat) ?? .monthDay
    }
}
