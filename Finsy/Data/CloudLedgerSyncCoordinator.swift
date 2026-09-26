import CloudKit
import Foundation

actor CloudLedgerSyncCoordinator: CKSyncEngineDelegate {
    private let database: CKDatabase
    private let folder: URL
    private var journal: CloudRecordJournal?
    private var engine: CKSyncEngine?
    private var paused = false
    private var stopped = false
    private var lastAssetPrune: Date?
    private var storageFailed = false
    private var automaticallySync = true
    private var requestedSend = false
    private var sendTask: Task<Void, Never>?
    private var submittedRecords: [CKRecord.ID: CKRecord] = [:]
    private var sendFailureCodes: [CKError.Code] = []
    private var lastSubmittedRevision: [UUID: UInt64] = [:]
    private var receive: (@Sendable ([CKRecord], [CKRecord.ID]) async -> Bool)?

    init(database: CKDatabase, stateName: String) {
        self.database = database
        folder = FinsyStorage.folder.appending(path: "Cloud-\(stateName)", directoryHint: .isDirectory)
    }

    func stop() async {
        stopped = true
        paused = true
        sendTask?.cancel()
        requestedSend = false
        if let engine { await engine.cancelOperations() }
        if let sendTask { await sendTask.value }
        sendTask = nil
        engine = nil
        journal = nil
        receive = nil
        lastSubmittedRevision.removeAll()
        submittedRecords.removeAll()
        storageFailed = false
    }

    private func storage() throws -> CloudRecordJournal {
        if let journal { return journal }
        let value = try CloudRecordJournal(folder: folder)
        journal = value
        return value
    }

    func start(receive: @escaping @Sendable ([CKRecord], [CKRecord.ID]) async -> Bool) async throws {
        self.receive = receive
        stopped = false
        paused = false
        _ = try syncEngine()
        try await deliverChanges()
    }

    func setAutomaticallySync(_ enabled: Bool) async throws {
        guard automaticallySync != enabled else { return }
        automaticallySync = enabled
        sendTask?.cancel()
        requestedSend = false
        if let engine { await engine.cancelOperations() }
        if let sendTask { await sendTask.value }
        sendTask = nil
        engine = nil
        submittedRecords.removeAll()
        if receive != nil { _ = try syncEngine() }
    }

    func deleteZone(_ zone: CKRecordZone.ID) async throws {
        let engine = try syncEngine()
        await engine.cancelOperations()
        let storage = try storage()
        let changes = engine.state.pendingRecordZoneChanges.filter {
            switch $0 {
            case .saveRecord(let id), .deleteRecord(let id): return id.zoneID == zone
            @unknown default: return false
            }
        }
        let key = zoneKey(zone)
        let data = try NSKeyedArchiver.archivedData(withRootObject: zone, requiringSecureCoding: true)
        try storage.database.transaction {
            try storage.removeZone(zone)
            try storage.database.put("deleted-zones", key, data)
            try storage.database.put("pending-zone-deletions", key, data)
            try storage.database.remove("delivery", key)
            try storage.database.remove("delivery-version", key)
        }
        engine.state.remove(pendingRecordZoneChanges: changes)
        engine.state.remove(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zone)])
        requestSend()
    }

    func allowRestoredZone(_ zone: CKRecordZone.ID) throws {
        let storage = try storage()
        let engine = try syncEngine()
        try storage.database.transaction {
            try storage.database.remove("deleted-zones", zoneKey(zone))
            try storage.database.remove("pending-zone-deletions", zoneKey(zone))
        }
        engine.state.remove(pendingDatabaseChanges: [.deleteZone(zone)])
    }

    func isZoneDeleted(_ zone: CKRecordZone.ID) throws -> Bool {
        try storage().database.data("deleted-zones", zoneKey(zone)) != nil
    }

    func recoverIfNeeded() async throws {
        guard storageFailed, !stopped else { return }
        paused = true
        if let engine { await engine.cancelOperations() }
        engine = nil
        journal = nil
        do {
            // Reload the last durable token, never the token that followed a failed disk write.
            storageFailed = false
            paused = false
            _ = try syncEngine()
            try await deliverChanges()
        } catch {
            storageFailed = true
            paused = true
            throw error
        }
    }

    private func syncEngine() throws -> CKSyncEngine {
        if let engine { return engine }
        let storage = try storage()
        for metadata in try LocalLedgerRepository().cloudMigrationBlocks() {
            let zone = CKRecordZone.ID(
                zoneName: metadata.zoneName,
                ownerName: metadata.ownerName ?? CKCurrentUserDefaultName
            )
            try storage.database.put("blocked", zoneKey(zone), Data([1]))
        }
        let serialization = try storage.database.data("engine", "state").map {
            try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        // Old JSON tokens are intentionally not imported: there was no durable record cache
        // behind those tokens. The SDK bootstraps a complete incremental cache once.
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: self)
        configuration.automaticallySync = automaticallySync
        let value = CKSyncEngine(configuration)
        engine = value
        // The journal is authoritative if the process stopped between acknowledgement
        // and engine-state serialization. Never replay a stale engine-only record ID.
        value.state.remove(pendingRecordZoneChanges: value.state.pendingRecordZoneChanges)
        value.state.add(pendingRecordZoneChanges: try storage.pendingIDs().map { .saveRecord($0) })
        value.state.add(pendingRecordZoneChanges: try storage.deletionIDs().map { .deleteRecord($0) })
        for key in try storage.database.keys("pending-zone-deletions") {
            guard let data = try storage.database.data("pending-zone-deletions", key),
                  let zone = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecordZone.ID.self, from: data) else { throw BackupError.invalidFormat }
            value.state.add(pendingDatabaseChanges: [.deleteZone(zone)])
        }
        return value
    }

    func enqueue(book: LedgerBook, zoneID: CKRecordZone.ID, ensureZone: Bool, revision: UInt64? = nil) throws {
        guard try storage().database.data("deleted-zones", zoneKey(zoneID)) == nil else { return }
        if let revision, let latest = lastSubmittedRevision[book.id], revision < latest { return }
        guard !paused else { throw CloudLedgerError.migrationInProgress }
        _ = try CloudRecordMapper.encryptionKey(for: book)
        guard try storage().database.data("blocked", zoneKey(zoneID)) == nil else { throw CloudLedgerError.migrationInProgress }
        let storage = try storage()
        let desiredPolicy = CloudEncryptionPolicy(book: book)
        let policy = try storage.mergeEncryptionPolicy(desiredPolicy, in: zoneID)
        guard !policy.required || desiredPolicy.required else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: book.keyFingerprint)
        }
        let fingerprints = try CloudRecordSelection.fingerprints(for: book)
        var changed: Set<String> = []
        for (name, fingerprint) in fingerprints {
            let id = CKRecord.ID(recordName: name, zoneID: zoneID)
            if try storage.database.data("fingerprints", CloudRecordJournal.key(id)) != fingerprint { changed.insert(name) }
        }
        let records = try CloudRecordMapper.records(for: book, zoneID: zoneID, attachmentFolder: AttachmentStore.folderURL, recordNames: changed)
        defer { CloudRecordMapper.removeTemporaryAssets(records) }
        var removals: [CKRecord.ID] = []
        let allKnownTxIDs: Set<String>
        if let repo = try? LocalLedgerRepository().transactionRepository(),
           let ids = try? repo.allTransactionIDs(bookID: book.id) {
            allKnownTxIDs = Set(ids.map { "transaction-\($0.uuidString)" })
        } else {
            allKnownTxIDs = Set(book.state.transactions.map { "transaction-\($0.id.uuidString)" })
        }
        try storage.database.transaction {
            for incoming in records {
                let record = try storage.record(incoming.recordID) ?? incoming
                Self.copyUserFields(from: incoming, to: record)
                try storage.store(record)
                try storage.markPending(record.recordID)
            }
            for (name, fingerprint) in fingerprints {
                try storage.database.put("fingerprints", CloudRecordJournal.key(CKRecord.ID(recordName: name, zoneID: zoneID)), fingerprint)
            }
            // Only remove records that this device previously included in its local snapshot.
            // Unseen remote records must never be deleted by a stale device.
            for id in try storage.knownLocalIDs(in: zoneID) where fingerprints[id.recordName] == nil {
                if id.recordName.hasPrefix("transaction-") && allKnownTxIDs.contains(id.recordName) {
                    continue
                }
                try storage.markDeleted(id); removals.append(id)
                try storage.database.remove("fingerprints", CloudRecordJournal.key(id))
            }
        }
        let engine = try syncEngine()
        if ensureZone { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
        engine.state.remove(pendingRecordZoneChanges: records.map { .deleteRecord($0.recordID) } + removals.map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) } + removals.map { .deleteRecord($0) })
        if let revision { lastSubmittedRevision[book.id] = revision }
        LedgerDiagnostics.cloud.info("Enqueued saves=\(records.count) deletes=\(removals.count)")
        if !records.isEmpty || !removals.isEmpty { requestSend() }
    }

    private func requestSend() {
        guard automaticallySync, !paused, !stopped else { return }
        requestedSend = true
        guard sendTask == nil else { return }
        // Task {} inherits the SDK's task-local delegate context, even after
        // the callback returns. sendChanges traps in that context. Detach the
        // operation, then enter this actor again to keep the outbox serialized.
        sendTask = Task.detached { await self.sendRequestedChanges() }
    }

    private func sendRequestedChanges() async {
        defer { sendTask = nil }
        while requestedSend, automaticallySync, !paused, !stopped, !Task.isCancelled {
            requestedSend = false
            do { try await sendPendingChanges() }
            catch {
                if !Task.isCancelled {
                    let message = error.localizedDescription
                    await MainActor.run { LedgerStore.shared.lastSyncError = message }
                    LedgerDiagnostics.failure(error, operation: "cloud-send", logger: LedgerDiagnostics.cloud)
                }
                // The durable outbox stays queued; the SDK retries recoverable failures.
                break
            }
        }
    }

    nonisolated static func copyUserFields(from source: CKRecord, to target: CKRecord) {
        for field in ["payload", "ciphertextV1", "keyFingerprint", "encryptionVersion", "updatedAt", "version", "receipt", "noteAttachment"] {
            target[field] = source[field]
        }
        // Keep a fetched record's existing sharing metadata unchanged. New
        // zone-shared records have no parent chain.
    }

    func cache(records: [CKRecord]) throws {
        let storage = try storage()
        try storage.database.transaction {
            for record in records {
                if record.recordType == CloudRecordType.book {
                    try storage.mergeEncryptionPolicy(CloudEncryptionPolicy(record: record), in: record.recordID.zoneID)
                }
                if try !storage.pending(record.recordID) { try storage.store(record) }
            }
        }
    }

    func revokeLocalAccess(zoneID: CKRecordZone.ID) async throws {
        // Cancel in-flight sends before clearing only this device's journal for the zone.
        if let engine { await engine.cancelOperations() }
        let storage = try storage()
        try storage.database.transaction { try storage.removeZone(zoneID) }
        if let engine {
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges.filter {
                switch $0 {
                case .saveRecord(let id), .deleteRecord(let id): return id.zoneID == zoneID
                @unknown default: return false
                }
            })
        }
        try storage.pruneAssets()
    }

    func beginMigration(zoneID: CKRecordZone.ID) async throws {
        let storage = try storage()
        try storage.database.put("blocked", zoneKey(zoneID), Data([1]))
        paused = true
        if let engine { await engine.cancelOperations() }
    }

    private func zoneKey(_ zone: CKRecordZone.ID) -> String {
        CloudRecordJournal.zoneKey(zone)
    }

    func completeMigration(records: [CKRecord], book: LedgerBook, zoneID: CKRecordZone.ID) throws {
        let storage = try storage()
        try storage.database.transaction {
            for record in records { try storage.store(record); try storage.acknowledge(record.recordID) }
            try storage.mergeEncryptionPolicy(CloudEncryptionPolicy(book: book), in: zoneID)
            for (name, value) in try CloudRecordSelection.fingerprints(for: book) {
                try storage.database.put("fingerprints", CloudRecordJournal.key(CKRecord.ID(recordName: name, zoneID: zoneID)), value)
            }
            try storage.database.remove("blocked", zoneKey(zoneID))
        }
        engine?.state.remove(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
        try resume()
    }

    func resume() throws {
        paused = false
        let storage = try storage()
        let engine = try syncEngine()
        engine.state.add(pendingRecordZoneChanges: try storage.pendingIDs().map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: try storage.deletionIDs().map { .deleteRecord($0) })
    }

    func fetchChanges() async throws {
        guard !paused else { throw CloudLedgerError.migrationInProgress }
        try await syncEngine().fetchChanges()
    }

    func flush() async throws {
        if let sendTask { await sendTask.value }
        try await sendPendingChanges()
        try await syncEngine().fetchChanges()
    }

    private func sendPendingChanges() async throws {
        guard !paused else { throw CloudLedgerError.migrationInProgress }
        let engine = try syncEngine()
        for attempt in 0..<3 {
            sendFailureCodes = []
            let before = Set(try storage().pendingIDs() + storage().deletionIDs())
            do { try await engine.sendChanges() }
            catch {
                // Conflicts handled by the delegate need a new send operation with fresh tags.
                let recovered = !sendFailureCodes.isEmpty && sendFailureCodes.contains { $0 == .serverRecordChanged || $0 == .unknownItem }
                    && sendFailureCodes.allSatisfy { $0 == .serverRecordChanged || $0 == .unknownItem || $0 == .batchRequestFailed }
                if recovered && attempt < 2 { continue }
                throw try detailedSendError(fallback: error)
            }
            if try !storage().hasPendingChanges(), try storage().database.keys("pending-zone-deletions").isEmpty { break }
            let after = Set(try storage().pendingIDs() + storage().deletionIDs())
            if attempt == 2 || before == after { throw try detailedSendError(fallback: CloudLedgerError.pendingChanges) }
        }
    }

    private func detailedSendError(fallback: Error) throws -> Error {
        let storage = try storage()
        let failures = try storage.database.keys("send-failures").compactMap { key -> CloudSendFailure? in
            guard let data = try storage.database.data("send-failures", key) else { return nil }
            return try JSONDecoder().decode(CloudSendFailure.self, from: data)
        }
        // Atomic companions say only that another record failed; show the actual rejection first.
        if let failure = failures.first(where: { $0.code != CKError.Code.batchRequestFailed.rawValue }) ?? failures.first { return failure }
        let pending = try storage.pendingIDs()
        if let id = pending.first, let record = try storage.record(id) {
            let blocked = try storage.database.data("blocked", zoneKey(id.zoneID)) != nil
            let required = try storage.encryptionPolicy(in: id.zoneID)?.required == true
            let reason = blocked ? "Encryption migration is blocking this zone." :
                (required && record["ciphertextV1"] == nil ? "The pending record requires encryption but has no encrypted payload." : fallback.localizedDescription)
            return CloudSendFailure(message: "Record: \(record.recordType) \(id.recordName)\nZone: \(id.zoneID.zoneName)\nPending records: \(pending.count)\nReason: \(reason)")
        }
        return fallback
    }

    private func rememberSendFailure(_ error: CKError, id: CKRecord.ID, type: String) throws {
        sendFailureCodes.append(error.code)
        let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? error.localizedDescription
        let detail = "Record: \(type) \(id.recordName)\nZone: \(id.zoneID.zoneName)\nCloudKit: \(error.code) (\(error.code.rawValue))\nReason: \(reason)"
        try storage().database.put("send-failures", CloudRecordJournal.key(id), JSONEncoder().encode(CloudSendFailure(message: detail, code: error.code.rawValue)))
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard !stopped, self.engine === syncEngine else { return }
        do {
            let storage = try storage()
            switch event {
            case .stateUpdate(let update):
                guard !storageFailed else { return }
                try storage.database.put("engine", "state", JSONEncoder().encode(update.stateSerialization))
            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions {
                    let zone = deletion.zoneID
                    guard zone.zoneName.hasPrefix("LedgerBook-") else { continue }
                    let bookUUIDString = String(zone.zoneName.dropFirst("LedgerBook-".count))
                    guard !bookUUIDString.isEmpty else { continue }
                    let rootID = CKRecord.ID(recordName: "book-\(bookUUIDString)", zoneID: zone)
                    let pending = try storage.pendingIDs().filter { $0.zoneID == zone }
                    let deleting = try storage.deletionIDs().filter { $0.zoneID == zone }
                    try storage.database.transaction {
                        try storage.removeZone(zone)
                        if database.databaseScope == .private {
                            try storage.database.put("deleted-zones", zoneKey(zone), NSKeyedArchiver.archivedData(withRootObject: zone, requiringSecureCoding: true))
                        }
                        try storage.database.put("remote-deletions", CloudRecordJournal.key(rootID), NSKeyedArchiver.archivedData(withRootObject: rootID, requiringSecureCoding: true))
                        try markChanged(zone, storage: storage)
                    }
                    syncEngine.state.remove(pendingRecordZoneChanges: pending.map { .saveRecord($0) } + deleting.map { .deleteRecord($0) })
                    syncEngine.state.remove(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
                }
            case .fetchedRecordZoneChanges(let changes):
                try storage.database.transaction {
                    // Process security metadata first; record ordering in a fetched batch is unspecified.
                    for modification in changes.modifications where modification.record.recordType == CloudRecordType.book {
                        guard try storage.database.data("deleted-zones", zoneKey(modification.record.recordID.zoneID)) == nil else { continue }
                        let record = modification.record
                        try storage.mergeEncryptionPolicy(CloudEncryptionPolicy(record: record), in: record.recordID.zoneID)
                    }
                    for modification in changes.modifications {
                        guard try storage.database.data("deleted-zones", zoneKey(modification.record.recordID.zoneID)) == nil else { continue }
                        let remote = modification.record
                        try markChanged(remote.recordID.zoneID, storage: storage)
                        if try storage.pending(remote.recordID), let local = try storage.record(remote.recordID) {
                            // Updating a change tag without resolving the content would let an
                            // older local edit overwrite a newer server edit without a conflict.
                            let required = try storage.encryptionPolicy(in: remote.recordID.zoneID)?.required ?? false
                            let localRootMatchesPolicy = remote.recordType != CloudRecordType.book || (local["ciphertextV1"] != nil) == required
                            if localRootMatchesPolicy && Self.localWins(local, over: remote) {
                                Self.copyUserFields(from: local, to: remote)
                            } else {
                                try storage.acknowledge(remote.recordID)
                                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(remote.recordID)])
                            }
                        }
                        try storage.store(remote)
                    }
                    for deletion in changes.deletions {
                        guard try !storage.pending(deletion.recordID) else { continue }
                        try storage.remove(deletion.recordID)
                        try storage.database.put("remote-deletions", CloudRecordJournal.key(deletion.recordID), NSKeyedArchiver.archivedData(withRootObject: deletion.recordID, requiringSecureCoding: true))
                        try markChanged(deletion.recordID.zoneID, storage: storage)
                    }
                }
            case .sentRecordZoneChanges(let sent):
                try storage.database.transaction {
                    for failure in sent.failedRecordSaves {
                        guard try storage.database.data("deleted-zones", zoneKey(failure.record.recordID.zoneID)) == nil else { continue }
                        if let server = failure.error.serverRecord, server.recordType == CloudRecordType.book {
                            try storage.mergeEncryptionPolicy(CloudEncryptionPolicy(record: server), in: server.recordID.zoneID)
                        }
                    }
                    for saved in sent.savedRecords {
                        guard try storage.database.data("deleted-zones", zoneKey(saved.recordID.zoneID)) == nil else { continue }
                        let submitted = submittedRecords.removeValue(forKey: saved.recordID)
                        try storage.database.remove("send-failures", CloudRecordJournal.key(saved.recordID))
                        if let current = try storage.record(saved.recordID),
                           submitted.map({ !Self.sameContent(current, $0) }) ?? !Self.sameContent(current, saved) {
                            // An edit made during the request must survive its older acknowledgement.
                            Self.copyUserFields(from: current, to: saved)
                            try storage.store(saved)
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(saved.recordID)])
                        } else {
                            try storage.store(saved)
                            try storage.acknowledge(saved.recordID)
                        }
                    }
                    for id in sent.deletedRecordIDs {
                        try storage.database.remove("send-failures", CloudRecordJournal.key(id))
                        if try storage.pending(id) {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                        } else { try storage.remove(id) }
                        try storage.database.remove("deletions", CloudRecordJournal.key(id))
                    }
                    for failure in sent.failedRecordSaves {
                        guard try storage.database.data("deleted-zones", zoneKey(failure.record.recordID.zoneID)) == nil else { continue }
                        submittedRecords.removeValue(forKey: failure.record.recordID)
                        try rememberSendFailure(failure.error, id: failure.record.recordID, type: failure.record.recordType)
                        LedgerDiagnostics.failure(failure.error, operation: "record-save", logger: LedgerDiagnostics.cloud)
                        let local = try storage.record(failure.record.recordID) ?? failure.record
                        if failure.error.code == .unknownItem {
                            let replacement = CKRecord(recordType: local.recordType, recordID: local.recordID)
                            Self.copyUserFields(from: local, to: replacement)
                            try storage.store(replacement)
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
                            continue
                        }
                        guard failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord else { continue }
                        let required = try storage.encryptionPolicy(in: server.recordID.zoneID)?.required ?? false
                        let localRootMatchesPolicy = server.recordType != CloudRecordType.book || (local["ciphertextV1"] != nil) == required
                        if localRootMatchesPolicy && Self.localWins(local, over: server) {
                            Self.copyUserFields(from: local, to: server)
                            try storage.store(server)
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                        } else {
                            try storage.store(server)
                            try storage.acknowledge(server.recordID)
                            try markChanged(server.recordID.zoneID, storage: storage)
                        }
                    }
                }
                for (id, error) in sent.failedRecordDeletes { try rememberSendFailure(error, id: id, type: "Delete") }
                if let failure = sent.failedRecordSaves.first?.error ?? sent.failedRecordDeletes.values.first {
                    await report(failure)
                } else if try !storage.hasPendingChanges() {
                    await MainActor.run { LedgerStore.shared.lastSyncError = nil }
                }
                LedgerDiagnostics.cloud.info("Sent saved=\(sent.savedRecords.count) failed=\(sent.failedRecordSaves.count) deleted=\(sent.deletedRecordIDs.count)")
            case .sentDatabaseChanges(let sent):
                for failed in sent.failedZoneSaves {
                    try rememberSendFailure(failed.error, id: CKRecord.ID(recordName: "zone-operation", zoneID: failed.zone.zoneID), type: "Create Zone")
                }
                for zone in sent.savedZones {
                    try storage.database.remove("send-failures", CloudRecordJournal.key(CKRecord.ID(recordName: "zone-operation", zoneID: zone.zoneID)))
                }
                for zone in sent.deletedZoneIDs {
                    try storage.database.remove("pending-zone-deletions", zoneKey(zone))
                    try storage.database.remove("send-failures", CloudRecordJournal.key(CKRecord.ID(recordName: "zone-operation", zoneID: zone)))
                }
                for (zone, error) in sent.failedZoneDeletes {
                    if error.code == .zoneNotFound || error.code == .unknownItem {
                        try storage.database.remove("pending-zone-deletions", zoneKey(zone))
                        try storage.database.remove("send-failures", CloudRecordJournal.key(CKRecord.ID(recordName: "zone-operation", zoneID: zone)))
                        syncEngine.state.remove(pendingDatabaseChanges: [.deleteZone(zone)])
                    } else {
                        try rememberSendFailure(error, id: CKRecord.ID(recordName: "zone-operation", zoneID: zone), type: "Delete Zone")
                        await report(error)
                    }
                }
            case .didFetchChanges:
                try await deliverChanges()
                if try !storage.hasPendingChanges(),
                   lastAssetPrune.map({ Date.now.timeIntervalSince($0) > 86_400 }) ?? true {
                    try storage.pruneAssets()
                    lastAssetPrune = .now
                }
            case .didSendChanges:
                try await deliverChanges()
            default: break
            }
        } catch {
            storageFailed = true
            paused = true
            LedgerDiagnostics.failure(error, operation: "sync-event", logger: LedgerDiagnostics.cloud)
            await report(error)
        }
    }

    private func markChanged(_ zone: CKRecordZone.ID, storage: CloudRecordJournal) throws {
        let key = zoneKey(zone)
        try storage.database.put("delivery", key, NSKeyedArchiver.archivedData(withRootObject: zone, requiringSecureCoding: true))
        try storage.database.put("delivery-version", key, Data(UUID().uuidString.utf8))
    }

    private func deliverChanges() async throws {
        guard !paused, let receive else { return }
        let storage = try storage()
        for key in try storage.database.keys("delivery") {
            guard let data = try storage.database.data("delivery", key),
                  let zone = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecordZone.ID.self, from: data) else { throw BackupError.invalidFormat }
            let version = try storage.database.data("delivery-version", key)
            let prefix = CloudRecordJournal.zonePrefix(zone)
            let deletionKeys = try storage.database.keys("remote-deletions", prefix: prefix)
            let deletions = try deletionKeys.map { key -> CKRecord.ID in
                guard let data = try storage.database.data("remote-deletions", key),
                      let id = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.ID.self, from: data) else { throw BackupError.invalidFormat }
                return id
            }
            let records = try storage.records(in: zone)
            if await receive(records, deletions), try storage.database.data("delivery-version", key) == version {
                try storage.database.transaction {
                    try storage.database.remove("delivery", key)
                    try storage.database.remove("delivery-version", key)
                    for deletionKey in deletionKeys { try storage.database.remove("remote-deletions", deletionKey) }
                }
            }
        }
    }

    private func report(_ error: Error) async {
        let message = ((try? detailedSendError(fallback: error)) ?? error).localizedDescription
        await MainActor.run { LedgerStore.shared.lastSyncError = message }
    }

    nonisolated static func localWins(_ local: CKRecord, over remote: CKRecord) -> Bool {
        let localVersion = (local["version"] as? Int) ?? 0
        let remoteVersion = (remote["version"] as? Int) ?? 0
        if localVersion != remoteVersion { return localVersion > remoteVersion }
        let localDate = local["updatedAt"] as? Date ?? .distantPast
        let remoteDate = remote["updatedAt"] as? Date ?? .distantPast
        if localDate != remoteDate { return localDate > remoteDate }
        return true
    }

    nonisolated static func sameContent(_ lhs: CKRecord, _ rhs: CKRecord) -> Bool {
        for field in ["payload", "ciphertextV1", "keyFingerprint", "encryptionVersion", "updatedAt", "version"] {
            let left = lhs[field] as? NSObject
            let right = rhs[field] as? NSObject
            if left != right { return false }
        }
        return true
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !paused, self.engine === syncEngine else { return nil }
        do {
            let storage = try storage()
            var batch: [CKSyncEngine.PendingRecordZoneChange] = []
            var allowedZones: [CKRecordZone.ID: Bool] = [:]
            var requiredEncryption: [CKRecordZone.ID: Bool] = [:]
            var snapshot: [CKRecord.ID: CKRecord] = [:]
            for change in syncEngine.state.pendingRecordZoneChanges {
                guard context.options.scope.contains(change) else { continue }
                let id: CKRecord.ID
                switch change {
                case .saveRecord(let value), .deleteRecord(let value): id = value
                @unknown default: continue
                }
                let allowed: Bool
                if let cached = allowedZones[id.zoneID] { allowed = cached }
                else {
                    allowed = try storage.database.data("blocked", zoneKey(id.zoneID)) == nil && storage.database.data("deleted-zones", zoneKey(id.zoneID)) == nil
                    allowedZones[id.zoneID] = allowed
                }
                guard allowed else { continue }
                if case .saveRecord = change {
                    guard let record = try storage.record(id) else { throw CloudLedgerError.missingPendingRecord }
                    let required: Bool
                    if let cached = requiredEncryption[id.zoneID] { required = cached }
                    else {
                        required = try storage.encryptionPolicy(in: id.zoneID)?.required ?? false
                        requiredEncryption[id.zoneID] = required
                    }
                    guard !required || record["ciphertextV1"] != nil else { continue }
                    snapshot[id] = record
                }
                batch.append(change)
                if batch.count == 200 { break }
            }
            guard !batch.isEmpty else { return nil }
            let records = snapshot
            for (id, record) in records {
                guard let copy = record.copy() as? CKRecord else { throw BackupError.invalidFormat }
                submittedRecords[id] = copy
            }
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: batch) { id in records[id] }

        } catch {
            await report(error)
            return nil
        }
    }
}

struct CloudSendFailure: LocalizedError, Codable {
    var message: String
    var code: Int? = nil
    var errorDescription: String? { message }
}
