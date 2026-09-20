import PassKit
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
    @State private var generatingPass = false
    @State private var passToPresent: PKPass?
    @State private var showingAddPassSheet = false
    @State private var passErrorMessage: String?
    private var session: PurchaseSession? { store.purchaseSessions.first(where: { $0.id == sessionID }) }
    var body: some View {
        NavigationStack {
            List {
                if let session {
                    Section {
                        let orderedItems = session.orderedItems
                        VStack(spacing: 10) {
                            ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
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
                                if index < orderedItems.count - 1 {
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
                        VStack(spacing: 8) {
                            HStack {
                                Text("Total")
                                    .font(.headline)
                                Spacer()
                                SensitiveMoneyText(amount: session.plannedAmount, currency: session.currency, maxIntegerDigits: 4)
                                    .font(.title3.bold())
                            }
                            .padding(16)
                            .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                            if let converted = baseCurrencyEquivalent {
                                HStack(spacing: 4) {
                                    Text("≈")
                                    SensitiveMoneyText(amount: converted, currency: store.state.settings.baseCurrency, maxIntegerDigits: 4)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
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
                                .controlSize(.large)
                            }
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
                            .controlSize(.large)
                            .disabled(saving)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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

                    if readOnly {
                        Section {
                            Button {
                                Task { await addReceiptToWallet() }
                            } label: {
                                HStack {
                                    Label("Add Receipt to Apple Wallet", systemImage: "wallet.pass")
                                    if generatingPass {
                                        Spacer()
                                        ProgressView()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(generatingPass)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
        .sheet(isPresented: $showingAddPassSheet) {
            if let pass = passToPresent {
                AddPassSheetView(pass: pass) {
                    passToPresent = nil
                }
            }
        }
        .alert("Apple Wallet", isPresented: Binding(
            get: { passErrorMessage != nil },
            set: { if !$0 { passErrorMessage = nil } }
        )) {
            Button("OK") { passErrorMessage = nil }
        } message: {
            Text(passErrorMessage ?? "")
        }
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

    private func addReceiptToWallet() async {
        guard let session else { return }
        guard WalletPassManager.shared.isPassLibraryAvailable else {
            passErrorMessage = WalletPassError.libraryUnavailable.localizedDescription
            return
        }
        generatingPass = true
        defer { generatingPass = false }

        let snapshot = WalletPassManager.shared.buildPurchaseReceiptSnapshot(session: session, store: store)
        do {
            let pass = try await WalletPassManager.shared.issuer.issuePurchaseReceiptPass(snapshot: snapshot)
            passToPresent = pass
            showingAddPassSheet = true
        } catch {
            passErrorMessage = error.localizedDescription
        }
    }
    private var baseCurrencyEquivalent: Double? {
        guard let session, session.currency != store.state.settings.baseCurrency else { return nil }
        let rates = store.state.settings.rates
        guard CurrencyRates.reference(session.currency, in: rates) != nil,
              CurrencyRates.reference(store.state.settings.baseCurrency, in: rates) != nil else { return nil }
        return LedgerCalculations.convert(session.plannedAmount, from: session.currency, to: store.state.settings.baseCurrency, rates: rates)
    }
    private func categoryName(_ id: LedgerCategoryID) -> String { store.state.categories.first(where: { $0.id == id })?.name ?? id.rawValue }
    @MainActor private func finalize() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        var newlyCreatedAttachmentID: String?
        do {
            if let receiptImage {
                newlyCreatedAttachmentID = try await AttachmentStore.shared.saveReceipt(receiptImage)
            }
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: newlyCreatedAttachmentID)
            dismiss()
        } catch {
            if let id = newlyCreatedAttachmentID {
                try? await AttachmentStore.shared.delete(identifier: id)
            }
            store.presentedError = error.localizedDescription
        }
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
