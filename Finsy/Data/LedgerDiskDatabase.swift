import Foundation
import SQLite3

/// A connection is confined to its caller's actor/thread. Every value is bound, never interpolated.
final class LedgerDiskDatabase: @unchecked Sendable {
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
            try execute("""
            CREATE TABLE IF NOT EXISTS transactions_index (
                book_id TEXT NOT NULL,
                transaction_id TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                account_id TEXT NOT NULL,
                destination_account_id TEXT,
                category_id TEXT NOT NULL,
                type TEXT NOT NULL,
                amount REAL NOT NULL,
                currency TEXT NOT NULL,
                account_currency TEXT,
                account_amount REAL,
                destination_amount REAL,
                destination_currency TEXT,
                is_deleted INTEGER NOT NULL,
                is_reversal INTEGER NOT NULL,
                parent_id TEXT,
                purchase_session_id TEXT,
                version INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (book_id, transaction_id)
            ) WITHOUT ROWID
            """)
            if try !hasColumn("account_currency", in: "transactions_index") {
                try execute("ALTER TABLE transactions_index ADD COLUMN account_currency TEXT")
                guard try hasColumn("account_currency", in: "transactions_index") else { throw error() }
            }
            try execute("CREATE INDEX IF NOT EXISTS idx_tx_occurred ON transactions_index (book_id, is_deleted, occurred_at DESC, transaction_id DESC)")
            try execute("CREATE INDEX IF NOT EXISTS idx_tx_account ON transactions_index (book_id, account_id, is_deleted, occurred_at DESC)")
            try execute("CREATE INDEX IF NOT EXISTS idx_tx_dest_account ON transactions_index (book_id, destination_account_id, is_deleted, occurred_at DESC)")
            try execute("CREATE INDEX IF NOT EXISTS idx_tx_category ON transactions_index (book_id, category_id, is_deleted, occurred_at DESC)")
            try execute("""
            CREATE TABLE IF NOT EXISTS transaction_index_state (
                book_id TEXT PRIMARY KEY NOT NULL,
                transaction_count INTEGER NOT NULL,
                id_digest TEXT NOT NULL,
                format_version INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
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

    func indexTransaction(
        bookID: String,
        transactionID: String,
        occurredAt: Double,
        accountID: String,
        destinationAccountID: String?,
        categoryID: String,
        type: String,
        amount: Double,
        currency: String,
        accountCurrency: String?,
        accountAmount: Double?,
        destinationAmount: Double?,
        destinationCurrency: String?,
        isDeleted: Bool,
        isReversal: Bool,
        parentID: String?,
        purchaseSessionID: String?,
        version: Int,
        updatedAt: Double
    ) throws {
        let sql = """
        INSERT INTO transactions_index(
            book_id, transaction_id, occurred_at, account_id, destination_account_id,
            category_id, type, amount, currency, account_currency, account_amount, destination_amount,
            destination_currency, is_deleted, is_reversal, parent_id, purchase_session_id, version, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, transaction_id) DO UPDATE SET
            occurred_at=excluded.occurred_at,
            account_id=excluded.account_id,
            destination_account_id=excluded.destination_account_id,
            category_id=excluded.category_id,
            type=excluded.type,
            amount=excluded.amount,
            currency=excluded.currency,
            account_currency=excluded.account_currency,
            account_amount=excluded.account_amount,
            destination_amount=excluded.destination_amount,
            destination_currency=excluded.destination_currency,
            is_deleted=excluded.is_deleted,
            is_reversal=excluded.is_reversal,
            parent_id=excluded.parent_id,
            purchase_session_id=excluded.purchase_session_id,
            version=excluded.version,
            updated_at=excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, bookID, -1, transient)
        sqlite3_bind_text(stmt, 2, transactionID, -1, transient)
        sqlite3_bind_double(stmt, 3, occurredAt)
        sqlite3_bind_text(stmt, 4, accountID, -1, transient)
        if let destinationAccountID { sqlite3_bind_text(stmt, 5, destinationAccountID, -1, transient) }
        else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_text(stmt, 6, categoryID, -1, transient)
        sqlite3_bind_text(stmt, 7, type, -1, transient)
        sqlite3_bind_double(stmt, 8, amount)
        sqlite3_bind_text(stmt, 9, currency, -1, transient)
        if let accountCurrency { sqlite3_bind_text(stmt, 10, accountCurrency, -1, transient) }
        else { sqlite3_bind_null(stmt, 10) }
        if let accountAmount { sqlite3_bind_double(stmt, 11, accountAmount) }
        else { sqlite3_bind_null(stmt, 11) }
        if let destinationAmount { sqlite3_bind_double(stmt, 12, destinationAmount) }
        else { sqlite3_bind_null(stmt, 12) }
        if let destinationCurrency { sqlite3_bind_text(stmt, 13, destinationCurrency, -1, transient) }
        else { sqlite3_bind_null(stmt, 13) }
        sqlite3_bind_int64(stmt, 14, isDeleted ? 1 : 0)
        sqlite3_bind_int64(stmt, 15, isReversal ? 1 : 0)
        if let parentID { sqlite3_bind_text(stmt, 16, parentID, -1, transient) }
        else { sqlite3_bind_null(stmt, 16) }
        if let purchaseSessionID { sqlite3_bind_text(stmt, 17, purchaseSessionID, -1, transient) }
        else { sqlite3_bind_null(stmt, 17) }
        sqlite3_bind_int64(stmt, 18, Int64(version))
        sqlite3_bind_double(stmt, 19, updatedAt)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    func removeIndexedTransaction(bookID: String, transactionID: String) throws {
        let query = try statement("DELETE FROM transactions_index WHERE book_id = ? AND transaction_id = ?", strings: [bookID, transactionID])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    /// Distinguishes a newly-created empty SQLite file from an interrupted/legacy ledger whose
    /// manifest is missing. No caller may treat the latter as a clean JSON import target.
    func hasLedgerContent() throws -> Bool {
        for sql in [
            "SELECT 1 FROM documents LIMIT 1",
            "SELECT 1 FROM transactions_index LIMIT 1",
            "SELECT 1 FROM transaction_index_state LIMIT 1"
        ] {
            let query = try statement(sql)
            let status = sqlite3_step(query)
            sqlite3_finalize(query)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error() }
            if status == SQLITE_ROW { return true }
        }
        return false
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        let pragma = try statement("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(pragma) }
        while true {
            let status = sqlite3_step(pragma)
            if status == SQLITE_DONE { return false }
            guard status == SQLITE_ROW else { throw error() }
            if let name = sqlite3_column_text(pragma, 1), String(cString: name) == column { return true }
        }
    }

    func removeAllIndexedTransactions(bookID: String) throws {
        let query = try statement("DELETE FROM transactions_index WHERE book_id = ?", strings: [bookID])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    struct TransactionIndexState: Equatable, Sendable {
        var transactionCount: Int
        var idDigest: String
        var formatVersion: Int
    }

    func transactionIndexState(bookID: String) throws -> TransactionIndexState? {
        let query = try statement(
            "SELECT transaction_count, id_digest, format_version FROM transaction_index_state WHERE book_id = ?",
            strings: [bookID]
        )
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let digest = sqlite3_column_text(query, 1) else { throw error() }
        return TransactionIndexState(
            transactionCount: Int(sqlite3_column_int64(query, 0)),
            idDigest: String(cString: digest),
            formatVersion: Int(sqlite3_column_int64(query, 2))
        )
    }

    func setTransactionIndexState(bookID: String, transactionCount: Int, idDigest: String, formatVersion: Int) throws {
        let sql = """
        INSERT INTO transaction_index_state(book_id, transaction_count, id_digest, format_version)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            transaction_count=excluded.transaction_count,
            id_digest=excluded.id_digest,
            format_version=excluded.format_version
        """
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query else { throw error() }
        defer { sqlite3_finalize(query) }
        guard sqlite3_bind_text(query, 1, bookID, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(query, 2, Int64(transactionCount)) == SQLITE_OK,
              sqlite3_bind_text(query, 3, idDigest, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(query, 4, Int64(formatVersion)) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    func removeTransactionIndexState(bookID: String) throws {
        let query = try statement("DELETE FROM transaction_index_state WHERE book_id = ?", strings: [bookID])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    func hasIndexedTransactions(bookID: String) throws -> Bool {
        let query = try statement("SELECT 1 FROM transactions_index WHERE book_id = ? LIMIT 1", strings: [bookID])
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error() }
        return status == SQLITE_ROW
    }

    func accountPocketPostingsSum(bookID: String, accountID: String, currency: String) throws -> Double {
        let sql = """
        SELECT
            COALESCE((
                SELECT SUM(
                    CASE
                        WHEN type IN ('expense', 'transfer') THEN -(COALESCE(account_amount, amount))
                        WHEN type = 'income' THEN COALESCE(account_amount, amount)
                        ELSE 0
                    END
                )
                FROM transactions_index
                WHERE book_id = ? AND account_id = ? AND COALESCE(account_currency, currency) = ? AND is_deleted = 0 AND is_reversal = 0
            ), 0)
            +
            COALESCE((
                SELECT SUM(COALESCE(destination_amount, account_amount, amount))
                FROM transactions_index
                WHERE book_id = ? AND destination_account_id = ? AND type = 'transfer'
                  AND COALESCE(destination_currency, currency) = ?
                  AND is_deleted = 0 AND is_reversal = 0
            ), 0)
        """
        let query = try statement(sql, strings: [bookID, accountID, currency, bookID, accountID, currency])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw error() }
        return sqlite3_column_double(query, 0)
    }

    func transactionCount(bookID: String, includeDeleted: Bool = false) throws -> Int {
        let sql = includeDeleted
            ? "SELECT COUNT(*) FROM transactions_index WHERE book_id = ?"
            : "SELECT COUNT(*) FROM transactions_index WHERE book_id = ? AND is_deleted = 0"
        let query = try statement(sql, strings: [bookID])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(query, 0))
    }

    func recentTransactionIDs(bookID: String, before: Date? = nil, beforeID: String? = nil, limit: Int = 300) throws -> [String] {
        let sql: String
        var stmt: OpaquePointer?
        if let before, let beforeID {
            sql = """
            SELECT transaction_id FROM transactions_index
            WHERE book_id = ? AND is_deleted = 0
              AND (occurred_at < ? OR (occurred_at = ? AND transaction_id < ?))
            ORDER BY occurred_at DESC, transaction_id DESC
            LIMIT ?
            """
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
            sqlite3_bind_text(stmt, 1, bookID, -1, transient)
            sqlite3_bind_double(stmt, 2, before.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, before.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, beforeID, -1, transient)
            sqlite3_bind_int64(stmt, 5, Int64(limit))
        } else {
            sql = """
            SELECT transaction_id FROM transactions_index
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY occurred_at DESC, transaction_id DESC
            LIMIT ?
            """
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
            sqlite3_bind_text(stmt, 1, bookID, -1, transient)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [String] = []
        results.reserveCapacity(limit)
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw error() }
            results.append(String(cString: text))
        }
    }

    func transactionIDs(bookID: String, from: Date? = nil, to: Date? = nil, limit: Int? = nil, offset: Int? = nil) throws -> [String] {
        var sql = "SELECT transaction_id FROM transactions_index WHERE book_id = ? AND is_deleted = 0"
        var bindIndex: Int32 = 2
        if from != nil { sql += " AND occurred_at >= ?" }
        if to != nil { sql += " AND occurred_at <= ?" }
        sql += " ORDER BY occurred_at DESC, transaction_id DESC"
        if let limit { sql += " LIMIT \(limit)" }
        if let offset { sql += " OFFSET \(offset)" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, bookID, -1, transient)
        if let from {
            sqlite3_bind_double(stmt, bindIndex, from.timeIntervalSince1970)
            bindIndex += 1
        }
        if let to {
            sqlite3_bind_double(stmt, bindIndex, to.timeIntervalSince1970)
            bindIndex += 1
        }

        var results: [String] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw error() }
            results.append(String(cString: text))
        }
    }

    func allIndexedTransactionIDs(bookID: String) throws -> [String] {
        let query = try statement("SELECT transaction_id FROM transactions_index WHERE book_id = ? ORDER BY occurred_at DESC, transaction_id DESC", strings: [bookID])
        defer { sqlite3_finalize(query) }
        var results: [String] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(query, 0) else { throw error() }
            results.append(String(cString: text))
        }
    }
}
