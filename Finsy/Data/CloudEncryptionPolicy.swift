import Foundation
import CloudKit

struct CloudEncryptionPolicy: Codable, Equatable {
    var required: Bool
    var changedAt: Date

    init(book: LedgerBook) {
        required = book.isEncrypted == true || book.effectiveEncryptionState != .disabled
        changedAt = book.encryptionUpdatedAt ?? .distantPast
    }

    init(record: CKRecord) throws {
        required = record["ciphertextV1"] != nil || record["keyFingerprint"] != nil
        let prefix = "LedgerBook-"
        let ledgerID = UUID(uuidString: String(record.recordID.zoneID.zoneName.dropFirst(prefix.count)))
        do {
            let metadata: CloudBookMetadata? = try CloudRecordMapper.decode(record, ledgerID: ledgerID)
            changedAt = metadata?.encryptionUpdatedAt ?? .distantPast
        } catch let error as LedgerCryptoError {
            // A device without the key must still enforce an encrypted remote root.
            guard required else { throw error }
            changedAt = record["updatedAt"] as? Date ?? .distantPast
        }
    }

    func merged(with incoming: Self) -> Self {
        if incoming.changedAt != changedAt { return incoming.changedAt > changedAt ? incoming : self }
        return incoming.required ? incoming : self
    }
}
