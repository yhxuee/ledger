import ActivityKit
import Foundation

/// Outcome of the App Group / ActivityKit bridge for one PurchaseSession action.
///
/// The local `PurchaseSession` is always committed to Finsy storage *before* this
/// runs, so no case here represents purchase failure. `interactive` reports whether the
/// App Group bridge accepted the snapshot, which is what enables Lock Screen / Dynamic
/// Island item controls. `warning` carries a nonfatal infrastructure notice for inline display.
struct PurchaseActivityOutcome: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case started(activityID: String)
        case updated
        case ended
        case notRunning
        case liveActivitiesDisabled
        case requestFailed(String)
    }

    var activity: Activity
    /// True when the shared container accepted the snapshot.
    var interactive: Bool
    /// Nonfatal notice; nil when the whole bridge worked.
    var warning: String?
}

protocol PurchaseActivityStarting: Sendable {
    /// Mirrors a committed session into App Group storage and refreshes the Live Activity.
    /// Implementations never throw: bridge problems are reported through `warning`.
    func publish(session: PurchaseSession, categoryColors: [String: String], requestActivityIfNeeded: Bool) async -> PurchaseActivityOutcome
}

extension PurchaseActivityStarting {
    func start(session: PurchaseSession, categoryColors: [String: String] = [:]) async -> PurchaseActivityOutcome {
        await publish(session: session, categoryColors: categoryColors, requestActivityIfNeeded: true)
    }

    func update(session: PurchaseSession, categoryColors: [String: String] = [:]) async -> PurchaseActivityOutcome {
        await publish(session: session, categoryColors: categoryColors, requestActivityIfNeeded: false)
    }
}

actor PurchaseLiveActivityController: PurchaseActivityStarting {
    static let shared = PurchaseLiveActivityController()
    private let snapshotWriter: @Sendable (PurchaseSession, [String: String]) throws -> Void
    private let activitiesEnabled: @Sendable () -> Bool
    private let requestActivity: @Sendable (PurchaseActivityAttributes, PurchaseActivityAttributes.ContentState) throws -> String

    init(
        snapshotWriter: @escaping @Sendable (PurchaseSession, [String: String]) throws -> Void = { try PurchaseSharedStateStore.write(session: $0, categoryColors: $1) },
        activitiesEnabled: @escaping @Sendable () -> Bool = { ActivityAuthorizationInfo().areActivitiesEnabled },
        requestActivity: @escaping @Sendable (PurchaseActivityAttributes, PurchaseActivityAttributes.ContentState) throws -> String = {
            try Activity.request(attributes: $0, content: ActivityContent(state: $1, staleDate: nil), pushType: nil).id
        }
    ) {
        self.snapshotWriter = snapshotWriter
        self.activitiesEnabled = activitiesEnabled
        self.requestActivity = requestActivity
    }

    func publish(session: PurchaseSession, categoryColors: [String: String], requestActivityIfNeeded: Bool) async -> PurchaseActivityOutcome {
        // Bridge first: a broken App Group must never suppress the visible Live Activity,
        // and it must never be reported as a purchase failure.
        var interactive = false
        var warnings: [String] = []
        do {
            try snapshotWriter(session, categoryColors)
            interactive = true
        } catch {
            // Concise, stable notice only: a failed bridge is never a fatal Purchase error and
            // must not repeat raw container errors. Details go to the Debug log instead.
            warnings.append(PurchaseSharedContainerState.containerUnavailable.warning
                ?? String(localized: "Lock Screen item controls require a signed build with App Group access."))
            #if DEBUG
            PurchaseActivityDiagnostics.logBridgeFailure(error)
            #endif
        }
        let state = PurchaseActivityAttributes.ContentState.make(
            session: session,
            interactiveCompletionAvailable: interactive,
            categoryColors: categoryColors)

        if let activity = Activity<PurchaseActivityAttributes>.activities.first(where: { $0.attributes.sessionID == session.id }) {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            if session.status == .completed || session.status == .cancelled {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
                return outcome(.ended, interactive: interactive, warnings: warnings)
            }
            return outcome(.updated, interactive: interactive, warnings: warnings)
        }
        guard requestActivityIfNeeded, session.status == .active else {
            return outcome(.notRunning, interactive: interactive, warnings: warnings)
        }
        guard activitiesEnabled() else {
            warnings.append(String(localized: "Live Activities are disabled in Settings, so purchase progress cannot appear on the Lock Screen."))
            return outcome(.liveActivitiesDisabled, interactive: interactive, warnings: warnings)
        }
        let attributes = PurchaseActivityAttributes(sessionID: session.id, title: session.name, currencyCode: session.currency.rawValue)
        do {
            let activityID = try requestActivity(attributes, state)
            return outcome(.started(activityID: activityID), interactive: interactive, warnings: warnings)
        } catch {
            let failure = error as NSError
            let detail = "\(failure.domain) (\(failure.code)): \(failure.localizedDescription)"
            warnings.append(String(format: String(localized: "The Live Activity could not start: %@"), detail))
            return outcome(.requestFailed(detail), interactive: interactive, warnings: warnings)
        }
    }

    private func outcome(_ activity: PurchaseActivityOutcome.Activity, interactive: Bool, warnings: [String]) -> PurchaseActivityOutcome {
        .init(activity: activity, interactive: interactive, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
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

#if DEBUG
/// Debug-only Purchase bridge diagnostics. Never logs monetary values.
enum PurchaseActivityDiagnostics {
    static func logStart(session: PurchaseSession) {
        let groupAvailable = PurchaseSharedStateStore.url(sessionID: session.id) != nil
        print("[Purchase] start session=\(session.id.uuidString.prefix(8)) items=\(session.items.count) activitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled) appGroupURL=\(groupAvailable) bridge=\(PurchaseSharedStateStore.availability())")
    }

    static func log(outcome: PurchaseActivityOutcome, session: PurchaseSession) {
        let activity: String
        switch outcome.activity {
        case .started(let id): activity = "started(\(id))"
        case .updated: activity = "updated"
        case .ended: activity = "ended"
        case .notRunning: activity = "idle"
        case .liveActivitiesDisabled: activity = "disabled"
        case .requestFailed(let detail): activity = "requestFailed(\(detail))"
        }
        print("[Purchase] publish session=\(session.id.uuidString.prefix(8)) items=\(session.completedItemCount)/\(session.items.count) status=\(session.status.rawValue) sharedWrite=\(outcome.interactive) activity=\(activity)")
    }

    /// Underlying App Group failure detail. Debug-only: the user-facing notice stays concise.
    static func logBridgeFailure(_ error: Error) {
        print("[Purchase] shared container write failed: \(error.localizedDescription)")
    }
}
#endif
