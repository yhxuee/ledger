import ActivityKit
import Foundation

struct PurchaseSharedSnapshot: Codable, Hashable {
    var session: PurchaseSession
    var currencyCode: CurrencyCode
    var updatedAt: Date
}

enum PurchaseSharedStateStore {
    static let appGroupIdentifier = "group.org.medx.WalletLedger"

    static func url(sessionID: UUID) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "active-purchase-\(sessionID.uuidString).json")
    }

    static func write(session: PurchaseSession, currency: CurrencyCode) throws {
        guard let url = url(sessionID: session.id) else { throw PurchaseSharedStateError.appGroupUnavailable }
        let data = try JSONEncoder.purchaseShared.encode(PurchaseSharedSnapshot(session: session, currencyCode: currency, updatedAt: .now))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func read(sessionID: UUID) -> PurchaseSharedSnapshot? {
        guard let url = url(sessionID: sessionID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.purchaseShared.decode(PurchaseSharedSnapshot.self, from: data)
    }

    static func updateItem(sessionID: UUID, itemID: UUID, completed: Bool) throws -> PurchaseSharedSnapshot {
        guard var snapshot = read(sessionID: sessionID), let index = snapshot.session.items.firstIndex(where: { $0.id == itemID }) else { throw PurchaseSharedStateError.notFound }
        snapshot.session.items[index].isCompleted = completed
        snapshot.session.items[index].completedAt = completed ? .now : nil
        if snapshot.session.items.allSatisfy(\.isCompleted) {
            snapshot.session.status = .awaitingSummary
            snapshot.session.completedAt = .now
        } else {
            snapshot.session.status = .active
            snapshot.session.completedAt = nil
        }
        snapshot.updatedAt = .now
        guard let url = url(sessionID: sessionID) else { throw PurchaseSharedStateError.appGroupUnavailable }
        try JSONEncoder.purchaseShared.encode(snapshot).write(to: url, options: [.atomic, .completeFileProtection])
        return snapshot
    }

    static func resetLocalSnapshots() throws {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("active-purchase-") && url.pathExtension == "json" {
            try FileManager.default.removeItem(at: url)
        }
    }
}

enum PurchaseSharedStateError: LocalizedError {
    case appGroupUnavailable, notFound
    var errorDescription: String? {
        switch self { case .appGroupUnavailable: "The shared purchase container is unavailable."; case .notFound: "The active purchase item was not found." }
    }
}

private extension JSONEncoder {
    static var purchaseShared: JSONEncoder { let coder = JSONEncoder(); coder.dateEncodingStrategy = .iso8601; return coder }
}

private extension JSONDecoder {
    static var purchaseShared: JSONDecoder { let coder = JSONDecoder(); coder.dateDecodingStrategy = .iso8601; return coder }
}

actor PurchaseLiveActivityController {
    static let shared = PurchaseLiveActivityController()

    func startOrUpdate(session: PurchaseSession, currency: CurrencyCode) async {
        try? PurchaseSharedStateStore.write(session: session, currency: currency)
        let state = contentState(session)
        if let activity = Activity<PurchaseActivityAttributes>.activities.first(where: { $0.attributes.sessionID == session.id }) {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            if state.isCompleted {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
            }
            return
        }
        guard session.status == .active, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = PurchaseActivityAttributes(sessionID: session.id, title: session.name, currencyCode: currency.rawValue)
        _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    func endAll() async {
        for activity in Activity<PurchaseActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func contentState(_ session: PurchaseSession) -> PurchaseActivityAttributes.ContentState {
        let total = session.items.reduce(0) { $0 + $1.amount }
        let completed = session.items.filter(\.isCompleted).reduce(0) { $0 + $1.amount }
        let previews = session.items.filter { !$0.isCompleted }.sorted { $0.displayOrder < $1.displayOrder }.prefix(3).map {
            PurchaseActivityAttributes.ItemPreview(id: $0.id, name: $0.note, amount: $0.amount)
        }
        return .init(totalPlannedAmount: total, completedAmount: completed, completionFraction: total > 0 ? completed / total : 0, nextItems: previews, isCompleted: session.status == .awaitingSummary || session.status == .completed)
    }
}
