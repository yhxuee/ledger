import Foundation
import UIKit
import CryptoKit

actor AttachmentStore {
    static let shared = AttachmentStore()
    nonisolated static var folderURL: URL {
        FinsyStorage.folder.appending(path: "Attachments", directoryHint: .isDirectory)
    }
    nonisolated static func url(for identifier: String) throws -> URL { try AttachmentPath.url(identifier, in: folderURL) }

    private struct LocalEncryptedAttachment: Codable {
        var ledgerID: UUID
        var fingerprint: String
        var ciphertext: Data
    }
    private nonisolated static let encryptedPrefix = Data("FinsyLocalAttachmentV1:".utf8)
    nonisolated static func plaintextData(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.starts(with: encryptedPrefix) else { return data }
        let value = try JSONDecoder().decode(LocalEncryptedAttachment.self, from: Data(data.dropFirst(encryptedPrefix.count)))
        guard !LedgerDeviceAuthorization.isRevoked(value.ledgerID),
              let key = try LedgerKeyStore.loadKey(for: value.ledgerID, expectedFingerprint: value.fingerprint) else {
            throw LedgerCryptoError.authorizationRequired(ledgerID: value.ledgerID, fingerprint: value.fingerprint)
        }
        return try LedgerCryptoService.decryptAttachment(value.ciphertext, ledgerID: value.ledgerID,
            attachmentID: url.lastPathComponent, associatedID: nil, key: key)
    }
    nonisolated static func protectedData(_ data: Data, identifier: String, ledgerID: UUID, key: SymmetricKey) throws -> Data {
        let value = LocalEncryptedAttachment(ledgerID: ledgerID,
            fingerprint: LedgerKeyStore.fingerprint(for: key, ledgerID: ledgerID),
            ciphertext: try LedgerCryptoService.encryptAttachment(data, ledgerID: ledgerID,
                attachmentID: identifier, associatedID: nil, key: key))
        return encryptedPrefix + (try JSONEncoder().encode(value))
    }
    nonisolated static func encryptLocalAttachments(for book: LedgerBook) throws {
        guard book.isEncrypted == true, book.effectiveEncryptionState != .authorizationRequired,
              let key = try LedgerKeyStore.loadKey(for: book.id, expectedFingerprint: book.keyFingerprint) else { return }
        let identifiers = Set(book.state.transactions.compactMap(\.noteAttachmentID)
            + (book.state.purchaseSessions ?? []).compactMap(\.receiptAttachmentID))
        for identifier in identifiers {
            let url = try Self.url(for: identifier)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let stored = try Data(contentsOf: url)
            if stored.starts(with: encryptedPrefix),
               let existing = try? JSONDecoder().decode(LocalEncryptedAttachment.self, from: Data(stored.dropFirst(encryptedPrefix.count))),
               existing.ledgerID == book.id, existing.fingerprint == book.keyFingerprint { continue }
            let plain = try plaintextData(at: url)
            try protectedData(plain, identifier: identifier, ledgerID: book.id, key: key)
                .write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    func saveReceipt(_ image: UIImage) throws -> String {
        try save(image, prefix: "receipt")
    }

    func saveTransactionNote(_ image: UIImage) throws -> String {
        try save(image, prefix: "transaction-note")
    }

    private func save(_ image: UIImage, prefix: String) throws -> String {
        try FinsyStorage.prepare()
        let identifier = "\(prefix)-\(UUID().uuidString).jpg"
        let folder = Self.folderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let maximum: CGFloat = 1_600
        let scale = min(1, maximum / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = rendered.jpegData(compressionQuality: 0.78) else { throw AttachmentError.encodingFailed }
        try data.write(to: folder.appending(path: identifier), options: [.atomic, .completeFileProtection])
        return identifier
    }

    func loadReceipt(identifier: String) -> UIImage? {
        guard let url = try? Self.url(for: identifier) else { return nil }
        guard let data = try? Self.plaintextData(at: url) else { return nil }
        return UIImage(data: data)
    }
    func loadTransactionNote(identifier: String) -> UIImage? { loadReceipt(identifier: identifier) }
    func delete(identifier: String) throws {
        let url = try Self.url(for: identifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum AttachmentError: LocalizedError { case encodingFailed; var errorDescription: String? { "The photo could not be encoded." } }
