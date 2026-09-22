import CloudKit
import Foundation

final class CloudLedgerSyncCoordinator: CKSyncEngineDelegate, @unchecked Sendable {
    private let database: CKDatabase
    private let stateURL: URL
    private let queue = DispatchQueue(label: "com.finsy.app.cloud-sync")
    private var pendingRecords: [CKRecord.ID: CKRecord] = [:]
    var receivedRecords: (@Sendable ([CKRecord]) -> Void)?

    lazy var syncEngine: CKSyncEngine = {
        let serialized = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialized, delegate: self)
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }()

    init(database: CKDatabase, stateName: String) {
        self.database = database
        self.stateURL = LocalLedgerRepository.storageFolder.appending(path: "cloud-\(stateName)-sync-state.json")
    }

    func enqueue(records: [CKRecord], zoneID: CKRecordZone.ID, ensureZone: Bool = true) {
        queue.sync {
            for record in records {
                if let cached = pendingRecords[record.recordID] {
                    cached["payload"] = record["payload"]
                    cached["ciphertextV1"] = record["ciphertextV1"]
                    cached["keyFingerprint"] = record["keyFingerprint"]
                    cached["encryptionVersion"] = record["encryptionVersion"]
                    cached["updatedAt"] = record["updatedAt"]
                    cached["version"] = record["version"]
                    cached["receipt"] = record["receipt"]
                    cached["noteAttachment"] = record["noteAttachment"]
                    cached.parent = record.parent
                    pendingRecords[record.recordID] = cached
                } else { pendingRecords[record.recordID] = record }
            }
        }
        if ensureZone { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
        syncEngine.state.add(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
    }

    func cache(records: [CKRecord]) { queue.sync { for record in records { pendingRecords[record.recordID] = record } } }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: stateURL, options: [.atomic, .completeFileProtection])
            }
        case .fetchedRecordZoneChanges(let changes):
            let records = changes.modifications.map(\.record)
            cache(records: records)
            if !records.isEmpty { receivedRecords?(records) }
        case .sentRecordZoneChanges(let sent):
            cache(records: sent.savedRecords)
            for failure in sent.failedRecordSaves where failure.error.code == .serverRecordChanged {
                guard let server = failure.error.serverRecord else { continue }
                let localDate = failure.record["updatedAt"] as? Date ?? .distantPast
                let serverDate = server["updatedAt"] as? Date ?? .distantPast
                if localDate > serverDate {
                    server["payload"] = failure.record["payload"]
                    server["ciphertextV1"] = failure.record["ciphertextV1"]
                    server["keyFingerprint"] = failure.record["keyFingerprint"]
                    server["encryptionVersion"] = failure.record["encryptionVersion"]
                    server["updatedAt"] = failure.record["updatedAt"]
                    server["version"] = failure.record["version"]
                    queue.sync { pendingRecords[server.recordID] = server }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                }
                else { queue.sync { pendingRecords[failure.record.recordID] = server }; receivedRecords?([server]) }
            }
        default: break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        let snapshot = queue.sync { pendingRecords }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in snapshot[recordID] }
    }
}

actor CloudLedgerService {
    static let shared = CloudLedgerService()
    let container = CKContainer(identifier: "iCloud.com.finsy.app")
    private lazy var ownerSync = CloudLedgerSyncCoordinator(database: container.privateCloudDatabase, stateName: "private")
    private lazy var participantSync = CloudLedgerSyncCoordinator(database: container.sharedCloudDatabase, stateName: "shared")
    private var callbacksConfigured = false

    private func configureCallbacksIfNeeded() {
        guard !callbacksConfigured else { return }
        callbacksConfigured = true
        let privateDatabase = container.privateCloudDatabase
        let sharedDatabase = container.sharedCloudDatabase
        ownerSync.receivedRecords = { [weak self] records in guard let zoneID = records.first?.recordID.zoneID else { return }; Task { await self?.refreshCachedBook(database: privateDatabase, zoneID: zoneID, participant: false) } }
        participantSync.receivedRecords = { [weak self] records in guard let zoneID = records.first?.recordID.zoneID else { return }; Task { await self?.refreshCachedBook(database: sharedDatabase, zoneID: zoneID, participant: true) } }
    }

    private func refreshCachedBook(database: CKDatabase?, zoneID: CKRecordZone.ID, participant: Bool) async {
        guard let database, let records = try? await fetchAllRecords(database: database, zoneID: zoneID), let book = try? CloudRecordMapper.decodeBook(from: records, participant: participant, attachmentFolder: AttachmentStore.folderURL) else { return }
        await MainActor.run { NotificationCenter.default.post(name: .acceptedCloudLedger, object: book) }
    }

    func share(book: LedgerBook) async throws -> CKShare {
        configureCallbacksIfNeeded()
        if book.effectiveStorageKind == .cloudParticipant {
            guard let zoneName = book.cloudZoneName, let ownerName = book.cloudZoneOwnerName else { throw CloudLedgerError.missingZone }
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            return try await existingShare(in: container.sharedCloudDatabase, zoneID: zoneID)
        }
        let database = container.privateCloudDatabase
        let zoneID = book.cloudZoneName.map { CKRecordZone.ID(zoneName: $0, ownerName: CKCurrentUserDefaultName) } ?? CloudRecordMapper.zoneID(for: book.id)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let record = try? await database.record(for: shareID), let existing = record as? CKShare { return existing }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        let records = try CloudRecordMapper.records(for: book, zoneID: zoneID, attachmentFolder: LocalLedgerRepository.storageFolder.appending(path: "Attachments"))
        var serverRecords: [CKRecord] = []
        for batch in records.chunked(into: 180) {
            let response = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            serverRecords += response.saveResults.values.compactMap { try? $0.get() }
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = book.name as CKRecordValue
        _ = try await database.save(share)
        ownerSync.cache(records: serverRecords)
        _ = ownerSync.syncEngine
        return share
    }

    private func existingShare(in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let record = try await database.record(for: shareID)
        guard let share = record as? CKShare else { throw CloudLedgerError.shareUnavailable }
        return share
    }

    func accept(_ metadata: CKShare.Metadata) async throws -> LedgerBook {
        configureCallbacksIfNeeded()
        try await container.accept(metadata)
        let zoneID = metadata.share.recordID.zoneID
        let records = try await fetchAllRecords(database: container.sharedCloudDatabase, zoneID: zoneID)
        let book = try CloudRecordMapper.decodeBook(from: records, participant: true, attachmentFolder: AttachmentStore.folderURL)
        participantSync.cache(records: records)
        _ = participantSync.syncEngine
        return book
    }

    func synchronize(book: LedgerBook) throws {
        configureCallbacksIfNeeded()
        guard book.effectiveStorageKind != .local, let zoneName = book.cloudZoneName else { return }
        let owner = book.cloudZoneOwnerName ?? (book.effectiveStorageKind == .cloudOwner ? CKCurrentUserDefaultName : "")
        guard !owner.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        let records = try CloudRecordMapper.records(for: book, zoneID: zoneID, attachmentFolder: LocalLedgerRepository.storageFolder.appending(path: "Attachments"))
        switch book.effectiveStorageKind {
        case .cloudOwner: ownerSync.enqueue(records: records, zoneID: zoneID, ensureZone: true); _ = ownerSync.syncEngine
        case .cloudParticipant: participantSync.enqueue(records: records, zoneID: zoneID, ensureZone: false); _ = participantSync.syncEngine
        case .local: break
        }
    }

    func flushAndFetch(book: LedgerBook) async throws -> LedgerBook? {
        configureCallbacksIfNeeded()
        guard book.effectiveStorageKind != .local, let zoneName = book.cloudZoneName else { return nil }
        let owner = book.cloudZoneOwnerName ?? (book.effectiveStorageKind == .cloudOwner ? CKCurrentUserDefaultName : "")
        guard !owner.isEmpty else { return nil }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        let database = (book.effectiveStorageKind == .cloudOwner) ? container.privateCloudDatabase : container.sharedCloudDatabase

        // Fetch latest records from CloudKit
        let records = try await fetchAllRecords(database: database, zoneID: zoneID)
        let decoded = try CloudRecordMapper.decodeBook(
            from: records,
            participant: (book.effectiveStorageKind == .cloudParticipant),
            attachmentFolder: AttachmentStore.folderURL
        )
        return decoded
    }

    func migrateToEncrypted(book: LedgerBook, key: SymmetricKey) async throws {
        configureCallbacksIfNeeded()
        guard book.effectiveStorageKind != .local, let zoneName = book.cloudZoneName else { return }
        let owner = book.cloudZoneOwnerName ?? (book.effectiveStorageKind == .cloudOwner ? CKCurrentUserDefaultName : "")
        guard !owner.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        let database = (book.effectiveStorageKind == .cloudOwner) ? container.privateCloudDatabase : container.sharedCloudDatabase

        let records = try await fetchAllRecords(database: database, zoneID: zoneID)
        var recordsToUpdate: [CKRecord] = []

        for record in records {
            guard let plaintextPayload = record["payload"] as? Data else { continue }
            let (ciphertext, fp) = try LedgerCryptoService.encryptRecord(
                plaintextPayload,
                ledgerID: book.id,
                recordType: record.recordType,
                recordID: record.recordID.recordName,
                key: key
            )
            record["ciphertextV1"] = ciphertext as CKRecordValue
            record["keyFingerprint"] = fp as CKRecordValue
            record["encryptionVersion"] = LedgerCryptoService.currentEncryptionVersion as CKRecordValue
            recordsToUpdate.append(record)
        }

        for batch in recordsToUpdate.chunked(into: 100) {
            let response = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            var savedRecords: [CKRecord] = []
            for saved in response.saveResults.values.compactMap({ try? $0.get() }) {
                // Clear plaintext payload only after server confirmed save
                saved["payload"] = nil
                savedRecords.append(saved)
            }
            _ = try await database.modifyRecords(saving: savedRecords, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        }
    }

    func postEnrollmentRequest(_ request: FinsyPairingRequest, book: LedgerBook) async throws {
        guard let zoneName = book.cloudZoneName, let owner = book.cloudZoneOwnerName else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        let record = CKRecord(recordType: CloudRecordType.enrollmentRequest, recordID: CKRecord.ID(recordName: "enroll-\(request.requestID.uuidString)", zoneID: zoneID))
        record["requestID"] = request.requestID.uuidString as CKRecordValue
        record["ledgerID"] = request.ledgerID.uuidString as CKRecordValue
        record["publicKey"] = request.newDevicePublicKey as CKRecordValue
        record["expiresAt"] = request.expiresAt as CKRecordValue
        record["createdAt"] = Date.now as CKRecordValue
        _ = try await container.sharedCloudDatabase.save(record)
    }

    func postKeyEnvelope(_ envelope: FinsyKeyGrantEnvelope, book: LedgerBook) async throws {
        guard let zoneName = book.cloudZoneName else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: book.cloudZoneOwnerName ?? CKCurrentUserDefaultName)
        let record = CKRecord(recordType: CloudRecordType.keyEnvelope, recordID: CKRecord.ID(recordName: "envelope-\(envelope.requestID.uuidString)", zoneID: zoneID))
        record["requestID"] = envelope.requestID.uuidString as CKRecordValue
        record["ledgerID"] = envelope.ledgerID.uuidString as CKRecordValue
        record["keyFingerprint"] = envelope.keyFingerprint as CKRecordValue
        record["encapsulatedKey"] = envelope.encapsulatedKey as CKRecordValue
        record["ciphertext"] = envelope.ciphertext as CKRecordValue
        let database = (book.effectiveStorageKind == .cloudOwner) ? container.privateCloudDatabase : container.sharedCloudDatabase
        _ = try await database.save(record)
    }

    private func fetchAllRecords(database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        var output: [CKRecord] = []
        for type in [
            CloudRecordType.book,
            CloudRecordType.account,
            CloudRecordType.transaction,
            CloudRecordType.category,
            CloudRecordType.settings,
            CloudRecordType.budget,
            CloudRecordType.recurring,
            CloudRecordType.purchaseSession,
            CloudRecordType.purchaseItem,
            CloudRecordType.enrollmentRequest,
            CloudRecordType.keyEnvelope
        ] {
            var cursor: CKQueryOperation.Cursor?
            repeat {
                let results: [(CKRecord.ID, Result<CKRecord, Error>)]
                if let existingCursor = cursor {
                    let page = try await database.records(continuingMatchFrom: existingCursor)
                    results = page.matchResults
                    cursor = page.queryCursor
                } else {
                    let page = try await database.records(matching: CKQuery(recordType: type, predicate: NSPredicate(value: true)), inZoneWith: zoneID)
                    results = page.matchResults
                    cursor = page.queryCursor
                }
                output += results.compactMap { try? $0.1.get() }
            } while cursor != nil
        }
        return output
    }
}

enum CloudLedgerError: LocalizedError {
    case missingZone, shareUnavailable
    var errorDescription: String? {
        switch self {
        case .missingZone: "This shared ledger is missing its CloudKit zone metadata."
        case .shareUnavailable: "The CloudKit sharing record is unavailable."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}
