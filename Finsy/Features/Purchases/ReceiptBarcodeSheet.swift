import PhotosUI
import SwiftUI
import Vision
import VisionKit

struct ReceiptBarcodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (WalletReceiptBarcode?) -> Void
    @State private var message = ""
    @State private var format = "PKBarcodeFormatQR"
    @State private var scanning = false
    @State private var photo: PhotosPickerItem?
    @State private var error: String?

    private var valid: Bool {
        !message.isEmpty && message.utf8.count <= 1024 &&
        (format != "PKBarcodeFormatCode128" || message.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 126 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Receipt Barcode") {
                    TextField("Scan or enter receipt code", text: $message, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Display", selection: $format) {
                        Text("QR Code").tag("PKBarcodeFormatQR")
                        Text("Code 128").tag("PKBarcodeFormatCode128")
                    }
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button("Scan Receipt Code") { scanning = true }
                    }
                    PhotosPicker("Import Receipt Image", selection: $photo, matching: .images)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Button("Add with Barcode") { onAdd(.init(message: message, format: format)); dismiss() }
                        .disabled(!valid)
                    Button("Add without Barcode") { onAdd(nil); dismiss() }
                }
            }
            .navigationTitle("Add Barcode?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                ReceiptCodeScanner(onScan: { value in message = value; scanning = false }, onError: { value in error = value; scanning = false })
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Receipt")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { return }
                let request = VNDetectBarcodesRequest()
                try VNImageRequestHandler(data: data).perform([request])
                guard let value = request.results?.first?.payloadStringValue else {
                    error = "No barcode found. Try a clearer image."; return
                }
                message = value
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ReceiptCodeScanner: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }
    func makeUIViewController(context: Context) -> ScannerContainer {
        let container = ScannerContainer()
        container.scanner.delegate = context.coordinator
        container.onError = onError
        return container
    }
    func updateUIViewController(_ controller: ScannerContainer, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerContainer, coordinator: Coordinator) { controller.scanner.stopScanning() }

    final class ScannerContainer: UIViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        var onError: ((String) -> Void)?
        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            view.addSubview(scanner.view)
            scanner.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
                scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            scanner.didMove(toParent: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            do { try scanner.startScanning() }
            catch { onError?("Camera scanning is unavailable. Import a receipt image or enter the code.") }
        }
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    dataScanner.stopScanning(); onScan(value); return
                }
            }
        }
    }
}
