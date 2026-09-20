import UniformTypeIdentifiers
import SwiftUI
import CryptoKit

extension UTType {
    static let fsyBackup = UTType(exportedAs: "com.finsy.app.backup", conformingTo: .data)
    static let legacyLedgerBackup = UTType(importedAs: FinsyCompatibility.backupType, conformingTo: .json)
    static let fsyPairingRequest = UTType(exportedAs: "com.finsy.app.pairing-request", conformingTo: .data)
    static let fsyKeyGrant = UTType(exportedAs: "com.finsy.app.key-grant", conformingTo: .data)
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.fsyBackup, .legacyLedgerBackup, .json, .commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.fsyBackup] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(envelope: LedgerBackupEnvelope, ledgerID: UUID, key: SymmetricKey?) {
        self.data = (try? BackupCodec.encodeFsy(envelope: envelope, ledgerID: ledgerID, key: key)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}
