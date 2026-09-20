import Foundation

enum CSVTransactionImporter {
    struct ParsedRow {
        var id: String
        var date: String
        var time: String
        var type: String
        var account: String
        var destinationAccount: String
        var category: String
        var note: String
        var currency: String
        var amount: Double
        var accountCurrency: String
        var accountAmount: Double?
        var destinationCurrency: String
        var destinationAmount: Double?
        var taxRate: Double?
        var taxAmount: Double?
        var taxBaseAmount: Double?
        var taxInputMode: String?
        var isTaxExempt: Bool
    }

    static func parseRows(from text: String) -> [ParsedRow] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }

        let headers = parseCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var rows: [ParsedRow] = []

        for lineIndex in 1..<lines.count {
            let cols = parseCSVLine(lines[lineIndex])
            guard cols.count == headers.count else { continue }

            var map: [String: String] = [:]
            for (i, h) in headers.enumerated() {
                map[h] = cols[i].trimmingCharacters(in: .whitespaces)
            }

            let id = map["id"] ?? UUID().uuidString
            let date = map["date"] ?? ""
            let time = map["time"] ?? "00:00"
            let type = map["type"] ?? "expense"
            let account = map["account"] ?? ""
            let destAccount = map["destination_account"] ?? ""
            let category = map["category"] ?? "Other"
            let note = map["note"] ?? ""
            let currency = map["currency"] ?? "USD"
            let amount = Double(map["amount"] ?? "") ?? 0.0
            let acctCurr = map["account_currency"] ?? currency
            let acctAmt = Double(map["account_amount"] ?? "")
            let destCurr = map["destination_currency"] ?? ""
            let destAmt = Double(map["destination_amount"] ?? "")
            let taxRate = Double(map["tax_rate"] ?? "")
            let taxAmount = Double(map["tax_amount"] ?? "")
            let taxBase = Double(map["tax_base_amount"] ?? "")
            let taxMode = map["tax_input_mode"]
            let isExempt = (map["is_tax_exempt"]?.lowercased() == "true")

            rows.append(ParsedRow(
                id: id,
                date: date,
                time: time,
                type: type,
                account: account,
                destinationAccount: destAccount,
                category: category,
                note: note,
                currency: currency,
                amount: amount,
                accountCurrency: acctCurr,
                accountAmount: acctAmt,
                destinationCurrency: destCurr,
                destinationAmount: destAmt,
                taxRate: taxRate,
                taxAmount: taxAmount,
                taxBaseAmount: taxBase,
                taxInputMode: taxMode,
                isTaxExempt: isExempt
            ))
        }

        return rows
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let c = iterator.next() {
            if c == "\"" {
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                results.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        results.append(current)
        return results
    }

    static func convertToImportPreview(
        csvText: String,
        sourceName: String,
        existingState: LedgerState
    ) throws -> ImportPreview {
        let rows = parseRows(from: csvText)
        guard !rows.isEmpty else {
            throw BackupError.corruptArchive
        }

        var accountsByName: [String: LedgerAccount] = [:]
        for acc in existingState.accounts {
            accountsByName[acc.name.lowercased()] = acc
        }

        var categoriesByName: [String: LedgerCategory] = [:]
        for cat in existingState.categories {
            categoriesByName[cat.id.rawValue.lowercased()] = cat
        }

        var missingAccounts: Set<String> = []
        var missingCategories: Set<String> = []
        var transactions: [LedgerTransaction] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = TimeZone.current

        for r in rows {
            let normalizedAccount = r.account.lowercased()
            guard let account = accountsByName[normalizedAccount] else {
                missingAccounts.insert(r.account)
                continue
            }

            var destAccountID: UUID? = nil
            if !r.destinationAccount.isEmpty {
                let normDest = r.destinationAccount.lowercased()
                if let dest = accountsByName[normDest] {
                    destAccountID = dest.id
                } else {
                    missingAccounts.insert(r.destinationAccount)
                    continue
                }
            }

            let normalizedCat = r.category.lowercased()
            guard let category = categoriesByName[normalizedCat] else {
                missingCategories.insert(r.category)
                continue
            }

            let dateString = "\(r.date) \(r.time)"
            let date = dateFormatter.date(from: dateString) ?? .now
            let txType: TransactionType
            switch r.type.lowercased() {
            case "income": txType = .income
            case "transfer": txType = .transfer
            default: txType = .expense
            }

            let currencyCode = CurrencyCode(rawValue: r.currency) ?? account.currency
            let acctCurrencyCode = CurrencyCode(rawValue: r.accountCurrency) ?? account.currency
            let destCurrencyCode = r.destinationCurrency.isEmpty ? nil : CurrencyCode(rawValue: r.destinationCurrency)

            var taxSnapshot: TaxRateSnapshot? = nil
            if let rate = r.taxRate, rate > 0 {
                taxSnapshot = TaxRateSnapshot(
                    rate: rate,
                    amount: r.taxAmount ?? 0,
                    baseAmount: r.taxBaseAmount ?? r.amount,
                    inputMode: TaxInputMode(rawValue: r.taxInputMode ?? "finalAmount") ?? .finalAmount,
                    isTaxExempt: r.isTaxExempt
                )
            }

            let tx = LedgerTransaction(
                id: UUID(),
                date: Calendar.current.startOfDay(for: date),
                occurredAt: date,
                time: r.time,
                type: txType,
                accountID: account.id,
                destinationAccountID: destAccountID,
                categoryID: category.id,
                note: r.note,
                currency: currencyCode,
                amount: r.amount,
                exchangeRateAtTransaction: 1.0,
                taxSnapshot: taxSnapshot,
                accountCurrency: acctCurrencyCode,
                accountAmount: r.accountAmount ?? r.amount,
                destinationAccountCurrency: destCurrencyCode,
                destinationAccountAmount: r.destinationAmount,
                updatedAt: date
            )
            transactions.append(tx)
        }

        var warnings: [String] = []
        if !missingAccounts.isEmpty {
            for missing in missingAccounts.sorted() {
                warnings.append("Account '\(missing)' does not exist. Please create it or verify mapping before importing.")
            }
        }
        if !missingCategories.isEmpty {
            for missing in missingCategories.sorted() {
                warnings.append("Category '\(missing)' does not exist.")
            }
        }
        warnings.append("CSV imports transactions only. Group, split, installment, and CloudKit links are not reconstructed.")

        var importedState = existingState
        importedState.transactions.append(contentsOf: transactions)
        SchemaMigration.normalize(&importedState)

        let envelope = LedgerBackupEnvelope(
            metadata: BackupMetadata(
                app: "wallet-ledger-ios",
                schemaVersion: BackupCodec.currentSchemaVersion,
                exportedAt: .now,
                userID: existingState.settings.userID,
                accountCount: existingState.accounts.count,
                transactionCount: transactions.count,
                categoryCount: existingState.categories.count,
                baseCurrency: existingState.settings.baseCurrency
            ),
            data: importedState
        )

        return ImportPreview(
            sourceName: sourceName,
            envelope: envelope,
            warnings: warnings
        )
    }
}
