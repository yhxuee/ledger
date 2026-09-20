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

struct IncompatibleSchemaError: Error, Sendable {
    let version: Int
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

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Expense"
        self.colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "8E8E93"
        self.amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0.0
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

    enum CodingKeys: String, CodingKey {
        case id, label, amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0.0
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

    enum CodingKeys: String, CodingKey {
        case id, label, amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0.0
    }
}

struct OverviewWidgetWeeklyActivityData: Codable, Sendable, Hashable {
    var total: Double
    var buckets: [OverviewWidgetDailyBucket]

    init(total: Double, buckets: [OverviewWidgetDailyBucket]) {
        self.total = total
        self.buckets = buckets
    }

    enum CodingKeys: String, CodingKey {
        case total, buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 0.0
        self.buckets = try container.decodeIfPresent([OverviewWidgetDailyBucket].self, forKey: .buckets) ?? []
    }

    static var empty: OverviewWidgetWeeklyActivityData {
        OverviewWidgetWeeklyActivityData(total: 0.0, buckets: [])
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

    enum CodingKeys: String, CodingKey {
        case budget, spent, remaining, ratio, hasBudget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let budget = try container.decodeIfPresent(Double.self, forKey: .budget) ?? 0.0
        let spent = try container.decodeIfPresent(Double.self, forKey: .spent) ?? 0.0
        let remaining = try container.decodeIfPresent(Double.self, forKey: .remaining) ?? (budget - spent)
        let ratio = try container.decodeIfPresent(Double.self, forKey: .ratio) ?? (budget > 0 ? spent / budget : 0.0)
        let hasBudget = try container.decodeIfPresent(Bool.self, forKey: .hasBudget) ?? (budget > 0)
        self.init(budget: budget, spent: spent, remaining: remaining, ratio: ratio, hasBudget: hasBudget)
    }

    static var empty: OverviewWidgetBudgetData {
        OverviewWidgetBudgetData(budget: 0.0, spent: 0.0, remaining: 0.0, ratio: 0.0, hasBudget: false)
    }
}

struct OverviewWidgetExpenseData: Codable, Sendable, Hashable {
    var total: Double
    var segments: [OverviewWidgetCategorySegment]

    init(total: Double, segments: [OverviewWidgetCategorySegment]) {
        self.total = total
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case total, segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 0.0
        self.segments = try container.decodeIfPresent([OverviewWidgetCategorySegment].self, forKey: .segments) ?? []
    }

    static var empty: OverviewWidgetExpenseData {
        OverviewWidgetExpenseData(total: 0.0, segments: [])
    }
}

struct OverviewWidgetTrendData: Codable, Sendable, Hashable {
    var total: Double
    var buckets: [OverviewWidgetMonthlyBucket]

    init(total: Double, buckets: [OverviewWidgetMonthlyBucket]) {
        self.total = total
        self.buckets = buckets
    }

    enum CodingKeys: String, CodingKey {
        case total, buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 0.0
        self.buckets = try container.decodeIfPresent([OverviewWidgetMonthlyBucket].self, forKey: .buckets) ?? []
    }

    static var empty: OverviewWidgetTrendData {
        OverviewWidgetTrendData(total: 0.0, buckets: [])
    }
}

struct OverviewWidgetSnapshot: Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var currency: CurrencyCode
    var isPrivacyMasked: Bool
    var weeklyActivity: OverviewWidgetWeeklyActivityData
    var budgetRemain: OverviewWidgetBudgetData
    var todayExpense: OverviewWidgetExpenseData
    var weekExpense: OverviewWidgetExpenseData
    var sixMonthTrend: OverviewWidgetTrendData

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date,
        currency: CurrencyCode,
        isPrivacyMasked: Bool,
        weeklyActivity: OverviewWidgetWeeklyActivityData,
        budgetRemain: OverviewWidgetBudgetData,
        todayExpense: OverviewWidgetExpenseData,
        weekExpense: OverviewWidgetExpenseData,
        sixMonthTrend: OverviewWidgetTrendData
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.currency = currency
        self.isPrivacyMasked = isPrivacyMasked
        self.weeklyActivity = weeklyActivity
        self.budgetRemain = budgetRemain
        self.todayExpense = todayExpense
        self.weekExpense = weekExpense
        self.sixMonthTrend = sixMonthTrend
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case currency
        case isPrivacyMasked
        case weeklyActivity
        case budgetRemain
        case todayExpense
        case weekExpense
        case sixMonthTrend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.currentSchemaVersion else {
            throw IncompatibleSchemaError(version: version)
        }
        self.schemaVersion = version
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        self.currency = try container.decodeIfPresent(CurrencyCode.self, forKey: .currency) ?? .HKD
        self.isPrivacyMasked = try container.decodeIfPresent(Bool.self, forKey: .isPrivacyMasked) ?? false
        self.weeklyActivity = try container.decodeIfPresent(OverviewWidgetWeeklyActivityData.self, forKey: .weeklyActivity) ?? .empty
        self.budgetRemain = try container.decodeIfPresent(OverviewWidgetBudgetData.self, forKey: .budgetRemain) ?? .empty
        self.todayExpense = try container.decodeIfPresent(OverviewWidgetExpenseData.self, forKey: .todayExpense) ?? .empty
        self.weekExpense = try container.decodeIfPresent(OverviewWidgetExpenseData.self, forKey: .weekExpense) ?? .empty
        self.sixMonthTrend = try container.decodeIfPresent(OverviewWidgetTrendData.self, forKey: .sixMonthTrend) ?? .empty
    }

    static var empty: OverviewWidgetSnapshot {
        OverviewWidgetSnapshot(
            schemaVersion: currentSchemaVersion,
            updatedAt: .now,
            currency: .HKD,
            isPrivacyMasked: false,
            weeklyActivity: .empty,
            budgetRemain: .empty,
            todayExpense: .empty,
            weekExpense: .empty,
            sixMonthTrend: .empty
        )
    }

    static var placeholder: OverviewWidgetSnapshot {
        OverviewWidgetSnapshot(
            schemaVersion: currentSchemaVersion,
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
    case snapshotIncompatible
    case readFailed(String)
    case decodeFailed(String)
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
        case .containerUnavailable:
            return "Shared data unavailable"
        case .snapshotIncompatible, .decodeFailed, .readFailed, .writeFailed:
            return "Open Finsy to refresh"
        }
    }

    var subtitle: String? {
        switch self {
        case .available:
            return nil
        case .snapshotMissing:
            return "Launch Finsy to sync your overview metrics."
        case .containerUnavailable:
            return "Check Finsy widget access."
        case .snapshotIncompatible, .decodeFailed, .readFailed:
            return "Launch Finsy to sync your overview metrics."
        case .writeFailed:
            return "Widget data could not be saved."
        }
    }

    var systemImage: String {
        switch self {
        case .available:
            return "checkmark.circle"
        case .snapshotMissing:
            return "arrow.clockwise"
        case .containerUnavailable, .snapshotIncompatible, .decodeFailed, .readFailed, .writeFailed:
            return "exclamationmark.triangle"
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
    var schemaVersion: Int?
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
        if let schema = schemaVersion {
            lines.append("schema version: \(schema)")
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

    static func legacyUserDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    @discardableResult
    static func write(_ snapshot: OverviewWidgetSnapshot) -> OverviewWidgetBridgeState {
        guard let folder = containerURL() else {
            return .containerUnavailable
        }

        let fileURL = folder.appending(path: fileName)
        do {
            let folderPath = folder.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: folderPath) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return .available
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }

    static func readResult() -> OverviewWidgetReadResult {
        guard let folder = containerURL() else {
            return OverviewWidgetReadResult(snapshot: .empty, state: .containerUnavailable)
        }

        let fileURL = folder.appending(path: fileName)
        let filePath = fileURL.path(percentEncoded: false)

        if FileManager.default.fileExists(atPath: filePath) {
            do {
                let data = try Data(contentsOf: fileURL)
                let snapshot = try JSONDecoder().decode(OverviewWidgetSnapshot.self, from: data)
                return OverviewWidgetReadResult(snapshot: snapshot, state: .available)
            } catch is IncompatibleSchemaError {
                return OverviewWidgetReadResult(snapshot: .empty, state: .snapshotIncompatible)
            } catch let error as DecodingError {
                return OverviewWidgetReadResult(snapshot: .empty, state: .decodeFailed(error.localizedDescription))
            } catch {
                return OverviewWidgetReadResult(snapshot: .empty, state: .readFailed(error.localizedDescription))
            }
        }

        // Check legacy UserDefaults migration fallback
        if let defaults = legacyUserDefaults(),
           let legacyData = defaults.data(forKey: legacySuiteKey) {
            do {
                let snapshot = try JSONDecoder().decode(OverviewWidgetSnapshot.self, from: legacyData)
                _ = write(snapshot)
                defaults.removeObject(forKey: legacySuiteKey)
                return OverviewWidgetReadResult(snapshot: snapshot, state: .available)
            } catch is IncompatibleSchemaError {
                return OverviewWidgetReadResult(snapshot: .empty, state: .snapshotIncompatible)
            } catch let error as DecodingError {
                return OverviewWidgetReadResult(snapshot: .empty, state: .decodeFailed(error.localizedDescription))
            } catch {
                return OverviewWidgetReadResult(snapshot: .empty, state: .readFailed(error.localizedDescription))
            }
        }

        return OverviewWidgetReadResult(snapshot: .empty, state: .snapshotMissing)
    }

    static func read() -> OverviewWidgetSnapshot {
        readResult().snapshot
    }

    @discardableResult
    static func writeAndVerify(_ snapshot: OverviewWidgetSnapshot) -> OverviewWidgetBridgeState {
        let writeState = write(snapshot)
        guard writeState == .available else {
            return writeState
        }

        let result = readResult()
        guard result.state == .available else {
            return result.state
        }

        guard result.snapshot.schemaVersion == snapshot.schemaVersion else {
            return .snapshotIncompatible
        }

        guard abs(result.snapshot.updatedAt.timeIntervalSince(snapshot.updatedAt)) < 1.0 else {
            return .readFailed("Timestamp verification mismatch: read back stale snapshot")
        }

        return .available
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
                schemaVersion: nil,
                state: .containerUnavailable,
                detail: "containerURL(forSecurityApplicationGroupIdentifier:) returned nil"
            )
        }

        let file = folder.appending(path: fileName)
        let filePath = file.path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: filePath)
        var size: Int?
        var modified: Date?
        if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: filePath) {
            size = attrs[.size] as? Int
            modified = attrs[.modificationDate] as? Date
        }

        let result = readResult()
        return OverviewWidgetBridgeDiagnostics(
            appGroupIdentifier: identifier,
            containerReachable: true,
            containerPath: folder.path(percentEncoded: false),
            snapshotFileExists: exists,
            snapshotFileSize: size,
            snapshotFileModifiedAt: modified,
            schemaVersion: result.state == .available ? result.snapshot.schemaVersion : nil,
            state: result.state,
            detail: {
                switch result.state {
                case .readFailed(let msg), .decodeFailed(let msg), .writeFailed(let msg):
                    return msg
                default:
                    return nil
                }
            }()
        )
    }

    #if DEBUG
    static func logDiagnostics(process: String) {
        let d = diagnostics()
        print("[OverviewWidget] [\(process)] App Group available = \(d.containerReachable), URL resolved = \(d.containerPath != nil), file exists = \(d.snapshotFileExists), size = \(d.snapshotFileSize.map { "\($0) bytes" } ?? "nil"), schema = \(d.schemaVersion.map { String($0) } ?? "nil"), updatedAt = \(d.snapshotFileModifiedAt?.description ?? "nil"), state = \(d.state)")
    }
    #endif
}
