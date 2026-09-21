import CloudKit
import Foundation
import CryptoKit

/// CI's unsigned artifact may be re-signed without CloudKit entitlements. CKContainer raises an
/// Objective-C exception in that configuration, so Swift error handling cannot recover from it.
enum CloudLedgerRuntime {
    static var isAvailable: Bool {
        #if FINSY_UNSIGNED_BUILD
        false
        #else
        true
        #endif
    }

}

actor CloudLedgerService {
    static let shared = CloudLedgerService()
    // Singleton initialization must remain safe in builds without CloudKit entitlements.
    private lazy var container = CKContainer(identifier: "iCloud.com.finsy.app")
    private lazy var ownerSync = CloudLedgerSyncCoordinator(database: container.privateCloudDatabase, stateName: "private")
    private lazy var participantSync = CloudLedgerSyncCoordinator(database: container.sharedCloudDatabase, stateName: "shared")
    private var callbacksConfigured = false
    private var loggedUnavailableRuntime = false

    private func requireAvailable() throws {
        guard CloudLedgerRuntime.isAvailable else {
            if !loggedUnavailableRuntime {
                LedgerDiagnostics.cloud.notice("CloudKit disabled: build has no usable CloudKit entitlement")
                loggedUnavailableRuntime = true
            }
            throw CloudLedgerError.unavailableInUnsignedBuild
        }
    }

    func resetLocalState() async {
        guard CloudLedgerRuntime.isAvailable else { return }
        await ownerSync.stop()
        await participantSync.stop()
        callbacksConfigured = false
    }

    func recoverSyncIfNeeded() async {
        guard CloudLedgerRuntime.isAvailable else {
            try? requireAvailable()
            return
        }
        guard callbacksConfigured else { return }
        do {
            try await ownerSync.recoverIfNeeded()
            try await participantSync.recoverIfNeeded()
        } catch {
            LedgerDiagnostics.failure(error, operation: "sync-storage-recovery", logger: LedgerDiagnostics.cloud)
            let message = error.localizedDescription
            await MainActor.run { LedgerStore.shared.lastSyncError = message }
        }
    }

    private func configureCallbacksIfNeeded() async throws {
        try requireAvailable()
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
                await MainActor.run { LedgerStore.shared.detachCloudZone(deletion.zoneID) }
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
        var serverRecords: [CKRecord] = []
        for batch in records.chunked(into: 180) {
            let response = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            serverRecords += try response.saveResults.values.map { try $0.get() }
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = book.name as CKRecordValue
        _ = try await database.save(share)
        try await ownerSync.cache(records: serverRecords)
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
        let records = try await fetchAllRecords(database: container.sharedCloudDatabase, zoneID: zoneID)
        let book = try CloudRecordMapper.decodeBook(from: records, participant: true, attachmentFolder: AttachmentStore.folderURL)
        try await participantSync.cache(records: records)
        return book
    }

    func synchronize(book: LedgerBook, revision: UInt64? = nil) async throws {
        guard book.effectiveStorageKind != .local, let zoneName = book.cloudZoneName else { return }
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
        let records = try await fetchAllRecords(database: participant ? container.sharedCloudDatabase : container.privateCloudDatabase, zoneID: zone)
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
        let records = try await fetchAllRecords(database: database, zoneID: zoneID)
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
        try await ownerSync.beginMigration(zoneID: zoneID)
        do {
            let remoteRecords = try await fetchAllRecords(database: container.privateCloudDatabase, zoneID: zoneID)
            let remote = try CloudRecordMapper.decodeBook(from: remoteRecords, participant: false, attachmentFolder: AttachmentStore.folderURL)
            var encrypted = try CloudBookMerge.merge(local: book, remote: remote)
            encrypted.isEncrypted = true
            encrypted.encryptionState = .enabled
            encrypted.keyFingerprint = LedgerKeyStore.fingerprint(for: key, ledgerID: book.id)
            encrypted.encryptionVersion = LedgerCryptoService.currentEncryptionVersion
            let generated = try CloudRecordMapper.records(for: encrypted, zoneID: zoneID, attachmentFolder: AttachmentStore.folderURL)
            defer { CloudRecordMapper.removeTemporaryAssets(generated) }
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
            // Old, unreferenced purchase items still contain financial payloads and must
            // not be left in plaintext merely because they no longer appear in a header.
            for record in remoteRecords where !generatedIDs.contains(record.recordID) {
                guard let payload = record["payload"] as? Data else { continue }
                let (ciphertext, fingerprint) = try LedgerCryptoService.encryptRecord(payload, ledgerID: book.id, recordType: record.recordType, recordID: record.recordID.recordName, key: key)
                record["ciphertextV1"] = ciphertext as CKRecordValue
                record["keyFingerprint"] = fingerprint as CKRecordValue
                record["encryptionVersion"] = LedgerCryptoService.currentEncryptionVersion as CKRecordValue
                record["payload"] = nil
                updates.append(record)
            }
            var saved: [CKRecord] = []
            for batch in updates.chunked(into: 100) {
                try validateStoredKey()
                let response = try await container.privateCloudDatabase.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                // One atomic record replacement removes plaintext and publishes ciphertext
                // and encrypted assets together. Every per-record failure aborts completion.
                saved += try response.saveResults.values.map { try $0.get() }
                LedgerDiagnostics.security.info("Encryption migration acknowledged records=\(saved.count) total=\(updates.count)")
            }
            try validateStoredKey()
            try await ownerSync.completeMigration(records: saved, book: encrypted, zoneID: zoneID)
            LedgerDiagnostics.security.info("Encryption migration completed records=\(saved.count)")
            return encrypted
        } catch {
            try? await ownerSync.resume()
            LedgerDiagnostics.failure(error, operation: "encryption-migration", logger: LedgerDiagnostics.security)
            throw error
        }
    }

    func postEnrollmentRequest(_ request: FinsyPairingRequest, book: LedgerBook) async throws {
        guard let zoneName = book.cloudZoneName, let owner = book.cloudZoneOwnerName else { return }
        try requireAvailable()
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
        try requireAvailable()
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
                output += try results.map { try $0.1.get() }
            } while cursor != nil
        }
        return output
    }
}

enum CloudLedgerError: LocalizedError {
    case missingZone, shareUnavailable, migrationInProgress, pendingChanges, missingPendingRecord, unavailableInUnsignedBuild
    var errorDescription: String? {
        switch self {
        case .migrationInProgress: "Encryption migration is still in progress."
        case .pendingChanges: "Some ledger changes have not reached iCloud yet."
        case .missingPendingRecord: "A pending iCloud record could not be loaded from local storage."
        case .missingZone: "This shared ledger is missing its CloudKit zone metadata."
        case .shareUnavailable: "The CloudKit sharing record is unavailable."
        case .unavailableInUnsignedBuild: "Cloud sync requires a signed build with the CloudKit entitlement. Local ledgers remain available."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}
