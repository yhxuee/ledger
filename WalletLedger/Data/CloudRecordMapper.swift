import CloudKit
import Foundation

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
}

struct CloudBookMetadata: Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
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
}

enum CloudRecordMapper {
    static func zoneID(for bookID: UUID, ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "LedgerBook-\(bookID.uuidString)", ownerName: ownerName)
    }

    static func records(for book: LedgerBook, zoneID: CKRecordZone.ID? = nil, attachmentFolder: URL? = nil) throws -> [CKRecord] {
        let zone = zoneID ?? self.zoneID(for: book.id)
        var records: [CKRecord] = []
        records.append(try record(type: CloudRecordType.book, name: "book-\(book.id.uuidString)", value: CloudBookMetadata(id: book.id, name: book.name, createdAt: book.createdAt, updatedAt: book.updatedAt, schemaVersion: book.state.schemaVersion), zoneID: zone, updatedAt: book.updatedAt, version: 1))
        records += try book.state.accounts.map { try record(type: CloudRecordType.account, name: "account-\($0.id.uuidString)", value: $0, zoneID: zone, updatedAt: $0.updatedAt, version: $0.version) }
        records += try book.state.transactions.map { try record(type: CloudRecordType.transaction, name: "transaction-\($0.id.uuidString)", value: $0, zoneID: zone, updatedAt: $0.updatedAt, version: $0.version) }
        records += try book.state.categories.map { try record(type: CloudRecordType.category, name: "category-\($0.id.rawValue)", value: $0, zoneID: zone, updatedAt: book.state.settings.updatedAt, version: 1) }
        records.append(try record(type: CloudRecordType.settings, name: "settings", value: book.state.settings, zoneID: zone, updatedAt: book.state.settings.updatedAt, version: 1))
        records.append(try record(type: CloudRecordType.budget, name: "budget", value: book.state.settings.budgetPlan, zoneID: zone, updatedAt: book.state.settings.updatedAt, version: 1))
        records += try (book.state.recurringRules ?? []).map { try record(type: CloudRecordType.recurring, name: "recurring-\($0.id.uuidString)", value: $0, zoneID: zone, updatedAt: $0.updatedAt, version: 1) }
        for session in book.state.purchaseSessions ?? [] {
            let header = CloudPurchaseSessionHeader(id: session.id, ledgerBookID: session.ledgerBookID, name: session.name, status: session.status, sections: session.sections, createdAt: session.createdAt, startedAt: session.startedAt, completedAt: session.completedAt, receiptAttachmentID: session.receiptAttachmentID)
            let sessionRecord = try record(type: CloudRecordType.purchaseSession, name: "purchase-\(session.id.uuidString)", value: header, zoneID: zone, updatedAt: session.completedAt ?? session.startedAt ?? session.createdAt, version: 1)
            if let identifier = session.receiptAttachmentID, let folder = attachmentFolder {
                let file = folder.appending(path: identifier)
                if FileManager.default.fileExists(atPath: file.path) { sessionRecord["receipt"] = CKAsset(fileURL: file) }
            }
            records.append(sessionRecord)
            records += try session.items.map { try record(type: CloudRecordType.purchaseItem, name: "purchase-item-\($0.id.uuidString)", value: $0, zoneID: zone, updatedAt: $0.completedAt ?? session.createdAt, version: 1, parentName: sessionRecord.recordID.recordName) }
        }
        return records
    }

    static func decodeBook(from records: [CKRecord], participant: Bool, attachmentFolder: URL? = nil) throws -> LedgerBook {
        guard let metadataRecord = records.first(where: { $0.recordType == CloudRecordType.book }), let metadata: CloudBookMetadata = try decode(metadataRecord) else { throw CloudMappingError.missingBook }
        let accounts: [LedgerAccount] = try decodeAll(CloudRecordType.account, records)
        let transactions: [LedgerTransaction] = try decodeAll(CloudRecordType.transaction, records)
        let categories: [LedgerCategory] = try decodeAll(CloudRecordType.category, records)
        guard let settingsRecord = records.first(where: { $0.recordType == CloudRecordType.settings }), var settings: LedgerSettings = try decode(settingsRecord) else { throw CloudMappingError.missingSettings }
        if let budgetRecord = records.first(where: { $0.recordType == CloudRecordType.budget }), let budget: BudgetPlan = try decode(budgetRecord) { settings.budgetPlan = budget }
        let recurring: [RecurringRule] = try decodeAll(CloudRecordType.recurring, records)
        let headers: [CloudPurchaseSessionHeader] = try decodeAll(CloudRecordType.purchaseSession, records)
        let allItems: [PurchaseItem] = try decodeAll(CloudRecordType.purchaseItem, records)
        let itemRecordByID: [UUID: CKRecord] = Dictionary(uniqueKeysWithValues: records.filter { $0.recordType == CloudRecordType.purchaseItem }.compactMap { record -> (UUID, CKRecord)? in
            guard let value: PurchaseItem = try? decode(record) else { return nil }; return (value.id, record)
        })
        let sessions = headers.map { header in
            let items = allItems.filter { item in
                guard let record = itemRecordByID[item.id], let parent = record.parent else { return false }
                return parent.recordID.recordName == "purchase-\(header.id.uuidString)"
            }
            var receiptIdentifier = header.receiptAttachmentID
            if let attachmentFolder,
               let sessionRecord = records.first(where: { $0.recordType == CloudRecordType.purchaseSession && $0.recordID.recordName == "purchase-\(header.id.uuidString)" }),
               let asset = sessionRecord["receipt"] as? CKAsset,
               let sourceURL = asset.fileURL {
                let identifier = header.receiptAttachmentID ?? "receipt-cloud-\(header.id.uuidString).jpg"
                let destination = attachmentFolder.appending(path: identifier)
                try? FileManager.default.createDirectory(at: attachmentFolder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.copyItem(at: sourceURL, to: destination) }
                if FileManager.default.fileExists(atPath: destination.path) { receiptIdentifier = identifier }
            }
            return PurchaseSession(id: header.id, ledgerBookID: header.ledgerBookID, name: header.name, status: header.status, sections: header.sections, items: items, createdAt: header.createdAt, startedAt: header.startedAt, completedAt: header.completedAt, receiptAttachmentID: receiptIdentifier)
        }
        let state = LedgerState(schemaVersion: metadata.schemaVersion, accounts: accounts, transactions: transactions, categories: categories, settings: settings, recurringRules: recurring, purchaseSessions: sessions)
        try BackupCodec.validate(state)
        return LedgerBook(id: metadata.id, name: metadata.name, state: state, createdAt: metadata.createdAt, updatedAt: metadata.updatedAt, storageKind: participant ? .cloudParticipant : .cloudOwner, cloudZoneName: metadataRecord.recordID.zoneID.zoneName, cloudZoneOwnerName: metadataRecord.recordID.zoneID.ownerName)
    }

    private static func record<T: Encodable>(type: String, name: String, value: T, zoneID: CKRecordZone.ID, updatedAt: Date, version: Int, parentName: String? = nil) throws -> CKRecord {
        let result = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        result["payload"] = try BackupCodec.encoder().encode(value) as CKRecordValue
        result["updatedAt"] = updatedAt as CKRecordValue
        result["version"] = version as CKRecordValue
        if let parentName { result.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: parentName, zoneID: zoneID), action: .none) }
        return result
    }

    static func decode<T: Decodable>(_ record: CKRecord) throws -> T? {
        guard let data = record["payload"] as? Data else { return nil }
        return try BackupCodec.decoder().decode(T.self, from: data)
    }

    private static func decodeAll<T: Decodable>(_ type: String, _ records: [CKRecord]) throws -> [T] {
        try records.filter { $0.recordType == type }.compactMap { try decode($0) }
    }
}

enum CloudMappingError: LocalizedError {
    case missingBook, missingSettings
    var errorDescription: String? { switch self { case .missingBook: "The shared ledger metadata is missing."; case .missingSettings: "The shared ledger settings are missing." } }
}
