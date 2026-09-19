import SwiftUI

struct TransactionRow: View {
    @EnvironmentObject private var preferences: AppPreferencesStore
    let transaction: LedgerTransaction
    let category: LedgerCategory
    var body: some View {
        HStack(spacing: 13) {
            CategoryIcon(category: category, font: .system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: category.colorHex))
                .frame(width: 40, height: 40)
                .background(Color(hex: category.colorHex).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.note?.isEmpty == false ? transaction.note! : category.name).font(.body.weight(.semibold)).lineLimit(1).strikethrough(transaction.isRefunded)
                Text("\(category.name) · \(preferences.value.dateFormat.transactionDateString(from: transaction.occurredAt))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SensitiveTransactionMoneyText(amount: transaction.amount, currency: transaction.currency, type: transaction.type, maxIntegerDigits: 4)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(transaction.type == .income ? .green : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(minWidth: LedgerAmountWidth.row, alignment: .trailing)
                .layoutPriority(1)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .opacity(transaction.isRefunded ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}
