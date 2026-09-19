import SwiftUI

struct CurrencyPickerLink: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selection: CurrencyCode
    var stablecoinDescriptions = true
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack { Text("Currency"); Spacer(); Text(selection.rawValue).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }.foregroundStyle(.primary)
        .sheet(isPresented: $showing) {
            NavigationStack {
                List {
                    Section {
                        ForEach(CurrencyCode.preferredFiat) { code in row(code) }
                    }
                    Section {
                        NavigationLink { CurrencySearchList(codes: otherCurrencies, selected: selection, rates: store.state.settings.rates, choose: choose) } label: { Label("Other…", systemImage: "globe") }
                        NavigationLink {
                            List { ForEach(CurrencyCode.usdStablecoins) { code in row(code, description: stablecoinDescriptions ? code.stablecoinName : nil) } }
                                .navigationTitle("Stablecoins").navigationBarTitleDisplayMode(.inline)
                        } label: { Label("Stablecoins", systemImage: "bitcoinsign.circle") }
                    }
                }
                .navigationTitle("Currency").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showing = false } } }
            }
        }
    }

    private var otherCurrencies: [CurrencyCode] {
        store.currencyCatalog.map(\.code).filter { !$0.isUSDStablecoin && !CurrencyCode.preferredFiat.contains($0) }.sorted { $0.rawValue < $1.rawValue }
    }
    private func choose(_ code: CurrencyCode) { selection = code; showing = false }
    private func row(_ code: CurrencyCode, description: String? = nil) -> some View {
        CurrencySelectionRow(code: code, description: description, selected: selection, available: CurrencyRates.reference(code, in: store.state.settings.rates) != nil) { choose(code) }
    }
}

private struct CurrencySelectionRow: View {
    let code: CurrencyCode
    var description: String? = nil
    let selected: CurrencyCode
    let available: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack {
                Text(description.map { "\(code.rawValue) · \($0)" } ?? code.rawValue)
                Spacer()
                if code == selected { Image(systemName: "checkmark") }
                if !available { Text("Set rate first").font(.caption).foregroundStyle(.secondary) }
            }
        }.disabled(!available)
    }
}

private struct CurrencySearchList: View {
    let codes: [CurrencyCode]
    let selected: CurrencyCode
    let rates: [CurrencyCode: Double]
    let choose: (CurrencyCode) -> Void
    @State private var query = ""
    var body: some View {
        List(codes.filter { query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) }) { code in
            CurrencySelectionRow(code: code, selected: selected, available: CurrencyRates.reference(code, in: rates) != nil) { choose(code) }
        }
        .navigationTitle("Other Currencies").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Currency code")
    }
}
