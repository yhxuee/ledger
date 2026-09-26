import SwiftUI
import CoreImage
import VisionKit
import CryptoKit
import UniformTypeIdentifiers

struct DeviceAuthorizationView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var preferences: AppPreferencesStore
    var targetLedgerID: UUID? = nil
    var targetName: String? = nil
    var targetFingerprint: String? = nil
    var requestPurpose: FinsyPairingRequest.Purpose = .authorization
    var incomingData: Data? = nil
    var onAuthorized: (() -> Void)? = nil
    @State private var selectedLedgerID: UUID?
    @State private var scanner = false
    @State private var scannedData: Data?
    @State private var importer = false
    @State private var requestToAuthorize: FinsyPairingRequest?
    @State private var confirmingAuthorization = false
    @State private var displayedPacket: AuthorizationPacket?
    @State private var sharingURL: URL?
    @State private var showingShare = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var ledgerID: UUID { targetLedgerID ?? selectedLedgerID ?? store.activeBookID }
    private var book: LedgerBook? { store.books.first { $0.id == ledgerID } }
    private var name: String { targetName ?? book?.name ?? "Encrypted Backup" }
    private var fingerprint: String? { targetFingerprint ?? book?.keyFingerprint }
    private var hasKey: Bool { LedgerKeyStore.hasKey(for: ledgerID, expectedFingerprint: fingerprint) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Device Identity") {
                    if targetLedgerID == nil {
                        Picker("Ledger", selection: Binding(get: { ledgerID }, set: { selectedLedgerID = $0 })) {
                            ForEach(store.books) { Text($0.name).tag($0.id) }
                        }
                    } else { LabeledContent("Ledger", value: name) }
                    LabeledContent("This Device ID", value: deviceID)
                    LabeledContent("Status", value: hasKey ? "Authorized" : "Authorization Required")
                    if let fingerprint { LabeledContent("Key Fingerprint", value: String(fingerprint.prefix(12))) }
                }
                SettingsGlassSection(hasKey ? "Authorize or Migrate" : "Request Key") {
                    Button { scanner = true } label: { SettingsLabel("Scan Request or Response", systemImage: "qrcode.viewfinder") }
                    Divider()
                    Button { importer = true } label: { SettingsLabel("Import Key or Request", systemImage: "square.and.arrow.down") }
                    if hasKey {
                        Divider()
                        Button { scanner = true } label: { SettingsLabel("Migrate Key via AirDrop", systemImage: "airdrop") }
                        Text("On the receiving device, request a key migration. Scan or import its request here, then share the encrypted key via AirDrop. This device is revoked after the recipient confirms receipt.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Divider()
                        Button { makeRequest(purpose: requestPurpose) } label: { SettingsLabel("Show Key Request QR", systemImage: "qrcode") }
                        if requestPurpose != .migration {
                            Divider()
                            Button { makeRequest(purpose: .migration) } label: { SettingsLabel("Request Key Migration", systemImage: "airdrop") }
                        }
                        Text(requestPurpose == .migration
                             ? "An authorized device must approve this backup migration. After confirmation, its key for this ledger is revoked. Other authorized devices retain access."
                             : "Use an authorized device to approve the request. Ordinary authorization keeps both devices authorized.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let statusMessage { Text(statusMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                if let receipt = try? LedgerDeviceAuthorization.read(FinsyTransferReceipt.self, account: "receipt-" + ledgerID.uuidString) {
                    SettingsGlassSection("Migration Confirmation") {
                        Button("Show Receipt Confirmation") { display(receipt, extension: "fsyreceipt", title: "Confirm Key Migration") }
                        Text("Return this confirmation to the original device to finish revoking its key.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Device Authorization")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanner, onDismiss: {
            if let scannedData { handle(scannedData) }
            scannedData = nil
        }) { VisionKitQRScannerSheet { scannedData = Data($0.utf8); scanner = false } }
        .sheet(item: $displayedPacket) { packet in
            NavigationStack {
                VStack(spacing: 20) {
                    if let image = qrImage(packet.data) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 280, maxHeight: 280).padding(16).background(.white)
                    }
                    Text(packet.title).font(.headline)
                    Text("Scan on the other device or share via AirDrop.").font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: packet.url) { Label("Share via AirDrop", systemImage: "airdrop") }
                    Button("Scan Response") { displayedPacket = nil; scanner = true }
                }.padding().navigationTitle("Device Authorization")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { displayedPacket = nil } } }
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.fsyPairingRequest, .fsyKeyGrant, .fsyTransferReceipt, .json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                handle(try Data(contentsOf: url))
            } catch { errorMessage = error.localizedDescription }
        }
        .alert(requestToAuthorize?.effectivePurpose == .migration ? "Migrate Ledger Key?" : "Authorize Device?", isPresented: $confirmingAuthorization) {
            Button("Cancel", role: .cancel) { requestToAuthorize = nil }
            Button("Approve") { if let requestToAuthorize { authorize(requestToAuthorize) } }
        } message: {
            Text(requestToAuthorize?.effectivePurpose == .migration
                 ? "Transfer access to the requesting device? After its signed receipt is confirmed, this device loses access to this ledger. Other authorized devices retain their keys."
                 : "Authorize the requesting device to decrypt and edit this shared ledger?")
        }
        .alert("Device Authorization", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .task { if let incomingData { handle(incomingData) } }
        .onReceive(NotificationCenter.default.publisher(for: .finsyDeviceAuthorized)) { notification in
            guard notification.object as? UUID == ledgerID else { return }
            displayedPacket = nil
            statusMessage = "Device authorized."
            onAuthorized?()
        }
    }
    private var deviceID: String {
        (try? LedgerDeviceIdentity.exportPublicKeyData().prefix(8).map { String(format: "%02X", $0) }.joined()) ?? "Unavailable"
    }
    private func makeRequest(purpose: FinsyPairingRequest.Purpose) {
        do {
            let request = try LedgerDeviceAuthorization.request(ledgerID: ledgerID, name: name,
                fingerprint: fingerprint, purpose: purpose, explicit: true)
            display(request, extension: "fsyrequest", title: purpose == .migration ? "Request Key Migration" : "Request Authorization")
        } catch { errorMessage = error.localizedDescription }
    }
    private func handle(_ data: Data) {
        do {
            if let request = try? JSONDecoder().decode(FinsyPairingRequest.self, from: data) {
                try request.validate()
                guard LedgerKeyStore.hasKey(for: request.ledgerID, expectedFingerprint: request.expectedFingerprint) else {
                    throw LedgerCryptoError.authorizationRequired(ledgerID: request.ledgerID, fingerprint: request.expectedFingerprint)
                }
                requestToAuthorize = request
                confirmingAuthorization = true
            } else if let grant = try? JSONDecoder().decode(FinsyKeyGrantEnvelope.self, from: data) {
                let receipt = try LedgerDeviceAuthorization.receive(grant)
                Task { await store.restoreAuthorizedLedger(bookID: grant.ledgerID) }
                statusMessage = "Device authorized."
                if let receipt { display(receipt, extension: "fsyreceipt", title: "Confirm Key Migration") }
                onAuthorized?()
            } else if let receipt = try? JSONDecoder().decode(FinsyTransferReceipt.self, from: data) {
                Task { @MainActor in
                    do { try await store.completeKeyTransfer(receipt); statusMessage = "Migration complete. This device's ledger key has been revoked." }
                    catch { errorMessage = error.localizedDescription }
                }
            } else { throw LedgerCryptoError.corruptedContainer("Unsupported authorization file.") }
        } catch { errorMessage = error.localizedDescription }
    }
    private func authorize(_ request: FinsyPairingRequest) {
        Task { @MainActor in
            guard await privacy.authorizeSensitiveChange(reason: "Authenticate to authorize this encryption key transfer.",
                protectionEnabled: true) else { return }
            do {
                let grant = try LedgerDeviceAuthorization.grant(request)
                display(grant, extension: "fsykey", title: "Encrypted Ledger Key")
                statusMessage = request.effectivePurpose == .migration ? "Awaiting the recipient's signed confirmation. This device still retains its key." : "Share this key response with the requesting device."
                if request.effectivePurpose == .authorization,
                   let source = store.books.first(where: { $0.id == request.ledgerID }), source.effectiveStorageKind != .local {
                    do { try await CloudLedgerService.shared.postKeyEnvelope(grant, book: source) }
                    catch { statusMessage = "Cloud delivery failed. Use QR or AirDrop: " + error.localizedDescription }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func display<T: Encodable>(_ value: T, extension suffix: String, title: String) {
        do {
            let data = try JSONEncoder().encode(value)
            let directory = FileManager.default.temporaryDirectory.appending(path: "FinsyAuthorization", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            let url = directory.appending(path: UUID().uuidString + "." + suffix)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            displayedPacket = AuthorizationPacket(data: data, url: url, title: title)
        } catch { errorMessage = error.localizedDescription }
    }
    private func qrImage(_ data: Data) -> UIImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
private struct AuthorizationPacket: Identifiable {
    let id = UUID()
    var data: Data
    var url: URL
    var title: String
}
struct IncomingDeviceAuthorization: Identifiable {
    let id = UUID()
    var data: Data
}
extension Notification.Name {
    static let finsyDeviceAuthorized = Notification.Name("FinsyDeviceAuthorized")
}
extension UTType {
    static let fsyTransferReceipt = UTType(exportedAs: "com.finsy.app.transfer-receipt", conformingTo: .data)
}

struct VisionKitQRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScannerRepresentable { scanned in
                        onScanned(scanned)
                        dismiss()
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Camera Scanner Unavailable")
                            .font(.headline)
                        Text("VisionKit camera scanning is unavailable on this device simulator. Use AirDrop to transfer the pairing file.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                }
            }
            .navigationTitle("Scan Authorization QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String) -> Void
        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard let item = addedItems.first else { return }
            switch item {
            case .barcode(let barcode):
                if let payload = barcode.payloadStringValue {
                    onScanned(payload)
                }
            default: break
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
