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

enum TransactionSwipeAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case reimburse
    case refund
    case delete
    case split

    var id: String { rawValue }
    var title: String {
        switch self {
        case .reimburse: "Reimburse"
        case .refund: "Refund"
        case .delete: "Delete"
        case .split: "Split"
        }
    }
    var systemImage: String {
        switch self {
        case .reimburse: "arrow.uturn.backward.circle"
        case .refund: "arrow.uturn.backward"
        case .delete: "trash"
        case .split: "person.2"
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

    func transactionDateString(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let year = abs((components.year ?? 0) % 100)
        return self == .monthDay
            ? String(format: "%02d/%02d/%02d", month, day, year)
            : String(format: "%02d/%02d/%02d", day, month, year)
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

enum AccountCardLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case horizontal
    case portrait

    var id: String { rawValue }
    var title: String {
        switch self {
        case .horizontal: "Horizontal"
        case .portrait: "Vertical"
        }
    }
}

typealias OverviewCardLayout = AccountCardLayout
typealias CardArtworkLayoutContext = AccountCardLayout

enum OverviewMetricLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case horizontalGrid
    case portraitSideColumn

    var id: String { rawValue }
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
        case .budget: "Budget Remain"
        case .todayExpensePie: "Today Expense"
        case .weekExpensePie: "Week Expense"
        case .sixMonthTrend: "6M Trends"
        }
    }
}

enum AccountCardMaterialStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case glass
    case metal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .glass: "Glass"
        case .metal: "Metal"
        }
    }
    var subtitle: String {
        switch self {
        case .auto: "Choose the best finish automatically"
        case .glass: "Clear polished glass look"
        case .metal: "Premium metallic sheen"
        }
    }
}

struct RecordingReminderSlot: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var isEnabled: Bool
    var hour: Int
    var minute: Int
}

struct AppPreferences: Codable, Hashable, Sendable {
    static let defaultSwipeActions: [TransactionSwipeAction] = [.reimburse, .refund, .delete, .split]
    static let defaultReminderSlots: [RecordingReminderSlot] = [
        RecordingReminderSlot(id: 1, isEnabled: false, hour: 10, minute: 0),
        RecordingReminderSlot(id: 2, isEnabled: false, hour: 14, minute: 0),
        RecordingReminderSlot(id: 3, isEnabled: false, hour: 21, minute: 0)
    ]

    var schemaVersion: Int = 1
    var languageCode: String = "en"
    var biometricLockEnabled: Bool = false
    var swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing
    var transactionSwipeActions: [TransactionSwipeAction] = defaultSwipeActions
    var splitActionOnRightSwipe: Bool = true
    var reimbursementActionOnRightSwipe: Bool = true
    var hapticFeedbackEnabled: Bool = true
    var dateFormat: AppDateFormat = .monthDay
    var transactionLayout: TransactionEditorLayout = .standard
    var overviewMetrics: [OverviewMetricKind] = [.sixMonthTrend, .weekExpensePie]
    var overviewCardLayout: AccountCardLayout = .portrait
    var accountCardMaterialStyle: AccountCardMaterialStyle = .auto
    var cashFlowForecastEnabled: Bool = true
    var forecastYellowThreshold: Double = 0.10
    var forecastRedThreshold: Double = 0.20
    var recordingReminderSlots: [RecordingReminderSlot] = defaultReminderSlots
    var monthlyStatementReminderEnabled: Bool = false
    var monthlyStatementReminderHour: Int = 20
    var monthlyStatementReminderMinute: Int = 0
    var statementThemeColorHex: String = "3A78C2"

    enum CodingKeys: String, CodingKey {
        case splitActionOnRightSwipe, reimbursementActionOnRightSwipe
        case schemaVersion, languageCode, biometricLockEnabled, swipeActionOrientation, transactionSwipeActions, hapticFeedbackEnabled, dateFormat, transactionLayout, overviewMetrics, overviewCardLayout, accountCardMaterialStyle
        case cashFlowForecastEnabled, forecastYellowThreshold, forecastRedThreshold
        case recordingReminderSlots, monthlyStatementReminderEnabled, monthlyStatementReminderHour, monthlyStatementReminderMinute
        case statementThemeColorHex
    }

    init(schemaVersion: Int = 1, languageCode: String = "en", biometricLockEnabled: Bool = false,
         swipeActionOrientation: SwipeActionOrientation = .refundLeadingDeleteTrailing,
         transactionSwipeActions: [TransactionSwipeAction] = defaultSwipeActions,
         hapticFeedbackEnabled: Bool = true, dateFormat: AppDateFormat = .monthDay,
         transactionLayout: TransactionEditorLayout = .standard,
         overviewMetrics: [OverviewMetricKind] = [.sixMonthTrend, .weekExpensePie],
         overviewCardLayout: AccountCardLayout = .portrait,
         accountCardMaterialStyle: AccountCardMaterialStyle = .auto,
         cashFlowForecastEnabled: Bool = true,
         forecastYellowThreshold: Double = 0.10,
         forecastRedThreshold: Double = 0.20,
         recordingReminderSlots: [RecordingReminderSlot] = defaultReminderSlots,
         monthlyStatementReminderEnabled: Bool = false,
         monthlyStatementReminderHour: Int = 20,
         monthlyStatementReminderMinute: Int = 0,
         statementThemeColorHex: String = "3A78C2") {
        self.schemaVersion = schemaVersion
        self.languageCode = languageCode
        self.biometricLockEnabled = biometricLockEnabled
        self.swipeActionOrientation = swipeActionOrientation
        self.transactionSwipeActions = transactionSwipeActions.count == 4 && Set(transactionSwipeActions).count == 4 ? transactionSwipeActions : Self.defaultSwipeActions
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.dateFormat = dateFormat
        self.transactionLayout = transactionLayout
        self.overviewMetrics = overviewMetrics.count == 2 && Set(overviewMetrics).count == 2 ? overviewMetrics : [.sixMonthTrend, .weekExpensePie]
        self.overviewCardLayout = overviewCardLayout
        self.accountCardMaterialStyle = accountCardMaterialStyle
        self.cashFlowForecastEnabled = cashFlowForecastEnabled
        self.forecastYellowThreshold = forecastYellowThreshold
        self.forecastRedThreshold = forecastRedThreshold
        self.recordingReminderSlots = recordingReminderSlots.count == 3 ? recordingReminderSlots : Self.defaultReminderSlots
        self.monthlyStatementReminderEnabled = monthlyStatementReminderEnabled
        self.monthlyStatementReminderHour = monthlyStatementReminderHour
        self.monthlyStatementReminderMinute = monthlyStatementReminderMinute
        self.statementThemeColorHex = statementThemeColorHex
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        splitActionOnRightSwipe = try values.decodeIfPresent(Bool.self, forKey: .splitActionOnRightSwipe) ?? true
        reimbursementActionOnRightSwipe = try values.decodeIfPresent(Bool.self, forKey: .reimbursementActionOnRightSwipe) ?? true
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode) ?? "en"
        biometricLockEnabled = try values.decodeIfPresent(Bool.self, forKey: .biometricLockEnabled) ?? false
        swipeActionOrientation = try values.decodeIfPresent(SwipeActionOrientation.self, forKey: .swipeActionOrientation) ?? .refundLeadingDeleteTrailing
        if let decodedActions = try? values.decodeIfPresent([TransactionSwipeAction].self, forKey: .transactionSwipeActions),
           decodedActions.count == 4, Set(decodedActions).count == 4 {
            transactionSwipeActions = decodedActions
        } else {
            transactionSwipeActions = Self.defaultSwipeActions
        }
        hapticFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .hapticFeedbackEnabled) ?? true
        dateFormat = try values.decodeIfPresent(AppDateFormat.self, forKey: .dateFormat) ?? .monthDay
        transactionLayout = try values.decodeIfPresent(TransactionEditorLayout.self, forKey: .transactionLayout) ?? .standard
        let decodedMetrics = (try? values.decodeIfPresent([OverviewMetricKind].self, forKey: .overviewMetrics)) ?? [.sixMonthTrend, .weekExpensePie]
        overviewMetrics = decodedMetrics.count == 2 && Set(decodedMetrics).count == 2 ? decodedMetrics : [.sixMonthTrend, .weekExpensePie]
        overviewCardLayout = try values.decodeIfPresent(AccountCardLayout.self, forKey: .overviewCardLayout) ?? .portrait
        accountCardMaterialStyle = try values.decodeIfPresent(AccountCardMaterialStyle.self, forKey: .accountCardMaterialStyle) ?? .auto
        cashFlowForecastEnabled = try values.decodeIfPresent(Bool.self, forKey: .cashFlowForecastEnabled) ?? true
        forecastYellowThreshold = try values.decodeIfPresent(Double.self, forKey: .forecastYellowThreshold) ?? 0.10
        forecastRedThreshold = try values.decodeIfPresent(Double.self, forKey: .forecastRedThreshold) ?? 0.20
        if let slots = try? values.decodeIfPresent([RecordingReminderSlot].self, forKey: .recordingReminderSlots), slots.count == 3 {
            recordingReminderSlots = slots
        } else {
            recordingReminderSlots = Self.defaultReminderSlots
        }
        monthlyStatementReminderEnabled = try values.decodeIfPresent(Bool.self, forKey: .monthlyStatementReminderEnabled) ?? false
        monthlyStatementReminderHour = try values.decodeIfPresent(Int.self, forKey: .monthlyStatementReminderHour) ?? 20
        monthlyStatementReminderMinute = try values.decodeIfPresent(Int.self, forKey: .monthlyStatementReminderMinute) ?? 0
        statementThemeColorHex = try values.decodeIfPresent(String.self, forKey: .statementThemeColorHex) ?? "3A78C2"
    }

    mutating func setOverviewMetric(at index: Int, to newKind: OverviewMetricKind) {
        guard index == 0 || index == 1 else { return }
        if overviewMetrics.count != 2 || Set(overviewMetrics).count != 2 {
            overviewMetrics = [.sixMonthTrend, .weekExpensePie]
        }
        let otherIndex = index == 0 ? 1 : 0
        if overviewMetrics[otherIndex] == newKind {
            overviewMetrics[otherIndex] = overviewMetrics[index]
        }
        overviewMetrics[index] = newKind
    }
}
