import Foundation
import CryptoKit

// Only application wiring and diagnostics are stubbed. Models, calculations,
// SQLite, vault migration, queries, and cryptography use their production sources.
enum BackupCodec { static let currentSchemaVersion = 3 }
enum BackupError: Error { case invalidFormat, futureSchema(Int) }
enum LedgerDiagnostics {
    struct Logger { func info(_ message: String) {} }
    static let persistence = Logger()
    static func recordStartupPhase(_ name: String, duration: TimeInterval, books: Int, transactions: Int = 0) {}
    static func recordLazyMetrics(operation: String, duration: TimeInterval, count: Int) {}
}

@main
struct EncryptedStorageVerification {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "EncryptedStorageVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        defer { try? LedgerKeyStore.reset(); IncrementalLedgerRepository.clearDecryptedCache() }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = directory.appending(path: "ledger.sqlite")
        let database = try LedgerDiskDatabase(url: url)
        let repository = IncrementalLedgerRepository(database: database)
        let id = UUID(), accountID = UUID(), now = Date.now
        let marker = "PRIVATE-FINANCIAL-MARKER-" + UUID().uuidString
        let account = LedgerAccount(id: accountID, userID: "verification", name: marker, type: .checking,
            currency: .HKD, openingBalance: 1_000_000, budget: 0, includeInBudget: false, logo: "T",
            cardStyle: .init(startHex: "000000", endHex: "000000"), createdAt: now, updatedAt: now,
            deletedAt: nil, version: 1, syncStatus: .pending)
        var state = SeedData.makeProductionEmpty()
        state.accounts = [account]
        var transactions: [LedgerTransaction] = []
        transactions.reserveCapacity(12_000)
        for index in 0..<12_000 {
            let amount = Double(index % 100 + 1)
            let timestamp = now.addingTimeInterval(-Double(index) * 13_140)
            let transaction = LedgerTransaction(
                id: UUID(),
                userID: "verification",
                type: .expense,
                accountID: accountID,
                destinationAccountID: nil,
                amount: amount,
                currency: .HKD,
                accountAmount: amount,
                destinationAmount: nil,
                categoryID: .food,
                occurredAt: timestamp,
                note: marker,
                exchangeRateAtTransaction: 1.0,
                createdAt: now,
                updatedAt: now,
                deletedAt: nil,
                version: 1,
                syncStatus: .pending
            )
            transactions.append(transaction)
        }
        state.transactions = transactions
        let plainBook = LedgerBook(id: id, name: marker, state: state, createdAt: now, updatedAt: now)
        let plainLibrary = LedgerLibrary(schemaVersion: 3, activeBookID: id, books: [plainBook])
        try repository.save(plainLibrary, previous: nil)
        let key = try LedgerKeyStore.generateAndSaveKey(for: id)
        var encrypted = plainBook
        encrypted.isEncrypted = true
        encrypted.keyFingerprint = key.fingerprint
        encrypted.encryptionVersion = 1
        encrypted.encryptionState = .enabled
        let library = LedgerLibrary(schemaVersion: 3, activeBookID: id, books: [encrypted])
        try repository.save(library, previous: plainLibrary)
        try require(try repository.load() == library, "Migration changed existing financial data")
        try require(try database.transactionCount(bookID: id.uuidString, includeDeleted: true) == 0, "Plaintext financial index survived encryption")
        try require(try database.data(id.uuidString, "transaction-" + state.transactions[0].id.uuidString) == nil, "Plaintext transaction survived migration")
        for suffix in ["", "-wal"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                guard let data = FileManager.default.contents(atPath: path) else {
                    throw NSError(domain: "EncryptedStorageVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read \(path)"])
                }
                try require(data.range(of: Data(marker.utf8)) == nil, "Plaintext financial content remains on disk")
            }
        }
        try require(try repository.transactionCount(bookID: id) == 12_000, "Encrypted transaction count is incorrect")
        let page = try repository.transactionPage(bookID: id, after: nil, limit: 100)
        try require(page.transactions.count == 100 && page.hasMore, "Encrypted pagination failed")
        let next = try repository.transactionPage(bookID: id, after: page.nextCursor, limit: 100)
        try require(Set(page.transactions.map(\.id)).isDisjoint(with: next.transactions.map(\.id)), "Pagination repeated transactions")
        let balance = try repository.accountBalance(for: account, bookID: id, rates: state.settings.rates)
        try require(balance == LedgerCalculations.balance(for: account, in: state), "Encrypted account balance differs from production calculations")
        let sealed = try database.data(id.uuidString, "encrypted-book")!
        var object = try JSONSerialization.jsonObject(with: sealed) as! [String: Any]
        var ciphertext = Data(base64Encoded: object["ciphertext"] as! String)!
        ciphertext[ciphertext.startIndex] ^= 1
        object["ciphertext"] = ciphertext.base64EncodedString()
        try database.put(id.uuidString, "encrypted-book", JSONSerialization.data(withJSONObject: object))
        do {
            _ = try repository.load()
            throw NSError(domain: "EncryptedStorageVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tampered vault was accepted"])
        } catch let error as NSError where error.domain == "EncryptedStorageVerification" { throw error }
        catch {}
        try database.put(id.uuidString, "encrypted-book", sealed)
        try LedgerKeyStore.deleteKey(for: id)
        let locked = try repository.load()!.books[0]
        try require(locked.effectiveEncryptionState == .authorizationRequired && locked.state.transactions.isEmpty && locked.state.accounts.isEmpty,
            "Missing key exposed cached plaintext")
        try LedgerKeyStore.saveKey(key.key, for: id)
        try require(try repository.load() == library, "Reauthorization did not recover all records")
        try LedgerDeviceAuthorization.write(true, account: "revoked-" + id.uuidString)
        try require(try repository.load()!.books[0].state.transactions.isEmpty, "Revoked device exposed a cached ledger")
        print("PASS: 12000-record plaintext migration, exact data round trip, disk plaintext removal, encrypted pagination, balances, tamper rejection, missing-key lock, reauthorization, revocation cache isolation")
    }
}
