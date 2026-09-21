import XCTest
import CloudKit
@testable import Finsy

@MainActor
final class LargeLedgerPerformanceTests: XCTestCase {
    func test10kSQLiteStartupAndIncrementalSave() throws { try exercisePersistence(count: 10_000) }
    func test50kSQLiteStartupAndIncrementalSave() throws { try exercisePersistence(count: 50_000) }
    func test100kSQLiteStartupAndIncrementalSave() throws { try exercisePersistence(count: 100_000) }

    private func exercisePersistence(count: Int) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FinsyScale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "ledger.sqlite")
        let book = LedgerBook(id: UUID(), name: "Scale", state: makeLargeLedger(count: count), createdAt: .now, updatedAt: .now)
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: book.id, books: [book])
        let initialStart = Date.now
        do {
            let repository = IncrementalLedgerRepository(database: try LedgerDiskDatabase(url: url))
            try repository.save(library, previous: nil)
        }
        let initialDuration = Date.now.timeIntervalSince(initialStart)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            do {
                try autoreleasepool {
                    let repository = IncrementalLedgerRepository(database: try LedgerDiskDatabase(url: url))
                    let loaded = try XCTUnwrap(repository.load())
                    // LedgerState remains the complete canonical domain state. A repository page
                    // is a separate value and can never be persisted as if it were the ledger.
                    XCTAssertEqual(loaded.books[0].state.transactions.count, count)

                    // Keyset pagination loads next page with correct ordering
                    let firstPage = try repository.recentTransactions(
                        bookID: book.id,
                        before: nil,
                        beforeID: nil,
                        limit: 300
                    )
                    let nextPage = try repository.recentTransactions(
                        bookID: book.id,
                        before: firstPage.last?.occurredAt,
                        beforeID: firstPage.last?.id,
                        limit: 250
                    )
                    XCTAssertEqual(nextPage.count, min(count - firstPage.count, 250))
                    if let firstOfNext = nextPage.first, let lastOfFirst = firstPage.last {
                        XCTAssertTrue(firstOfNext.occurredAt <= lastOfFirst.occurredAt)
                    }

                    // Single transaction fetch by ID works
                    let targetID = book.state.transactions[count / 2].id
                    let fetched = try XCTUnwrap(repository.transaction(id: targetID, bookID: book.id))
                    XCTAssertEqual(fetched.id, targetID)

                    // Range query for monthly Analytics matches full materialized oracle
                    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
                    let testFrom = baseDate.addingTimeInterval(3600)
                    let testTo = baseDate.addingTimeInterval(7200)
                    let rangeTxs = try repository.transactions(bookID: book.id, from: testFrom, to: testTo, limit: nil, offset: nil)
                    let oracleTxs = book.state.transactions.filter { $0.deletedAt == nil && $0.occurredAt >= testFrom && $0.occurredAt <= testTo }.sorted {
                        if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                        return $0.id.uuidString > $1.id.uuidString
                    }
                    XCTAssertEqual(rangeTxs.map(\.id), oracleTxs.map(\.id))

                    // Account balance aggregate equals full materialized reference result
                    let aggregatedBalance = try repository.accountBalance(for: book.state.accounts[0], bookID: book.id, rates: [:])
                    let oracleBalance = LedgerCalculations.balance(for: book.state.accounts[0], in: book.state)
                    XCTAssertEqual(aggregatedBalance, oracleBalance, accuracy: 0.001)

                    // Statement range query matches full materialized reference result
                    let stmtTxs = try repository.transactions(bookID: book.id, from: nil, to: testTo, limit: nil, offset: nil)
                    let oracleStmtTxs = book.state.transactions.filter { $0.deletedAt == nil && $0.occurredAt <= testTo }.sorted {
                        if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                        return $0.id.uuidString > $1.id.uuidString
                    }
                    XCTAssertEqual(stmtTxs.map(\.id), oracleStmtTxs.map(\.id))

                    // Full materialization only for backup/export
                    let full = try repository.materializeFullLibrary()
                    XCTAssertEqual(full.books[0].state.transactions.count, count)
                }
            } catch { XCTFail("Startup failed: \(error)") }
        }
        var edited = library
        edited.books[0].state.transactions[count / 2].note = "One changed record"
        edited.books[0].state.transactions[count / 2].version += 1
        let deltaStart = Date.now
        do {
            let repository = IncrementalLedgerRepository(database: try LedgerDiskDatabase(url: url))
            try repository.save(edited, previous: library)
            let loadedEdited = try repository.materializeFullLibrary()
            XCTAssertEqual(loadedEdited, edited)
            // Capture live WAL size before closing the last connection checkpoints it.
            let report = "transactions=\(count) initialSaveSeconds=\(initialDuration) deltaSaveAndVerifySeconds=\(Date.now.timeIntervalSince(deltaStart)) databaseBytes=\(fileSize(url)) walBytes=\(fileSize(URL(fileURLWithPath: url.path + "-wal")))"
            let attachment = XCTAttachment(string: report)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func test10kOfflineOutboxSurvivesReopenAndAcknowledgement() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FinsyOutboxScale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let zone = CKRecordZone.ID(zoneName: "Scale", ownerName: CKCurrentUserDefaultName)
        do {
            let journal = try CloudRecordJournal(folder: folder)
            try journal.database.transaction {
                for index in 0..<10_000 {
                    try autoreleasepool {
                        let record = CKRecord(recordType: "LedgerTransaction", recordID: .init(recordName: "transaction-\(index)", zoneID: zone))
                        record["payload"] = Data(repeating: 42, count: 512) as CKRecordValue
                        try journal.store(record)
                        try journal.markPending(record.recordID)
                    }
                }
            }
        }
        do {
            let journal = try CloudRecordJournal(folder: folder)
            let ids = try journal.pendingIDs()
            XCTAssertEqual(ids.count, 10_000)
            try journal.database.transaction {
                for id in ids.prefix(200) {
                    XCTAssertNotNil(try journal.record(id))
                    try journal.acknowledge(id)
                }
            }
        }
        let recovered = try CloudRecordJournal(folder: folder)
        XCTAssertEqual(try recovered.pendingIDs().count, 9_800)
    }

    private func makeLargeLedger(count: Int) -> LedgerState {
        var state = SeedData.makeEmpty()
        let accountID = UUID()
        let account = LedgerAccount(
            id: accountID,
            userID: state.settings.userID,
            name: "Performance Account",
            type: .checking,
            currency: .USD,
            openingBalance: 10_000,
            budget: 0,
            includeInBudget: false,
            logo: "PERF",
            cardStyle: .init(startHex: "3A78C2", endHex: "6C9EBB"),
            createdAt: .now,
            updatedAt: .now,
            version: 1,
            syncStatus: .synced
        )
        state.accounts = [account]

        var txs: [LedgerTransaction] = []
        txs.reserveCapacity(count)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<count {
            let tx = LedgerTransaction(
                id: UUID(),
                userID: state.settings.userID,
                type: i % 5 == 0 ? .income : .expense,
                accountID: accountID,
                destinationAccountID: nil,
                amount: Double((i % 100) + 1),
                currency: .USD,
                accountAmount: Double((i % 100) + 1),
                destinationAmount: nil,
                categoryID: .food,
                occurredAt: baseDate.addingTimeInterval(Double(i * 60)),
                note: "Tx \(i)",
                exchangeRateAtTransaction: 1.0,
                createdAt: baseDate,
                updatedAt: baseDate,
                version: 1,
                syncStatus: .synced
            )
            txs.append(tx)
        }
        state.transactions = txs
        return state
    }

    func test10kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 10_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.portfolioBalance(state, target: state.settings.baseCurrency)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 2.0, "10k calculation took \(duration)s, expected < 2.0s")
    }

    func test50kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 50_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.portfolioBalance(state, target: state.settings.baseCurrency)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 5.0, "50k calculation took \(duration)s, expected < 5.0s")
    }

    func test100kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 100_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.portfolioBalance(state, target: state.settings.baseCurrency)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 10.0, "100k calculation took \(duration)s, expected < 10.0s")
    }
}
