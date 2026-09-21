import SwiftUI

enum TransactionDisclosure: Equatable, Sendable {
    case standard
    case collapsed
    case expanded
    case none

    var systemImage: String? {
        switch self {
        case .standard, .collapsed: return "chevron.right"
        case .expanded: return "chevron.down"
        case .none: return nil
        }
    }
}

struct TransactionRow: View {
    @EnvironmentObject private var preferences: AppPreferencesStore
    let transaction: LedgerTransaction
    let category: LedgerCategory
    var showsDate = true
    var groupStatus: GroupStatusPresentation? = nil
    var disclosure: TransactionDisclosure = .standard
    var subtitleOverride: String? = nil

    private var isPendingChild: Bool {
        if transaction.linkedTransactionKind == .splitSettlement {
            return transaction.linkedStatus == .pending
        }
        if transaction.linkedTransactionKind == .reimbursementIncome {
            return transaction.linkedStatus == .pending
        }
        if transaction.linkedTransactionKind == .installment {
            return !transaction.isEffectivelyCompleted
        }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, font: .system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: category.colorHex))
                .frame(width: 40, height: 40)
                .background(Color(hex: category.colorHex).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.groupMode == .combinedPayment ? String(localized: "Combined Payment") : (transaction.note?.isEmpty == false ? transaction.note! : category.displayName))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(transaction.isRefunded)
                Group {
                    if let subtitleOverride {
                        Text(subtitleOverride)
                    } else if showsDate {
                        Text("\(category.displayName) · \(preferences.value.dateFormat.transactionDateString(from: transaction.occurredAt))")
                    } else {
                        Text(category.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                SensitiveTransactionMoneyText(amount: transaction.amount, currency: transaction.currency, type: transaction.type, maxIntegerDigits: 4)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(transaction.type == .income ? .green : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let groupStatus {
                    Text(groupStatus.localizedText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(groupStatus.isPending ? .red : .green)
                        .lineLimit(1)
                } else if isPendingChild {
                    Text("Pending")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: LedgerAmountWidth.row, alignment: .trailing)
            .layoutPriority(0)

            if let icon = disclosure.systemImage {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .animation(.snappy, value: disclosure)
            }
        }
        .padding(.vertical, 9)
        .opacity(transaction.isRefunded || isPendingChild ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}
