import SwiftUI

enum AccountSelectorDisplay {
    case name
    case logo
}

/// One-line account selector for the transaction editor.
///
/// When display is .logo, the collapsed state displays the account Tag (account.logo), compactly without wrapping,
/// while the opened menu shows "DC   Daily Checking".
/// VoiceOver always receives the full name.
struct AccountSelectorMenu: View {
    let accounts: [LedgerAccount]
    @Binding var selection: UUID?
    var title: String
    var placeholder = "Select Account"
    var display: AccountSelectorDisplay = .name
    /// Visible width reserved for roughly this many English characters.
    var visibleCharacters = 15
    var valueAlignment: Alignment = .leading

    private var selectedAccount: LedgerAccount? {
        accounts.first { $0.id == selection }
    }

    private var selectedName: String {
        selectedAccount?.name ?? placeholder
    }

    private var displayedText: String {
        switch display {
        case .name:
            return selectedName
        case .logo:
            return selectedAccount?.logo ?? placeholder
        }
    }

    var body: some View {
        Menu {
            ForEach(accounts) { account in
                Button {
                    selection = account.id
                } label: {
                    let itemText = display == .logo ? "\(account.logo)   \(account.name)" : account.name
                    if account.id == selection {
                        Label(itemText, systemImage: "checkmark")
                    } else {
                        Text(itemText)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if display == .logo {
                    Text(displayedText)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsTightening(true)
                        .foregroundStyle(selection == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                } else {
                    MarqueeText(text: displayedText, font: .body, visibleCharacters: visibleCharacters, alignment: valueAlignment)
                        .foregroundStyle(selection == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(maxWidth: display == .logo ? nil : .infinity, alignment: valueAlignment)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
        .accessibilityValue(selectedName)
    }
}
