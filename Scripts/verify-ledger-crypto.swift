import Foundation
import CryptoKit

@main
struct LedgerCryptoVerification {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CryptoVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "CryptoVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    struct ReinstallProbe: Codable {
        var ledgerID: UUID
        var fingerprint: String
        var publicKey: Data
        var ciphertext: Data
    }
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let url = URL(fileURLWithPath: CommandLine.arguments[2])
            if CommandLine.arguments[1] == "--seed-reinstall" {
                let id = UUID()
                let generated = try LedgerKeyStore.generateAndSaveKey(for: id)
                let sealed = try LedgerCryptoService.encryptBackup(Data("Reinstall recovery".utf8), ledgerID: id, key: generated.key)
                let probe = ReinstallProbe(ledgerID: id, fingerprint: generated.fingerprint,
                    publicKey: try LedgerDeviceIdentity.exportPublicKeyData(for: id), ciphertext: sealed.ciphertext)
                try JSONEncoder().encode(probe).write(to: url)
                return
            }
            if CommandLine.arguments[1] == "--verify-reinstall" {
                defer { try? LedgerKeyStore.reset() }
                let probe = try JSONDecoder().decode(ReinstallProbe.self, from: Data(contentsOf: url))
                let reused = try LedgerKeyStore.generateAndSaveKey(for: probe.ledgerID)
                try require(reused.fingerprint == probe.fingerprint, "Fresh process changed ledger key")
                try require(try LedgerDeviceIdentity.exportPublicKeyData(for: probe.ledgerID) == probe.publicKey, "Fresh process changed device identity")
                let opened = try LedgerCryptoService.decryptBackup(probe.ciphertext, ledgerID: probe.ledgerID,
                    key: reused.key, formatVersion: 1, expectedFingerprint: probe.fingerprint)
                try require(opened == Data("Reinstall recovery".utf8), "Old backup no longer decrypts")
                print("PASS: fresh-process key and identity reuse with old-backup decryption")
                return
            }
        }
        defer { try? LedgerKeyStore.reset() }
        let id = UUID(), otherID = UUID()
        let generated = try LedgerKeyStore.generateAndSaveKey(for: id)
        let unrelated = try LedgerKeyStore.generateAndSaveKey(for: otherID)
        let reused = try LedgerKeyStore.generateAndSaveKey(for: id)
        try require(reused.fingerprint == generated.fingerprint, "Reinitialization rotated an existing ledger key")
        try require(reused.key.withUnsafeBytes { Data($0) } == generated.key.withUnsafeBytes { Data($0) }, "Reinitialization replaced key bytes")
        try require(LedgerKeyStore.hasKey(for: id, expectedFingerprint: generated.fingerprint), "Wrapped local key round trip failed")
        let originalIdentity = try LedgerDeviceIdentity.exportPublicKeyData(for: id)
        try require(originalIdentity == LedgerDeviceIdentity.exportPublicKeyData(for: id), "Identity changed during ordinary use")
        let plain = Data("Existing ledger records, including purchase details".utf8)
        let encrypted = try LedgerCryptoService.encryptBackup(plain, ledgerID: id, key: generated.key)
        let opened = try LedgerCryptoService.decryptBackup(encrypted.ciphertext, ledgerID: id, key: generated.key,
            formatVersion: 1, expectedFingerprint: generated.fingerprint)
        try require(opened == plain, "Backup round trip failed")
        try rejects("Backup accepted the wrong ledger binding") {
            _ = try LedgerCryptoService.decryptBackup(encrypted.ciphertext, ledgerID: otherID, key: generated.key,
                formatVersion: 1, expectedFingerprint: nil)
        }
        let request = try LedgerDeviceAuthorization.request(ledgerID: id, name: "Verification", fingerprint: generated.fingerprint,
            purpose: .migration, explicit: true)
        // The remote sender has the ledger key, while this Keychain represents the recipient.
        let grant = try LedgerCryptoService.grantKey(request: request, ledgerKey: generated.key)
        try LedgerDeviceAuthorization.write(LedgerDeviceAuthorization.PendingTransfer(request: request, grant: grant),
            account: "transfer-" + request.requestID.uuidString)
        let privateKey = try LedgerDeviceIdentity.getOrCreatePrivateKey(for: id)
        var altered = request
        altered.nonce = Data(UUID().uuidString.utf8)
        try rejects("Grant accepted an altered request nonce") {
            _ = try LedgerCryptoService.receiveKeyGrant(envelope: grant, devicePrivateKey: privateKey, request: altered)
        }
        try rejects("Grant accepted the wrong recipient") {
            _ = try LedgerCryptoService.receiveKeyGrant(envelope: grant, devicePrivateKey: P256.KeyAgreement.PrivateKey(), request: request)
        }
        altered = request
        altered.expiresAt = .now.addingTimeInterval(-1)
        try rejects("Expired request was accepted") { _ = try LedgerCryptoService.grantKey(request: altered, ledgerKey: generated.key) }
        guard let receipt = try LedgerDeviceAuthorization.receive(grant) else { fatalError("Migration did not produce a receipt") }
        try require(LedgerKeyStore.hasKey(for: id, expectedFingerprint: generated.fingerprint), "Key revoked before receipt confirmation")
        try rejects("Grant replay was accepted") { _ = try LedgerDeviceAuthorization.receive(grant) }
        var forged = receipt
        forged.grantDigest = Data(repeating: 0, count: 32)
        try rejects("Forged confirmation was accepted") { _ = try LedgerDeviceAuthorization.verify(forged) }
        _ = try LedgerDeviceAuthorization.verify(receipt)
        try LedgerDeviceAuthorization.revoke(receipt)
        try require(!LedgerKeyStore.hasKey(for: id, expectedFingerprint: generated.fingerprint), "Source key remains after confirmed migration")
        try require(LedgerDeviceAuthorization.isRevoked(id), "Revocation was not persisted")
        try require(LedgerKeyStore.hasKey(for: otherID, expectedFingerprint: unrelated.fingerprint), "Migration deleted another ledger's key")
        try rejects("Revoked device silently re-enrolled") {
            _ = try LedgerDeviceAuthorization.request(ledgerID: id, name: "Verification", fingerprint: generated.fingerprint, purpose: .authorization)
        }
        let ordinary = try LedgerDeviceAuthorization.request(ledgerID: otherID, name: "Ordinary", fingerprint: unrelated.fingerprint,
            purpose: .authorization, explicit: true)
        let ordinaryGrant = try LedgerCryptoService.grantKey(request: ordinary, ledgerKey: unrelated.key)
        try require(try LedgerDeviceAuthorization.receive(ordinaryGrant) == nil, "Ordinary authorization unexpectedly migrated the key")
        try require(LedgerKeyStore.hasKey(for: otherID, expectedFingerprint: unrelated.fingerprint), "Ordinary authorization removed access")
        try LedgerDeviceIdentity.revoke(for: otherID)
        try rejects("Orphaned wrapped key was overwritten") {
            _ = try LedgerKeyStore.generateAndSaveKey(for: otherID)
        }
        try rejects("Revoked ledger generated a replacement key") {
            _ = try LedgerKeyStore.generateAndSaveKey(for: id)
        }
        print("PASS: device wrapping, stable identity, backup AAD, request binding, expiry, recipient isolation, replay rejection, signed receipts, confirmed revocation, other-ledger preservation, ordinary authorization")
    }
}
