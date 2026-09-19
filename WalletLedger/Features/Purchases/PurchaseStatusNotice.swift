import SwiftUI

/// Keep errors readable on the current purchase sheet even when the root alert is behind it.
struct PurchaseStatusNotice: View {
    @EnvironmentObject private var store: LedgerStore
    var body: some View {
        if let message = store.presentedError {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout)
                Button("OK") { store.presentedError = nil }.fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding()
            .accessibilityElement(children: .contain)
        }
    }
}

