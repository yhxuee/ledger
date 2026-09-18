import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let walletLedgerBackup = UTType(exportedAs: "org.medx.walletledger.backup", conformingTo: .json)
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.walletLedgerBackup, .json] }
    var data: Data

    init(envelope: LedgerBackupEnvelope) { data = (try? BackupCodec.encode(envelope)) ?? Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
