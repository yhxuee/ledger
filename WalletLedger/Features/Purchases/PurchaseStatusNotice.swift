import SwiftUI

/// Inline Purchase Mode notices.
///
/// Two distinct channels:
/// - `purchaseSyncWarning` is a nonfatal infrastructure notice (App Group bridge / Live
///   Activity). It never interrupts shopping and can be dismissed.
/// - `presentedError` is a real operation error (invalid account/session, local save failure).
struct PurchaseStatusNotice: View {
    @EnvironmentObject private var store: LedgerStore
    var body: some View {
        VStack(spacing: 8) {
            if let warning = store.purchaseSyncWarning {
                notice(warning, systemImage: "iphone.slash", tint: .orange) { store.dismissPurchaseSyncWarning() }
            }
            if let message = store.presentedError {
                notice(message, systemImage: "exclamationmark.triangle.fill", tint: .red) { store.presentedError = nil }
            }
        }
    }

    private func notice(_ message: String, systemImage: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.callout)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss).font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

