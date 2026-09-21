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

    static func recordLazyMetrics(operation: String, duration: TimeInterval, count: Int, totalCount: Int? = nil) {
        if let totalCount {
            persistence.info("LazyMetrics op=\(operation, privacy: .public) count=\(count) total=\(totalCount) durationMs=\(Int(duration * 1000))")
        } else {
            persistence.info("LazyMetrics op=\(operation, privacy: .public) count=\(count) durationMs=\(Int(duration * 1000))")
        }
    }

    static func recordStartupPhase(_ phase: String, duration: TimeInterval, books: Int? = nil, transactions: Int? = nil) {
        var msg = "startup \(phase) elapsed=\(String(format: "%.4f", duration))"
        if let books { msg += " books=\(books)" }
        if let transactions { msg += " transactions=\(transactions)" }
        persistence.info("\(msg, privacy: .public)")
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
