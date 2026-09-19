import SwiftUI

/// Native selection and dismissal, with the selected currency code as the visible label.
struct CurrencyMenuPicker: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selection: CurrencyCode
    let codes: [CurrencyCode]
    var title = "Currency"
    var showsOther = false
    var showsStablecoinNames = true
    var requiresConfiguredRate = true

    private var displayedCodes: [CurrencyCode] {
        // Keep a currency chosen through Other represented by a valid native Picker tag.
        showsOther && !codes.contains(selection) ? codes + [selection] : codes
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker(title, selection: $selection) {
                ForEach(displayedCodes) { code in
                    Text(code.rawValue).tag(code)
                        .disabled(requiresConfiguredRate && CurrencyRates.reference(code, in: store.state.settings.rates) == nil)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(title)
            if showsOther {
                OtherCurrencyButton(codes: store.availableCurrencies, selection: selection,
                                    showsStablecoinNames: showsStablecoinNames) { selection = $0 }
            }
        }
    }
}

/// Adding a pocket is an action, so nil represents the prompt after each selection.
struct CurrencyPocketAddPicker: View {
    @EnvironmentObject private var store: LedgerStore
    let codes: [CurrencyCode]
    let otherCodes: [CurrencyCode]
    let onSelect: (CurrencyCode) -> Void

    private var addition: Binding<CurrencyCode?> {
        Binding(get: { nil }, set: { code in
            if let code { onSelect(code) }
        })
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker("Add Currency Pocket", selection: addition) {
                Text("Add Currency").tag(nil as CurrencyCode?)
                ForEach(codes) { code in
                    Text(code.rawValue).tag(Optional(code))
                        .disabled(CurrencyRates.reference(code, in: store.state.settings.rates) == nil)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Add Currency Pocket")
            OtherCurrencyButton(codes: otherCodes, showsStablecoinNames: false, onSelect: onSelect)
        }
    }
}

private struct OtherCurrencyButton: View {
    let codes: [CurrencyCode]
    var selection: CurrencyCode? = nil
    var showsStablecoinNames = true
    let onSelect: (CurrencyCode) -> Void
    @State private var showingSearch = false

    var body: some View {
        Button("Other…") { showingSearch = true }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .sheet(isPresented: $showingSearch) {
                NavigationStack {
                    CurrencySearchList(codes: codes, selection: selection,
                                       showsStablecoinNames: showsStablecoinNames) { code in
                        onSelect(code)
                        showingSearch = false
                    }
                    .navigationTitle("All Currencies")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingSearch = false }
                        }
                    }
                }
            }
    }
}
