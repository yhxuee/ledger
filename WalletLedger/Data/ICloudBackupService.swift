import Foundation
import CryptoKit

actor ICloudBackupService {
    static let shared = ICloudBackupService()
    private let primaryFileName = "Finsy-latest.fsy"
    private let legacyFileName = "WalletLedger-latest.walletledger"

    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func backup(_ envelope: LedgerBackupEnvelope, ledgerID: UUID, key: SymmetricKey?) async throws -> Date {
        let data = try BackupCodec.encodeFsy(envelope: envelope, ledgerID: ledgerID, key: key)
        let url = try await backupURL(fileName: primaryFileName, createDirectory: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return .now
    }

    func restoreLatest(existingState: LedgerState? = nil) async throws -> ImportPreview {
        let primaryURL = try await backupURL(fileName: primaryFileName, createDirectory: false)
        let legacyURL = try await backupURL(fileName: legacyFileName, createDirectory: false)

        let targetURL: URL
        let sourceName: String
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            targetURL = primaryURL
            sourceName = primaryFileName
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            targetURL = legacyURL
            sourceName = legacyFileName
        } else {
            throw BackupError.noICloudBackup
        }

        if FileManager.default.isUbiquitousItem(at: targetURL) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: targetURL)
        }
        let data = try Data(contentsOf: targetURL)
        return try BackupCodec.decode(data, sourceName: sourceName, existingState: existingState)
    }

    private func backupURL(fileName: String, createDirectory: Bool) async throws -> URL {
        let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        guard let container else { throw BackupError.iCloudUnavailable }
        let folder = container.appending(path: "Documents/WalletLedger", directoryHint: .isDirectory)
        if createDirectory {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        }
        return folder.appending(path: fileName)
    }
}
