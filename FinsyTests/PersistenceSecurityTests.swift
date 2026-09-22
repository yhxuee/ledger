import XCTest
import CloudKit
@testable import Finsy

@MainActor
final class PersistenceSecurityTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "FinsyTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func book() -> LedgerBook {
        LedgerBook(id: UUID(), name: "Test", state: SeedData.make(), createdAt: .now, updatedAt: .now)
    }

    func testMissingKeyAndLockedPlaceholderNeverProducePlaintextRecords() throws {
        var value = book()
        value.isEncrypted = true
        value.encryptionState = .enabled
        XCTAssertThrowsError(try CloudRecordMapper.records(for: value))
        value.encryptionState = .authorizationRequired
        XCTAssertThrowsError(try CloudRecordMapper.records(for: value))
        value.encryptionState = .migrationFailed
        XCTAssertThrowsError(try CloudRecordMapper.records(for: value))
        value.encryptionState = .disabled // Inconsistent old metadata must also fail closed.
        XCTAssertThrowsError(try CloudRecordMapper.records(for: value))
    }

    func testAttachmentPathsRejectTraversalAndEscapingSymlinks() throws {
        let root = try temporaryFolder()
        let attachments = root.appending(path: "Attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        for name in ["../library.json", "/library.json", "..\\library.json", "a/b.jpg", "", ".", "..", "a\0b"] {
            XCTAssertThrowsError(try AttachmentPath.url(name, in: attachments), name)
        }
        let outside = root.appending(path: "library.json")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: attachments.appending(path: "escape.jpg"), withDestinationURL: outside)
        XCTAssertThrowsError(try AttachmentPath.url("escape.jpg", in: attachments))
        XCTAssertEqual(try Data(contentsOf: outside), Data("original".utf8))
    }

    func testInvalidCloudAttachmentCannotOverwriteLibrary() throws {
        let root = try temporaryFolder()
        let attachments = root.appending(path: "Attachments", directoryHint: .isDirectory)
        let library = root.appending(path: "library.json")
        let asset = root.appending(path: "incoming.jpg")
        try Data("original".utf8).write(to: library)
        try Data("replacement".utf8).write(to: asset)
        var value = book()
        XCTAssertFalse(value.state.transactions.isEmpty)
        value.state.transactions[0].noteAttachmentID = "../library.json"
        let records = try CloudRecordMapper.records(for: value)
        let target = try XCTUnwrap(records.first { $0.recordID.recordName == "transaction-\(value.state.transactions[0].id)" })
        target["noteAttachment"] = CKAsset(fileURL: asset)
        XCTAssertThrowsError(try CloudRecordMapper.decodeBook(from: records, participant: true, attachmentFolder: attachments))
        XCTAssertEqual(try Data(contentsOf: library), Data("original".utf8))
    }

    func testCloudMergePreservesLocalEditsAndAcceptsNewerRemoteEntities() throws {
        var local = book()
        var remote = local
        let now = Date.now
        local.state.transactions[0].note = "Unsent local change"
        local.state.transactions[0].updatedAt = now.addingTimeInterval(20)
        remote.state.transactions[1].note = "Remote change"
        remote.state.transactions[1].updatedAt = now.addingTimeInterval(10)
        // Whole-book timestamp is deliberately older than the local book.
        remote.updatedAt = local.updatedAt.addingTimeInterval(-100)
        let merged = try CloudBookMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.state.transactions[0].note, "Unsent local change")
        XCTAssertEqual(merged.state.transactions[1].note, "Remote change")
    }

    func testCloudUpdateDoesNotSwitchAnExistingInactiveBook() {
        let store = LedgerStore(stateForTesting: SeedData.make())
        let selected = store.activeBookID
        var other = book()
        store.books.append(other)
        other.name = "Updated remotely"
        other.updatedAt = .now.addingTimeInterval(10)
        XCTAssertTrue(store.addOrMergeCloudBook(other))
        XCTAssertEqual(store.activeBookID, selected)
        XCTAssertEqual(store.books.last?.name, "Updated remotely")
    }

    func testReadOnlySnapshotDoesNotAdvanceBookTimestamp() {
        let store = LedgerStore(stateForTesting: SeedData.make())
        let before = store.activeBook.updatedAt
        store.commitActiveBook()
        XCTAssertEqual(store.librarySnapshot().books[0].updatedAt, before)
    }

    func testSQLiteRoundTripAndIncrementalUpdatePreserveOtherEntities() throws {
        let root = try temporaryFolder()
        let database = try LedgerDiskDatabase(url: root.appending(path: "test.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try repository.save(library, previous: nil)
        XCTAssertEqual(try repository.load(), library)
        let unchangedKey = "transaction-\(original.state.transactions[1].id)"
        let unchanged = try database.data(original.id.uuidString, unchangedKey)
        var edited = library
        edited.books[0].state.transactions[0].note = "Only one changed entity"
        edited.books[0].state.transactions[0].updatedAt = .now
        try repository.save(edited, previous: library)
        XCTAssertEqual(try repository.load(), edited)
        XCTAssertEqual(try database.data(original.id.uuidString, unchangedKey), unchanged)
        let reopened = try LedgerDiskDatabase(url: root.appending(path: "test.sqlite"))
        XCTAssertEqual(try IncrementalLedgerRepository(database: reopened).load(), edited)
    }

    func testDatabaseTransactionRollsBackPartialWrite() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "rollback.sqlite"))
        try database.put("test", "value", Data("before".utf8))
        XCTAssertThrowsError(try database.transaction {
            try database.put("test", "value", Data("after".utf8))
            throw BackupError.invalidFormat
        })
        XCTAssertEqual(try database.data("test", "value"), Data("before".utf8))
    }

    func testJournalRestoresPendingRecordsAndAssetsAfterRelaunch() throws {
        let root = try temporaryFolder()
        let assetURL = root.appending(path: "temporary.jpg")
        try Data("image bytes".utf8).write(to: assetURL)
        let record = CKRecord(recordType: "LedgerTransaction", recordID: CKRecord.ID(recordName: "transaction-test", zoneID: .init(zoneName: "test", ownerName: CKCurrentUserDefaultName)))
        record["payload"] = Data("payload".utf8) as CKRecordValue
        record["noteAttachment"] = CKAsset(fileURL: assetURL)
        let folder = root.appending(path: "journal")
        do {
            let journal = try CloudRecordJournal(folder: folder)
            try journal.database.transaction { try journal.store(record); try journal.markPending(record.recordID) }
        }
        try FileManager.default.removeItem(at: assetURL)
        let recovered = try CloudRecordJournal(folder: folder)
        XCTAssertEqual(try recovered.pendingIDs(), [record.recordID])
        let saved = try XCTUnwrap(recovered.record(record.recordID))
        XCTAssertEqual(saved["payload"] as? Data, Data("payload".utf8))
        let savedAsset = try XCTUnwrap((saved["noteAttachment"] as? CKAsset)?.fileURL)
        XCTAssertEqual(try Data(contentsOf: savedAsset), Data("image bytes".utf8))
        try recovered.acknowledge(record.recordID)
        XCTAssertTrue(try recovered.pendingIDs().isEmpty)
    }

    func testCacheEvictsLeastRecentlyUsedAndExpiredValues() {
        var cache = ExpiringCache<String, Int>(capacity: 2, lifetime: 10)
        let now = Date(timeIntervalSince1970: 100)
        cache.insert(1, for: "a", now: now)
        cache.insert(2, for: "b", now: now)
        XCTAssertEqual(cache.value(for: "a", now: now), 1)
        cache.insert(3, for: "c", now: now)
        XCTAssertNil(cache.value(for: "b", now: now))
        XCTAssertNil(cache.value(for: "a", now: now.addingTimeInterval(11)))
        XCTAssertLessThanOrEqual(cache.count, 2)
    }

    func testRecordSelectionDoesNotRebuildUnchangedRecords() throws {
        let original = book()
        let before = try CloudRecordSelection.fingerprints(for: original)
        var edited = original
        edited.state.transactions[0].note = "Changed"
        let after = try CloudRecordSelection.fingerprints(for: edited)
        let changed = Set(after.keys.filter { before[$0] != after[$0] })
        XCTAssertEqual(changed, ["transaction-\(edited.state.transactions[0].id)"])
        let records = try CloudRecordMapper.records(for: edited, recordNames: changed)
        XCTAssertEqual(records.count, 1)
    }

    func testHigherEntityVersionsWinDespiteClockSkew() throws {
        var local = book()
        var remote = local
        local.state.accounts[0].version = 10
        local.state.accounts[0].updatedAt = .distantPast
        local.state.accounts[0].name = "Newer revision"
        remote.state.accounts[0].version = 9
        remote.state.accounts[0].updatedAt = .distantFuture
        local.state.transactions[0].version = 4
        local.state.transactions[0].updatedAt = .distantFuture
        remote.state.transactions[0].version = 5
        remote.state.transactions[0].updatedAt = .distantPast
        remote.state.transactions[0].note = "Newer revision"
        let merged = try CloudBookMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.state.accounts[0].name, "Newer revision")
        XCTAssertEqual(merged.state.transactions[0].note, "Newer revision")
        let localRecord = CKRecord(recordType: "LedgerTransaction")
        let remoteRecord = CKRecord(recordType: "LedgerTransaction")
        localRecord["version"] = 5 as CKRecordValue
        localRecord["updatedAt"] = Date.distantPast as CKRecordValue
        remoteRecord["version"] = 4 as CKRecordValue
        remoteRecord["updatedAt"] = Date.distantFuture as CKRecordValue
        XCTAssertTrue(CloudLedgerSyncCoordinator.localWins(localRecord, over: remoteRecord))
        XCTAssertFalse(CloudLedgerSyncCoordinator.localWins(remoteRecord, over: localRecord))
    }

    func testEqualVersionTieBreaksByUpdatedAtLimitation() throws {
        // Equal-version concurrent writes from two devices fall back to timestamps (imperfect causal ordering limitation).
        var local = book()
        var remote = local
        local.state.transactions[0].version = 5
        local.state.transactions[0].updatedAt = Date(timeIntervalSince1970: 1000)
        local.state.transactions[0].note = "Earlier timestamp"
        remote.state.transactions[0].version = 5
        remote.state.transactions[0].updatedAt = Date(timeIntervalSince1970: 2000)
        remote.state.transactions[0].note = "Later timestamp"

        let merged = try CloudBookMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.state.transactions[0].note, "Later timestamp")

        let localRecord = CKRecord(recordType: "LedgerTransaction")
        let remoteRecord = CKRecord(recordType: "LedgerTransaction")
        localRecord["version"] = 5 as CKRecordValue
        localRecord["updatedAt"] = Date(timeIntervalSince1970: 2000) as CKRecordValue
        remoteRecord["version"] = 5 as CKRecordValue
        remoteRecord["updatedAt"] = Date(timeIntervalSince1970: 1000) as CKRecordValue
        XCTAssertTrue(CloudLedgerSyncCoordinator.localWins(localRecord, over: remoteRecord))
        XCTAssertFalse(CloudLedgerSyncCoordinator.localWins(remoteRecord, over: localRecord))
    }

    func testBulkReadPreservesRequestedOrderAndRejectsMissingRows() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "bulk.sqlite"))
        try database.put("book", "second", Data("2".utf8))
        try database.put("book", "first", Data("1".utf8))
        let values = try database.values("book", keys: ["first", "second", "first"]) { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(values, ["1", "2", "1"])
        XCTAssertThrowsError(try database.values("book", keys: ["first", "missing"]) { $0 })
    }

    func testSavingStaleTransactionDraftAdvancesCurrentVersion() throws {
        let store = LedgerStore(stateForTesting: SeedData.make())
        let account = try XCTUnwrap(store.state.accounts.first { $0.isAvailableForNewTransactions })
        var draft = try store.buildTransaction(type: .expense, accountID: account.id, destinationAccountID: nil,
            amount: 10, currency: account.currency, categoryID: .food, occurredAt: .now, note: nil, in: store.state)
        store.mutateState {
            $0.transactions.insert(draft, at: 0)
            $0.transactions[0].version = 8
        }
        draft.note = "Saved after remote update"
        store.updateTransaction(draft)
        XCTAssertEqual(store.state.transactions.first { $0.id == draft.id }?.version, 9)
    }

    func testFailedShortcutPersistenceRemovesOnlyItsInsertion() async throws {
        #if DEBUG
        let store = LedgerStore(stateForTesting: SeedData.make())
        store.persistenceEnabled = true
        defer { store.persistenceEnabled = false; store.saveTask?.cancel() }
        let category = try XCTUnwrap(store.state.categories.first { $0.kind == .expense && !$0.id.isSystemLinked })
        let account = try XCTUnwrap(store.state.accounts.first { $0.isAvailableForNewTransactions })
        store.mutateState { $0.settings.defaultExpenseAccountByCategory[category.id] = account.id }
        let originalIDs = store.state.transactions.map(\.id)
        store.persistenceTestHook = {
            store.mutateState { $0.transactions[1].note = "Concurrent edit" }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        do {
            _ = try await store.recordQuickTransaction(amount: 1, currencyID: account.currency.rawValue,
                categoryID: "\(store.activeBookID.uuidString)/\(category.id.rawValue)")
            XCTFail("Failed persistence must throw")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        XCTAssertEqual(store.state.transactions.map(\.id), originalIDs)
        XCTAssertEqual(store.state.transactions[0].note, "Concurrent edit")
        store.persistenceTestHook = nil
        #endif
    }

    func testQuickTransactionValidationAndDefaultAccountResolution() throws {
        let store = LedgerStore(stateForTesting: SeedData.make())
        store.persistenceEnabled = true // This test only builds, never saves.
        defer { store.persistenceEnabled = false }
        let category = try XCTUnwrap(store.state.categories.first { $0.kind == .expense && !$0.id.isSystemLinked })
        let account = try XCTUnwrap(store.state.accounts.last { $0.isAvailableForNewTransactions })
        let categoryID = "\(store.activeBookID.uuidString)/\(category.id.rawValue)"

        // 1. Without configured default account -> throws noDefaultAccountConfigured
        XCTAssertThrowsError(try store.buildQuickTransaction(amount: 12.5, currencyID: account.currency.rawValue, categoryID: categoryID)) { error in
            XCTAssertEqual(error as? QuickTransactionError, .noDefaultAccountConfigured)
        }

        // 2. Configure default account -> succeeds
        store.mutateState { $0.settings.defaultExpenseAccountByCategory[category.id] = account.id }
        let count = store.state.transactions.count
        let transaction = try store.buildQuickTransaction(amount: 12.5, currencyID: account.currency.rawValue, categoryID: categoryID)
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.type, .expense)
        XCTAssertEqual(transaction.amount, 12.5)
        XCTAssertEqual(store.state.transactions.count, count)

        // 3. Frozen or unavailable default account -> throws defaultAccountUnavailable
        store.mutateState {
            if let idx = $0.accounts.firstIndex(where: { $0.id == account.id }) {
                $0.accounts[idx].isFrozen = true
            }
        }
        XCTAssertThrowsError(try store.buildQuickTransaction(amount: 12.5, currencyID: account.currency.rawValue, categoryID: categoryID)) { error in
            XCTAssertEqual(error as? QuickTransactionError, .defaultAccountUnavailable)
        }
        store.mutateState {
            if let idx = $0.accounts.firstIndex(where: { $0.id == account.id }) {
                $0.accounts[idx].isFrozen = false
            }
        }

        // 4. Income category with configured default account -> succeeds
        let incomeCategory = try XCTUnwrap(store.state.categories.first { $0.kind == .income && !$0.id.isSystemLinked })
        let incomeCategoryID = "\(store.activeBookID.uuidString)/\(incomeCategory.id.rawValue)"
        XCTAssertThrowsError(try store.buildQuickTransaction(amount: 50, currencyID: account.currency.rawValue, categoryID: incomeCategoryID)) { error in
            XCTAssertEqual(error as? QuickTransactionError, .noDefaultAccountConfigured)
        }
        store.mutateState { $0.settings.defaultExpenseAccountByCategory[incomeCategory.id] = account.id }
        let incomeTx = try store.buildQuickTransaction(amount: 50, currencyID: account.currency.rawValue, categoryID: incomeCategoryID)
        XCTAssertEqual(incomeTx.accountID, account.id)
        XCTAssertEqual(incomeTx.type, .income)
        XCTAssertEqual(incomeTx.amount, 50)

        // 5. Invalid amounts and edge cases
        for amount in [0, -1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try store.buildQuickTransaction(amount: amount, currencyID: account.currency.rawValue, categoryID: categoryID))
        }
        XCTAssertThrowsError(try store.buildQuickTransaction(amount: 1, currencyID: account.currency.rawValue, categoryID: "\(UUID())/\(category.id.rawValue)"))
        store.mutateState { $0.settings.archivedCategoryIDs.insert(category.id) }
        XCTAssertThrowsError(try store.buildQuickTransaction(amount: 1, currencyID: account.currency.rawValue, categoryID: categoryID))
        store.persistenceEnabled = false
        XCTAssertThrowsError(try store.buildQuickTransaction(amount: 1, currencyID: account.currency.rawValue, categoryID: categoryID))
    }

    func testFingerprintsSurviveDictionaryReconstruction() throws {
        let original = book()
        let reloaded = try JSONDecoder().decode(LedgerBook.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(try CloudRecordSelection.fingerprints(for: original), try CloudRecordSelection.fingerprints(for: reloaded))
    }

    func testJSONMigrationKeepsTheRecoverySource() throws {
        let root = try temporaryFolder()
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        let source = try BackupCodec.encoder().encode(library)
        let sourceURL = root.appending(path: "library.json")
        try source.write(to: sourceURL)
        let repository = LocalLedgerRepository(folder: root)
        let loaded = try XCTUnwrap(repository.loadLibrary())
        try repository.saveLibrary(loaded)
        XCTAssertEqual(try repository.loadLibrary(), loaded)
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
    }

    func testCorruptSQLiteUsesLegacyJSONOnlyInReadOnlyRecoveryMode() throws {
        let root = try temporaryFolder()
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try BackupCodec.encoder().encode(library).write(to: root.appending(path: "library.json"))
        let corrupt = Data("this is not sqlite".utf8)
        try corrupt.write(to: root.appending(path: "ledger.sqlite"))

        let result = try XCTUnwrap(LocalLedgerRepository(folder: root).loadResult())
        XCTAssertEqual(result.source, .legacyJSONReadOnlyRecovery)
        XCTAssertEqual(result.library, library)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "ledger.sqlite")), corrupt)
    }

    func testEmptySQLiteAllowsLegacyImportButResidualDataRequiresReadOnlyRecovery() throws {
        let root = try temporaryFolder()
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        let legacyData = try BackupCodec.encoder().encode(library)
        try legacyData.write(to: root.appending(path: "library.json"))
        let database = try LedgerDiskDatabase(url: root.appending(path: "ledger.sqlite"))
        let local = LocalLedgerRepository(folder: root)

        XCTAssertEqual(try local.loadResult()?.source, .legacyJSONImport)
        try database.put(original.id.uuidString, "transaction-\(UUID())", Data("orphan".utf8))
        let recovery = try XCTUnwrap(local.loadResult())
        XCTAssertEqual(recovery.source, .legacyJSONReadOnlyRecovery)
        XCTAssertEqual(recovery.library, library)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "library.json")), legacyData)
        XCTAssertThrowsError(try IncrementalLedgerRepository(database: database).load()) { error in
            XCTAssertEqual(error as? PersistenceIntegrityError, .missingManifest)
        }
    }

    func testRecoveryModeRejectsMutationsWithoutReportingSuccess() throws {
        let store = LedgerStore(stateForTesting: SeedData.make(), recoveryMode: .legacyJSONReadOnlyRecovery)
        let before = store.state
        let account = try XCTUnwrap(before.accounts.first { $0.isAvailableForNewTransactions })

        XCTAssertNil(store.addTransaction(type: .expense, accountID: account.id, destinationAccountID: nil,
            amount: 1, currency: account.currency, categoryID: .food, occurredAt: .now, note: nil))
        XCTAssertNil(store.addCategory(name: "Blocked", detail: "", symbol: "circle", colorHex: "FFFFFF"))
        XCTAssertFalse(store.ensureCurrencyPocket(accountID: account.id, currency: account.currency))
        store.updateSettings { $0.automaticRates.toggle() }
        store.saveAccount(account, desiredBalance: 123)

        XCTAssertEqual(store.state, before)
        XCTAssertNil(store.undoMessage)
        XCTAssertNotNil(store.presentedError)
        XCTAssertEqual(store.backupEnvelope().data, before)
    }

    func testMissingOrOrphanedEntityBlobRejectsSQLiteSnapshot() throws {
        let root = try temporaryFolder()
        let database = try LedgerDiskDatabase(url: root.appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try repository.save(library, previous: nil)

        let transaction = try XCTUnwrap(original.state.transactions.first)
        try database.remove(original.id.uuidString, "transaction-\(transaction.id)")
        XCTAssertThrowsError(try repository.load())
        try BackupCodec.encoder().encode(library).write(to: root.appending(path: "library.json"))
        let recovery = try XCTUnwrap(LocalLedgerRepository(folder: root).loadResult())
        XCTAssertEqual(recovery.source, .legacyJSONReadOnlyRecovery)
        XCTAssertEqual(recovery.library, library)

        try database.put(original.id.uuidString, "transaction-\(transaction.id)", JSONEncoder().encode(transaction))
        var orphan = transaction
        orphan.id = UUID()
        try database.put(original.id.uuidString, "transaction-\(orphan.id)", JSONEncoder().encode(orphan))
        XCTAssertThrowsError(try repository.load())
    }

    func testPartialIndexIsRebuiltBeforeItCanAnswerQueries() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try repository.save(library, previous: nil)
        let removed = try XCTUnwrap(original.state.transactions.first)
        try database.removeIndexedTransaction(bookID: original.id.uuidString, transactionID: removed.id.uuidString)
        var metadataOnlyEdit = library
        metadataOnlyEdit.books[0].name = "Renamed"
        try repository.save(metadataOnlyEdit, previous: library)

        XCTAssertEqual(try repository.transactionCount(bookID: original.id), original.state.transactions.filter { $0.deletedAt == nil }.count)
        XCTAssertNotNil(try repository.transaction(id: removed.id, bookID: original.id))
    }

    func testIndexWithSameCountAndWrongIDSetIsRebuilt() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try repository.save(library, previous: nil)

        let canonicalIDs = Set(original.state.transactions.map { $0.id.uuidString })
        let removed = try XCTUnwrap(canonicalIDs.first)
        let replacement = UUID().uuidString
        try database.execute("UPDATE transactions_index SET transaction_id = '\(replacement)' WHERE book_id = '\(original.id.uuidString)' AND transaction_id = '\(removed)'")
        XCTAssertEqual(try database.allIndexedTransactionIDs(bookID: original.id.uuidString).count, canonicalIDs.count)

        _ = try repository.transactionCount(bookID: original.id)
        XCTAssertEqual(Set(try database.allIndexedTransactionIDs(bookID: original.id.uuidString)), canonicalIDs)
    }

    func testExplicitDeltaPreservesTransactionsOutsideCurrentPage() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        let original = book()
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try repository.save(library, previous: nil)

        let unseen = try XCTUnwrap(original.state.transactions.last)
        let unseenBlob = try database.data(original.id.uuidString, "transaction-\(unseen.id)")
        var changed = try XCTUnwrap(original.state.transactions.first)
        changed.note = "Explicit delta"
        changed.version += 1
        changed.updatedAt = .now
        try repository.applyTransactionDelta(try LedgerTransactionDelta(upserts: [changed]), bookID: original.id)

        let catalog = try repository.transactionCatalog(bookID: original.id)
        XCTAssertEqual(Set(catalog.ids), Set(original.state.transactions.map(\.id)))
        XCTAssertTrue(catalog.contains(unseen.id))
        XCTAssertEqual(try database.data(original.id.uuidString, "transaction-\(unseen.id)"), unseenBlob)
        XCTAssertEqual(try repository.transaction(id: changed.id, bookID: original.id)?.note, "Explicit delta")

        try repository.applyTransactionDelta(try LedgerTransactionDelta(removedIDs: [changed.id]), bookID: original.id)
        XCTAssertFalse(try repository.transactionCatalog(bookID: original.id).contains(changed.id))
        XCTAssertNotNil(try repository.transaction(id: unseen.id, bookID: original.id))
    }

    func testMetadataLoadKeepsInactiveTransactionBlobsUnhydrated() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        let active = book()
        var inactive = book()
        inactive.name = "Inactive"
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: active.id, books: [active, inactive])
        try repository.save(library, previous: nil)

        let damaged = try XCTUnwrap(inactive.state.transactions.first)
        try database.put(inactive.id.uuidString, "transaction-\(damaged.id)", Data("invalid payload".utf8))
        let metadata = try XCTUnwrap(repository.loadMetadata())
        XCTAssertEqual(metadata.activeBookID, active.id)
        XCTAssertEqual(metadata.books.count, 2)
        XCTAssertEqual(metadata.books[1].transactionCatalog.count, inactive.state.transactions.count)
        XCTAssertEqual(metadata.books[1].accounts, inactive.state.accounts)
        XCTAssertThrowsError(try repository.load())
    }

    func testKeysetPaginationIsStableAcrossIdenticalTimestamps() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        var original = book()
        let template = try XCTUnwrap(original.state.transactions.first)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        original.state.transactions = (0..<750).map { _ in
            var transaction = template
            transaction.id = UUID()
            transaction.occurredAt = timestamp
            return transaction
        }
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        try repository.save(library, previous: nil)

        let catalog = try repository.transactionCatalog(bookID: original.id)
        XCTAssertEqual(catalog.count, 750)
        XCTAssertEqual(Set(catalog.ids), Set(original.state.transactions.map(\.id)))

        var ids: [UUID] = []
        var cursorDate: Date?
        var cursorID: UUID?
        repeat {
            let page = try repository.recentTransactions(bookID: original.id, before: cursorDate, beforeID: cursorID, limit: 113)
            ids.append(contentsOf: page.map(\.id))
            cursorDate = page.last?.occurredAt
            cursorID = page.last?.id
            if page.count < 113 { break }
        } while true
        XCTAssertEqual(ids.count, 750)
        XCTAssertEqual(Set(ids).count, 750)
        XCTAssertEqual(ids, ids.sorted { $0.uuidString > $1.uuidString })

        var pageIDs: [UUID] = []
        var cursor: LedgerTransactionCursor?
        repeat {
            let page = try repository.transactionPage(bookID: original.id, after: cursor, limit: 113)
            pageIDs.append(contentsOf: page.transactions.map(\.id))
            cursor = page.nextCursor
            if !page.hasMore { break }
            XCTAssertNotNil(cursor)
        } while true
        XCTAssertEqual(pageIDs, ids)
    }

    func testCloudMergeRejectsDuplicateRemoteIDsWithoutTrapping() throws {
        let local = book()
        var remote = local
        remote.state.transactions.append(try XCTUnwrap(remote.state.transactions.first))
        XCTAssertThrowsError(try CloudBookMerge.merge(local: local, remote: remote)) { error in
            XCTAssertEqual(error as? PersistenceIntegrityError, .duplicateID("transaction merge"))
        }
    }

    func testPersistenceRejectsDuplicateIDsBeforeDictionaryConstruction() throws {
        let database = try LedgerDiskDatabase(url: temporaryFolder().appending(path: "ledger.sqlite"))
        let repository = IncrementalLedgerRepository(database: database)
        var original = book()
        original.state.transactions.append(try XCTUnwrap(original.state.transactions.first))
        let library = LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion, activeBookID: original.id, books: [original])
        XCTAssertThrowsError(try repository.save(library, previous: library)) { error in
            XCTAssertEqual(error as? PersistenceIntegrityError, .duplicateID("transaction"))
        }
    }

    func testPendingDeletionDoesNotReappearInTheCachedLedger() throws {
        let journal = try CloudRecordJournal(folder: temporaryFolder())
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "LedgerAccount", recordID: CKRecord.ID(recordName: "account-test", zoneID: zone))
        try journal.store(record)
        try journal.markDeleted(record.recordID)
        XCTAssertTrue(try journal.records(in: zone).isEmpty)
        XCTAssertEqual(try journal.deletionIDs(), [record.recordID])
        try journal.markPending(record.recordID)
        XCTAssertTrue(try journal.deletionIDs().isEmpty)
        XCTAssertEqual(try journal.records(in: zone).count, 1)
    }

    func testFetchedNewerServerRecordWinsOverPendingOlderEdit() {
        let id = CKRecord.ID(recordName: "transaction-test")
        let local = CKRecord(recordType: "LedgerTransaction", recordID: id)
        let remote = CKRecord(recordType: "LedgerTransaction", recordID: id)
        let now = Date.now
        local["updatedAt"] = now as CKRecordValue
        remote["updatedAt"] = now.addingTimeInterval(1) as CKRecordValue
        XCTAssertFalse(CloudLedgerSyncCoordinator.localWins(local, over: remote))
        remote["updatedAt"] = now as CKRecordValue
        local["version"] = 1 as CKRecordValue
        remote["version"] = 2 as CKRecordValue
        XCTAssertFalse(CloudLedgerSyncCoordinator.localWins(local, over: remote))
    }

    func testDiscoveringCloudBookDoesNotChangeCurrentSelection() {
        let store = LedgerStore(stateForTesting: SeedData.make())
        let selected = store.activeBookID
        XCTAssertTrue(store.addOrMergeCloudBook(book(), selectNewBook: false))
        XCTAssertEqual(store.activeBookID, selected)
    }

    func testFinancialEditCannotOverrideRemoteEncryptionConfiguration() throws {
        var local = book()
        var remote = local
        remote.isEncrypted = true
        remote.encryptionState = .enabled
        remote.encryptionUpdatedAt = .now
        local.updatedAt = .now.addingTimeInterval(100)
        let merged = try CloudBookMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.effectiveEncryptionState, .enabled)
        XCTAssertEqual(merged.isEncrypted, true)
    }

    func testPersistedEncryptionPolicyRejectsStalePlaintextButAllowsExplicitDisable() throws {
        let journal = try CloudRecordJournal(folder: temporaryFolder())
        var value = book()
        let zone = CloudRecordMapper.zoneID(for: value.id)
        let plaintext = CloudEncryptionPolicy(book: value)
        value.isEncrypted = true
        value.encryptionState = .enabled
        value.encryptionUpdatedAt = .now
        try journal.mergeEncryptionPolicy(CloudEncryptionPolicy(book: value), in: zone)
        XCTAssertTrue(try journal.mergeEncryptionPolicy(plaintext, in: zone).required)
        value.isEncrypted = false
        value.encryptionState = .disabled
        value.encryptionUpdatedAt = .now.addingTimeInterval(1)
        XCTAssertFalse(try journal.mergeEncryptionPolicy(CloudEncryptionPolicy(book: value), in: zone).required)
    }

    func testUnlockingRetainsUnsentEditsFromBeforeTheLedgerWasLocked() throws {
        var local = book()
        var remote = local
        local.encryptionState = .authorizationRequired
        local.isEncrypted = true
        local.state.transactions[0].note = "Unsent before authorization"
        local.state.transactions[0].updatedAt = .now.addingTimeInterval(1)
        remote.encryptionState = .enabled
        remote.isEncrypted = true
        let merged = try CloudBookMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.effectiveEncryptionState, .enabled)
        XCTAssertEqual(merged.state.transactions[0].note, "Unsent before authorization")
    }
}
