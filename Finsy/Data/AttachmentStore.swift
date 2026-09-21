import Foundation
import UIKit

actor AttachmentStore {
    static let shared = AttachmentStore()
    nonisolated static var folderURL: URL {
        FinsyStorage.folder.appending(path: "Attachments", directoryHint: .isDirectory)
    }
    nonisolated static func url(for identifier: String) throws -> URL { try AttachmentPath.url(identifier, in: folderURL) }

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
        return UIImage(contentsOfFile: url.path)
    }
    func loadTransactionNote(identifier: String) -> UIImage? { loadReceipt(identifier: identifier) }
    func delete(identifier: String) throws {
        let url = try Self.url(for: identifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum AttachmentError: LocalizedError { case encodingFailed; var errorDescription: String? { "The photo could not be encoded." } }
