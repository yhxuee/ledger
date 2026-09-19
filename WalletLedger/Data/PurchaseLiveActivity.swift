import ActivityKit
import Foundation

enum PurchaseActivityResult: Equatable, Sendable {
    case started(activityID: String), updated, ended, notRunning
    case liveActivitiesDisabled
    case sharedStateFailed(String)
    case requestFailed(String)
    /// The ActivityKit request succeeded but the App Group snapshot could not be written.
    case startedWithoutSharedState(activityID: String, detail: String)

    var userMessage: String? {
        switch self {
        case .started, .updated, .ended, .notRunning: nil
        case .liveActivitiesDisabled:
            "Your purchase is active in the app. Live Activities are unavailable or disabled. Enable Live Activities for Wallet Ledger in Settings to show shopping progress on the Lock Screen."
        case .sharedStateFailed(let detail):
            "Your purchase is saved. Live Activity shared storage is unavailable: \(detail)"
        case .requestFailed(let detail):
            "Your purchase is active in the app, but the Live Activity could not start: \(detail)"
        case .startedWithoutSharedState(_, let detail):
            "Your purchase is active and the Live Activity started, but shared purchase storage is unavailable: \(detail) Items checked from the Lock Screen may not sync until the App Group is available."
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
        // A broken App Group must never suppress the visible Live Activity: record the
        // shared-state problem and continue, so the request itself still runs below.
        let sharedStateError: String?
        do {
            try snapshotWriter(session)
            sharedStateError = nil
        } catch {
            sharedStateError = error.localizedDescription
        }
        let state = PurchaseActivityAttributes.ContentState.make(session: session)
        if let activity = Activity<PurchaseActivityAttributes>.activities.first(where: { $0.attributes.sessionID == session.id }) {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            if session.status == .completed || session.status == .cancelled {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
                return .ended
            }
            if let sharedStateError { return .sharedStateFailed(sharedStateError) }
            return .updated
        }
        guard requestIfNeeded, session.status == .active else {
            if let sharedStateError { return .sharedStateFailed(sharedStateError) }
            return .notRunning
        }
        guard activitiesEnabled() else {
            guard let sharedStateError else { return .liveActivitiesDisabled }
            return .sharedStateFailed("\(sharedStateError) Live Activities are also disabled in Settings.")
        }
        let attributes = PurchaseActivityAttributes(sessionID: session.id, title: session.name, currencyCode: session.currency.rawValue)
        do {
            let activityID = try requestActivity(attributes, state)
            if let sharedStateError { return .startedWithoutSharedState(activityID: activityID, detail: sharedStateError) }
            return .started(activityID: activityID)
        } catch {
            let failure = error as NSError
            var detail = "\(failure.domain) (\(failure.code)): \(failure.localizedDescription)"
            if let sharedStateError { detail += " Shared storage also failed: \(sharedStateError)" }
            return .requestFailed(detail)
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
