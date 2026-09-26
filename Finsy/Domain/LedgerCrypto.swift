import Foundation
import CryptoKit
import Security

// MARK: - Crypto Errors

enum LedgerCryptoError: LocalizedError {
    case authorizationRequired(ledgerID: UUID, fingerprint: String?)
    case keyNotFound(UUID)
    case fingerprintMismatch(expected: String, actual: String)
    case decryptionFailed
    case pairingExpired
    case invalidProtocolVersion(Int)
    case invalidPublicKey
    case corruptedContainer(String)
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "This device is not authorized to decrypt this ledger. Use a paired device to authorize this device by QR code or secure transfer."
        case .keyNotFound(let id):
            return "No encryption key found for ledger \(id.uuidString)."
        case .fingerprintMismatch(let exp, let act):
            return "Key fingerprint mismatch (expected \(exp), found \(act))."
        case .decryptionFailed:
            return "Failed to decrypt ledger data. Authentication tag or key was invalid."
        case .pairingExpired:
            return "The device authorization request has expired."
        case .invalidProtocolVersion(let ver):
            return "Unsupported pairing protocol version \(ver)."
        case .invalidPublicKey:
            return "The provided device public key could not be decoded."
        case .corruptedContainer(let msg):
            return "Corrupted backup container: \(msg)"
        case .keychainError(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

// MARK: - Backup Container Models

struct FsyBackupContainer: Codable, Sendable {
    static let currentFormat = "FinsyBackup"
    static let currentFormatVersion = 1

    var format: String
    var formatVersion: Int
    var ledgerID: UUID

    var encrypted: Bool
    var encryptionVersion: Int?
    var keyFingerprint: String?

    var createdAt: Date
    var payload: Data
}

struct FsyInnerManifest: Codable, Sendable {
    var ledgerID: UUID
    var snapshotCreatedAt: Date
    var stateLastModifiedAt: Date
    var schemaVersion: Int
    var accountCount: Int
    var transactionCount: Int
}

struct FsyInnerBackupPayload: Codable, Sendable {
    var manifest: FsyInnerManifest
    var envelope: LedgerBackupEnvelope
}

// MARK: - Pairing & Device Authorization Models

struct FinsyPairingRequest: Codable, Sendable, Identifiable {
    static let currentProtocolVersion = 2

    var id: UUID { requestID }
    var protocolVersion: Int
    var ledgerID: UUID
    var ledgerName: String
    var requestID: UUID
    var newDevicePublicKey: Data
    var nonce: Data
    var expiresAt: Date

    var purpose: Purpose? = nil
    var expectedFingerprint: String? = nil
    enum Purpose: String, Codable, Sendable { case authorization, migration }
    var effectivePurpose: Purpose { purpose ?? .authorization }
    var isExpired: Bool { Date.now > expiresAt }
    func validate() throws {
        guard protocolVersion == Self.currentProtocolVersion else { throw LedgerCryptoError.invalidProtocolVersion(protocolVersion) }
        guard !isExpired, expiresAt.timeIntervalSinceNow <= 610, nonce.count >= 16 else { throw LedgerCryptoError.pairingExpired }
        _ = try P256.KeyAgreement.PublicKey(rawRepresentation: newDevicePublicKey)
    }
}

struct FinsyKeyGrantEnvelope: Codable, Sendable {
    static let currentProtocolVersion = 2

    var protocolVersion: Int
    var requestID: UUID
    var ledgerID: UUID
    var keyFingerprint: String
    var senderPublicKey: Data?
    var encapsulatedKey: Data
    var ciphertext: Data
}

struct LedgerKeyGrantPayload: Codable, Sendable {
    var ledgerID: UUID
    var keyData: Data
    var keyFingerprint: String
    var keyVersion: Int
    var request: FinsyPairingRequest
}

// MARK: - Device Identity (K_device)

enum LedgerDeviceIdentity {
    private static let service = "com.finsy.app.device-identity"
    private static let account = "k-device-p256"

    static func getOrCreatePrivateKey(for ledgerID: UUID? = nil) throws -> P256.KeyAgreement.PrivateKey {
        let keyAccount = ledgerID.map { "ledger-device-" + $0.uuidString } ?? account
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: keyAccount,
            kSecAttrSynchronizable as String: false]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            let updated = SecItemUpdate(query as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
            guard updated == errSecSuccess else { throw LedgerCryptoError.keychainError(updated) }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw LedgerCryptoError.keychainError(status) }
        let key = P256.KeyAgreement.PrivateKey()
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem { return try getOrCreatePrivateKey(for: ledgerID) }
        guard added == errSecSuccess else { throw LedgerCryptoError.keychainError(added) }
        return key
    }

    static func exportPublicKeyData(for ledgerID: UUID? = nil) throws -> Data {
        try getOrCreatePrivateKey(for: ledgerID).publicKey.rawRepresentation
    }

    static func localWrappingKey(for ledgerID: UUID, create: Bool = true) throws -> SymmetricKey {
        if !create {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "ledger-device-" + ledgerID.uuidString,
                kSecAttrSynchronizable as String: false]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecItemNotFound { throw LedgerCryptoError.keyNotFound(ledgerID) }
            guard status == errSecSuccess else { throw LedgerCryptoError.keychainError(status) }
        }
        let privateKey = try getOrCreatePrivateKey(for: ledgerID)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: privateKey.rawRepresentation),
            salt: Data("FinsyLocalDeviceKeyV1".utf8), info: Data(service.utf8), outputByteCount: 32)
    }

    static func revoke(for ledgerID: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "ledger-device-" + ledgerID.uuidString,
            kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LedgerCryptoError.keychainError(status) }
    }

    static func reset() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LedgerCryptoError.keychainError(status) }
    }

}

// MARK: - Ledger Key Store (K_ledger)

enum LedgerKeyStore {
    private static let service = "com.finsy.app.ledger-key"
    private static let wrappedPrefix = Data("FinsyDeviceWrappedKeyV1:".utf8)

    static func fingerprint(for key: SymmetricKey, ledgerID: UUID) -> String {
        var hasher = SHA256()
        if let idData = ledgerID.uuidString.data(using: .utf8) {
            hasher.update(data: idData)
        }
        key.withUnsafeBytes { rawBytes in
            hasher.update(bufferPointer: rawBytes)
        }
        let digest = hasher.finalize()
        let prefixBytes = digest.prefix(16)
        return prefixBytes.map { String(format: "%02x", $0) }.joined()
    }

    static func generateAndSaveKey(for ledgerID: UUID) throws -> (key: SymmetricKey, fingerprint: String) {
        let key = SymmetricKey(size: .bits256)
        let fp = fingerprint(for: key, ledgerID: ledgerID)
        try saveKey(key, for: ledgerID)
        return (key, fp)
    }

    static func saveKey(_ key: SymmetricKey, for ledgerID: UUID) throws {
        let plain = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(plain, using: LedgerDeviceIdentity.localWrappingKey(for: ledgerID), authenticating: Data(ledgerID.uuidString.utf8))
        guard let combined = sealed.combined else { throw LedgerCryptoError.decryptionFailed }
        let keyData = wrappedPrefix + combined
        let account = ledgerID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw LedgerCryptoError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw LedgerCryptoError.keychainError(updateStatus)
        }
    }

    static func validateLocalKey(for ledgerID: UUID, expectedFingerprint: String?) throws {
        guard try loadKey(for: ledgerID, expectedFingerprint: expectedFingerprint) != nil else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: ledgerID, fingerprint: expectedFingerprint)
        }
    }

    static func migrateLegacyCloudKeys() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".icloud", kSecAttrSynchronizable as String: true]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecReturnAttributes as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw LedgerCryptoError.keychainError(status)
        }
        // Preserve a local, device-wrapped copy before deleting legacy cloud secrets.
        for item in items {
            guard let name = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: name), let data = item[kSecValueData as String] as? Data,
                  data.count == 32 else { throw LedgerCryptoError.corruptedContainer("Legacy cloud key is invalid.") }
            if !LedgerDeviceAuthorization.isRevoked(id), try loadKey(for: id) == nil { try saveKey(SymmetricKey(data: data), for: id) }
        }
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw LedgerCryptoError.keychainError(deleted) }
    }

    static func loadKey(for ledgerID: UUID, expectedFingerprint: String? = nil) throws -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: ledgerID.uuidString,
            kSecAttrSynchronizable as String: false, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw LedgerCryptoError.keychainError(status) }
        let plain: Data
        if data.starts(with: wrappedPrefix) {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(wrappedPrefix.count)))
            do {
                plain = try AES.GCM.open(box, using: LedgerDeviceIdentity.localWrappingKey(for: ledgerID, create: false), authenticating: Data(ledgerID.uuidString.utf8))
            } catch LedgerCryptoError.keyNotFound { return nil }
        } else {
            guard data.count == 32 else { throw LedgerCryptoError.corruptedContainer("Local key is invalid.") }
            plain = data
        }
        let key = SymmetricKey(data: plain)
        guard expectedFingerprint == nil || fingerprint(for: key, ledgerID: ledgerID).lowercased() == expectedFingerprint?.lowercased() else { return nil }
        if !data.starts(with: wrappedPrefix) { try saveKey(key, for: ledgerID) }
        return key
    }

    static func deleteKey(for ledgerID: UUID) throws {
        let account = ledgerID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LedgerCryptoError.keychainError(status)
        }
    }

    static func reset() throws {
        for name in [service, service + ".icloud"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: name, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LedgerCryptoError.keychainError(status) }
        }
        try LedgerDeviceAuthorization.reset()
        try LedgerDeviceIdentity.reset()
    }

    static func hasKey(for ledgerID: UUID, expectedFingerprint: String?) -> Bool {
        guard let key = try? loadKey(for: ledgerID, expectedFingerprint: expectedFingerprint) else { return false }
        guard let expected = expectedFingerprint, !expected.isEmpty else { return true }
        let currentFp = fingerprint(for: key, ledgerID: ledgerID)
        return currentFp.lowercased() == expected.lowercased()
    }
}

// MARK: - Central Cryptographic Service

enum LedgerCryptoService {
    static let currentEncryptionVersion = 1

    // MARK: - CloudKit Record Encryption & Decryption

    static func recordAAD(
        encryptionVersion: Int,
        ledgerID: UUID,
        recordType: String,
        recordID: String,
        fingerprint: String
    ) -> Data {
        let aadString = "Finsy:\(encryptionVersion):\(ledgerID.uuidString):\(recordType):\(recordID):\(fingerprint)"
        return Data(aadString.utf8)
    }

    static func encryptRecord(
        _ plaintext: Data,
        ledgerID: UUID,
        recordType: String,
        recordID: String,
        key: SymmetricKey,
        version: Int = currentEncryptionVersion
    ) throws -> (ciphertext: Data, fingerprint: String) {
        let fp = LedgerKeyStore.fingerprint(for: key, ledgerID: ledgerID)
        let aad = recordAAD(
            encryptionVersion: version,
            ledgerID: ledgerID,
            recordType: recordType,
            recordID: recordID,
            fingerprint: fp
        )
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = sealedBox.combined else {
            throw LedgerCryptoError.decryptionFailed
        }
        return (combined, fp)
    }

    static func decryptRecord(
        _ ciphertext: Data,
        ledgerID: UUID,
        recordType: String,
        recordID: String,
        key: SymmetricKey,
        version: Int,
        expectedFingerprint: String?
    ) throws -> Data {
        let fp = LedgerKeyStore.fingerprint(for: key, ledgerID: ledgerID)
        if let expected = expectedFingerprint, !expected.isEmpty {
            guard expected.lowercased() == fp.lowercased() else {
                throw LedgerCryptoError.fingerprintMismatch(expected: expected, actual: fp)
            }
        }
        let aad = recordAAD(
            encryptionVersion: version,
            ledgerID: ledgerID,
            recordType: recordType,
            recordID: recordID,
            fingerprint: fp
        )
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - Backup Encryption & Decryption

    static func backupAAD(
        formatVersion: Int,
        ledgerID: UUID,
        fingerprint: String
    ) -> Data {
        let aadString = "FinsyBackup:\(formatVersion):\(ledgerID.uuidString):\(fingerprint)"
        return Data(aadString.utf8)
    }

    static func encryptBackup(
        _ plaintext: Data,
        ledgerID: UUID,
        key: SymmetricKey,
        formatVersion: Int = FsyBackupContainer.currentFormatVersion
    ) throws -> (ciphertext: Data, fingerprint: String) {
        let fp = LedgerKeyStore.fingerprint(for: key, ledgerID: ledgerID)
        let aad = backupAAD(formatVersion: formatVersion, ledgerID: ledgerID, fingerprint: fp)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = box.combined else {
            throw LedgerCryptoError.decryptionFailed
        }
        return (combined, fp)
    }

    static func decryptBackup(
        _ ciphertext: Data,
        ledgerID: UUID,
        key: SymmetricKey,
        formatVersion: Int,
        expectedFingerprint: String?
    ) throws -> Data {
        let fp = LedgerKeyStore.fingerprint(for: key, ledgerID: ledgerID)
        if let expected = expectedFingerprint, !expected.isEmpty {
            guard expected.lowercased() == fp.lowercased() else {
                throw LedgerCryptoError.fingerprintMismatch(expected: expected, actual: fp)
            }
        }
        let aad = backupAAD(formatVersion: formatVersion, ledgerID: ledgerID, fingerprint: fp)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - Attachment Encryption & Decryption

    static func attachmentAAD(ledgerID: UUID, attachmentID: String, associatedID: String?) -> Data {
        let aadString = "FinsyAsset:\(ledgerID.uuidString):\(attachmentID):\(associatedID ?? "")"
        return Data(aadString.utf8)
    }

    static func encryptAttachment(
        _ plaintext: Data,
        ledgerID: UUID,
        attachmentID: String,
        associatedID: String?,
        key: SymmetricKey
    ) throws -> Data {
        let aad = attachmentAAD(ledgerID: ledgerID, attachmentID: attachmentID, associatedID: associatedID)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = box.combined else {
            throw LedgerCryptoError.decryptionFailed
        }
        return combined
    }

    static func decryptAttachment(
        _ ciphertext: Data,
        ledgerID: UUID,
        attachmentID: String,
        associatedID: String?,
        key: SymmetricKey
    ) throws -> Data {
        let aad = attachmentAAD(ledgerID: ledgerID, attachmentID: attachmentID, associatedID: associatedID)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - HPKE Device Key Grants (P256_SHA256_AES_GCM_256)

    private static let hpkeSuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    private static let hpkeInfo = Data("FinsyDeviceKeyGrantV2".utf8)

    static func grantKey(
        request: FinsyPairingRequest,
        ledgerKey: SymmetricKey
    ) throws -> FinsyKeyGrantEnvelope {
        try request.validate()
        guard let recipientKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: request.newDevicePublicKey) else {
            throw LedgerCryptoError.invalidPublicKey
        }

        let fp = LedgerKeyStore.fingerprint(for: ledgerKey, ledgerID: request.ledgerID)
        if let expected = request.expectedFingerprint, expected.lowercased() != fp.lowercased() {
            throw LedgerCryptoError.fingerprintMismatch(expected: expected, actual: fp)
        }
        let keyData = ledgerKey.withUnsafeBytes { Data($0) }
        let payload = LedgerKeyGrantPayload(
            ledgerID: request.ledgerID,
            keyData: keyData,
            keyFingerprint: fp,
            keyVersion: currentEncryptionVersion,
            request: request
        )
        let encodedPayload = try JSONEncoder().encode(payload)

        var sender = try HPKE.Sender(
            recipientKey: recipientKey,
            ciphersuite: hpkeSuite,
            info: hpkeInfo
        )
        let ciphertext = try sender.seal(encodedPayload)
        let encapsulatedKey = sender.encapsulatedKey

        return FinsyKeyGrantEnvelope(
            protocolVersion: FinsyKeyGrantEnvelope.currentProtocolVersion,
            requestID: request.requestID,
            ledgerID: request.ledgerID,
            keyFingerprint: fp,
            senderPublicKey: nil,
            encapsulatedKey: encapsulatedKey,
            ciphertext: ciphertext
        )
    }

    static func receiveKeyGrant(
        envelope: FinsyKeyGrantEnvelope,
        devicePrivateKey: P256.KeyAgreement.PrivateKey,
        request: FinsyPairingRequest
    ) throws -> (key: SymmetricKey, ledgerID: UUID, fingerprint: String) {
        try request.validate()
        guard envelope.protocolVersion == FinsyKeyGrantEnvelope.currentProtocolVersion,
              envelope.requestID == request.requestID, envelope.ledgerID == request.ledgerID,
              devicePrivateKey.publicKey.rawRepresentation == request.newDevicePublicKey else {
            throw LedgerCryptoError.corruptedContainer("Unsolicited device key grant.")
        }
        var recipient = try HPKE.Recipient(
            privateKey: devicePrivateKey,
            ciphersuite: hpkeSuite,
            info: hpkeInfo,
            encapsulatedKey: envelope.encapsulatedKey
        )
        let decryptedBytes = try recipient.open(envelope.ciphertext)
        let payload = try JSONDecoder().decode(LedgerKeyGrantPayload.self, from: decryptedBytes)

        guard payload.request.requestID == request.requestID,
              payload.request.nonce == request.nonce,
              payload.request.newDevicePublicKey == request.newDevicePublicKey,
              payload.request.expiresAt == request.expiresAt,
              payload.request.effectivePurpose == request.effectivePurpose,
              payload.request.expectedFingerprint == request.expectedFingerprint,
              payload.keyData.count == 32, payload.keyVersion == currentEncryptionVersion,
              payload.ledgerID == envelope.ledgerID else {
            throw LedgerCryptoError.corruptedContainer("Ledger ID mismatch")
        }
        let recoveredKey = SymmetricKey(data: payload.keyData)
        let recoveredFp = LedgerKeyStore.fingerprint(for: recoveredKey, ledgerID: payload.ledgerID)
        guard recoveredFp.lowercased() == envelope.keyFingerprint.lowercased() else {
            throw LedgerCryptoError.fingerprintMismatch(expected: envelope.keyFingerprint, actual: recoveredFp)
        }

        if let expected = request.expectedFingerprint, expected.lowercased() != recoveredFp.lowercased() {
            throw LedgerCryptoError.fingerprintMismatch(expected: expected, actual: recoveredFp)
        }
        try LedgerKeyStore.saveKey(recoveredKey, for: payload.ledgerID)
        return (recoveredKey, payload.ledgerID, recoveredFp)
    }
}


// Pending requests and transfer receipts stay in the local, migratable Keychain.
// A transfer is committed only after a receipt signed by the requesting device.
struct FinsyTransferReceipt: Codable, Sendable {
    var requestID: UUID
    var ledgerID: UUID
    var grantDigest: Data
    var signature: Data
    var signedData: Data {
        Data("FinsyTransferReceiptV2:\(requestID.uuidString):\(ledgerID.uuidString):".utf8) + grantDigest
    }
}

enum LedgerDeviceAuthorization {
    private static let service = "com.finsy.app.device-authorization"
    struct PendingTransfer: Codable {
        var request: FinsyPairingRequest
        var grant: FinsyKeyGrantEnvelope
    }
    static func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw LedgerCryptoError.keychainError(status) }
        return try JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var added = query
            added.merge(attributes) { _, new in new }
            let result = SecItemAdd(added as CFDictionary, nil)
            guard result == errSecSuccess else { throw LedgerCryptoError.keychainError(result) }
        } else if status != errSecSuccess { throw LedgerCryptoError.keychainError(status) }
    }
    static func remove(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LedgerCryptoError.keychainError(status) }
    }
    static func isRevoked(_ ledgerID: UUID) -> Bool {
        // Fail closed if Keychain is temporarily unavailable.
        do { return try read(Bool.self, account: "revoked-" + ledgerID.uuidString) == true }
        catch { return true }
    }
    static func request(ledgerID: UUID, name: String, fingerprint: String?, purpose: FinsyPairingRequest.Purpose,
                        explicit: Bool = false) throws -> FinsyPairingRequest {
        guard explicit || !isRevoked(ledgerID) else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: ledgerID, fingerprint: fingerprint)
        }
        let account = "request-" + ledgerID.uuidString
        if let pending = try read(FinsyPairingRequest.self, account: account), !pending.isExpired,
           pending.effectivePurpose == purpose, pending.expectedFingerprint == fingerprint { return pending }
        let request = FinsyPairingRequest(protocolVersion: FinsyPairingRequest.currentProtocolVersion,
            ledgerID: ledgerID, ledgerName: name, requestID: UUID(),
            newDevicePublicKey: try LedgerDeviceIdentity.exportPublicKeyData(for: ledgerID),
            nonce: Data(UUID().uuidString.utf8), expiresAt: .now.addingTimeInterval(600),
            purpose: purpose, expectedFingerprint: fingerprint)
        try write(request, account: account)
        return request
    }
    static func pendingRequest(_ ledgerID: UUID) throws -> FinsyPairingRequest? {
        try read(FinsyPairingRequest.self, account: "request-" + ledgerID.uuidString)
    }
    static func digest(_ grant: FinsyKeyGrantEnvelope) -> Data {
        // Hash the cryptographic bytes, not JSON whose field order may vary.
        Data(SHA256.hash(data: Data(grant.requestID.uuidString.utf8) + Data(grant.ledgerID.uuidString.utf8)
            + Data(grant.keyFingerprint.utf8) + grant.encapsulatedKey + grant.ciphertext))
    }
    static func grant(_ request: FinsyPairingRequest) throws -> FinsyKeyGrantEnvelope {
        try request.validate()
        guard request.newDevicePublicKey != (try LedgerDeviceIdentity.exportPublicKeyData(for: request.ledgerID)) else {
            throw LedgerCryptoError.corruptedContainer("The request belongs to this device.")
        }
        guard let key = try LedgerKeyStore.loadKey(for: request.ledgerID, expectedFingerprint: request.expectedFingerprint) else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: request.ledgerID, fingerprint: request.expectedFingerprint)
        }
        let grant = try LedgerCryptoService.grantKey(request: request, ledgerKey: key)
        if request.effectivePurpose == .migration {
            try write(PendingTransfer(request: request, grant: grant), account: "transfer-" + request.requestID.uuidString)
        }
        return grant
    }
    static func receive(_ grant: FinsyKeyGrantEnvelope) throws -> FinsyTransferReceipt? {
        guard let request = try pendingRequest(grant.ledgerID) else {
            throw LedgerCryptoError.corruptedContainer("No matching device authorization request.")
        }
        let privateKey = try LedgerDeviceIdentity.getOrCreatePrivateKey(for: grant.ledgerID)
        _ = try LedgerCryptoService.receiveKeyGrant(envelope: grant, devicePrivateKey: privateKey, request: request)
        var receipt: FinsyTransferReceipt?
        if request.effectivePurpose == .migration {
            var value = FinsyTransferReceipt(requestID: request.requestID, ledgerID: request.ledgerID,
                                            grantDigest: digest(grant), signature: Data())
            value.signature = try P256.Signing.PrivateKey(rawRepresentation: privateKey.rawRepresentation)
                .signature(for: value.signedData).derRepresentation
            try write(value, account: "receipt-" + request.ledgerID.uuidString)
            receipt = value
        }
        try remove("request-" + grant.ledgerID.uuidString)
        try remove("revoked-" + grant.ledgerID.uuidString)
        return receipt
    }
    static func verify(_ receipt: FinsyTransferReceipt) throws -> PendingTransfer {
        guard let pending = try read(PendingTransfer.self, account: "transfer-" + receipt.requestID.uuidString),
              pending.request.effectivePurpose == .migration, pending.request.ledgerID == receipt.ledgerID,
              digest(pending.grant) == receipt.grantDigest else {
            throw LedgerCryptoError.corruptedContainer("No matching key transfer.")
        }
        let key = try P256.Signing.PublicKey(rawRepresentation: pending.request.newDevicePublicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: receipt.signature)
        guard key.isValidSignature(signature, for: receipt.signedData) else { throw LedgerCryptoError.invalidPublicKey }
        guard LedgerKeyStore.hasKey(for: receipt.ledgerID, expectedFingerprint: pending.grant.keyFingerprint) else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: receipt.ledgerID, fingerprint: pending.grant.keyFingerprint)
        }
        return pending
    }
    static func revoke(_ receipt: FinsyTransferReceipt) throws {
        _ = try verify(receipt)
        // Persist the tombstone before deletion; automatic sync must never re-enroll this device.
        try write(true, account: "revoked-" + receipt.ledgerID.uuidString)
        try LedgerKeyStore.deleteKey(for: receipt.ledgerID)
        try LedgerDeviceIdentity.revoke(for: receipt.ledgerID)
        try remove("request-" + receipt.ledgerID.uuidString)
        try remove("transfer-" + receipt.requestID.uuidString)
    }
    static func reset() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LedgerCryptoError.keychainError(status) }
    }
}
