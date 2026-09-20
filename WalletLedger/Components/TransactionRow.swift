import SwiftUI

struct TransactionRow: View {
    @EnvironmentObject private var preferences: AppPreferencesStore
    let transaction: LedgerTransaction
    let category: LedgerCategory
    var showsDate = true
    var attention: TransactionAttentionState? = nil
    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, font: .system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: category.colorHex))
                .frame(width: 40, height: 40)
                .background(Color(hex: category.colorHex).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.note?.isEmpty == false ? transaction.note! : category.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(transaction.isRefunded)
                Group {
                    if showsDate {
                        Text("\(category.name) · \(preferences.value.dateFormat.transactionDateString(from: transaction.occurredAt))")
                    } else {
                        Text(category.name)
                    }
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                if let attention {
                    Group {
                        switch attention {
                        case .splitOutstanding(let count): Text("Split ? \(count) unpaid")
                        case .reimbursementPending(let amount, let currency):
                            Text("Awaiting Reimbursement") + Text(" ? ") + Text(LedgerMoneyFormat.code(amount, currency: currency))
                        }
                    }.font(.caption.weight(.semibold)).foregroundStyle(.red)
                } else if transaction.groupMode == .split {
                    Text("Fully Settled").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)

            Spacer(minLength: 4)

            SensitiveTransactionMoneyText(amount: transaction.amount, currency: transaction.currency, type: transaction.type, maxIntegerDigits: 4)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(transaction.type == .income ? .green : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: LedgerAmountWidth.row, alignment: .trailing)
                .layoutPriority(0)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .opacity(transaction.isRefunded || (transaction.linkedTransactionKind == .installment && transaction.occurredAt > .now) ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}
