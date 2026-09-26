import CloudKit
import Foundation
import CryptoKit

enum CloudRecordType {
    static let book = "LedgerBook"
    static let account = "LedgerAccount"
    static let transaction = "LedgerTransaction"
    static let category = "LedgerCategory"
    static let settings = "LedgerSettings"
    static let budget = "BudgetPlan"
    static let recurring = "RecurringRule"
    static let purchaseSession = "PurchaseSession"
    static let purchaseItem = "PurchaseItem"
    static let enrollmentRequest = "DeviceEnrollmentRequest"
    static let keyEnvelope = "LedgerKeyEnvelope"
}

struct CloudBookMetadata: Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
    var isEncrypted: Bool? = nil
    var encryptionVersion: Int? = nil
    var keyFingerprint: String? = nil
    var encryptionUpdatedAt: Date? = nil
}

struct CloudPurchaseSessionHeader: Codable, Hashable {
    var id: UUID
    var ledgerBookID: UUID
    var name: String
    var status: PurchaseSessionStatus
    var sections: [PurchaseCategorySection]
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var receiptAttachmentID: String?
    var currency: CurrencyCode? = nil
    var accountID: UUID? = nil
    var updatedAt: Date? = nil
    var itemIDs: [UUID]? = nil
}

enum CloudRecordMapper {
    static func removeTemporaryAssets(_ records: [CKRecord]) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        for record in records {
            for field in ["receipt", "noteAttachment"] {
                guard let asset = record[field] as? CKAsset, let url = asset.fileURL,
                      url.deletingLastPathComponent().standardizedFileURL == temporary,
                      url.lastPathComponent.hasPrefix("enc-") else { continue }
                do { try FileManager.default.removeItem(at: url) }
                catch { LedgerDiagnostics.failure(error, operation: "encrypted-asset-cleanup", logger: LedgerDiagnostics.security) }
            }
        }
    }
    static func encryptionKey(for book: LedgerBook) throws -> SymmetricKey? {
        guard book.effectiveEncryptionState != .authorizationRequired else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: book.keyFingerprint)
        }
        let required = book.isEncrypted == true || book.effectiveEncryptionState != .disabled
        guard required else { return nil }
        guard let key = try LedgerKeyStore.loadKey(for: book.id, expectedFingerprint: book.keyFingerprint) else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: book.keyFingerprint)
        }
        if let expected = book.keyFingerprint,
           expected.lowercased() != LedgerKeyStore.fingerprint(for: key, ledgerID: book.id).lowercased() {
            throw LedgerCryptoError.authorizationRequired(ledgerID: book.id, fingerprint: expected)
        }
        return key
    }

    static func zoneID(for bookID: UUID, ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "LedgerBook-\(bookID.uuidString)", ownerName: ownerName)
    }

    static func records(for book: LedgerBook, zoneID: CKRecordZone.ID? = nil, attachmentFolder: URL? = nil, recordNames: Set<String>? = nil) throws -> [CKRecord] {
        let zone = zoneID ?? self.zoneID(for: book.id)
        let key = try encryptionKey(for: book)
        let wireEncoder = JSONEncoder()
        wireEncoder.dateEncodingStrategy = .iso8601
        wireEncoder.outputFormatting = [.withoutEscapingSlashes]
        let isEncrypted = key != nil

        var records: [CKRecord] = []
        var completed = false
        defer { if !completed { removeTemporaryAssets(records) } }
        let metadata = CloudBookMetadata(
            id: book.id,
            name: book.name,
            createdAt: book.createdAt,
            updatedAt: book.updatedAt,
            schemaVersion: book.state.schemaVersion,
            isEncrypted: isEncrypted ? true : nil,
            encryptionVersion: isEncrypted ? LedgerCryptoService.currentEncryptionVersion : nil,
            keyFingerprint: key.map { LedgerKeyStore.fingerprint(for: $0, ledgerID: book.id) },
            encryptionUpdatedAt: book.encryptionUpdatedAt
        )

        if recordNames?.contains("book-\(book.id.uuidString)") ?? true {
            records.append(try record(encoder: wireEncoder,
                type: CloudRecordType.book,
                name: "book-\(book.id.uuidString)",
                value: metadata,
                zoneID: zone,
                updatedAt: book.updatedAt,
                version: 1,
                ledgerID: book.id,
                key: key
            ))
        }
        records += try book.state.accounts.filter { recordNames?.contains("account-\($0.id.uuidString)") ?? true }.map {
            try record(encoder: wireEncoder,
                type: CloudRecordType.account,
                name: "account-\($0.id.uuidString)",
                value: $0,
                zoneID: zone,
                updatedAt: $0.updatedAt,
                version: $0.version,
                ledgerID: book.id,
                key: key
            )
        }

        for transaction in book.state.transactions where recordNames?.contains("transaction-\(transaction.id.uuidString)") ?? true {
            let transactionRecord = try record(encoder: wireEncoder,
                type: CloudRecordType.transaction,
                name: "transaction-\(transaction.id.uuidString)",
                value: transaction,
                zoneID: zone,
                updatedAt: transaction.updatedAt,
                version: transaction.version,
                ledgerID: book.id,
                key: key
            )

            if let identifier = transaction.noteAttachmentID, let folder = attachmentFolder {
                let file = try AttachmentPath.url(identifier, in: folder)
                if FileManager.default.fileExists(atPath: file.path) {
                    if let key {
                        let fileData = try AttachmentStore.plaintextData(at: file)
                        let encryptedData = try LedgerCryptoService.encryptAttachment(
                            fileData,
                            ledgerID: book.id,
                            attachmentID: identifier,
                            associatedID: transaction.id.uuidString,
                            key: key
                        )
                        let tempFile = FileManager.default.temporaryDirectory.appending(path: "enc-\(UUID().uuidString)-\(identifier)")
                        try encryptedData.write(to: tempFile, options: .atomic)
                        transactionRecord["noteAttachment"] = CKAsset(fileURL: tempFile)
                    } else {
                        transactionRecord["noteAttachment"] = CKAsset(fileURL: file)
                    }
                }
            }
            records.append(transactionRecord)
        }

        records += try book.state.categories.filter { recordNames?.contains("category-\($0.id.rawValue)") ?? true }.map {
            try record(encoder: wireEncoder,
                type: CloudRecordType.category,
                name: "category-\($0.id.rawValue)",
                value: $0,
                zoneID: zone,
                updatedAt: book.state.settings.updatedAt,
                version: 1,
                ledgerID: book.id,
                key: key
            )
        }

        if recordNames?.contains("settings") ?? true {
            records.append(try record(encoder: wireEncoder,
                type: CloudRecordType.settings,
                name: "settings",
                value: book.state.settings,
                zoneID: zone,
                updatedAt: book.state.settings.updatedAt,
                version: 1,
                ledgerID: book.id,
                key: key
            ))
        }
        if recordNames?.contains("budget") ?? true {
            records.append(try record(encoder: wireEncoder,
                type: CloudRecordType.budget,
                name: "budget",
                value: book.state.settings.budgetPlan,
                zoneID: zone,
                updatedAt: book.state.settings.updatedAt,
                version: 1,
                ledgerID: book.id,
                key: key
            ))
        }
        records += try (book.state.recurringRules ?? []).filter { recordNames?.contains("recurring-\($0.id.uuidString)") ?? true }.map {
            try record(encoder: wireEncoder,
                type: CloudRecordType.recurring,
                name: "recurring-\($0.id.uuidString)",
                value: $0,
                zoneID: zone,
                updatedAt: $0.updatedAt,
                version: 1,
                ledgerID: book.id,
                key: key
            )
        }

        for session in book.state.purchaseSessions ?? [] where recordNames?.contains("purchase-\(session.id.uuidString)") ?? true {
            let header = CloudPurchaseSessionHeader(
                id: session.id,
                ledgerBookID: session.ledgerBookID,
                name: session.name,
                status: session.status,
                sections: session.sections,
                createdAt: session.createdAt,
                startedAt: session.startedAt,
                completedAt: session.completedAt,
                receiptAttachmentID: session.receiptAttachmentID,
                currency: session.currency,
                accountID: session.accountID,
                updatedAt: session.updatedAt,
                itemIDs: session.items.map(\.id)
            )
            let sessionRecord = try record(encoder: wireEncoder,
                type: CloudRecordType.purchaseSession,
                name: "purchase-\(session.id.uuidString)",
                value: header,
                zoneID: zone,
                updatedAt: session.updatedAt ?? session.completedAt ?? session.startedAt ?? session.createdAt,
                version: 1,
                ledgerID: book.id,
                key: key
            )

            if let identifier = session.receiptAttachmentID, let folder = attachmentFolder {
                let file = try AttachmentPath.url(identifier, in: folder)
                if FileManager.default.fileExists(atPath: file.path) {
                    if let key {
                        let fileData = try AttachmentStore.plaintextData(at: file)
                        let encryptedData = try LedgerCryptoService.encryptAttachment(
                            fileData,
                            ledgerID: book.id,
                            attachmentID: identifier,
                            associatedID: session.id.uuidString,
                            key: key
                        )
                        let tempFile = FileManager.default.temporaryDirectory.appending(path: "enc-\(UUID().uuidString)-\(identifier)")
                        try encryptedData.write(to: tempFile, options: .atomic)
                        sessionRecord["receipt"] = CKAsset(fileURL: tempFile)
                    } else {
                        sessionRecord["receipt"] = CKAsset(fileURL: file)
                    }
                }
            }
            records.append(sessionRecord)

            records += try session.items.map {
                try record(encoder: wireEncoder,
                    type: CloudRecordType.purchaseItem,
                    name: "purchase-item-\($0.id.uuidString)",
                    value: $0,
                    zoneID: zone,
                    updatedAt: session.updatedAt ?? $0.completedAt ?? session.createdAt,
                    version: 1,
                    ledgerID: book.id,
                    key: key
                )
            }
        }
        completed = true
        return records
    }

    static func decodeBook(from records: [CKRecord], participant: Bool, attachmentFolder: URL? = nil) throws -> LedgerBook {
        guard let metadataRecord = records.first(where: { $0.recordType == CloudRecordType.book }) else {
            throw CloudMappingError.missingBook
        }

        // Infer ledger ID from zone name or record name if needed
        let zoneName = metadataRecord.recordID.zoneID.zoneName
        let inferredID: UUID? = {
            if zoneName.hasPrefix("LedgerBook-") {
                let idStr = String(zoneName.dropFirst("LedgerBook-".count))
                if let uuid = UUID(uuidString: idStr) { return uuid }
            }
            if metadataRecord.recordID.recordName.hasPrefix("book-") {
                let idStr = String(metadataRecord.recordID.recordName.dropFirst("book-".count))
                if let uuid = UUID(uuidString: idStr) { return uuid }
            }
            return nil
        }()

        let isRecordEncrypted = (metadataRecord["ciphertextV1"] as? Data != nil) || (metadataRecord["keyFingerprint"] as? String != nil)
        let recordFingerprint = metadataRecord["keyFingerprint"] as? String

        let batchDecoder = BackupCodec.decoder()
        let batchKey: SymmetricKey? = inferredID.flatMap { id in
            LedgerDeviceAuthorization.isRevoked(id) ? nil : try? LedgerKeyStore.loadKey(for: id, expectedFingerprint: recordFingerprint)
        }
        if isRecordEncrypted {
            guard let bookID = inferredID else {
                throw CloudMappingError.missingBook
            }
            let localKey = batchKey
            let localFp = localKey.map { LedgerKeyStore.fingerprint(for: $0, ledgerID: bookID) }

            // If key is missing or fingerprint mismatches, return a locked book in authorizationRequired state
            if localKey == nil || (recordFingerprint != nil && recordFingerprint?.lowercased() != localFp?.lowercased()) {
                let initial = SeedData.makeProductionEmpty()
                return LedgerBook(
                    id: bookID,
                    name: "Encrypted Ledger",
                    state: initial,
                    createdAt: metadataRecord.creationDate ?? .now,
                    updatedAt: (metadataRecord["updatedAt"] as? Date) ?? .now,
                    storageKind: participant ? .cloudParticipant : .cloudOwner,
                    cloudZoneName: metadataRecord.recordID.zoneID.zoneName,
                    cloudZoneOwnerName: metadataRecord.recordID.zoneID.ownerName,
                    isEncrypted: true,
                    encryptionVersion: (metadataRecord["encryptionVersion"] as? Int) ?? 1,
                    keyFingerprint: recordFingerprint,
                    encryptionState: .authorizationRequired
                )
            }
        }

        let metadata: CloudBookMetadata
        if let decoded: CloudBookMetadata = try decode(metadataRecord, ledgerID: inferredID, authorizedKey: batchKey, decoder: batchDecoder) {
            metadata = decoded
        } else {
            throw CloudMappingError.missingBook
        }

        let bookID = metadata.id
        let accounts: [LedgerAccount] = try decodeAll(CloudRecordType.account, records, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder)
        var transactions: [LedgerTransaction] = try decodeAll(CloudRecordType.transaction, records, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder)
        var attachmentWrites: [(record: CKRecord, source: URL, destination: URL, identifier: String, associatedID: String)] = []

        if let attachmentFolder {
            let recordsByName = Dictionary(grouping: records, by: { $0.recordID.recordName })
            for index in transactions.indices {
                guard let record = recordsByName["transaction-\(transactions[index].id.uuidString)"]?.first,
                      let asset = record["noteAttachment"] as? CKAsset,
                      let source = asset.fileURL else { continue }
                let identifier = transactions[index].noteAttachmentID ?? "transaction-note-cloud-\(transactions[index].id.uuidString).jpg"
                let destination = try AttachmentPath.url(identifier, in: attachmentFolder)
                attachmentWrites.append((record, source, destination, identifier, transactions[index].id.uuidString))
                transactions[index].noteAttachmentID = identifier
            }
        }

        let categories: [LedgerCategory] = try decodeAll(CloudRecordType.category, records, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder)
        guard let settingsRecord = records.first(where: { $0.recordType == CloudRecordType.settings }),
              var settings: LedgerSettings = try decode(settingsRecord, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder) else {
            throw CloudMappingError.missingSettings
        }
        if let budgetRecord = records.first(where: { $0.recordType == CloudRecordType.budget }),
           let budget: BudgetPlan = try decode(budgetRecord, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder) {
            settings.budgetPlan = budget
        }

        let recurring: [RecurringRule] = try decodeAll(CloudRecordType.recurring, records, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder)
        let headers: [CloudPurchaseSessionHeader] = try decodeAll(CloudRecordType.purchaseSession, records, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder)
        var allItems: [PurchaseItem] = []
        var itemRecordByID: [UUID: CKRecord] = [:]
        for record in records where record.recordType == CloudRecordType.purchaseItem {
            guard let value: PurchaseItem = try decode(record, ledgerID: bookID, authorizedKey: batchKey, decoder: batchDecoder) else { continue }
            guard itemRecordByID.updateValue(record, forKey: value.id) == nil else { throw BackupError.duplicateID("purchase item") }
            allItems.append(value)
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        let itemsByParent = Dictionary(grouping: allItems, by: { itemRecordByID[$0.id]?.parent?.recordID.recordName ?? "" })
        let sessions = try headers.map { header in
            let sessionName = "purchase-\(header.id.uuidString)"
            // Zone-wide shares do not use CloudKit parent chains. Current headers
            // carry item IDs; retain parent-based decoding for older saved records.
            let items: [PurchaseItem]
            if let itemIDs = header.itemIDs {
                items = itemIDs.compactMap { id in
                    guard let item = itemsByID[id] else { return nil }
                    if let parent = itemRecordByID[id]?.parent,
                       parent.recordID.recordName != sessionName { return nil }
                    return item
                }
            } else {
                items = itemsByParent[sessionName] ?? []
            }
            var receiptIdentifier = header.receiptAttachmentID
            if let attachmentFolder,
               let sessionRecord = records.first(where: { $0.recordType == CloudRecordType.purchaseSession && $0.recordID.recordName == "purchase-\(header.id.uuidString)" }),
               let asset = sessionRecord["receipt"] as? CKAsset,
               let sourceURL = asset.fileURL {
                let identifier = header.receiptAttachmentID ?? "receipt-cloud-\(header.id.uuidString).jpg"
                let destination = try AttachmentPath.url(identifier, in: attachmentFolder)
                attachmentWrites.append((sessionRecord, sourceURL, destination, identifier, header.id.uuidString))
                receiptIdentifier = identifier
            }
            return PurchaseSession(
                id: header.id,
                ledgerBookID: header.ledgerBookID,
                name: header.name,
                status: header.status,
                sections: header.sections,
                items: items,
                createdAt: header.createdAt,
                startedAt: header.startedAt,
                completedAt: header.completedAt,
                receiptAttachmentID: receiptIdentifier,
                currency: header.currency ?? settings.baseCurrency,
                accountID: header.accountID,
                updatedAt: header.updatedAt,
                requiresCurrencyMigration: header.currency == nil,
                requiresPaymentMigration: header.currency == nil
            )
        }

        var state = LedgerState(
            schemaVersion: metadata.schemaVersion,
            accounts: accounts,
            transactions: transactions,
            categories: categories,
            settings: settings,
            recurringRules: recurring,
            purchaseSessions: sessions
        )
        PurchaseRules.migrateDevelopmentSessions(in: &state)
        SchemaMigration.normalize(&state)
        try BackupCodec.validate(state)
        let attachmentKey = batchKey
        for write in attachmentWrites {
            var data = try Data(contentsOf: write.source)
            if write.record["ciphertextV1"] != nil {
                guard let attachmentKey else { throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: recordFingerprint) }
                data = try LedgerCryptoService.decryptAttachment(data, ledgerID: bookID, attachmentID: write.identifier, associatedID: write.associatedID, key: attachmentKey)
            }
            try FileManager.default.createDirectory(at: write.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isRecordEncrypted, let attachmentKey, let bookID = inferredID {
                data = try AttachmentStore.protectedData(data, identifier: write.identifier, ledgerID: bookID, key: attachmentKey)
            }
            try data.write(to: write.destination, options: [.atomic, .completeFileProtection])
        }

        return LedgerBook(
            id: metadata.id,
            name: metadata.name,
            state: state,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            storageKind: participant ? .cloudParticipant : .cloudOwner,
            cloudZoneName: metadataRecord.recordID.zoneID.zoneName,
            cloudZoneOwnerName: metadataRecord.recordID.zoneID.ownerName,
            isEncrypted: isRecordEncrypted ? true : nil,
            encryptionVersion: metadataRecord["encryptionVersion"] as? Int,
            keyFingerprint: recordFingerprint,
            encryptionState: isRecordEncrypted ? .enabled : .disabled,
            encryptionUpdatedAt: metadata.encryptionUpdatedAt
        )
    }

    private static func record<T: Encodable>(
        encoder: JSONEncoder,
        type: String,
        name: String,
        value: T,
        zoneID: CKRecordZone.ID,
        updatedAt: Date,
        version: Int,
        ledgerID: UUID,
        key: SymmetricKey?
    ) throws -> CKRecord {
        let result = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        let encodedData = try encoder.encode(value)

        if let key {
            let (ciphertext, fp) = try LedgerCryptoService.encryptRecord(
                encodedData,
                ledgerID: ledgerID,
                recordType: type,
                recordID: name,
                key: key
            )
            result["ciphertextV1"] = ciphertext as CKRecordValue
            result["keyFingerprint"] = fp as CKRecordValue
            result["encryptionVersion"] = LedgerCryptoService.currentEncryptionVersion as CKRecordValue
        } else {
            result["payload"] = encodedData as CKRecordValue
        }

        result["updatedAt"] = updatedAt as CKRecordValue
        result["version"] = version as CKRecordValue
        return result
    }

    static func decode<T: Decodable>(_ record: CKRecord, ledgerID: UUID? = nil, authorizedKey: SymmetricKey? = nil, decoder: JSONDecoder = BackupCodec.decoder()) throws -> T? {
        if let ciphertext = record["ciphertextV1"] as? Data {
            guard let bookID = ledgerID else {
                throw LedgerCryptoError.authorizationRequired(ledgerID: UUID(), fingerprint: record["keyFingerprint"] as? String)
            }
            guard let key = try authorizedKey ?? LedgerKeyStore.loadKey(for: bookID, expectedFingerprint: record["keyFingerprint"] as? String) else {
                throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: record["keyFingerprint"] as? String)
            }
            let version = (record["encryptionVersion"] as? Int) ?? 1
            let expectedFp = record["keyFingerprint"] as? String
            let decryptedData = try LedgerCryptoService.decryptRecord(
                ciphertext,
                ledgerID: bookID,
                recordType: record.recordType,
                recordID: record.recordID.recordName,
                key: key,
                version: version,
                expectedFingerprint: expectedFp
            )
            return try decodePayload(T.self, data: decryptedData, record: record, decoder: decoder)
        }

        guard let data = record["payload"] as? Data else { return nil }
        return try decodePayload(T.self, data: data, record: record, decoder: decoder)
    }

    private static func decodePayload<T: Decodable>(_ type: T.Type, data: Data, record: CKRecord, decoder: JSONDecoder) throws -> T {
        let decoded = try decoder.decode(type, from: data)
        // Legacy payload dates have second precision; CKRecord dates retain the original
        // timestamp. Use them for conflict resolution without changing the wire format.
        guard let updatedAt = record["updatedAt"] as? Date else { return decoded }
        if var value = decoded as? LedgerAccount { value.updatedAt = updatedAt; return (value as? T) ?? decoded }
        if var value = decoded as? LedgerTransaction { value.updatedAt = updatedAt; return (value as? T) ?? decoded }
        if var value = decoded as? LedgerSettings { value.updatedAt = updatedAt; return (value as? T) ?? decoded }
        if var value = decoded as? RecurringRule { value.updatedAt = updatedAt; return (value as? T) ?? decoded }
        if var value = decoded as? CloudBookMetadata { value.updatedAt = updatedAt; return (value as? T) ?? decoded }
        if var value = decoded as? CloudPurchaseSessionHeader { value.updatedAt = updatedAt; return (value as? T) ?? decoded }
        return decoded
    }

    private static func decodeAll<T: Decodable>(_ type: String, _ records: [CKRecord], ledgerID: UUID? = nil, authorizedKey: SymmetricKey? = nil, decoder: JSONDecoder = BackupCodec.decoder()) throws -> [T] {
        try records.filter { $0.recordType == type }.compactMap { try decode($0, ledgerID: ledgerID, authorizedKey: authorizedKey, decoder: decoder) }
    }
}

enum CloudMappingError: LocalizedError {
    case missingBook, missingSettings
    var errorDescription: String? {
        switch self {
        case .missingBook: "The shared ledger metadata is missing."
        case .missingSettings: "The shared ledger settings are missing."
        }
    }
}
