import Foundation
import SQLite3

/// A connection is confined to its caller's actor/thread. Every value is bound, never interpolated.
final class LedgerDiskDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.complete])
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = error(); sqlite3_close(handle); handle = nil; throw failure
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            try execute("CREATE TABLE IF NOT EXISTS documents (namespace TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(namespace, key)) WITHOUT ROWID")
            for suffix in ["", "-wal", "-shm"] {
                let path = url.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
                }
            }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }

    deinit { sqlite3_close(handle) }

    private func error() -> NSError {
        NSError(domain: "Finsy.SQLite", code: Int(sqlite3_errcode(handle)), userInfo: [NSLocalizedDescriptionKey: "Local database operation failed."])
    }

    private func statement(_ sql: String, strings: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else { throw error() }
        for (offset, value) in strings.enumerated() {
            guard sqlite3_bind_text(result, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(result); throw error()
            }
        }
        return result
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func transaction<T>(write: Bool = true, _ operation: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func data(_ namespace: String, _ key: String) throws -> Data? {
        let query = try statement("SELECT value FROM documents WHERE namespace = ? AND key = ?", strings: [namespace, key])
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw error() }
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count > 0, let bytes = sqlite3_column_blob(query, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func put(_ namespace: String, _ key: String, _ data: Data) throws {
        let query = try statement("INSERT INTO documents(namespace,key,value) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value WHERE value != excluded.value", strings: [namespace, key])
        defer { sqlite3_finalize(query) }
        let status = data.withUnsafeBytes { bytes in
            bytes.isEmpty ? sqlite3_bind_zeroblob(query, 3, 0) : sqlite3_bind_blob(query, 3, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard status == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    func remove(_ namespace: String, _ key: String) throws {
        let query = try statement("DELETE FROM documents WHERE namespace = ? AND key = ?", strings: [namespace, key])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    /// Reuse one bound SQLite statement and decode one blob at a time during hydration.
    /// Missing manifest entries are corruption, never silently omitted transactions.
    func values<Keys: Sequence, Value>(_ namespace: String, keys: Keys,
                                      decode: (Data) throws -> Value) throws -> [Value] where Keys.Element == String {
        let query = try statement("SELECT value FROM documents WHERE namespace = ? AND key = ?", strings: [namespace])
        defer { sqlite3_finalize(query) }
        var values: [Value] = []
        values.reserveCapacity(keys.underestimatedCount)
        for key in keys {
            guard sqlite3_reset(query) == SQLITE_OK,
                  sqlite3_bind_text(query, 2, key, -1, transient) == SQLITE_OK else { throw error() }
            let status = sqlite3_step(query)
            guard status != SQLITE_DONE else { throw CocoaError(.fileReadCorruptFile) }
            guard status == SQLITE_ROW else { throw error() }
            let count = Int(sqlite3_column_bytes(query, 0))
            let data: Data
            if count > 0, let bytes = sqlite3_column_blob(query, 0) { data = Data(bytes: bytes, count: count) }
            else { data = Data() }
            values.append(try autoreleasepool { try decode(data) })
        }
        return values
    }

    func hasAny(_ namespace: String) throws -> Bool {
        let query = try statement("SELECT 1 FROM documents WHERE namespace = ? LIMIT 1", strings: [namespace])
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error() }
        return status == SQLITE_ROW
    }

    func keys(_ namespace: String, prefix: String? = nil) throws -> [String] {
        let query: OpaquePointer
        if let prefix {
            query = try statement("SELECT key FROM documents WHERE namespace = ? AND key >= ? AND key < ? ORDER BY key", strings: [namespace, prefix, prefix + "\u{10FFFF}"])
        } else {
            query = try statement("SELECT key FROM documents WHERE namespace = ? ORDER BY key", strings: [namespace])
        }
        defer { sqlite3_finalize(query) }
        var result: [String] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(query, 0) else { throw error() }
            result.append(String(cString: text))
        }
    }
}
