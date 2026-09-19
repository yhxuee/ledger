import SwiftUI
import UIKit

struct PurchaseSummaryView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let readOnly: Bool
    @State private var receiptImage: UIImage?
    @State private var showingCamera = false
    @State private var saving = false
    @State private var storedReceiptImage: UIImage?
    private var session: PurchaseSession? { store.purchaseSessions.first(where: { $0.id == sessionID }) }
    var body: some View {
        NavigationStack {
            List {
                if let session {
                Section("Items") {
                    ForEach(session.orderedItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(item.note); Text(categoryName(item.categoryID)).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); SensitiveMoneyText(amount: item.amount, currency: session.currency).font(.subheadline.bold())
                        }
                    }
                }
                Section { LabeledContent("Total") { SensitiveMoneyText(amount: session.plannedAmount, currency: session.currency).font(.headline) } }
                if !readOnly {
                    Section("Receipt") {
                        if let receiptImage { Image(uiImage: receiptImage).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 16)) }
                        Button { showingCamera = true } label: { Label(receiptImage == nil ? "Take Receipt Photo" : "Retake Receipt Photo", systemImage: "camera") }
                    }
                    Section { Button("Create Ledger Transactions") { Task { await finalize() } }.fontWeight(.semibold).disabled(saving) }
                } else if session.receiptAttachmentID != nil {
                    Section("Receipt") {
                        if let storedReceiptImage { Image(uiImage: storedReceiptImage).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16)) }
                        else { Label("Receipt stored securely outside the ledger JSON.", systemImage: "doc.viewfinder") }
                    }
                }
                }
            }
            .navigationTitle("Purchase Summary").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { PurchaseStatusNotice() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { if readOnly { Button("Done") { dismiss() } } } }
        }
        .sheet(isPresented: $showingCamera) { CameraPicker(image: $receiptImage) }
        .task(id: session?.receiptAttachmentID) {
            guard let identifier = session?.receiptAttachmentID else { return }
            storedReceiptImage = await AttachmentStore.shared.loadReceipt(identifier: identifier)
        }
    }
    private func categoryName(_ id: LedgerCategoryID) -> String { store.state.categories.first(where: { $0.id == id })?.name ?? id.rawValue }
    @MainActor private func finalize() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        do {
            let attachmentID: String?
            if let receiptImage {
                attachmentID = try await AttachmentStore.shared.saveReceipt(receiptImage)
            } else {
                attachmentID = nil
            }
            try store.finalizePurchaseSession(sessionID, receiptAttachmentID: attachmentID)
            dismiss()
        } catch { store.presentedError = error.localizedDescription }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { parent.image = info[.originalImage] as? UIImage; parent.dismiss() }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
