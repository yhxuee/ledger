import AppIntents
import Foundation

public enum OverviewMetricWidgetOption: String, AppEnum, Sendable {
    case weeklyActivity
    case budgetRemain
    case todayExpense
    case weekExpense
    case sixMonthTrend

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    public static var caseDisplayRepresentations: [OverviewMetricWidgetOption: DisplayRepresentation] = [
        .weeklyActivity: "Weekly Activity",
        .budgetRemain: "Budget Remain",
        .todayExpense: "Today Expense",
        .weekExpense: "Week Expense",
        .sixMonthTrend: "6M Trends"
    ]
}

public struct SelectOverviewMetricIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Overview Metric"
    public static var description = IntentDescription("Select which Overview metric to display.")

    @Parameter(title: "Metric", default: .budgetRemain)
    public var metric: OverviewMetricWidgetOption

    public init() {
        self.metric = .budgetRemain
    }

    public init(metric: OverviewMetricWidgetOption) {
        self.metric = metric
    }
}

public struct OverviewWidgetCategorySegment: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var colorHex: String
    public var amount: Double

    public init(id: String, name: String, colorHex: String, amount: Double) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.amount = amount
    }
}

public struct OverviewWidgetDailyBucket: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var label: String
    public var amount: Double

    public init(id: String, label: String, amount: Double) {
        self.id = id
        self.label = label
        self.amount = amount
    }
}

public struct OverviewWidgetMonthlyBucket: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var label: String
    public var amount: Double

    public init(id: String, label: String, amount: Double) {
        self.id = id
        self.label = label
        self.amount = amount
    }
}

public struct OverviewWidgetWeeklyActivityData: Codable, Sendable, Hashable {
    public var total: Double
    public var buckets: [OverviewWidgetDailyBucket]

    public init(total: Double, buckets: [OverviewWidgetDailyBucket]) {
        self.total = total
        self.buckets = buckets
    }
}

public struct OverviewWidgetBudgetData: Codable, Sendable, Hashable {
    public var budget: Double
    public var spent: Double
    public var remaining: Double
    public var ratio: Double
    public var hasBudget: Bool

    public init(budget: Double, spent: Double, remaining: Double, ratio: Double, hasBudget: Bool) {
        self.budget = budget
        self.spent = spent
        self.remaining = remaining
        self.ratio = ratio
        self.hasBudget = hasBudget
    }
}

public struct OverviewWidgetExpenseData: Codable, Sendable, Hashable {
    public var total: Double
    public var segments: [OverviewWidgetCategorySegment]

    public init(total: Double, segments: [OverviewWidgetCategorySegment]) {
        self.total = total
        self.segments = segments
    }
}

public struct OverviewWidgetTrendData: Codable, Sendable, Hashable {
    public var total: Double
    public var buckets: [OverviewWidgetMonthlyBucket]

    public init(total: Double, buckets: [OverviewWidgetMonthlyBucket]) {
        self.total = total
        self.buckets = buckets
    }
}

public struct OverviewWidgetSnapshot: Codable, Sendable, Hashable {
    public var updatedAt: Date
    public var currency: CurrencyCode
    public var isPrivacyMasked: Bool
    public var weeklyActivity: OverviewWidgetWeeklyActivityData
    public var budgetRemain: OverviewWidgetBudgetData
    public var todayExpense: OverviewWidgetExpenseData
    public var weekExpense: OverviewWidgetExpenseData
    public var sixMonthTrend: OverviewWidgetTrendData

    public init(
        updatedAt: Date,
        currency: CurrencyCode,
        isPrivacyMasked: Bool,
        weeklyActivity: OverviewWidgetWeeklyActivityData,
        budgetRemain: OverviewWidgetBudgetData,
        todayExpense: OverviewWidgetExpenseData,
        weekExpense: OverviewWidgetExpenseData,
        sixMonthTrend: OverviewWidgetTrendData
    ) {
        self.updatedAt = updatedAt
        self.currency = currency
        self.isPrivacyMasked = isPrivacyMasked
        self.weeklyActivity = weeklyActivity
        self.budgetRemain = budgetRemain
        self.todayExpense = todayExpense
        self.weekExpense = weekExpense
        self.sixMonthTrend = sixMonthTrend
    }

    public static var empty: OverviewWidgetSnapshot {
        OverviewWidgetSnapshot(
            updatedAt: .now,
            currency: .HKD,
            isPrivacyMasked: false,
            weeklyActivity: .init(total: 0, buckets: []),
            budgetRemain: .init(budget: 0, spent: 0, remaining: 0, ratio: 0, hasBudget: false),
            todayExpense: .init(total: 0, segments: []),
            weekExpense: .init(total: 0, segments: []),
            sixMonthTrend: .init(total: 0, buckets: [])
        )
    }

    public static var placeholder: OverviewWidgetSnapshot {
        OverviewWidgetSnapshot(
            updatedAt: .now,
            currency: .HKD,
            isPrivacyMasked: false,
            weeklyActivity: .init(total: 1250, buckets: [
                .init(id: "1", label: "SUN", amount: 120),
                .init(id: "2", label: "MON", amount: 350),
                .init(id: "3", label: "TUE", amount: 180),
                .init(id: "4", label: "WED", amount: 420),
                .init(id: "5", label: "THU", amount: 80),
                .init(id: "6", label: "FRI", amount: 200),
                .init(id: "7", label: "SAT", amount: 150)
            ]),
            budgetRemain: .init(budget: 8000, spent: 4760, remaining: 3240, ratio: 0.40, hasBudget: true),
            todayExpense: .init(total: 428, segments: [
                .init(id: "food", name: "Food", colorHex: "F05E4F", amount: 260),
                .init(id: "transport", name: "Transport", colorHex: "36A7C9", amount: 168)
            ]),
            weekExpense: .init(total: 2310, segments: [
                .init(id: "food", name: "Food", colorHex: "F05E4F", amount: 980),
                .init(id: "shopping", name: "Shopping", colorHex: "F3A11F", amount: 650),
                .init(id: "transport", name: "Transport", colorHex: "36A7C9", amount: 420),
                .init(id: "utilities", name: "Utilities", colorHex: "B54AC6", amount: 260)
            ]),
            sixMonthTrend: .init(total: 12500, buckets: [
                .init(id: "1", label: "APR", amount: 1900),
                .init(id: "2", label: "MAY", amount: 2300),
                .init(id: "3", label: "JUN", amount: 1800),
                .init(id: "4", label: "JUL", amount: 2400),
                .init(id: "5", label: "AUG", amount: 2100),
                .init(id: "6", label: "SEP", amount: 2000)
            ])
        )
    }
}

public enum OverviewWidgetSnapshotStore {
    public static let appGroupIdentifier = "group.com.finsy.app"
    public static let suiteKey = "overview_widget_snapshot"

    public static func userDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    public static func write(_ snapshot: OverviewWidgetSnapshot) {
        guard let defaults = userDefaults(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: suiteKey)
    }

    public static func read() -> OverviewWidgetSnapshot {
        guard let defaults = userDefaults(),
              let data = defaults.data(forKey: suiteKey),
              let snapshot = try? JSONDecoder().decode(OverviewWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}

