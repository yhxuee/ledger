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

enum OverviewWidgetBridgeState: Equatable, Sendable {
    case available
    case containerUnavailable
    case snapshotMissing
    case decodeFailed
    case writeFailed(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .available:
            return nil
        case .snapshotMissing:
            return "Open Finsy to update"
        case .containerUnavailable, .decodeFailed, .writeFailed:
            return "Data unavailable"
        }
    }
}

struct OverviewWidgetReadResult: Sendable {
    var snapshot: OverviewWidgetSnapshot
    var state: OverviewWidgetBridgeState
}

struct OverviewWidgetBridgeDiagnostics: Equatable, Sendable {
    var appGroupIdentifier: String
    var containerReachable: Bool
    var containerPath: String?
    var snapshotFileExists: Bool
    var snapshotFileSize: Int?
    var snapshotFileModifiedAt: Date?
    var state: OverviewWidgetBridgeState
    var detail: String?

    var report: String {
        var lines = [
            "App Group identifier: \(appGroupIdentifier)",
            "containerURL available: \(containerReachable)",
            "snapshot file exists: \(snapshotFileExists)"
        ]
        if let size = snapshotFileSize {
            lines.append("snapshot size: \(size) bytes")
        }
        if let date = snapshotFileModifiedAt {
            lines.append("snapshot modified: \(date)")
        }
        lines.append("bridge state: \(state)")
        if let detail {
            lines.append("detail: \(detail)")
        }
        return lines.joined(separator: "\n")
    }
}

enum OverviewWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.finsy.app"
    static let fileName = "overview-widget.json"
    static let legacySuiteKey = "overview_widget_snapshot"

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func snapshotURL() -> URL? {
        containerURL()?.appending(path: fileName)
    }

    static func userDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    @discardableResult
    static func write(_ snapshot: OverviewWidgetSnapshot) -> OverviewWidgetBridgeState {
        guard let url = snapshotURL() else {
            // Also attempt writing to suite defaults as fallback
            if let defaults = userDefaults(),
               let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: legacySuiteKey)
            }
            return .containerUnavailable
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if let defaults = userDefaults() {
                defaults.set(data, forKey: legacySuiteKey)
            }
            return .available
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }

    static func readResult() -> OverviewWidgetReadResult {
        guard let url = snapshotURL() else {
            if let defaults = userDefaults(),
               let data = defaults.data(forKey: legacySuiteKey) {
                if let snapshot = try? JSONDecoder().decode(OverviewWidgetSnapshot.self, from: data) {
                    return OverviewWidgetReadResult(snapshot: snapshot, state: .available)
                }
                return OverviewWidgetReadResult(snapshot: .empty, state: .decodeFailed)
            }
            return OverviewWidgetReadResult(snapshot: .empty, state: .containerUnavailable)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            if let defaults = userDefaults(),
               let data = defaults.data(forKey: legacySuiteKey),
               let snapshot = try? JSONDecoder().decode(OverviewWidgetSnapshot.self, from: data) {
                return OverviewWidgetReadResult(snapshot: snapshot, state: .available)
            }
            return OverviewWidgetReadResult(snapshot: .empty, state: .snapshotMissing)
        }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(OverviewWidgetSnapshot.self, from: data)
            return OverviewWidgetReadResult(snapshot: snapshot, state: .available)
        } catch {
            return OverviewWidgetReadResult(snapshot: .empty, state: .decodeFailed)
        }
    }

    static func read() -> OverviewWidgetSnapshot {
        readResult().snapshot
    }

    static func diagnostics() -> OverviewWidgetBridgeDiagnostics {
        let identifier = appGroupIdentifier
        guard let folder = containerURL() else {
            return OverviewWidgetBridgeDiagnostics(
                appGroupIdentifier: identifier,
                containerReachable: false,
                containerPath: nil,
                snapshotFileExists: false,
                snapshotFileSize: nil,
                snapshotFileModifiedAt: nil,
                state: .containerUnavailable,
                detail: "containerURL(forSecurityApplicationGroupIdentifier:) returned nil"
            )
        }

        let file = folder.appending(path: fileName)
        let exists = FileManager.default.fileExists(atPath: file.path)
        var size: Int?
        var modified: Date?
        if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) {
            size = attrs[.size] as? Int
            modified = attrs[.modificationDate] as? Date
        }

        let result = readResult()
        return OverviewWidgetBridgeDiagnostics(
            appGroupIdentifier: identifier,
            containerReachable: true,
            containerPath: folder.path,
            snapshotFileExists: exists,
            snapshotFileSize: size,
            snapshotFileModifiedAt: modified,
            state: result.state,
            detail: nil
        )
    }
}
