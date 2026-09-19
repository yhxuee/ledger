import Foundation

struct PurchaseSharedSnapshot: Codable, Hashable, Sendable {
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

    static func write(session: PurchaseSession) throws {
        guard let url = url(sessionID: session.id) else { throw PurchaseSharedStateError.appGroupUnavailable }
        try coordinateWrite(url: url) { target in
            let timestamp = session.updatedAt ?? session.startedAt ?? session.createdAt
            if let old = decode(at: target), old.updatedAt > timestamp { return }
            let data = try JSONEncoder.purchaseShared.encode(PurchaseSharedSnapshot(session: session, currencyCode: session.currency, updatedAt: timestamp))
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func read(sessionID: UUID) -> PurchaseSharedSnapshot? {
        guard let url = url(sessionID: sessionID) else { return nil }
        var result: PurchaseSharedSnapshot?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            result = decode(at: target)
        }
        return result
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
