import UniformTypeIdentifiers
import SwiftUI

extension UTType {
    static let walletLedgerBackup = UTType(exportedAs: "com.finsy.app.backup", conformingTo: .json)
    static let legacyWalletLedgerBackup = UTType(importedAs: "org.medx.walletledger.backup", conformingTo: .json)
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.walletLedgerBackup, .legacyWalletLedgerBackup, .json] }
    static var writableContentTypes: [UTType] { [.walletLedgerBackup] }
    var data: Data

    init(envelope: LedgerBackupEnvelope) { data = (try? BackupCodec.encode(envelope)) ?? Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}
