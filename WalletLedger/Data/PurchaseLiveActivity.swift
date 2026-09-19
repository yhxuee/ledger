import ActivityKit
import Foundation

enum PurchaseActivityResult: Equatable, Sendable {
    case started(activityID: String), updated, ended, notRunning
    case liveActivitiesDisabled
    case sharedStateFailed(String)
    case requestFailed(String)

    var userMessage: String? {
        switch self {
        case .started, .updated, .ended, .notRunning: nil
        case .liveActivitiesDisabled:
            "Your purchase is active in the app. Live Activities are unavailable or disabled. Enable Live Activities for Wallet Ledger in Settings to show shopping progress on the Lock Screen."
        case .sharedStateFailed(let detail):
            "Your purchase is saved. Live Activity shared storage is unavailable: \(detail)"
        case .requestFailed(let detail):
            "Your purchase is active in the app, but the Live Activity could not start: \(detail)"
        }
    }
}

protocol PurchaseActivityStarting: Sendable {
    func start(session: PurchaseSession) async -> PurchaseActivityResult
}

actor PurchaseLiveActivityController: PurchaseActivityStarting {
    static let shared = PurchaseLiveActivityController()
    private let snapshotWriter: @Sendable (PurchaseSession) throws -> Void
    private let activitiesEnabled: @Sendable () -> Bool
    private let requestActivity: @Sendable (PurchaseActivityAttributes, PurchaseActivityAttributes.ContentState) throws -> String

    init(
        snapshotWriter: @escaping @Sendable (PurchaseSession) throws -> Void = { try PurchaseSharedStateStore.write(session: $0) },
        activitiesEnabled: @escaping @Sendable () -> Bool = { ActivityAuthorizationInfo().areActivitiesEnabled },
        requestActivity: @escaping @Sendable (PurchaseActivityAttributes, PurchaseActivityAttributes.ContentState) throws -> String = {
            try Activity.request(attributes: $0, content: ActivityContent(state: $1, staleDate: nil), pushType: nil).id
        }
    ) {
        self.snapshotWriter = snapshotWriter
        self.activitiesEnabled = activitiesEnabled
        self.requestActivity = requestActivity
    }

    func start(session: PurchaseSession) async -> PurchaseActivityResult {
        await perform(session: session, requestIfNeeded: true)
    }

    func update(session: PurchaseSession) async -> PurchaseActivityResult {
        await perform(session: session, requestIfNeeded: false)
    }

    private func perform(session: PurchaseSession, requestIfNeeded: Bool) async -> PurchaseActivityResult {
        do { try snapshotWriter(session) }
        catch { return .sharedStateFailed(error.localizedDescription) }
        let state = PurchaseActivityAttributes.ContentState.make(session: session)
        if let activity = Activity<PurchaseActivityAttributes>.activities.first(where: { $0.attributes.sessionID == session.id }) {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            if session.status == .completed || session.status == .cancelled {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
                return .ended
            }
            return .updated
        }
        guard requestIfNeeded, session.status == .active else { return .notRunning }
        guard activitiesEnabled() else { return .liveActivitiesDisabled }
        let attributes = PurchaseActivityAttributes(sessionID: session.id, title: session.name, currencyCode: session.currency.rawValue)
        do {
            return .started(activityID: try requestActivity(attributes, state))
        } catch {
            let failure = error as NSError
            return .requestFailed("\(failure.domain) (\(failure.code)): \(failure.localizedDescription)")
        }
    }

    func end(sessionID: UUID) async {
        for activity in Activity<PurchaseActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func endAll() async {
        for activity in Activity<PurchaseActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
