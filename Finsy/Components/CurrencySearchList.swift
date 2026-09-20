import SwiftUI

/// Fixed ordering and membership rules for the dropdowns, so no screen re-invents them.
enum CurrencySelection {
    /// Common currencies in the required order: HKD, USD, GBP, JPY, CNY, EUR, SGD, CHF.
    static var common: [CurrencyCode] { CurrencyCode.preferredFiat }

    /// `common` reduced to those that are not already in `excluding`.
    static func addable(excluding existing: [CurrencyCode]) -> [CurrencyCode] {
        common.filter { !existing.contains($0) }
    }
}

/// Full searchable currency selector, reached only through `Other…`.
struct CurrencySearchList: View {
    @EnvironmentObject private var store: LedgerStore
    let codes: [CurrencyCode]
    var selection: CurrencyCode? = nil
    var showsStablecoinNames = true
    let choose: (CurrencyCode) -> Void

    @State private var query = ""

    private var matches: [CurrencyCode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return codes }
        return codes.filter { code in
            code.rawValue.localizedCaseInsensitiveContains(needle) || (code.stablecoinName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        List(matches) { code in
            CurrencySelectionRow(code: code, description: showsStablecoinNames ? code.stablecoinName : nil, selected: selection, available: CurrencyRates.reference(code, in: store.state.settings.rates) != nil) { choose(code) }
        }
        .searchable(text: $query, prompt: "Currency code or name")
    }
}

/// One selectable currency row on the full selector page.
struct CurrencySelectionRow: View {
    let code: CurrencyCode
    var description: String? = nil
    var selected: CurrencyCode? = nil
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
