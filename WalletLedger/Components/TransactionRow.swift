import SwiftUI

struct TransactionRow: View {
    let transaction: LedgerTransaction
    let category: LedgerCategory
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: category.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LedgerPalette.category(category.id))
                .frame(width: 40, height: 40)
                .background(LedgerPalette.category(category.id).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.note?.isEmpty == false ? transaction.note! : category.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(category.name) · \(transaction.occurredAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(LedgerFormat.transaction(transaction.amount, currency: transaction.currency, type: transaction.type))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(transaction.type == .income ? .green : .primary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
