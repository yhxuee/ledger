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
