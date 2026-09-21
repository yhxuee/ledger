import Foundation
import CryptoKit

enum CloudRecordSelection {
    /// Compare compact digests before building records or encrypting any attachments.
    static func fingerprints(for book: LedgerBook) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let security = "\(book.isEncrypted == true)|\(book.effectiveEncryptionState.rawValue)|\(book.keyFingerprint ?? "")"
        func digest<T: Encodable>(_ value: T, canonicalCollections: Bool = false) throws -> Data {
            var hash = SHA256()
            hash.update(data: Data(security.utf8))
            let encoded = try encoder.encode(value)
            if canonicalCollections {
                let object = try JSONSerialization.jsonObject(with: encoded)
                hash.update(data: try JSONSerialization.data(withJSONObject: canonicalize(object), options: [.sortedKeys]))
            } else { hash.update(data: encoded) }
            return Data(hash.finalize())
        }
        var result = ["book-\(book.id.uuidString)": try digest(CloudBookMetadata(id: book.id, name: book.name, createdAt: book.createdAt, updatedAt: book.updatedAt, schemaVersion: book.state.schemaVersion, encryptionUpdatedAt: book.encryptionUpdatedAt))]
        for value in book.state.accounts { result["account-\(value.id)"] = try digest(value) }
        for value in book.state.transactions { result["transaction-\(value.id)"] = try digest(value) }
        for value in book.state.categories { result["category-\(value.id.rawValue)"] = try digest(value) }
        result["settings"] = try digest(book.state.settings, canonicalCollections: true)
        result["budget"] = try digest(book.state.settings.budgetPlan, canonicalCollections: true)
        for value in book.state.recurringRules ?? [] { result["recurring-\(value.id)"] = try digest(value) }
        for value in book.state.purchaseSessions ?? [] {
            result["purchase-\(value.id)"] = try digest(value)
            for item in value.items { result["purchase-item-\(item.id)"] = try digest(item) }
        }
        return result
    }
    private static func canonicalize(_ object: Any, field: String = "") -> Any {
        if let object = object as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, item in
                result[item.key] = canonicalize(item.value, field: item.key)
            }
        }
        guard let array = object as? [Any] else { return object }
        if field == "archivedCategoryIDs", let values = array as? [String] { return values.sorted() }
        // Codable dictionaries with non-String keys encode as alternating key/value arrays.
        let dictionaryFields: Set<String> = ["categoryRates", "categoryAllocations", "accountAllocations", "defaultExpenseAccountByCategory", "rates"]
        if dictionaryFields.contains(field), array.count.isMultiple(of: 2) {
            let pairs = stride(from: 0, to: array.count, by: 2).map { (array[$0], array[$0 + 1]) }
            return pairs.sorted { String(describing: $0.0) < String(describing: $1.0) }.flatMap { [canonicalize($0.0), canonicalize($0.1)] }
        }
        return array.map { canonicalize($0) }
    }

}
