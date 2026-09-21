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
    private var lastSubmittedRevision: [UUID: UInt64] = [:]
    private var receive: (@Sendable ([CKRecord], [CKRecord.ID]) async -> Bool)?

    init(database: CKDatabase, stateName: String) {
        self.database = database
        folder = FinsyStorage.folder.appending(path: "Cloud-\(stateName)", directoryHint: .isDirectory)
    }

    func stop() async {
        stopped = true
        paused = true
        if let engine { await engine.cancelOperations() }
        engine = nil
        journal = nil
        receive = nil
        lastSubmittedRevision.removeAll()
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
        if let library = try LocalLedgerRepository().loadLibrary() {
            for book in library.books where book.effectiveEncryptionState == .enabling || book.effectiveEncryptionState == .migrationFailed {
                guard let name = book.cloudZoneName else { continue }
                let zone = CKRecordZone.ID(zoneName: name, ownerName: book.cloudZoneOwnerName ?? CKCurrentUserDefaultName)
                try storage.database.put("blocked", zoneKey(zone), Data([1]))
            }
        }
        let serialization = try storage.database.data("engine", "state").map {
            try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        // Old JSON tokens are intentionally not imported: there was no durable record cache
        // behind those tokens. The SDK bootstraps a complete incremental cache once.
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: self)
        configuration.automaticallySync = true
        let value = CKSyncEngine(configuration)
        engine = value
        // The journal is authoritative if the process stopped between acknowledgement
        // and engine-state serialization. Never replay a stale engine-only record ID.
        value.state.remove(pendingRecordZoneChanges: value.state.pendingRecordZoneChanges)
        value.state.add(pendingRecordZoneChanges: try storage.pendingIDs().map { .saveRecord($0) })
        value.state.add(pendingRecordZoneChanges: try storage.deletionIDs().map { .deleteRecord($0) })
        return value
    }

    func enqueue(book: LedgerBook, zoneID: CKRecordZone.ID, ensureZone: Bool, revision: UInt64? = nil) throws {
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
    }

    nonisolated static func copyUserFields(from source: CKRecord, to target: CKRecord) {
        for field in ["payload", "ciphertextV1", "keyFingerprint", "encryptionVersion", "updatedAt", "version", "receipt", "noteAttachment"] {
            target[field] = source[field]
        }
        target.parent = source.parent
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

    func beginMigration(zoneID: CKRecordZone.ID) async throws {
        let storage = try storage()
        try storage.database.put("blocked", zoneKey(zoneID), Data([1]))
        paused = true
        if let engine { await engine.cancelOperations() }
    }

    private func zoneKey(_ zone: CKRecordZone.ID) -> String {
        CloudRecordJournal.key(CKRecord.ID(recordName: "", zoneID: zone))
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

    func flush() async throws {
        guard !paused else { throw CloudLedgerError.migrationInProgress }
        let engine = try syncEngine()
        try await engine.sendChanges()
        guard try !storage().hasPendingChanges() else { throw CloudLedgerError.pendingChanges }
        try await engine.fetchChanges()
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
                    let rootID = CKRecord.ID(recordName: "book-" + String(zone.zoneName.dropFirst("LedgerBook-".count)), zoneID: zone)
                    let pending = try storage.pendingIDs().filter { $0.zoneID == zone }
                    let deleting = try storage.deletionIDs().filter { $0.zoneID == zone }
                    try storage.database.transaction {
                        try storage.removeZone(zone)
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
                        let record = modification.record
                        try storage.mergeEncryptionPolicy(CloudEncryptionPolicy(record: record), in: record.recordID.zoneID)
                    }
                    for modification in changes.modifications {
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
                        if let server = failure.error.serverRecord, server.recordType == CloudRecordType.book {
                            try storage.mergeEncryptionPolicy(CloudEncryptionPolicy(record: server), in: server.recordID.zoneID)
                        }
                    }
                    for saved in sent.savedRecords {
                        if let current = try storage.record(saved.recordID), !Self.sameContent(current, saved) {
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
                        if try storage.pending(id) {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                        } else { try storage.remove(id) }
                        try storage.database.remove("deletions", CloudRecordJournal.key(id))
                    }
                    for failure in sent.failedRecordSaves {
                        LedgerDiagnostics.failure(failure.error, operation: "record-save", logger: LedgerDiagnostics.cloud)
                        let local = try storage.record(failure.record.recordID) ?? failure.record
                        if failure.error.code == .unknownItem || (failure.error.code == .zoneNotFound && database.databaseScope == .private) {
                            let replacement = CKRecord(recordType: local.recordType, recordID: local.recordID)
                            Self.copyUserFields(from: local, to: replacement)
                            try storage.store(replacement)
                            if failure.error.code == .zoneNotFound {
                                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: local.recordID.zoneID))])
                            }
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
                if let failure = sent.failedRecordSaves.first?.error ?? sent.failedRecordDeletes.values.first {
                    await report(failure)
                } else if try !storage.hasPendingChanges() {
                    await MainActor.run { LedgerStore.shared.lastSyncError = nil }
                }
                LedgerDiagnostics.cloud.info("Sent saved=\(sent.savedRecords.count) failed=\(sent.failedRecordSaves.count) deleted=\(sent.deletedRecordIDs.count)")
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
            let prefix = [zone.ownerName, zone.zoneName].map { "\($0.utf8.count):\($0)" }.joined()
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
        let message = error.localizedDescription
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
                    allowed = try storage.database.data("blocked", zoneKey(id.zoneID)) == nil
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
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: batch) { id in records[id] }

        } catch {
            await report(error)
            return nil
        }
    }
}
