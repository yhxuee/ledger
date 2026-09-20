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
    static func zoneID(for bookID: UUID, ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "LedgerBook-\(bookID.uuidString)", ownerName: ownerName)
    }

    static func records(for book: LedgerBook, zoneID: CKRecordZone.ID? = nil, attachmentFolder: URL? = nil) throws -> [CKRecord] {
        let zone = zoneID ?? self.zoneID(for: book.id)
        let isEncrypted = (book.effectiveEncryptionState == .enabled)
        let key: SymmetricKey? = isEncrypted ? try LedgerKeyStore.loadKey(for: book.id) : nil

        var records: [CKRecord] = []
        let metadata = CloudBookMetadata(
            id: book.id,
            name: book.name,
            createdAt: book.createdAt,
            updatedAt: book.updatedAt,
            schemaVersion: book.state.schemaVersion,
            isEncrypted: isEncrypted ? true : nil,
            encryptionVersion: isEncrypted ? LedgerCryptoService.currentEncryptionVersion : nil,
            keyFingerprint: key.map { LedgerKeyStore.fingerprint(for: $0, ledgerID: book.id) }
        )

        records.append(try record(
            type: CloudRecordType.book,
            name: "book-\(book.id.uuidString)",
            value: metadata,
            zoneID: zone,
            updatedAt: book.updatedAt,
            version: 1,
            ledgerID: book.id,
            key: key
        ))

        records += try book.state.accounts.map {
            try record(
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

        for transaction in book.state.transactions {
            let transactionRecord = try record(
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
                let file = folder.appending(path: identifier)
                if FileManager.default.fileExists(atPath: file.path) {
                    if let key {
                        let fileData = try Data(contentsOf: file)
                        let encryptedData = try LedgerCryptoService.encryptAttachment(
                            fileData,
                            ledgerID: book.id,
                            attachmentID: identifier,
                            associatedID: transaction.id.uuidString,
                            key: key
                        )
                        let tempFile = FileManager.default.temporaryDirectory.appending(path: "enc-\(identifier)")
                        try encryptedData.write(to: tempFile, options: .atomic)
                        transactionRecord["noteAttachment"] = CKAsset(fileURL: tempFile)
                    } else {
                        transactionRecord["noteAttachment"] = CKAsset(fileURL: file)
                    }
                }
            }
            records.append(transactionRecord)
        }

        records += try book.state.categories.map {
            try record(
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

        records.append(try record(
            type: CloudRecordType.settings,
            name: "settings",
            value: book.state.settings,
            zoneID: zone,
            updatedAt: book.state.settings.updatedAt,
            version: 1,
            ledgerID: book.id,
            key: key
        ))

        records.append(try record(
            type: CloudRecordType.budget,
            name: "budget",
            value: book.state.settings.budgetPlan,
            zoneID: zone,
            updatedAt: book.state.settings.updatedAt,
            version: 1,
            ledgerID: book.id,
            key: key
        ))

        records += try (book.state.recurringRules ?? []).map {
            try record(
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

        for session in book.state.purchaseSessions ?? [] {
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
            let sessionRecord = try record(
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
                let file = folder.appending(path: identifier)
                if FileManager.default.fileExists(atPath: file.path) {
                    if let key {
                        let fileData = try Data(contentsOf: file)
                        let encryptedData = try LedgerCryptoService.encryptAttachment(
                            fileData,
                            ledgerID: book.id,
                            attachmentID: identifier,
                            associatedID: session.id.uuidString,
                            key: key
                        )
                        let tempFile = FileManager.default.temporaryDirectory.appending(path: "enc-\(identifier)")
                        try encryptedData.write(to: tempFile, options: .atomic)
                        sessionRecord["receipt"] = CKAsset(fileURL: tempFile)
                    } else {
                        sessionRecord["receipt"] = CKAsset(fileURL: file)
                    }
                }
            }
            records.append(sessionRecord)

            records += try session.items.map {
                try record(
                    type: CloudRecordType.purchaseItem,
                    name: "purchase-item-\($0.id.uuidString)",
                    value: $0,
                    zoneID: zone,
                    updatedAt: session.updatedAt ?? $0.completedAt ?? session.createdAt,
                    version: 1,
                    parentName: sessionRecord.recordID.recordName,
                    ledgerID: book.id,
                    key: key
                )
            }
        }
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
                return UUID(uuidString: idStr)
            }
            return nil
        }()

        let isRecordEncrypted = (metadataRecord["ciphertextV1"] as? Data != nil) || (metadataRecord["keyFingerprint"] as? String != nil)
        let recordFingerprint = metadataRecord["keyFingerprint"] as? String

        if isRecordEncrypted {
            guard let bookID = inferredID else {
                throw CloudMappingError.missingBook
            }
            let localKey = try? LedgerKeyStore.loadKey(for: bookID)
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
                    encryptionVersion: metadataRecord["encryptionVersion"] as? Int ?? 1,
                    keyFingerprint: recordFingerprint,
                    encryptionState: .authorizationRequired
                )
            }
        }

        let metadata: CloudBookMetadata
        if let decoded: CloudBookMetadata = try decode(metadataRecord, ledgerID: inferredID) {
            metadata = decoded
        } else {
            throw CloudMappingError.missingBook
        }

        let bookID = metadata.id
        let accounts: [LedgerAccount] = try decodeAll(CloudRecordType.account, records, ledgerID: bookID)
        var transactions: [LedgerTransaction] = try decodeAll(CloudRecordType.transaction, records, ledgerID: bookID)

        if let attachmentFolder {
            let key = try? LedgerKeyStore.loadKey(for: bookID)
            let recordsByID = Dictionary(uniqueKeysWithValues: records.filter { $0.recordType == CloudRecordType.transaction }.compactMap { record -> (UUID, CKRecord)? in
                guard let value: LedgerTransaction = try? decode(record, ledgerID: bookID) else { return nil }
                return (value.id, record)
            })

            for index in transactions.indices {
                guard let record = recordsByID[transactions[index].id],
                      let asset = record["noteAttachment"] as? CKAsset,
                      let sourceURL = asset.fileURL else { continue }
                let identifier = transactions[index].noteAttachmentID ?? "transaction-note-cloud-\(transactions[index].id.uuidString).jpg"
                let destination = attachmentFolder.appending(path: identifier)
                try? FileManager.default.createDirectory(at: attachmentFolder, withIntermediateDirectories: true)

                if let assetData = try? Data(contentsOf: sourceURL) {
                    if let key, record["ciphertextV1"] != nil {
                        if let decrypted = try? LedgerCryptoService.decryptAttachment(
                            assetData,
                            ledgerID: bookID,
                            attachmentID: identifier,
                            associatedID: transactions[index].id.uuidString,
                            key: key
                        ) {
                            try? decrypted.write(to: destination, options: .atomic)
                        }
                    } else {
                        try? assetData.write(to: destination, options: .atomic)
                    }
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    transactions[index].noteAttachmentID = identifier
                }
            }
        }

        let categories: [LedgerCategory] = try decodeAll(CloudRecordType.category, records, ledgerID: bookID)
        guard let settingsRecord = records.first(where: { $0.recordType == CloudRecordType.settings }),
              var settings: LedgerSettings = try decode(settingsRecord, ledgerID: bookID) else {
            throw CloudMappingError.missingSettings
        }
        if let budgetRecord = records.first(where: { $0.recordType == CloudRecordType.budget }),
           let budget: BudgetPlan = try decode(budgetRecord, ledgerID: bookID) {
            settings.budgetPlan = budget
        }

        let recurring: [RecurringRule] = try decodeAll(CloudRecordType.recurring, records, ledgerID: bookID)
        let headers: [CloudPurchaseSessionHeader] = try decodeAll(CloudRecordType.purchaseSession, records, ledgerID: bookID)
        let allItems: [PurchaseItem] = try decodeAll(CloudRecordType.purchaseItem, records, ledgerID: bookID)
        let itemRecordByID: [UUID: CKRecord] = Dictionary(uniqueKeysWithValues: records.filter { $0.recordType == CloudRecordType.purchaseItem }.compactMap { record -> (UUID, CKRecord)? in
            guard let value: PurchaseItem = try? decode(record, ledgerID: bookID) else { return nil }
            return (value.id, record)
        })

        let sessions = headers.map { header in
            let items = allItems.filter { item in
                guard let record = itemRecordByID[item.id], let parent = record.parent else { return false }
                return parent.recordID.recordName == "purchase-\(header.id.uuidString)" && (header.itemIDs?.contains(item.id) ?? true)
            }
            var receiptIdentifier = header.receiptAttachmentID
            if let attachmentFolder,
               let sessionRecord = records.first(where: { $0.recordType == CloudRecordType.purchaseSession && $0.recordID.recordName == "purchase-\(header.id.uuidString)" }),
               let asset = sessionRecord["receipt"] as? CKAsset,
               let sourceURL = asset.fileURL {
                let identifier = header.receiptAttachmentID ?? "receipt-cloud-\(header.id.uuidString).jpg"
                let destination = attachmentFolder.appending(path: identifier)
                try? FileManager.default.createDirectory(at: attachmentFolder, withIntermediateDirectories: true)
                if let assetData = try? Data(contentsOf: sourceURL) {
                    let key = try? LedgerKeyStore.loadKey(for: bookID)
                    if let key, sessionRecord["ciphertextV1"] != nil {
                        if let decrypted = try? LedgerCryptoService.decryptAttachment(
                            assetData,
                            ledgerID: bookID,
                            attachmentID: identifier,
                            associatedID: header.id.uuidString,
                            key: key
                        ) {
                            try? decrypted.write(to: destination, options: .atomic)
                        }
                    } else {
                        try? assetData.write(to: destination, options: .atomic)
                    }
                }
                if FileManager.default.fileExists(atPath: destination.path) { receiptIdentifier = identifier }
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
            encryptionState: isRecordEncrypted ? .enabled : .disabled
        )
    }

    private static func record<T: Encodable>(
        type: String,
        name: String,
        value: T,
        zoneID: CKRecordZone.ID,
        updatedAt: Date,
        version: Int,
        parentName: String? = nil,
        ledgerID: UUID,
        key: SymmetricKey?
    ) throws -> CKRecord {
        let result = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        let encodedData = try BackupCodec.encoder().encode(value)

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
        if let parentName {
            result.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: parentName, zoneID: zoneID), action: .none)
        }
        return result
    }

    static func decode<T: Decodable>(_ record: CKRecord, ledgerID: UUID? = nil) throws -> T? {
        if let ciphertext = record["ciphertextV1"] as? Data {
            guard let bookID = ledgerID else {
                throw LedgerCryptoError.authorizationRequired(ledgerID: UUID(), fingerprint: record["keyFingerprint"] as? String)
            }
            guard let key = try LedgerKeyStore.loadKey(for: bookID) else {
                throw LedgerCryptoError.authorizationRequired(ledgerID: bookID, fingerprint: record["keyFingerprint"] as? String)
            }
            let version = record["encryptionVersion"] as? Int ?? 1
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
            return try BackupCodec.decoder().decode(T.self, from: decryptedData)
        }

        guard let data = record["payload"] as? Data else { return nil }
        return try BackupCodec.decoder().decode(T.self, from: data)
    }

    private static func decodeAll<T: Decodable>(_ type: String, _ records: [CKRecord], ledgerID: UUID? = nil) throws -> [T] {
        try records.filter { $0.recordType == type }.compactMap { try decode($0, ledgerID: ledgerID) }
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
