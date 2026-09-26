import Foundation
import CryptoKit

actor ICloudBackupService {
    static let shared = ICloudBackupService()
    private let primaryFileName = "Finsy-latest.fsy"
    private let libraryFileName = "Finsy-library-latest.fsy"
    private let legacyFileName = FinsyCompatibility.backupFile

    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func backupLibrary(_ library: LedgerLibrary) async throws -> Date {
        let data = try ICloudLibraryBackup.encode(library)
        let url = try await backupURL(fileName: libraryFileName, createDirectory: true)
        try await writeCoordinated(data, to: url)
        try await waitForTransfer(at: url, uploading: true)
        return .now
    }

    func restoreLibrary(existingState: LedgerState? = nil) async throws -> ICloudLibraryRestorePreview {
        let url = try await backupURL(fileName: libraryFileName, createDirectory: false)
        do {
            if FileManager.default.isUbiquitousItem(at: url) {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                try await waitForTransfer(at: url, uploading: false)
            }
            let snapshot = try await Self.readCoordinated(url)
            let backup = try BackupCodec.decoder().decode(ICloudLibraryBackup.self, from: snapshot.data)
            return try ICloudLibraryRestorePreview(library: backup.library(), createdAt: backup.createdAt)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            // Existing single-ledger iCloud backups remain readable.
            let preview = try await restoreLatest(existingState: existingState)
            let book = LedgerBook(id: UUID(), name: "Restored Ledger", state: preview.envelope.data,
                                  createdAt: preview.envelope.metadata.exportedAt, updatedAt: preview.envelope.data.lastModifiedAt)
            return ICloudLibraryRestorePreview(library: LedgerLibrary(schemaVersion: BackupCodec.currentSchemaVersion,
                activeBookID: book.id, books: [book]), createdAt: preview.envelope.metadata.exportedAt)
        }
    }

    func backup(_ envelope: LedgerBackupEnvelope, ledgerID: UUID, key: SymmetricKey?) async throws -> Date {
        let data = try BackupCodec.encodeFsy(envelope: envelope, ledgerID: ledgerID, key: key)
        let url = try await backupURL(fileName: primaryFileName, createDirectory: true)
        try await writeCoordinated(data, to: url)
        try await waitForTransfer(at: url, uploading: true)
        return .now
    }

    private func writeCoordinated(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var writeError: Error?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do { try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtection]) }
                catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }.value
    }

    func restoreLatest(existingState: LedgerState? = nil) async throws -> ImportPreview {
        let primaryURL = try await backupURL(fileName: primaryFileName, createDirectory: false)
        let previousPrimaryURL = try await backupURL(fileName: primaryFileName, createDirectory: false, legacy: true)
        let legacyURL = try await backupURL(fileName: legacyFileName, createDirectory: false, legacy: true)

        // Coordinate every compatible location, including undownloaded iCloud placeholders.
        // A stale primary file must not hide a newer backup in the legacy location.
        var latest: (data: Data, date: Date, name: String)?
        for url in [primaryURL, previousPrimaryURL, legacyURL] {
            do {
                if FileManager.default.isUbiquitousItem(at: url) {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    try await waitForTransfer(at: url, uploading: false)
                }
                let snapshot = try await Self.readCoordinated(url)
                if latest == nil || snapshot.date > latest!.date {
                    latest = (snapshot.data, snapshot.date, url.lastPathComponent)
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                continue
            }
        }
        guard let latest else { throw BackupError.noICloudBackup }
        return try BackupCodec.decode(latest.data, sourceName: latest.name, existingState: existingState)
    }

    private static func readCoordinated(_ url: URL) async throws -> (data: Data, date: Date) {
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<(data: Data, date: Date), Error>?
            // Default reading options wait for contents, unlike metadata-only coordination.
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result {
                    let data = try Data(contentsOf: coordinatedURL)
                    let values = try coordinatedURL.resourceValues(forKeys: [.contentModificationDateKey])
                    return (data, values.contentModificationDate ?? .distantPast)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw BackupError.noICloudBackup }
            return try result.get()
        }.value
    }

    private func waitForTransfer(at url: URL, uploading: Bool) async throws {
        let deadline = Date.now.addingTimeInterval(60)
        while true {
            try Task.checkCancellation()
            // Use a fresh URL so resource-value caching cannot freeze transfer progress.
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
                .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey
            ])
            if let error = uploading ? values.ubiquitousItemUploadingError : values.ubiquitousItemDownloadingError {
                throw error
            }
            if uploading ? values.ubiquitousItemIsUploaded == true : values.ubiquitousItemDownloadingStatus == .current {
                return
            }
            guard Date.now < deadline else { throw BackupError.iCloudSyncPending }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func backupURL(fileName: String, createDirectory: Bool, legacy: Bool = false) async throws -> URL {
        let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        guard let container else { throw BackupError.iCloudUnavailable }
        let folder = container.appending(path: "Documents/" + (legacy ? FinsyCompatibility.storageDirectory : "finsy"), directoryHint: .isDirectory)
        if createDirectory {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        }
        return folder.appending(path: fileName)
    }
}
