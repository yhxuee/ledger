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
    static let currentProtocolVersion = 1

    var id: UUID { requestID }
    var protocolVersion: Int
    var ledgerID: UUID
    var ledgerName: String
    var requestID: UUID
    var newDevicePublicKey: Data
    var nonce: Data
    var expiresAt: Date

    var isExpired: Bool { Date.now > expiresAt }
}

struct FinsyKeyGrantEnvelope: Codable, Sendable {
    static let currentProtocolVersion = 1

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
}

// MARK: - Device Identity (K_device)

enum LedgerDeviceIdentity {
    private static let service = "com.finsy.app.device-identity"
    private static let account = "k-device-p256"

    static func getOrCreatePrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        if let existing = try loadPrivateKey() {
            return existing
        }
        let fresh = P256.KeyAgreement.PrivateKey()
        try savePrivateKey(fresh)
        return fresh
    }

    static func publicKey() throws -> P256.KeyAgreement.PublicKey {
        let privateKey = try getOrCreatePrivateKey()
        return privateKey.publicKey
    }

    static func exportPublicKeyData() throws -> Data {
        let pub = try publicKey()
        return pub.rawRepresentation
    }

    private static func loadPrivateKey() throws -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LedgerCryptoError.keychainError(status)
        }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private static func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey) throws {
        let data = key.rawRepresentation
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LedgerCryptoError.keychainError(status)
        }
    }
}

// MARK: - Ledger Key Store (K_ledger)

enum LedgerKeyStore {
    private static let service = "com.finsy.app.ledger-key"

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
        let keyData = key.withUnsafeBytes { Data($0) }
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

    static func loadKey(for ledgerID: UUID) throws -> SymmetricKey? {
        let account = ledgerID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LedgerCryptoError.keychainError(status)
        }
        return SymmetricKey(data: data)
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

    static func hasKey(for ledgerID: UUID, expectedFingerprint: String?) -> Bool {
        guard let key = try? loadKey(for: ledgerID) else { return false }
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
    private static let hpkeInfo = Data("FinsyDeviceKeyGrantV1".utf8)

    static func grantKey(
        request: FinsyPairingRequest,
        ledgerKey: SymmetricKey
    ) throws -> FinsyKeyGrantEnvelope {
        guard !request.isExpired else { throw LedgerCryptoError.pairingExpired }
        guard let recipientKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: request.newDevicePublicKey) else {
            throw LedgerCryptoError.invalidPublicKey
        }

        let fp = LedgerKeyStore.fingerprint(for: ledgerKey, ledgerID: request.ledgerID)
        let keyData = ledgerKey.withUnsafeBytes { Data($0) }
        let payload = LedgerKeyGrantPayload(
            ledgerID: request.ledgerID,
            keyData: keyData,
            keyFingerprint: fp,
            keyVersion: currentEncryptionVersion
        )
        let encodedPayload = try JSONEncoder().encode(payload)

        let sender = try HPKE.Sender(
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
        devicePrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> (key: SymmetricKey, ledgerID: UUID, fingerprint: String) {
        let recipient = try HPKE.Recipient(
            privateKey: devicePrivateKey,
            ciphersuite: hpkeSuite,
            info: hpkeInfo,
            encapsulatedKey: envelope.encapsulatedKey
        )
        let decryptedBytes = try recipient.open(envelope.ciphertext)
        let payload = try JSONDecoder().decode(LedgerKeyGrantPayload.self, from: decryptedBytes)

        guard payload.ledgerID == envelope.ledgerID else {
            throw LedgerCryptoError.corruptedContainer("Ledger ID mismatch")
        }
        let recoveredKey = SymmetricKey(data: payload.keyData)
        let recoveredFp = LedgerKeyStore.fingerprint(for: recoveredKey, ledgerID: payload.ledgerID)
        guard recoveredFp.lowercased() == envelope.keyFingerprint.lowercased() else {
            throw LedgerCryptoError.fingerprintMismatch(expected: envelope.keyFingerprint, actual: recoveredFp)
        }

        try LedgerKeyStore.saveKey(recoveredKey, for: payload.ledgerID)
        return (recoveredKey, payload.ledgerID, recoveredFp)
    }
}
