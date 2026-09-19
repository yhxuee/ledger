import SwiftUI
import UIKit

struct PurchaseSummaryView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
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
                    Section {
                        VStack(spacing: 10) {
                            ForEach(session.orderedItems) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.note.isEmpty ? "Item" : item.note)
                                            .font(.body.weight(.medium))
                                        Text(categoryName(item.categoryID))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    SensitiveMoneyText(amount: item.amount, currency: session.currency, maxIntegerDigits: 4)
                                        .font(.subheadline.bold())
                                }
                                if item.id != session.orderedItems.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(16)
                        .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Items").font(.subheadline.weight(.semibold))
                    }

                    Section {
                        HStack {
                            Text("Total")
                                .font(.headline)
                            Spacer()
                            SensitiveMoneyText(amount: session.plannedAmount, currency: session.currency, maxIntegerDigits: 4)
                                .font(.title3.bold())
                        }
                        .padding(16)
                        .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if !readOnly {
                        Section {
                            VStack(spacing: 12) {
                                if let receiptImage {
                                    Image(uiImage: receiptImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                Button {
                                    showingCamera = true
                                } label: {
                                    Label(receiptImage == nil ? "Take Receipt Photo" : "Retake Receipt Photo", systemImage: "camera")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } header: {
                            Text("Receipt").font(.subheadline.weight(.semibold))
                        }

                        Section {
                            Button {
                                Task { await finalize() }
                            } label: {
                                Text("Create Ledger Transactions")
                                    .frame(maxWidth: .infinity)
                                    .fontWeight(.semibold)
                            }
                            .glassPrimaryButton()
                            .disabled(saving)
                            .padding(.vertical, 4)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } else if session.receiptAttachmentID != nil {
                        Section {
                            Group {
                                if let storedReceiptImage {
                                    Image(uiImage: storedReceiptImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 260)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                } else {
                                    Label("Receipt stored securely outside the ledger JSON.", systemImage: "doc.viewfinder")
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } header: {
                            Text("Receipt").font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(LedgerBackground())
            .navigationTitle("Purchase Summary").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { PurchaseStatusNotice() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if readOnly {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .tint(primaryActionColor)
                        .accessibilityLabel("Done")
                    }
                }
            }
        }
        .sheet(isPresented: $showingCamera) { CameraPicker(image: $receiptImage) }
        .task(id: sessionID) {
            // Final controlled reconciliation before reviewing/finalizing, so an item that was
            // checked on the Lock Screen is never omitted from the created transactions.
            store.reconcileSharedActivePurchases()
        }
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
