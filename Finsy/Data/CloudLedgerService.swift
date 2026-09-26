import CloudKit
import Foundation
import CryptoKit

actor CloudLedgerService {
    static let shared = CloudLedgerService()
    private lazy var container = CKContainer(identifier: "iCloud.com.finsy.app")
    private lazy var ownerSync = CloudLedgerSyncCoordinator(database: container.privateCloudDatabase, stateName: "private")
    private lazy var participantSync = CloudLedgerSyncCoordinator(database: container.sharedCloudDatabase, stateName: "shared")
    private var callbacksConfigured = false
    func resetLocalState() async {
        await ownerSync.stop()
        await participantSync.stop()
        callbacksConfigured = false
    }

    func recoverSyncIfNeeded() async {
        do {
            guard await MainActor.run(body: { LedgerStore.shared.persistenceEnabled }) else { return }
            try await configureCallbacksIfNeeded()
            try await ownerSync.recoverIfNeeded()
            try await participantSync.recoverIfNeeded()
            if await MainActor.run(body: { AppPreferencesStore.shared.value.iCloudSyncEnabled }) {
                try await ownerSync.fetchChanges()
            }
            try await participantSync.fetchChanges()
        } catch {
            LedgerDiagnostics.failure(error, operation: "sync-storage-recovery", logger: LedgerDiagnostics.cloud)
            let message = error.localizedDescription
            await MainActor.run { LedgerStore.shared.lastSyncError = message }
        }
    }

    func fetchAllLedgers() async throws {
        try await configureCallbacksIfNeeded()
        try await ownerSync.recoverIfNeeded()
        try await participantSync.recoverIfNeeded()
        try await ownerSync.fetchChanges()
        try await participantSync.fetchChanges()
        await MainActor.run { LedgerStore.shared.iCloudSyncReady = true }
        try await updateICloudPreference()
    }

    func flushAllLedgers() async throws {
        try await configureCallbacksIfNeeded()
        try await ownerSync.flush()
        try await participantSync.flush()
    }

    func updateICloudPreference() async throws {
        let enabled = await MainActor.run { AppPreferencesStore.shared.value.iCloudSyncEnabled && LedgerStore.shared.iCloudSyncReady }
        try await ownerSync.setAutomaticallySync(enabled)
    }

    func deleteOwnedLedger(_ book: LedgerBook) async throws {
        try await configureCallbacksIfNeeded()
        let zone = book.cloudZoneName.map { CKRecordZone.ID(zoneName: $0, ownerName: CKCurrentUserDefaultName) }
            ?? CloudRecordMapper.zoneID(for: book.id)
        try await ownerSync.deleteZone(zone)
    }

    func leaveSharedLedger(_ book: LedgerBook) async throws {
        guard let zoneName = book.cloudZoneName, let ownerName = book.cloudZoneOwnerName else { throw CloudLedgerError.missingZone }
        try await configureCallbacksIfNeeded()
        // In the shared database, deleting a zone removes only this participant's access.
        try await participantSync.deleteZone(CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName))
    }

    private func configureCallbacksIfNeeded() async throws {
        try await updateICloudPreference()
        guard !callbacksConfigured else { return }
        callbacksConfigured = true
        do {
            try await ownerSync.start { [weak self] records, deletions in
                await self?.refreshCachedBook(records: records, deletions: deletions, participant: false) ?? false
            }
            try await participantSync.start { [weak self] records, deletions in
                await self?.refreshCachedBook(records: records, deletions: deletions, participant: true) ?? false
            }
        } catch { callbacksConfigured = false; throw error }
    }

    private func refreshCachedBook(records: [CKRecord], deletions: [CKRecord.ID], participant: Bool) async -> Bool {
        do {
            if !records.contains(where: { $0.recordType == CloudRecordType.book }),
               let deletion = deletions.first(where: { $0.recordName.hasPrefix("book-") }) {
                let explicitlyLeft = participant ? try await participantSync.isZoneDeleted(deletion.zoneID) : false
                await MainActor.run {
                    if participant && !explicitlyLeft { LedgerStore.shared.detachCloudZone(deletion.zoneID) }
                    else { LedgerStore.shared.removeDeletedCloudBook(in: deletion.zoneID) }
                }
                try await LedgerStore.shared.persistDurableAsync()
                return true
            }
            let book = try CloudRecordMapper.decodeBook(from: records, participant: participant, attachmentFolder: AttachmentStore.folderURL)
            let accepted = await MainActor.run {
                LedgerStore.shared.persistenceEnabled && LedgerStore.shared.addOrMergeCloudBook(book, deletedRecordNames: Set(deletions.map(\.recordName)), selectNewBook: false)
            }
            guard accepted else { return false }
            try await LedgerStore.shared.persistDurableAsync()
            return true
        } catch {
            LedgerDiagnostics.failure(error, operation: "cloud-decode", logger: LedgerDiagnostics.cloud)
            let message = error.localizedDescription
            await MainActor.run { LedgerStore.shared.lastSyncError = message }
            return false
        }
    }

    func share(book: LedgerBook) async throws -> CKShare {
        try await configureCallbacksIfNeeded()
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
        defer { CloudRecordMapper.removeTemporaryAssets(records) }
        for batch in records.chunked(into: 100) {
            let fetched = try await database.records(for: batch.map(\.recordID))
            var missing: [CKRecord] = []
            var known: [CKRecord] = []
            for record in batch {
                guard let result = fetched[record.recordID] else { throw CloudLedgerError.incompleteShareUpload }
                switch result {
                case .success(let existing):
                    known.append(existing)
                case .failure(let error):
                    guard (error as? CKError)?.code == .unknownItem else { throw error }
                    missing.append(record)
                }
            }
            if !missing.isEmpty {
                // A previous share attempt or sync may already have saved some records.
                // Keep those records and their change tags; create only the absent ones.
                let response = try await database.modifyRecords(
                    saving: missing, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false
                )
                var firstFailure: Error?
                for record in missing {
                    guard let result = response.saveResults[record.recordID] else {
                        throw CloudLedgerError.incompleteShareUpload
                    }
                    switch result {
                    case .success(let saved): known.append(saved)
                    case .failure(let error):
                        LedgerDiagnostics.failure(error, operation: "share-record-save", logger: LedgerDiagnostics.cloud)
                        if firstFailure == nil { firstFailure = error }
                    }
                }
                try await ownerSync.cache(records: known)
                if let firstFailure { throw firstFailure }
            } else {
                try await ownerSync.cache(records: known)
            }
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = book.name as CKRecordValue
        _ = try await database.save(share)
        return share
    }

    private func existingShare(in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let record = try await database.record(for: shareID)
        guard let share = record as? CKShare else { throw CloudLedgerError.shareUnavailable }
        return share
    }

    func accept(_ metadata: CKShare.Metadata) async throws -> LedgerBook {
        try await configureCallbacksIfNeeded()
        try await container.accept(metadata)
        let zoneID = metadata.share.recordID.zoneID
        try await participantSync.allowRestoredZone(zoneID)
        let records = try await fetchZoneSnapshot(database: container.sharedCloudDatabase, zoneID: zoneID)
        let book = try CloudRecordMapper.decodeBook(from: records, participant: true, attachmentFolder: AttachmentStore.folderURL)
        try await participantSync.cache(records: records)
        return book
    }

    func synchronize(book: LedgerBook, revision: UInt64? = nil) async throws {
        guard book.effectiveStorageKind != .local, let zoneName = book.cloudZoneName else { return }
        if book.effectiveStorageKind == .cloudOwner,
           !(await MainActor.run { AppPreferencesStore.shared.value.iCloudSyncEnabled && LedgerStore.shared.iCloudSyncReady }) { return }
        try await configureCallbacksIfNeeded()
        let securityMatches = await MainActor.run {
            guard LedgerStore.shared.persistenceEnabled, let current = LedgerStore.shared.books.first(where: { $0.id == book.id }) else { return false }
            return current.effectiveEncryptionState == book.effectiveEncryptionState && current.keyFingerprint == book.keyFingerprint
        }
        guard securityMatches else { return }
        let owner = book.cloudZoneOwnerName ?? (book.effectiveStorageKind == .cloudOwner ? CKCurrentUserDefaultName : "")
        guard !owner.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        guard book.effectiveEncryptionState != .authorizationRequired,
              book.effectiveEncryptionState != .enabling,
              book.effectiveEncryptionState != .migrationFailed else { return }
        if book.isEncrypted == true,
           await MainActor.run(body: { AppPreferencesStore.shared.value.iCloudSyncEnabled }) {
            try LedgerKeyStore.publishKeyToICloud(for: book.id, expectedFingerprint: book.keyFingerprint)
        }
        switch book.effectiveStorageKind {
        case .cloudOwner: try await ownerSync.enqueue(book: book, zoneID: zoneID, ensureZone: true, revision: revision)
        case .cloudParticipant: try await participantSync.enqueue(book: book, zoneID: zoneID, ensureZone: false, revision: revision)
        case .local: break
        }
    }

    func authorizedBook(_ book: LedgerBook) async throws -> LedgerBook {
        try await configureCallbacksIfNeeded()
        guard let zoneName = book.cloudZoneName else { throw CloudLedgerError.missingZone }
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: book.cloudZoneOwnerName ?? CKCurrentUserDefaultName)
        let participant = book.effectiveStorageKind == .cloudParticipant
        let records = try await fetchZoneSnapshot(database: participant ? container.sharedCloudDatabase : container.privateCloudDatabase, zoneID: zone)
        let decoded = try CloudRecordMapper.decodeBook(from: records, participant: participant, attachmentFolder: AttachmentStore.folderURL)
        guard decoded.effectiveEncryptionState != .authorizationRequired else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: book.keyFingerprint)
        }
        try await (participant ? participantSync : ownerSync).cache(records: records)
        return decoded
    }

    func flushAndFetch(book: LedgerBook) async throws -> LedgerBook? {
        guard book.effectiveStorageKind != .local, let zoneName = book.cloudZoneName else { return nil }
        try await configureCallbacksIfNeeded()
        let owner = book.cloudZoneOwnerName ?? (book.effectiveStorageKind == .cloudOwner ? CKCurrentUserDefaultName : "")
        guard !owner.isEmpty else { return nil }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        let database = (book.effectiveStorageKind == .cloudOwner) ? container.privateCloudDatabase : container.sharedCloudDatabase

        try await synchronize(book: book)
        try await (book.effectiveStorageKind == .cloudOwner ? ownerSync : participantSync).flush()

        // Explicit refresh/export may request a complete snapshot after the outbox is acknowledged.
        let records = try await fetchZoneSnapshot(database: database, zoneID: zoneID)
        let decoded = try CloudRecordMapper.decodeBook(
            from: records,
            participant: (book.effectiveStorageKind == .cloudParticipant),
            attachmentFolder: AttachmentStore.folderURL
        )
        return decoded
    }

    func migrateToEncrypted(book: LedgerBook, key: SymmetricKey) async throws -> LedgerBook {
        func validateStoredKey() throws {
            try Task.checkCancellation()
            let expected = LedgerKeyStore.fingerprint(for: key, ledgerID: book.id)
            guard let stored = try LedgerKeyStore.loadKey(for: book.id),
                  LedgerKeyStore.fingerprint(for: stored, ledgerID: book.id) == expected else {
                throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: expected)
            }
        }
        try validateStoredKey()
        guard book.effectiveStorageKind == .cloudOwner, let zoneName = book.cloudZoneName else { return book }
        try await configureCallbacksIfNeeded()
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: book.cloudZoneOwnerName ?? CKCurrentUserDefaultName)
        try await ensureZoneExists(database: container.privateCloudDatabase, zoneID: zoneID)
        try await ownerSync.beginMigration(zoneID: zoneID)

        let maxMigrationAttempts = 3
        var currentBook = book

        do {
            for attempt in 1...maxMigrationAttempts {
                try Task.checkCancellation()
                try validateStoredKey()

                LedgerDiagnostics.security.info(
                    "Encryption migration attempt=\(attempt)/\(maxMigrationAttempts) for ledger=\(book.id)"
                )

                // 1. Fetch fresh complete zone snapshot
                let remoteRecords = try await fetchZoneSnapshot(database: container.privateCloudDatabase, zoneID: zoneID)
                LedgerDiagnostics.security.info(
                    "Fetched zone snapshot for attempt=\(attempt) remoteRecords=\(remoteRecords.count)"
                )

                // 2. Decode remote book if complete, merge with current local book
                let remote: LedgerBook? = {
                    guard remoteRecords.contains(where: { $0.recordType == CloudRecordType.book }),
                          remoteRecords.contains(where: { $0.recordType == CloudRecordType.settings }) else {
                        return nil
                    }
                    return try? CloudRecordMapper.decodeBook(from: remoteRecords, participant: false, attachmentFolder: AttachmentStore.folderURL)
                }()
                var encrypted = try remote.map { try CloudBookMerge.merge(local: currentBook, remote: $0) } ?? currentBook
                let expectedFingerprint = LedgerKeyStore.fingerprint(for: key, ledgerID: book.id)
                encrypted.isEncrypted = true
                encrypted.encryptionState = .enabled
                encrypted.keyFingerprint = expectedFingerprint
                encrypted.encryptionVersion = LedgerCryptoService.currentEncryptionVersion

                // 3. Generate encrypted records and temporary assets
                let generated = try CloudRecordMapper.records(for: encrypted, zoneID: zoneID, attachmentFolder: AttachmentStore.folderURL)

                // Attempt block ensuring temporary assets are cleaned up when this attempt finishes
                let attemptResult: Result<LedgerBook, Error> = await {
                    defer { CloudRecordMapper.removeTemporaryAssets(generated) }
                    do {
                        guard Set(remoteRecords.map(\.recordID)).count == remoteRecords.count else {
                            throw BackupError.invalidValue("duplicate CloudKit record ID")
                        }
                        let originals = Dictionary(remoteRecords.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
                        var updates = generated.map { value -> CKRecord in
                            let target = originals[value.recordID] ?? value
                            CloudLedgerSyncCoordinator.copyUserFields(from: value, to: target)
                            return target
                        }
                        let generatedIDs = Set(generated.map(\.recordID))
                        var toDelete: [CKRecord.ID] = []

                        // Old, unreferenced purchase items still contain financial payloads and must
                        // not be left in plaintext merely because they no longer appear in a header.
                        for record in remoteRecords where !generatedIDs.contains(record.recordID) {
                            if let payload = record["payload"] as? Data {
                                let (ciphertext, fingerprint) = try LedgerCryptoService.encryptRecord(
                                    payload,
                                    ledgerID: book.id,
                                    recordType: record.recordType,
                                    recordID: record.recordID.recordName,
                                    key: key
                                )
                                record["ciphertextV1"] = ciphertext as CKRecordValue
                                record["keyFingerprint"] = fingerprint as CKRecordValue
                                record["encryptionVersion"] = LedgerCryptoService.currentEncryptionVersion as CKRecordValue
                                record["payload"] = nil
                                updates.append(record)
                            } else if let fp = record["keyFingerprint"] as? String, fp.lowercased() != expectedFingerprint.lowercased() {
                                // Dead unreferenced record encrypted with an obsolete/incompatible key.
                                toDelete.append(record.recordID)
                            }
                        }

                        LedgerDiagnostics.security.info(
                            "Encryption migration attempt=\(attempt) records=\(updates.count) deletions=\(toDelete.count)"
                        )

                        let batchRecordsByID = Dictionary(
                            (updates + remoteRecords).map { ($0.recordID, $0) },
                            uniquingKeysWith: { first, _ in first }
                        )

                        var saved: [CKRecord] = []
                        var pendingDeletions = toDelete
                        var batchIndex = 0

                        for batch in updates.chunked(into: 100) {
                            batchIndex += 1
                            try validateStoredKey()
                            let batchDeletions = pendingDeletions
                            pendingDeletions = []

                            LedgerDiagnostics.security.info(
                                "Migration batch=\(batchIndex) saves=\(batch.count) deletes=\(batchDeletions.count)"
                            )

                            do {
                                let response = try await container.privateCloudDatabase.modifyRecords(
                                    saving: batch,
                                    deleting: batchDeletions,
                                    savePolicy: .ifServerRecordUnchanged,
                                    atomically: true
                                )

                                var hasFailure = false
                                for res in response.saveResults.values {
                                    if case .failure = res { hasFailure = true; break }
                                }
                                if !hasFailure {
                                    for res in response.deleteResults.values {
                                        if case .failure = res { hasFailure = true; break }
                                    }
                                }

                                if hasFailure {
                                    throw rootMigrationFailure(
                                        operationError: nil,
                                        saveResults: response.saveResults,
                                        deleteResults: response.deleteResults,
                                        recordsByID: batchRecordsByID,
                                        zoneID: zoneID
                                    )
                                }

                                saved += try response.saveResults.values.map { try $0.get() }
                                LedgerDiagnostics.security.info(
                                    "Encryption migration acknowledged records=\(saved.count) total=\(updates.count)"
                                )
                            } catch {
                                if let migrationFailure = error as? CloudMigrationRecordFailure {
                                    throw migrationFailure
                                }
                                throw rootMigrationFailure(
                                    operationError: error,
                                    saveResults: [:],
                                    deleteResults: [:],
                                    recordsByID: batchRecordsByID,
                                    zoneID: zoneID
                                )
                            }
                        }

                        if !pendingDeletions.isEmpty {
                            do {
                                let response = try await container.privateCloudDatabase.modifyRecords(
                                    saving: [],
                                    deleting: pendingDeletions,
                                    savePolicy: .ifServerRecordUnchanged,
                                    atomically: true
                                )
                                var hasFailure = false
                                for res in response.deleteResults.values {
                                    if case .failure = res { hasFailure = true; break }
                                }
                                if hasFailure {
                                    throw rootMigrationFailure(
                                        operationError: nil,
                                        saveResults: [:],
                                        deleteResults: response.deleteResults,
                                        recordsByID: batchRecordsByID,
                                        zoneID: zoneID
                                    )
                                }
                            } catch {
                                if let migrationFailure = error as? CloudMigrationRecordFailure {
                                    throw migrationFailure
                                }
                                throw rootMigrationFailure(
                                    operationError: error,
                                    saveResults: [:],
                                    deleteResults: [:],
                                    recordsByID: batchRecordsByID,
                                    zoneID: zoneID
                                )
                            }
                        }

                        try validateStoredKey()

                        // Fetch a fresh complete zone snapshot again to verify actual server state.
                        LedgerDiagnostics.security.info("Fetching fresh post-migration zone snapshot for ledger=\(book.id)")
                        let verifiedSnapshot = try await fetchZoneSnapshot(database: container.privateCloudDatabase, zoneID: zoneID)
                        try verifyEncryptedZoneSnapshot(verifiedSnapshot, expectedFingerprint: expectedFingerprint)
                        LedgerDiagnostics.security.info(
                            "Post-migration server verification succeeded for ledger=\(book.id) verifiedRecords=\(verifiedSnapshot.count)"
                        )

                        try await ownerSync.completeMigration(records: verifiedSnapshot, book: encrypted, zoneID: zoneID)
                        LedgerDiagnostics.security.info("Encryption migration completed records=\(verifiedSnapshot.count)")
                        return .success(encrypted)
                    } catch {
                        return .failure(error)
                    }
                }()

                switch attemptResult {
                case .success(let finalEncrypted):
                    return finalEncrypted
                case .failure(let error):
                    if attempt < maxMigrationAttempts,
                       let recordFailure = error as? CloudMigrationRecordFailure,
                       recordFailure.isRetriableConflictOrAsset {
                        LedgerDiagnostics.security.info(
                            "Retrying migration attempt=\(attempt) after retriable error: \(recordFailure.localizedDescription)"
                        )
                        if let retryAfter = recordFailure.retryAfterSeconds, retryAfter > 0 {
                            let delayNanos = UInt64(min(retryAfter, 5.0) * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: delayNanos)
                        }
                        currentBook = book
                        continue
                    }
                    throw error
                }
            }

            throw CloudMigrationRecordFailure(
                recordName: "CloudKit Migration",
                recordType: nil,
                code: .serverRecordChanged,
                reason: "Migration exceeded maximum retry attempts (\(maxMigrationAttempts)) due to persistent conflicts."
            )
        } catch {
            try? await ownerSync.resume()
            LedgerDiagnostics.failure(error, operation: "encryption-migration", logger: LedgerDiagnostics.security)
            throw error
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

    private static let financialRecordTypes: Set<String> = [
        CloudRecordType.book,
        CloudRecordType.account,
        CloudRecordType.transaction,
        CloudRecordType.category,
        CloudRecordType.settings,
        CloudRecordType.budget,
        CloudRecordType.recurring,
        CloudRecordType.purchaseSession,
        CloudRecordType.purchaseItem
    ]

    private func rootMigrationFailure(
        operationError: Error?,
        saveResults: [CKRecord.ID: Result<CKRecord, Error>],
        deleteResults: [CKRecord.ID: Result<Void, Error>],
        recordsByID: [CKRecord.ID: CKRecord],
        zoneID: CKRecordZone.ID
    ) -> CloudMigrationRecordFailure {
        struct ItemFailureCandidate {
            let recordID: CKRecord.ID
            let recordName: String
            let recordType: String?
            let code: CKError.Code
            let reason: String
            let retryAfterSeconds: Double?
        }

        func parseCKErrorInfo(_ error: Error) -> (code: CKError.Code, retryAfter: Double?) {
            if let ckError = error as? CKError {
                return (ckError.code, ckError.retryAfterSeconds)
            }
            let nsError = error as NSError
            if nsError.domain == CKErrorDomain {
                let code = CKError.Code(rawValue: nsError.code) ?? .internalError
                let retry = (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
                return (code, retry)
            }
            return (.internalError, nil)
        }

        func inferRecordType(for recordID: CKRecord.ID) -> String? {
            if let record = recordsByID[recordID] {
                return record.recordType
            }
            let name = recordID.recordName
            if name.hasPrefix("transaction-") { return CloudRecordType.transaction }
            if name.hasPrefix("account-") { return CloudRecordType.account }
            if name.hasPrefix("category-") { return CloudRecordType.category }
            if name.hasPrefix("recurring-") { return CloudRecordType.recurring }
            if name.hasPrefix("purchase-item-") { return CloudRecordType.purchaseItem }
            if name.hasPrefix("purchase-") { return CloudRecordType.purchaseSession }
            if name.hasPrefix("book-") { return CloudRecordType.book }
            if name == "settings" { return CloudRecordType.settings }
            if name == "budget" { return CloudRecordType.budget }
            if name.hasPrefix("enroll-") { return CloudRecordType.enrollmentRequest }
            if name.hasPrefix("envelope-") { return CloudRecordType.keyEnvelope }
            return nil
        }

        func humanFriendlyReason(for code: CKError.Code, underlyingError: Error) -> String {
            switch code {
            case .serverRecordChanged:
                return "The record was modified on the server before this migration batch was saved."
            case .assetFileNotFound:
                return "The temporary encrypted attachment file could not be found."
            case .assetFileModified:
                return "The temporary encrypted attachment file was modified during upload."
            case .networkUnavailable:
                return "The network is unavailable. Please check your internet connection."
            case .networkFailure:
                return "A network failure occurred while communicating with iCloud."
            case .serviceUnavailable:
                return "iCloud services are temporarily unavailable. Please try again later."
            case .requestRateLimited:
                return "iCloud requests are being rate-limited. Please wait a moment and retry."
            case .zoneBusy:
                return "The iCloud record zone is currently busy. Please retry shortly."
            case .notAuthenticated:
                return "You are not signed in to iCloud. Please check your Apple Account settings."
            case .quotaExceeded:
                return "Your iCloud storage quota has been exceeded."
            case .permissionFailure:
                return "Finsy does not have permission to write to this iCloud container."
            case .invalidArguments:
                let msg = underlyingError.localizedDescription
                return msg.isEmpty ? "CloudKit rejected the record with invalid arguments." : msg
            case .batchRequestFailed:
                return "CloudKit rejected the atomic batch."
            default:
                let desc = underlyingError.localizedDescription
                return desc.isEmpty ? "CloudKit operation failed with code \(code.rawValue)." : desc
            }
        }

        var candidates: [ItemFailureCandidate] = []

        func recordCandidate(id: CKRecord.ID, error: Error) {
            let (code, retry) = parseCKErrorInfo(error)
            let type = inferRecordType(for: id)
            let reason = humanFriendlyReason(for: code, underlyingError: error)
            candidates.append(ItemFailureCandidate(
                recordID: id,
                recordName: id.recordName,
                recordType: type,
                code: code,
                reason: reason,
                retryAfterSeconds: retry
            ))
        }

        // 1. Inspect saveResults
        for (id, result) in saveResults {
            if case .failure(let error) = result {
                recordCandidate(id: id, error: error)
            }
        }

        // 2. Inspect deleteResults
        for (id, result) in deleteResults {
            if case .failure(let error) = result {
                recordCandidate(id: id, error: error)
            }
        }

        // 3. Inspect operationError for partial failure dictionary
        if let operationError {
            let nsError = operationError as NSError
            if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                for (key, itemError) in partialErrors {
                    if let recordID = key as? CKRecord.ID {
                        recordCandidate(id: recordID, error: itemError)
                    } else if let recordName = key as? String {
                        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
                        recordCandidate(id: recordID, error: itemError)
                    }
                }
            }
        }

        let failure: CloudMigrationRecordFailure

        // Priority 1: Any item failure whose code is NOT .batchRequestFailed and NOT .partialFailure
        let nonBatchCandidates = candidates.filter { $0.code != .batchRequestFailed && $0.code != .partialFailure }

        if let chosen = nonBatchCandidates.first(where: { $0.code == .serverRecordChanged || $0.code == .assetFileNotFound || $0.code == .assetFileModified })
            ?? nonBatchCandidates.first(where: { $0.code == .invalidArguments })
            ?? nonBatchCandidates.first(where: { $0.code == .quotaExceeded || $0.code == .permissionFailure || $0.code == .notAuthenticated })
            ?? nonBatchCandidates.first {
            failure = CloudMigrationRecordFailure(
                recordName: chosen.recordName,
                recordType: chosen.recordType,
                code: chosen.code,
                reason: chosen.reason,
                retryAfterSeconds: chosen.retryAfterSeconds
            )
        } else if let operationError {
            // Priority 2: Inspect operation-level error if it is not partialFailure or batchRequestFailed
            let (opCode, opRetry) = parseCKErrorInfo(operationError)
            if opCode != .partialFailure && opCode != .batchRequestFailed {
                failure = CloudMigrationRecordFailure(
                    recordName: "iCloud Sync",
                    recordType: nil,
                    code: opCode,
                    reason: humanFriendlyReason(for: opCode, underlyingError: operationError),
                    retryAfterSeconds: opRetry
                )
            } else if let first = candidates.first {
                failure = CloudMigrationRecordFailure(
                    recordName: first.recordName,
                    recordType: first.recordType,
                    code: .batchRequestFailed,
                    reason: "All records in the atomic batch were rejected by CloudKit.",
                    retryAfterSeconds: first.retryAfterSeconds
                )
            } else {
                failure = CloudMigrationRecordFailure(
                    recordName: "CloudKit Batch (\(recordsByID.count) records)",
                    recordType: nil,
                    code: opCode,
                    reason: humanFriendlyReason(for: opCode, underlyingError: operationError),
                    retryAfterSeconds: opRetry
                )
            }
        } else if let first = candidates.first {
            failure = CloudMigrationRecordFailure(
                recordName: first.recordName,
                recordType: first.recordType,
                code: .batchRequestFailed,
                reason: "All records in the atomic batch were rejected by CloudKit.",
                retryAfterSeconds: first.retryAfterSeconds
            )
        } else {
            failure = CloudMigrationRecordFailure(
                recordName: "CloudKit Batch (\(recordsByID.count) records)",
                recordType: nil,
                code: .batchRequestFailed,
                reason: "CloudKit rejected the atomic batch.",
                retryAfterSeconds: nil
            )
        }

        LedgerDiagnostics.security.error(
            """
            Migration root failure:
            type=\(failure.recordType ?? "unknown")
            record=\(failure.recordName)
            code=\(CloudMigrationRecordFailure.codeName(for: failure.code))
            retryAfter=\(failure.retryAfterSeconds.map { "\($0)s" } ?? "nil")
            """
        )

        return failure
    }

    private func ensureZoneExists(database: CKDatabase, zoneID: CKRecordZone.ID) async throws {
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists on server
        } catch let nsError as NSError where nsError.domain == CKErrorDomain && nsError.code == CKError.Code.serverRecordChanged.rawValue {
            // Zone already exists on server (bridged NSError)
        }
    }

    private func fetchZoneSnapshot(database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        var changeToken: CKServerChangeToken? = nil
        var moreComing = true

        while moreComing {
            try Task.checkCancellation()
            do {
                let page = try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: changeToken,
                    desiredKeys: nil,
                    resultsLimit: nil
                )
                for (_, result) in page.modificationResultsByID {
                    try Task.checkCancellation()
                    let modification = try result.get()
                    recordsByID[modification.record.recordID] = modification.record
                }
                for deletion in page.deletions {
                    recordsByID.removeValue(forKey: deletion.recordID)
                }
                changeToken = page.changeToken
                moreComing = page.moreComing
            } catch let error as CKError where error.code == .zoneNotFound {
                // Zone does not exist on server yet. Ensure it is created and return empty snapshot.
                try await ensureZoneExists(database: database, zoneID: zoneID)
                return []
            } catch let nsError as NSError where nsError.domain == CKErrorDomain && nsError.code == CKError.Code.zoneNotFound.rawValue {
                try await ensureZoneExists(database: database, zoneID: zoneID)
                return []
            }
        }

        LedgerDiagnostics.cloud.info("Fetched zone snapshot records=\(recordsByID.count) zone=\(zoneID.zoneName)")
        return Array(recordsByID.values)
    }

    private func verifyEncryptedZoneSnapshot(
        _ records: [CKRecord],
        expectedFingerprint: String
    ) throws {
        let expectedFingerprintLower = expectedFingerprint.lowercased()
        let protocolRecordTypes: Set<String> = [
            CloudRecordType.enrollmentRequest,
            CloudRecordType.keyEnvelope,
            "cloudkit.share",
            "cloudkit.zoneshare"
        ]

        var financialRecordCount = 0

        for record in records {
            // Protocol and system records have distinct security semantics and are excluded
            // from financial payload encryption requirements.
            let isProtocolOrSystem = protocolRecordTypes.contains(record.recordType)
                || record is CKShare
                || record.recordType.hasPrefix("cloudkit.")
                || record.recordID.recordName == CKRecordNameZoneWideShare

            if isProtocolOrSystem {
                continue
            }

            // Reject any leftover record containing the legacy plaintext payload field,
            // even if it is an old/unreferenced record.
            if record["payload"] != nil {
                throw CloudLedgerError.migrationVerificationFailed(
                    "Plaintext payload detected in record \(record.recordID.recordName) (type: \(record.recordType))"
                )
            }

            // Financial records must be encrypted with ciphertext, matching fingerprint, and current version.
            if Self.financialRecordTypes.contains(record.recordType) {
                financialRecordCount += 1

                guard let ciphertext = record["ciphertextV1"] as? Data, !ciphertext.isEmpty else {
                    throw CloudLedgerError.migrationVerificationFailed(
                        "Missing ciphertextV1 in financial record \(record.recordID.recordName)"
                    )
                }

                guard let fingerprint = record["keyFingerprint"] as? String,
                      fingerprint.lowercased() == expectedFingerprintLower else {
                    throw CloudLedgerError.migrationVerificationFailed(
                        "Fingerprint mismatch in financial record \(record.recordID.recordName) (expected \(expectedFingerprintLower), found \(record["keyFingerprint"] as? String ?? "nil"))"
                    )
                }

                guard let version = record["encryptionVersion"] as? Int,
                      version == LedgerCryptoService.currentEncryptionVersion else {
                    throw CloudLedgerError.migrationVerificationFailed(
                        "Invalid encryptionVersion in financial record \(record.recordID.recordName)"
                    )
                }
            }
        }

        guard financialRecordCount > 0 else {
            throw CloudLedgerError.migrationVerificationFailed("No financial records found in migrated zone snapshot")
        }
    }
}

public struct CloudMigrationRecordFailure: LocalizedError, Sendable {
    public let recordName: String
    public let recordType: String?
    public let code: CKError.Code
    public let reason: String
    public let retryAfterSeconds: Double?

    public init(
        recordName: String,
        recordType: String?,
        code: CKError.Code,
        reason: String,
        retryAfterSeconds: Double? = nil
    ) {
        self.recordName = recordName
        self.recordType = recordType
        self.code = code
        self.reason = reason
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var isServerRecordChanged: Bool {
        code == .serverRecordChanged
    }

    public var isAssetError: Bool {
        code == .assetFileNotFound || code == .assetFileModified
    }

    public var isRetriableConflictOrAsset: Bool {
        isServerRecordChanged || isAssetError
    }

    public var errorDescription: String? {
        var lines: [String] = []
        lines.append("Record:")
        if let recordType, !recordType.isEmpty {
            lines.append(recordType)
        }
        lines.append(recordName)
        lines.append("")
        lines.append("CloudKit:")
        lines.append("CKError.\(Self.codeName(for: code))")
        lines.append("")
        lines.append("Reason:")
        lines.append(reason)
        return lines.joined(separator: "\n")
    }

    public static func codeName(for code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .resultsTruncated: return "resultsTruncated"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        @unknown default: return "code(\(code.rawValue))"
        }
    }
}

enum CloudLedgerError: LocalizedError {
    case missingZone, shareUnavailable, migrationInProgress, pendingChanges, missingPendingRecord, incompleteShareUpload, migrationVerificationFailed(String)
    var errorDescription: String? {
        switch self {
        case .migrationInProgress: "Encryption migration is still in progress."
        case .pendingChanges: "Some ledger changes have not reached iCloud yet."
        case .missingPendingRecord: "A pending iCloud record could not be loaded from local storage."
        case .incompleteShareUpload: "CloudKit did not return the result for every ledger record. Please retry sharing."
        case .missingZone: "This shared ledger is missing its CloudKit zone metadata."
        case .shareUnavailable: "The CloudKit sharing record is unavailable."
        case .migrationVerificationFailed(let reason): "Encryption migration verification failed: \(reason)."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}
