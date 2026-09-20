import SwiftUI
import CoreImage
import VisionKit
import CryptoKit
import UniformTypeIdentifiers

struct DeviceAuthorizationView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var preferences: AppPreferencesStore

    @State private var showingQRScanner = false
    @State private var showingPairingRequestQR = false
    @State private var pairingRequest: FinsyPairingRequest?
    @State private var pairingQRImage: UIImage?
    @State private var requestToAuthorize: FinsyPairingRequest?
    @State private var showingAuthorizeAlert = false
    @State private var activeSheetDocument: BackupDocument?
    @State private var showingDocumentShare = false
    @State private var statusMessage: String?

    private var activeBook: LedgerBook { store.activeBook }
    private var ledgerID: UUID { activeBook.id }

    private var localKey: SymmetricKey? {
        try? LedgerKeyStore.loadKey(for: ledgerID)
    }

    private var currentFingerprint: String? {
        if let localKey {
            return LedgerKeyStore.fingerprint(for: localKey, ledgerID: ledgerID)
        }
        return activeBook.keyFingerprint
    }

    private var devicePublicKeyPrefix: String {
        if let pub = try? LedgerDeviceIdentity.exportPublicKeyData() {
            return pub.prefix(8).map { String(format: "%02X", $0) }.joined()
        }
        return "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                deviceInfoSection
                if activeBook.effectiveEncryptionState == .enabled && localKey != nil {
                    authorizedActionsSection
                } else if activeBook.effectiveEncryptionState == .authorizationRequired || (activeBook.isEncrypted == true && localKey == nil) {
                    unauthorizedActionsSection
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Device Authorization")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPairingRequestQR) {
            if let image = pairingQRImage, let req = pairingRequest {
                PairingRequestDisplaySheet(
                    qrImage: image,
                    request: req,
                    onAirDrop: { sharePairingRequest(req) }
                )
            }
        }
        .sheet(isPresented: $showingQRScanner) {
            VisionKitQRScannerSheet { scannedString in
                handleScannedData(scannedString)
            }
        }
        .sheet(isPresented: $showingDocumentShare) {
            if let doc = activeSheetDocument {
                ShareSheet(items: [doc.data])
            }
        }
        .alert("Authorize Device", isPresented: $showingAuthorizeAlert) {
            Button("Cancel", role: .cancel) { requestToAuthorize = nil }
            Button("Authorize") {
                if let req = requestToAuthorize {
                    processAuthorization(for: req)
                }
            }
        } message: {
            if let req = requestToAuthorize {
                Text("Authorize this device for “\(req.ledgerName)”?\n\nThis will transfer the ledger encryption key wrapped with the new device's public key.")
            }
        }
        .alert("Device Authorization", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private var deviceInfoSection: some View {
        SettingsGlassSection("Device Identity") {
            LabeledContent("This Device ID", value: devicePublicKeyPrefix)
            if let fp = currentFingerprint {
                LabeledContent("Key Fingerprint", value: fp.prefix(12) + "…")
            }
            LabeledContent("Ledger", value: activeBook.name)
            LabeledContent("Status", value: statusText)
        }
    }

    private var statusText: String {
        switch activeBook.effectiveEncryptionState {
        case .enabled:
            return localKey != nil ? "Authorized" : "Locked — Authorization Required"
        case .authorizationRequired:
            return "Locked — Authorization Required"
        case .enabling:
            return "Enabling…"
        case .disabling:
            return "Disabling…"
        case .disabled:
            return "Encryption Disabled"
        case .migrationFailed:
            return "Migration Failed"
        }
    }

    private var authorizedActionsSection: some View {
        SettingsGlassSection("Authorize Another Device") {
            Button {
                showingQRScanner = true
            } label: {
                SettingsLabel("Scan Authorization Request", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)

            Divider()

            Text("Scan the QR code displayed by an unauthorized device, or import its .fsyrequest file via AirDrop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var unauthorizedActionsSection: some View {
        SettingsGlassSection("Request Authorization") {
            Button {
                generatePairingRequest()
            } label: {
                SettingsLabel("Show Authorization QR", systemImage: "qrcode")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)

            Divider()

            Button {
                generatePairingRequest(andAirDrop: true)
            } label: {
                SettingsLabel("Share Request via AirDrop", systemImage: "airdrop")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)

            Divider()

            Text("Display this request on an authorized device to transfer the encryption key securely.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func generatePairingRequest(andAirDrop: Bool = false) {
        do {
            let pubKey = try LedgerDeviceIdentity.exportPublicKeyData()
            let req = FinsyPairingRequest(
                protocolVersion: FinsyPairingRequest.currentProtocolVersion,
                ledgerID: ledgerID,
                ledgerName: activeBook.name,
                requestID: UUID(),
                newDevicePublicKey: pubKey,
                nonce: Data(UUID().uuidString.utf8),
                expiresAt: Date.now.addingTimeInterval(600) // 10 minutes
            )
            self.pairingRequest = req
            let data = try JSONEncoder().encode(req)
            self.pairingQRImage = generateQRCode(from: data)

            if andAirDrop {
                self.activeSheetDocument = BackupDocument(data: data)
                self.showingDocumentShare = true
            } else {
                self.showingPairingRequestQR = true
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func sharePairingRequest(_ req: FinsyPairingRequest) {
        if let data = try? JSONEncoder().encode(req) {
            self.activeSheetDocument = BackupDocument(data: data)
            self.showingDocumentShare = true
        }
    }

    private func handleScannedData(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        if let req = try? JSONDecoder().decode(FinsyPairingRequest.self, from: data) {
            guard req.ledgerID == ledgerID else {
                statusMessage = "Scanned request is for a different ledger."
                return
            }
            guard !req.isExpired else {
                statusMessage = "Scanned authorization request has expired."
                return
            }
            self.requestToAuthorize = req
            self.showingAuthorizeAlert = true
        } else {
            statusMessage = "Invalid authorization request QR code."
        }
    }

    private func processAuthorization(for request: FinsyPairingRequest) {
        guard let key = localKey else {
            statusMessage = "Local encryption key is missing."
            return
        }
        do {
            let grant = try LedgerCryptoService.grantKey(request: request, ledgerKey: key)
            let grantData = try JSONEncoder().encode(grant)

            // If this is a cloud ledger, also post key envelope to CloudKit
            if activeBook.effectiveStorageKind != .local {
                Task {
                    try? await CloudLedgerService.shared.postKeyEnvelope(grant, book: activeBook)
                }
            }

            self.activeSheetDocument = BackupDocument(data: grantData)
            self.showingDocumentShare = true
            statusMessage = "Key grant generated. Share via AirDrop or CloudKit to complete authorization."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func generateQRCode(from data: Data) -> UIImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = output.transformed(by: transform)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Sheets & Scanners

struct PairingRequestDisplaySheet: View {
    @Environment(\.dismiss) private var dismiss
    let qrImage: UIImage
    let request: FinsyPairingRequest
    let onAirDrop: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(radius: 8)

                VStack(spacing: 6) {
                    Text("Scan with Authorized Device")
                        .font(.headline)
                    Text("Expires in 10 minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onAirDrop()
                } label: {
                    Label("Share via AirDrop", systemImage: "airdrop")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .background(LedgerBackground())
            .navigationTitle("Device Authorization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
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
