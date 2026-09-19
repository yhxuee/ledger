import SwiftUI

/// Transaction-specific currency selector.
///
/// Identification UI only: currencies are shown as canonical codes (HKD, USD, USDT…), never as
/// localized names. The eight preferred currencies come first in a fixed order, and
/// `Other Currencies` expands **inline** — a single tap, no second sheet — with a live code search
/// over every remaining supported fiat currency plus the USD stablecoins.
struct TransactionCurrencySheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selection: CurrencyCode
    var onSelect: (CurrencyCode) -> Void = { _ in }

    @State private var otherExpanded = false
    @State private var query = ""

    /// Preferred currencies that actually have a configured rate.
    private var preferred: [CurrencyCode] {
        CurrencyCode.preferredFiat.filter { store.availableCurrencies.contains($0) }
    }

    /// Everything that is not in the preferred row: remaining fiat currencies and stablecoins.
    private var others: [CurrencyCode] {
        store.availableCurrencies
            .filter { !CurrencyCode.preferredFiat.contains($0) }
            .filter { code in
                guard !query.isEmpty else { return true }
                let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { return true }
                if code.rawValue.localizedCaseInsensitiveContains(needle) { return true }
                return code.stablecoinName?.localizedCaseInsensitiveContains(needle) ?? false
            }
            .sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        List {
            Section("Common") {
                ForEach(preferred) { code in row(code) }
            }
            Section {
                DisclosureGroup(isExpanded: $otherExpanded) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search currency code", text: $query)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    ForEach(others) { code in row(code, description: code.stablecoinName) }
                    if others.isEmpty { Text("No matching currency").font(.footnote).foregroundStyle(.secondary) }
                } label: {
                    Label("Other Currencies", systemImage: "globe")
                }
            } footer: {
                Text("Currency codes identify the denomination. Amounts are still shown with their currency symbol.")
            }
        }
        .navigationTitle("Transaction Currency")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ code: CurrencyCode, description: String? = nil) -> some View {
        Button {
            selection = code
            onSelect(code)
        } label: {
            HStack {
                Text(description.map { "\(code.rawValue) · \($0)" } ?? code.rawValue)
                Spacer()
                if code == selection { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact trigger that opens the transaction currency sheet.
struct TransactionCurrencyPicker: View {
    @Binding var selection: CurrencyCode
    var title = "Currency"

    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 6) {
                Text(selection.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .ledgerGlass(interactive: true, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selection.rawValue)
        .sheet(isPresented: $showing) {
            NavigationStack {
                TransactionCurrencySheet(selection: $selection) { _ in showing = false }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showing = false } } }
            }
        }
    }
}

/// Currency-pocket selector for the account side of a transaction.
/// Single-currency accounts never show this: their account currency is fixed.
struct AccountPocketPicker: View {
    let account: LedgerAccount
    @Binding var selection: CurrencyCode
    var title: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(account.normalizedPockets) { pocket in
                Text(pocket.currency.rawValue).tag(pocket.currency)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}