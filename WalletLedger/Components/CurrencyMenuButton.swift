import SwiftUI

/// Uses the same native Menu interaction as AccountSelectorMenu.
struct CurrencyMenuButton: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding private var selection: CurrencyCode?
    private let codes: [CurrencyCode]
    private let title: String
    private let showsOther: Bool
    private let showsStablecoinNames: Bool
    private let requiresConfiguredRate: Bool
    private let otherCodes: [CurrencyCode]?
    @State private var showingAllCurrencies = false

    init(selection: Binding<CurrencyCode>, codes: [CurrencyCode], title: String = "Currency",
         showsOther: Bool = false, showsStablecoinNames: Bool = true,
         requiresConfiguredRate: Bool = true) {
        _selection = Binding(get: { selection.wrappedValue }, set: { code in
            if let code { selection.wrappedValue = code }
        })
        self.codes = codes
        self.title = title
        self.showsOther = showsOther
        self.showsStablecoinNames = showsStablecoinNames
        self.requiresConfiguredRate = requiresConfiguredRate
        self.otherCodes = nil
    }

    /// Adding a pocket uses the same menu, without changing the primary currency.
    init(adding codes: [CurrencyCode], otherCodes: [CurrencyCode] = [], showsOther: Bool = true, requiresConfiguredRate: Bool = true, onSelect: @escaping (CurrencyCode) -> Void) {
        _selection = Binding(get: { nil }, set: { code in
            if let code { onSelect(code) }
        })
        self.codes = codes
        self.title = "Add Currency"
        self.showsOther = showsOther
        self.showsStablecoinNames = false
        self.requiresConfiguredRate = requiresConfiguredRate
        self.otherCodes = otherCodes
    }

    var body: some View {
        Menu {
            ForEach(codes) { code in
                Button {
                    selection = code
                } label: {
                    if selection == code { Label(code.rawValue, systemImage: "checkmark") }
                    else { Text(code.rawValue) }
                }
                .disabled(requiresConfiguredRate && CurrencyRates.reference(code, in: store.state.settings.rates) == nil)
            }
            if showsOther {
                Divider()
                Button {
                    showingAllCurrencies = true
                } label: {
                    Label("Other…", systemImage: "globe")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection?.rawValue ?? title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
        .accessibilityValue(selection?.rawValue ?? title)
        .sheet(isPresented: $showingAllCurrencies) {
            NavigationStack {
                CurrencySearchList(codes: otherCodes ?? store.availableCurrencies, selection: selection,
                                   showsStablecoinNames: showsStablecoinNames) { code in
                    selection = code
                    showingAllCurrencies = false
                }
                .navigationTitle("All Currencies")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showingAllCurrencies = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Cancel")
                    }
                }
            }
        }
    }
}
