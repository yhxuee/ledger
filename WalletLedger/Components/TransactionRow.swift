import SwiftUI

struct TransactionRow: View {
    @EnvironmentObject private var preferences: AppPreferencesStore
    let transaction: LedgerTransaction
    let category: LedgerCategory
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
                Text("\(category.name) · \(preferences.value.dateFormat.transactionDateString(from: transaction.occurredAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
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
        .opacity(transaction.isRefunded ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}
