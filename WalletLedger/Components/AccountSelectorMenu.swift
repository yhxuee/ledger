import SwiftUI

/// One-line account selector for the transaction editor.
///
/// The selected name never wraps: it marquees inside a reserved ~15 character window, while the
/// full list keeps every complete name and VoiceOver always receives the whole name.
struct AccountSelectorMenu: View {
    let accounts: [LedgerAccount]
    @Binding var selection: UUID?
    var title: String
    var placeholder = "Select Account"
    /// Visible width reserved for roughly this many English characters.
    var visibleCharacters = 15
    var valueAlignment: Alignment = .leading

    private var selectedName: String {
        accounts.first { $0.id == selection }?.name ?? placeholder
    }

    var body: some View {
        Menu {
            ForEach(accounts) { account in
                Button {
                    selection = account.id
                } label: {
                    if account.id == selection { Label(account.name, systemImage: "checkmark") }
                    else { Text(account.name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                MarqueeText(text: selectedName, font: .body, visibleCharacters: visibleCharacters, alignment: valueAlignment)
                    .foregroundStyle(selection == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: valueAlignment)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
        .accessibilityValue(selectedName)
    }
}
