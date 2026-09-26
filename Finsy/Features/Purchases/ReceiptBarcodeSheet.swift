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
                ReceiptCodeScanner { value in message = value; scanning = false }
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
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
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
