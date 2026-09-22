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

    private var isPassLibraryAvailable: Bool {
        WalletPassManager.shared.isPassLibraryAvailable
    }

    private var isIssuerConfigured: Bool {
        WalletPassManager.shared.isIssuerConfigured
    }

    private var isWalletActionEnabled: Bool {
        readOnly && isPassLibraryAvailable && isIssuerConfigured && !generatingPass
    }

    private var walletStatusMessage: String? {
        guard readOnly else { return nil }
        if !isPassLibraryAvailable {
            return String(localized: "Apple Wallet is unavailable on this device.")
        }
        if !isIssuerConfigured {
            return String(localized: "Apple Wallet pass issuance is unavailable.")
        }
        return nil
    }

    private var totalTax: Double {
        guard let session else { return 0 }
        if readOnly {
            let txByID = Dictionary(store.state.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var sum: Double = 0
            var foundAny = false
            for item in session.items {
                if let linkedID = item.linkedTransactionID, let tx = txByID[linkedID], let tax = tx.taxAmount {
                    sum += tax
                    foundAny = true
                }
            }
            if foundAny {
                return sum
            }
            let sessionTxs = store.state.transactions.filter { $0.purchaseSessionID == session.id && $0.deletedAt == nil }
            if !sessionTxs.isEmpty {
                return sessionTxs.reduce(0) { $0 + ($1.taxAmount ?? 0) }
            }
        }
        // Pre-finalization preview or fallback when no linked snapshots exist
        var sum: Double = 0
        for item in session.items {
            let cat = store.state.categories.first(where: { $0.id == item.categoryID })
            if let cat {
                let taxSnapshot = TaxCalculations.resolve(
                    entered: item.amount,
                    type: .expense,
                    rate: store.state.settings.taxRate(for: cat),
                    mode: .finalAmount,
                    exempt: false
                )
                sum += taxSnapshot?.taxAmount ?? 0
            }
        }
        return sum
    }

    var body: some View {
        NavigationStack {
            List {
                if let session {
                    // Unified Serrated Receipt Ticket Card
                    Section {
                        PurchaseWalletTicketCard(
                            session: session,
                            categoryResolver: { categoryName($0) },
                            totalTax: totalTax,
                            baseCurrency: store.state.settings.baseCurrency,
                            baseCurrencyEquivalent: baseCurrencyEquivalent
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if readOnly {
                        // Standalone Add to Apple Wallet button directly below the ticket
                        Section {
                            VStack(spacing: 6) {
                                Button {
                                    Task { await addReceiptToWallet() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "wallet.pass.fill")
                                            .font(.system(size: 15, weight: .medium))
                                        Text(generatingPass ? String(localized: "Adding to Apple Wallet...") : String(localized: "Add to Apple Wallet"))
                                            .font(.subheadline.weight(.semibold))
                                        if generatingPass {
                                            Spacer()
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(isWalletActionEnabled ? Color.primary : Color.secondary.opacity(0.3))
                                .disabled(!isWalletActionEnabled)

                                if let message = walletStatusMessage {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        if session.receiptAttachmentID != nil {
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
                    } else {
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
    private func categoryName(_ id: LedgerCategoryID) -> String { store.state.categories.first(where: { $0.id == id })?.displayName ?? id.rawValue }
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
