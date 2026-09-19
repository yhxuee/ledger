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

enum TransactionEditorLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case categoryFirst

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .categoryFirst: "Category First"
        }
    }
}

enum OverviewMetricKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case weeklyActivity
    case budget
    case todayExpensePie
    case weekExpensePie
    case sixMonthTrend

    var id: String { rawValue }
    var title: String {
        switch self {
        case .weeklyActivity: "Weekly Activity"
        case .budget: "Budget"
        case .todayExpensePie: "Today Expense"
        case .weekExpensePie: "This Week Expense"
        case .sixMonthTrend: "6M Trends"
        }
    }
}

struct AppPreferences: Codable, Hashable, Sendable {
    var schemaVersion: Int = 1
    var languageCode: String = "en"
    var biometricLockEnabled: Bool = false
    var swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing
    var hapticFeedbackEnabled: Bool = true
    var dateFormat: AppDateFormat = .monthDay
    var transactionLayout: TransactionEditorLayout = .standard
    var overviewMetrics: [OverviewMetricKind] = [.weeklyActivity, .budget]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, languageCode, biometricLockEnabled, swipeActionOrientation, hapticFeedbackEnabled, dateFormat, transactionLayout, overviewMetrics
    }

    init(schemaVersion: Int = 1, languageCode: String = "en", biometricLockEnabled: Bool = false,
         swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing,
         hapticFeedbackEnabled: Bool = true, dateFormat: AppDateFormat = .monthDay,
         transactionLayout: TransactionEditorLayout = .standard,
         overviewMetrics: [OverviewMetricKind] = [.weeklyActivity, .budget]) {
        self.schemaVersion = schemaVersion
        self.languageCode = languageCode
        self.biometricLockEnabled = biometricLockEnabled
        self.swipeActionOrientation = swipeActionOrientation
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.dateFormat = dateFormat
        self.transactionLayout = transactionLayout
        self.overviewMetrics = overviewMetrics.count == 2 ? overviewMetrics : [.weeklyActivity, .budget]
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode) ?? "en"
        biometricLockEnabled = try values.decodeIfPresent(Bool.self, forKey: .biometricLockEnabled) ?? false
        swipeActionOrientation = try values.decodeIfPresent(SwipeActionOrientation.self, forKey: .swipeActionOrientation) ?? .refundLeadingDeleteTrailing
        hapticFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .hapticFeedbackEnabled) ?? true
        dateFormat = try values.decodeIfPresent(AppDateFormat.self, forKey: .dateFormat) ?? .monthDay
        transactionLayout = try values.decodeIfPresent(TransactionEditorLayout.self, forKey: .transactionLayout) ?? .standard
        let decodedMetrics = try values.decodeIfPresent([OverviewMetricKind].self, forKey: .overviewMetrics) ?? [.weeklyActivity, .budget]
        overviewMetrics = decodedMetrics.count == 2 ? decodedMetrics : [.weeklyActivity, .budget]
    }

    mutating func setOverviewMetric(at index: Int, to newKind: OverviewMetricKind) {
        guard index == 0 || index == 1 else { return }
        if overviewMetrics.count != 2 {
            overviewMetrics = [.weeklyActivity, .budget]
        }
        let otherIndex = index == 0 ? 1 : 0
        if overviewMetrics[otherIndex] == newKind {
            overviewMetrics[otherIndex] = overviewMetrics[index]
        }
        overviewMetrics[index] = newKind
    }
}
