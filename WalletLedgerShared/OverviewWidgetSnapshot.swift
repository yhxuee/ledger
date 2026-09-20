import AppIntents
import Foundation

enum OverviewMetricWidgetOption: String, AppEnum, Sendable {
    case weeklyActivity
    case budgetRemain
    case todayExpense
    case weekExpense
    case sixMonthTrend

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    static let caseDisplayRepresentations: [OverviewMetricWidgetOption: DisplayRepresentation] = [
        .weeklyActivity: "Weekly Activity",
        .budgetRemain: "Budget Remain",
        .todayExpense: "Today Expense",
        .weekExpense: "Week Expense",
        .sixMonthTrend: "6M Trends"
    ]
}

struct SelectOverviewMetricIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Overview Metric"
    static let description = IntentDescription("Select which Overview metric to display.")

    @Parameter(title: "Metric", default: .budgetRemain)
    var metric: OverviewMetricWidgetOption

    init() {
        self.metric = .budgetRemain
    }

    init(metric: OverviewMetricWidgetOption) {
        self.metric = metric
    }
}

struct OverviewWidgetCategorySegment: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var colorHex: String
    var amount: Double

    init(id: String, name: String, colorHex: String, amount: Double) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.amount = amount
    }
}

struct OverviewWidgetDailyBucket: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var label: String
    var amount: Double

    init(id: String, label: String, amount: Double) {
        self.id = id
        self.label = label
        self.amount = amount
    }
}

struct OverviewWidgetMonthlyBucket: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var label: String
    var amount: Double

    init(id: String, label: String, amount: Double) {
        self.id = id
        self.label = label
        self.amount = amount
    }
}

struct OverviewWidgetWeeklyActivityData: Codable, Sendable, Hashable {
    var total: Double
    var buckets: [OverviewWidgetDailyBucket]

    init(total: Double, buckets: [OverviewWidgetDailyBucket]) {
        self.total = total
        self.buckets = buckets
    }
}

struct OverviewWidgetBudgetData: Codable, Sendable, Hashable {
    var budget: Double
    var spent: Double
    var remaining: Double
    var ratio: Double
    var hasBudget: Bool

    init(budget: Double, spent: Double, remaining: Double, ratio: Double, hasBudget: Bool) {
        self.budget = budget
        self.spent = spent
        self.remaining = remaining
        self.ratio = ratio
        self.hasBudget = hasBudget
    }
}

struct OverviewWidgetExpenseData: Codable, Sendable, Hashable {
    var total: Double
    var segments: [OverviewWidgetCategorySegment]

    init(total: Double, segments: [OverviewWidgetCategorySegment]) {
        self.total = total
        self.segments = segments
    }
}

struct OverviewWidgetTrendData: Codable, Sendable, Hashable {
    var total: Double
    var buckets: [OverviewWidgetMonthlyBucket]

    init(total: Double, buckets: [OverviewWidgetMonthlyBucket]) {
        self.total = total
        self.buckets = buckets
    }
}

struct OverviewWidgetSnapshot: Codable, Sendable, Hashable {
    var updatedAt: Date
    var currency: CurrencyCode
    var isPrivacyMasked: Bool
    var weeklyActivity: OverviewWidgetWeeklyActivityData
    var budgetRemain: OverviewWidgetBudgetData
    var todayExpense: OverviewWidgetExpenseData
    var weekExpense: OverviewWidgetExpenseData
    var sixMonthTrend: OverviewWidgetTrendData

    init(
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

    static var empty: OverviewWidgetSnapshot {
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

    static var placeholder: OverviewWidgetSnapshot {
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

enum OverviewWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.finsy.app"
    static let suiteKey = "overview_widget_snapshot"

    static func userDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func write(_ snapshot: OverviewWidgetSnapshot) {
        guard let defaults = userDefaults(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: suiteKey)
    }

    static func read() -> OverviewWidgetSnapshot {
        guard let defaults = userDefaults(),
              let data = defaults.data(forKey: suiteKey),
              let snapshot = try? JSONDecoder().decode(OverviewWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}
