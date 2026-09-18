import Foundation

actor ICloudBackupService {
    static let shared = ICloudBackupService()
    private let fileName = "WalletLedger-latest.walletledger"

    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func backup(_ envelope: LedgerBackupEnvelope) async throws -> Date {
        let data = try BackupCodec.encode(envelope)
        let url = try await backupURL(createDirectory: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return .now
    }

    func restoreLatest() async throws -> ImportPreview {
        let url = try await backupURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { throw BackupError.noICloudBackup }
        if FileManager.default.isUbiquitousItem(at: url) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        let data = try Data(contentsOf: url)
        return try BackupCodec.decode(data, sourceName: fileName)
    }

    private func backupURL(createDirectory: Bool) async throws -> URL {
        let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        guard let container else { throw BackupError.iCloudUnavailable }
        let folder = container.appending(path: "Documents/WalletLedger", directoryHint: .isDirectory)
        if createDirectory { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil) }
        return folder.appending(path: fileName)
    }
}
