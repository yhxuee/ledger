import Foundation
import CloudKit
import CryptoKit

/// Durable record bodies, change tags and outbox. No whole-ledger in-memory record cache.
final class CloudRecordJournal {
    let database: LedgerDiskDatabase
    let assets: URL

    init(folder: URL) throws {
        database = try LedgerDiskDatabase(url: folder.appending(path: "records.sqlite"))
        assets = folder.appending(path: "Assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.complete])
    }

    static func key(_ id: CKRecord.ID) -> String {
        // Length-delimited components prevent collisions with arbitrary CloudKit names.
        [id.zoneID.ownerName, id.zoneID.zoneName, id.recordName].map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func zoneKey(_ zone: CKRecordZone.ID) -> String {
        // Match key's length-delimited format without creating a CKRecord.ID
        // since CloudKit throws an Objective-C exception for an empty recordName.
        [zone.ownerName, zone.zoneName, ""].map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func zonePrefix(_ zone: CKRecordZone.ID) -> String {
        [zone.ownerName, zone.zoneName].map { "\($0.utf8.count):\($0)" }.joined()
    }

    func record(_ id: CKRecord.ID) throws -> CKRecord? { try record(key: Self.key(id)) }
    func record(key: String) throws -> CKRecord? {
        guard let data = try database.data("records", key) else { return nil }
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else { throw BackupError.invalidFormat }
        return value
    }

    func store(_ input: CKRecord) throws {
        guard let record = input.copy() as? CKRecord else { throw BackupError.invalidFormat }
        // CKAsset URLs from CloudKit and temporary encryption files do not survive relaunches.
        for field in ["receipt", "noteAttachment"] {
            guard let asset = record[field] as? CKAsset, let source = asset.fileURL else { continue }
            if source.deletingLastPathComponent().standardizedFileURL == assets.standardizedFileURL { continue }
            let destination = assets.appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            record[field] = CKAsset(fileURL: destination)
        }
        let assetPaths = ["receipt", "noteAttachment"].compactMap { (record[$0] as? CKAsset)?.fileURL?.path }
        if assetPaths.isEmpty { try database.remove("asset-files", Self.key(record.recordID)) }
        else { try database.put("asset-files", Self.key(record.recordID), JSONEncoder().encode(assetPaths)) }
        try database.put("records", Self.key(record.recordID), NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true))
    }

    func pending(_ id: CKRecord.ID) throws -> Bool { try database.data("outbox", Self.key(id)) != nil }
    func hasPendingChanges() throws -> Bool { try database.hasAny("outbox") || database.hasAny("deletions") }
    func markPending(_ id: CKRecord.ID) throws {
        try database.remove("deletions", Self.key(id))
        try database.put("outbox", Self.key(id), NSKeyedArchiver.archivedData(withRootObject: id, requiringSecureCoding: true))
    }
    func markDeleted(_ id: CKRecord.ID) throws {
        try acknowledge(id)
        try database.put("deletions", Self.key(id), NSKeyedArchiver.archivedData(withRootObject: id, requiringSecureCoding: true))
    }
    func deletionIDs() throws -> [CKRecord.ID] {
        try database.keys("deletions").map { key in
            guard let data = try database.data("deletions", key),
                  let id = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.ID.self, from: data) else { throw BackupError.invalidFormat }
            return id
        }
    }
    func knownLocalIDs(in zone: CKRecordZone.ID) throws -> [CKRecord.ID] {
        let prefix = Self.zonePrefix(zone)
        return try database.keys("fingerprints", prefix: prefix).compactMap { key in
            let suffix = key.dropFirst(prefix.count)
            guard let separator = suffix.firstIndex(of: ":") else { return nil }
            let recordName = String(suffix[suffix.index(after: separator)...])
            guard !recordName.isEmpty else { return nil }
            return CKRecord.ID(recordName: recordName, zoneID: zone)
        }
    }
    func acknowledge(_ id: CKRecord.ID) throws {
        try database.remove("outbox", Self.key(id))
        try database.remove("send-failures", Self.key(id))
    }
    func pendingIDs() throws -> [CKRecord.ID] {
        try database.keys("outbox").map { key in
            guard let data = try database.data("outbox", key),
                  let id = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.ID.self, from: data) else { throw BackupError.invalidFormat }
            return id
        }
    }

    func records(in zone: CKRecordZone.ID) throws -> [CKRecord] {
        // Primary-key prefix bounds the lookup to this zone without retaining records in RAM.
        let prefix = Self.zonePrefix(zone)
        return try database.keys("records", prefix: prefix).compactMap { key in
            guard try database.data("deletions", key) == nil else { return nil }
            return try record(key: key)
        }
    }

    func remove(_ id: CKRecord.ID) throws {
        try database.remove("records", Self.key(id))
        try database.remove("asset-files", Self.key(id))
        try database.remove("deletions", Self.key(id))
        try database.remove("fingerprints", Self.key(id))
        try acknowledge(id)
    }

    func encryptionPolicy(in zone: CKRecordZone.ID) throws -> CloudEncryptionPolicy? {
        let key = Self.key(CKRecord.ID(recordName: "encryption-policy", zoneID: zone))
        guard let data = try database.data("encryption-policy", key) else { return nil }
        return try JSONDecoder().decode(CloudEncryptionPolicy.self, from: data)
    }

    @discardableResult
    func mergeEncryptionPolicy(_ policy: CloudEncryptionPolicy, in zone: CKRecordZone.ID) throws -> CloudEncryptionPolicy {
        let key = Self.key(CKRecord.ID(recordName: "encryption-policy", zoneID: zone))
        let result = try encryptionPolicy(in: zone)?.merged(with: policy) ?? policy
        try database.put("encryption-policy", key, JSONEncoder().encode(result))
        return result
    }

    func removeZone(_ zone: CKRecordZone.ID) throws {
        let prefix = Self.zonePrefix(zone)
        for namespace in ["records", "asset-files", "outbox", "deletions", "fingerprints", "blocked", "remote-deletions", "encryption-policy", "send-failures"] {
            for key in try database.keys(namespace, prefix: prefix) { try database.remove(namespace, key) }
        }
    }

    func pruneAssets() throws {
        var used: Set<URL> = []
        for key in try database.keys("asset-files") {
            guard let data = try database.data("asset-files", key) else { continue }
            for path in try JSONDecoder().decode([String].self, from: data) { used.insert(URL(fileURLWithPath: path).standardizedFileURL) }
        }
        for url in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil) where !used.contains(url.standardizedFileURL) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
