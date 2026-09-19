import Foundation

struct PurchaseSharedSnapshot: Codable, Hashable, Sendable {
    var session: PurchaseSession
    var currencyCode: CurrencyCode
    var updatedAt: Date
    /// Optional so snapshots written by earlier builds still decode.
    var categoryColors: [String: String]? = nil

    var resolvedCategoryColors: [String: String] { categoryColors ?? [:] }
}

/// Runtime state of the App Group bridge. The bridge is a cross-process message channel
/// (main app ↔ widget/AppIntent); it is never the authoritative store for Purchase Mode.
enum PurchaseSharedContainerState: Equatable, Sendable {
    case available
    case containerUnavailable
    case writeFailed(String)
    case readFailed(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Nonfatal infrastructure notice. Nil when the bridge works, because a working
    /// bridge needs no user-facing warning.
    var warning: String? {
        switch self {
        case .available: nil
        case .containerUnavailable, .writeFailed, .readFailed:
            "Lock Screen item controls are unavailable because the shared purchase container could not be opened. Purchase Mode still works in the app."
        }
    }
}

/// Result of actively probing the App Group container. Probe files are always removed.
struct PurchaseSharedContainerDiagnostics: Equatable, Sendable {
    var appGroupIdentifier: String
    var containerPath: String?
    var wroteProbeFile: Bool
    var readProbeFile: Bool
    var removedProbeFile: Bool
    var state: PurchaseSharedContainerState
    var detail: String?

    var containerReachable: Bool { containerPath != nil }

    var report: String {
        var lines = [
            "App Group identifier: \(appGroupIdentifier)",
            "containerURL available: \(containerReachable)",
            "probe file written: \(wroteProbeFile)",
            "probe file read: \(readProbeFile)",
            "probe file removed: \(removedProbeFile)",
            "bridge state: \(state)"
        ]
        if let detail { lines.append("detail: \(detail)") }
        return lines.joined(separator: "\n")
    }
}

enum PurchaseSharedStateStore {
    static let appGroupIdentifier = "group.org.medx.WalletLedger"

    /// The App Group container root, or nil when the runtime (signed) entitlement is missing.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func url(sessionID: UUID) -> URL? {
        containerURL()?.appending(path: "active-purchase-\(sessionID.uuidString).json")
    }

    /// Cheap availability check: only asks whether the container URL resolves.
    static func availability() -> PurchaseSharedContainerState {
        containerURL() == nil ? .containerUnavailable : .available
    }

    /// Probes the container with a temporary file (and removes it) when `probing` is true.
    static func availability(probing: Bool) -> PurchaseSharedContainerState {
        probing ? diagnostics().state : availability()
    }

    /// Full diagnostic used by Debug logging, tests and the ActivityKit environment report.
    static func diagnostics() -> PurchaseSharedContainerDiagnostics {
        let identifier = appGroupIdentifier
        guard let folder = containerURL() else {
            return .init(appGroupIdentifier: identifier, containerPath: nil, wroteProbeFile: false, readProbeFile: false,
                         removedProbeFile: false, state: .containerUnavailable,
                         detail: "containerURL(forSecurityApplicationGroupIdentifier:) returned nil")
        }
        let probe = folder.appending(path: "purchase-bridge-probe-\(UUID().uuidString).json")
        let payload = Data("{\"probe\":true}".utf8)
        var wrote = false, read = false
        var state = PurchaseSharedContainerState.available
        var detail: String?
        do {
            try payload.write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            wrote = true
            read = (try Data(contentsOf: probe)) == payload
        } catch {
            state = wrote ? .readFailed(error.localizedDescription) : .writeFailed(error.localizedDescription)
            detail = error.localizedDescription
        }
        // Probe files are never kept around.
        try? FileManager.default.removeItem(at: probe)
        let removed = !FileManager.default.fileExists(atPath: probe.path)
        if wrote, !read { state = .readFailed("probe file content did not match what was written") }
        return .init(appGroupIdentifier: identifier, containerPath: folder.path, wroteProbeFile: wrote, readProbeFile: read,
                     removedProbeFile: removed, state: state, detail: detail)
    }

    /// True only when the bridge is usable, so item controls may be rendered interactively.
    static var supportsInteractiveCompletion: Bool { availability().isAvailable }

    /// Returns a stored snapshot only when it is strictly newer than the supplied session.
    /// Both processes write subsecond `updatedAt` values, so the comparison is deterministic.
    static func newerSnapshot(for session: PurchaseSession) -> PurchaseSharedSnapshot? {
        guard let snapshot = readIfAvailable(sessionID: session.id) else { return nil }
        let localTimestamp = session.updatedAt ?? session.startedAt ?? session.createdAt
        return snapshot.updatedAt > localTimestamp ? snapshot : nil
    }

    static func write(session: PurchaseSession, categoryColors: [String: String] = [:]) throws {
        guard let url = url(sessionID: session.id) else { throw PurchaseSharedStateError.appGroupUnavailable }
        try coordinateWrite(url: url) { target in
            let timestamp = session.updatedAt ?? session.startedAt ?? session.createdAt
            // Never overwrite a newer widget/AppIntent snapshot with an older local session.
            if let old = decode(at: target), old.updatedAt > timestamp { return }
            let snapshot = PurchaseSharedSnapshot(session: session, currencyCode: session.currency, updatedAt: timestamp, categoryColors: categoryColors)
            let data = try JSONEncoder.purchaseShared.encode(snapshot)
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func read(sessionID: UUID) throws -> PurchaseSharedSnapshot? {
        guard let url = url(sessionID: sessionID) else { throw PurchaseSharedStateError.appGroupUnavailable }
        var snapshot: PurchaseSharedSnapshot?
        var coordinationError: NSError?
        var decodingError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            do { snapshot = try JSONDecoder.purchaseShared.decode(PurchaseSharedSnapshot.self, from: Data(contentsOf: target)) }
            catch { decodingError = error }
        }
        if let coordinationError, snapshot == nil { throw coordinationError }
        if let decodingError { throw decodingError }
        return snapshot
    }

    /// Nonthrowing read used by the reconciliation fast path.
    static func readIfAvailable(sessionID: UUID) -> PurchaseSharedSnapshot? {
        (try? read(sessionID: sessionID)) ?? nil
    }

    static func updateItem(sessionID: UUID, itemID: UUID, completed: Bool) throws -> PurchaseSharedSnapshot {
        guard let url = url(sessionID: sessionID) else { throw PurchaseSharedStateError.appGroupUnavailable }
        return try coordinateWrite(url: url) { target in
            guard var snapshot = decode(at: target),
                  snapshot.session.status == .active || snapshot.session.status == .awaitingSummary,
                  snapshot.session.accountID != nil,
                  let index = snapshot.session.items.firstIndex(where: { $0.id == itemID }) else { throw PurchaseSharedStateError.notFound }
            snapshot.session.items[index].isCompleted = completed
            snapshot.session.items[index].completedAt = completed ? .now : nil
            let finished = snapshot.session.items.allSatisfy(\.isCompleted)
            snapshot.session.status = finished ? .awaitingSummary : .active
            snapshot.session.completedAt = finished ? .now : nil
            snapshot.updatedAt = .now
            snapshot.session.updatedAt = snapshot.updatedAt
            try JSONEncoder.purchaseShared.encode(snapshot).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return snapshot
        }
    }

    private static func decode(at url: URL) -> PurchaseSharedSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.purchaseShared.decode(PurchaseSharedSnapshot.self, from: data)
    }

    private static func coordinateWrite<T>(url: URL, action: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try action(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PurchaseSharedStateError.notFound }
        return try result.get()
    }

    static func resetLocalSnapshots() throws {
        guard let folder = containerURL() else { return }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("active-purchase-") && url.pathExtension == "json" {
            try FileManager.default.removeItem(at: url)
        }
    }
}

enum PurchaseSharedStateError: LocalizedError {
    case appGroupUnavailable, notFound
    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Lock Screen item controls are unavailable because the shared purchase container could not be opened."
        case .notFound:
            "The active purchase item was not found."
        }
    }
}

private extension JSONEncoder {
    static var purchaseShared: JSONEncoder {
        let coder = JSONEncoder()
        // Preserve subsecond item updates so rapid in-app/intent completions reconcile correctly.
        coder.dateEncodingStrategy = .millisecondsSince1970
        return coder
    }
}

private extension JSONDecoder {
    static var purchaseShared: JSONDecoder {
        let coder = JSONDecoder()
        coder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let milliseconds = try? value.decode(Double.self) { return Date(timeIntervalSince1970: milliseconds / 1000) }
            let text = try value.decode(String.self)
            let format = ISO8601DateFormatter()
            if let date = format.date(from: text) { return date }
            format.formatOptions.insert(.withFractionalSeconds)
            if let date = format.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid purchase timestamp")
        }
        return coder
    }
}
