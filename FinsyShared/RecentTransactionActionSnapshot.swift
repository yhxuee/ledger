import Foundation

/// Snapshot stored in App Group storage for fast cross-process access by widgets and AppIntents.
public struct RecentTransactionActionSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var operationID: UUID
    public var ledgerBookID: UUID
    public var transactionID: UUID
    public var title: String
    public var amountText: String
    public var occurredAt: Date
    public var createdAt: Date
    public var expiresAt: Date
    public var isRefundable: Bool
    public var accountName: String
    public var isUndone: Bool
    public var isRefunded: Bool

    public var id: UUID { transactionID }

    public init(
        operationID: UUID = UUID(),
        ledgerBookID: UUID = UUID(),
        transactionID: UUID,
        title: String,
        amountText: String,
        occurredAt: Date,
        createdAt: Date = .now,
        expiresAt: Date,
        isRefundable: Bool,
        accountName: String,
        isUndone: Bool = false,
        isRefunded: Bool = false
    ) {
        self.operationID = operationID
        self.ledgerBookID = ledgerBookID
        self.transactionID = transactionID
        self.title = title
        self.amountText = amountText
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isRefundable = isRefundable
        self.accountName = accountName
        self.isUndone = isUndone
        self.isRefunded = isRefunded
    }
}

public enum RecentTransactionSharedStore {
    public static let appGroupIdentifier = "group.com.finsy.app"
    private static let key = "recent_transaction_action_snapshots"

    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static var userDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func saveSnapshot(_ snapshot: RecentTransactionActionSnapshot) {
        var all = loadSnapshots()
        all.removeAll(where: { $0.id == snapshot.id || $0.expiresAt < Date.now })
        all.append(snapshot)
        persist(all)
    }

    public static func loadSnapshots() -> [RecentTransactionActionSnapshot] {
        guard let data = userDefaults.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentTransactionActionSnapshot].self, from: data) else {
            return []
        }
        return list
    }

    public static func loadSnapshot(id: UUID) -> RecentTransactionActionSnapshot? {
        loadSnapshots().first(where: { $0.id == id })
    }

    public static func markUndone(id: UUID) {
        var all = loadSnapshots()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all[idx].isUndone = true
            persist(all)
        }
    }

    public static func markRefunded(id: UUID) {
        var all = loadSnapshots()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all[idx].isRefunded = true
            persist(all)
        }
    }

    private static func persist(_ snapshots: [RecentTransactionActionSnapshot]) {
        if let data = try? JSONEncoder().encode(snapshots) {
            userDefaults.set(data, forKey: key)
        }
    }
}
