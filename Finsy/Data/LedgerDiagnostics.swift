import Foundation
import OSLog

enum LedgerDiagnostics {
    static let persistence = Logger(subsystem: "com.finsy.app", category: "persistence")
    static let cloud = Logger(subsystem: "com.finsy.app", category: "cloud-sync")
    static let security = Logger(subsystem: "com.finsy.app", category: "security")
    static let market = Logger(subsystem: "com.finsy.app", category: "market-data")
    static let activity = Logger(subsystem: "com.finsy.app", category: "live-activity")

    // Never log payloads, financial values, attachment names, or credential-bearing URLs.
    static func failure(_ error: Error, operation: String, logger: Logger) {
        let value = error as NSError
        logger.error("\(operation, privacy: .public) failed domain=\(value.domain, privacy: .public) code=\(value.code)")
    }
}

enum AttachmentPath {
    static func validate(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier != ".", identifier != "..",
              !identifier.contains("/"), !identifier.contains("\\"),
              !identifier.contains(":"), !identifier.contains("\0") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    static func url(_ identifier: String, in folder: URL) throws -> URL {
        try validate(identifier)
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let result = root.appendingPathComponent(identifier).standardizedFileURL.resolvingSymlinksInPath()
        guard result.deletingLastPathComponent() == root else { throw CocoaError(.fileReadNoPermission) }
        return result
    }
}
