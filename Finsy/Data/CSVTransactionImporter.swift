import Foundation
import CryptoKit

enum CSVImportError: LocalizedError, Sendable {
    case emptyFile
    case lineError(line: Int, message: String)
    case ambiguousAccount(String)
    case ambiguousCategory(String)
    case missingRate(CurrencyCode)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return String(localized: "The CSV file is empty or contains no data rows.")
        case .lineError(let line, let message):
            return String(format: String(localized: "Line %d: %@"), line, message)
        case .ambiguousAccount(let name):
            return String(format: String(localized: "Ambiguous account name '%@': multiple active accounts match this name."), name)
        case .ambiguousCategory(let name):
            return String(format: String(localized: "Ambiguous category name '%@': multiple categories match this name."), name)
        case .missingRate(let currency):
            return String(format: String(localized: "Missing exchange rate for currency '%@'. Please configure the exchange rate before importing."), currency.rawValue)
        case .validationFailed(let reason):
            return String(format: String(localized: "Import validation failed: %@"), reason)
        }
    }
}

enum CSVTransactionImporter {
    struct RawRow {
        var line: Int
        var map: [String: String]
    }

    /// RFC 4180 compliant character-stream CSV parser supporting quoted strings,
    /// escaped quotes (""), embedded newlines, and trailing empty columns.
    static func parseRFC4180(text: String) throws -> [(line: Int, fields: [String])] {
        var rows: [(line: Int, fields: [String])] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var currentLine = 1
        var rowStartLine = 1

        let chars = Array(text)
        var i = 0
        let count = chars.count

        while i < count {
            let c = chars[i]

            if inQuotes {
                if c == "\"" {
                    if i + 1 < count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    if c == "\n" {
                        currentLine += 1
                    } else if c == "\r" {
                        if i + 1 < count && chars[i + 1] == "\n" {
                            currentField.append("\r\n")
                            currentLine += 1
                            i += 2
                            continue
                        } else {
                            currentLine += 1
                        }
                    }
                    currentField.append(c)
                    i += 1
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                    i += 1
                } else if c == "," {
                    currentRow.append(currentField)
                    currentField = ""
                    i += 1
                } else if c == "\r" || c == "\n" {
                    currentRow.append(currentField)
                    currentField = ""
                    rows.append((line: rowStartLine, fields: currentRow))
                    currentRow = []
                    if c == "\r" && i + 1 < count && chars[i + 1] == "\n" {
                        i += 2
                    } else {
                        i += 1
                    }
                    currentLine += 1
                    rowStartLine = currentLine
                } else {
                    currentField.append(c)
                    i += 1
                }
            }
        }

        if inQuotes {
            throw CSVImportError.lineError(line: rowStartLine, message: "unclosed quotation mark")
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append((line: rowStartLine, fields: currentRow))
        }

        return rows
    }

    private static func parseTaxRate(_ raw: String?) -> (rate: Double?, isValid: Bool) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (nil, true)
        }
        if raw.hasSuffix("%") {
            let numPart = raw.dropLast().trimmingCharacters(in: .whitespaces)
            if let val = Double(numPart), val.isFinite {
                return (val / 100.0, true)
            }
            return (nil, false)
        }
        if let val = Double(raw), val.isFinite {
            return (val, true)
        }
        return (nil, false)
    }

    private static func parseDate(dateStr: String, timeStr: String) -> Date? {
        let trimmedDate = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTime = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if trimmedTime.isEmpty {
            combined = trimmedDate
        } else {
            combined = "\(trimmedDate) \(trimmedTime)"
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: combined) {
                return d
            }
        }
        return nil
    }

    private static func deterministicUUID(
        csvId: String,
        date: String,
        time: String,
        type: String,
        account: String,
        destinationAccount: String,
        currency: String,
        amount: Double
    ) -> UUID {
        let identity = "\(csvId.lowercased())|\(date)|\(time)|\(type.lowercased())|\(account.lowercased())|\(destinationAccount.lowercased())|\(currency.uppercased())|\(String(format: "%.4f", amount))"
        let digest = SHA256.hash(data: Data(identity.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // Version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isEquivalent(tx1: LedgerTransaction, tx2: LedgerTransaction) -> Bool {
        guard tx1.type == tx2.type,
              tx1.accountID == tx2.accountID,
              tx1.destinationAccountID == tx2.destinationAccountID,
              tx1.currency == tx2.currency,
              abs(tx1.amount - tx2.amount) < 0.0001,
              tx1.categoryID == tx2.categoryID,
              abs(tx1.occurredAt.timeIntervalSince(tx2.occurredAt)) < 1.0 else {
            return false
        }
        return true
    }

    static func convertToImportPreview(
        csvText: String,
        sourceName: String,
        existingState: LedgerState
    ) throws -> ImportPreview {
        let allParsedRows = try parseRFC4180(text: csvText)
        guard !allParsedRows.isEmpty else {
            throw CSVImportError.emptyFile
        }

        // Find header row (first non-empty row)
        guard let headerEntry = allParsedRows.first(where: { row in
            row.fields.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }) else {
            throw CSVImportError.emptyFile
        }

        let headers = headerEntry.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let headerCount = headers.count

        var dataRows: [RawRow] = []
        var foundHeader = false

        for row in allParsedRows {
            if !foundHeader {
                if row.line == headerEntry.line {
                    foundHeader = true
                }
                continue
            }

            // Skip completely empty lines
            if row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            guard row.fields.count == headerCount else {
                throw CSVImportError.lineError(
                    line: row.line,
                    message: "expected \(headerCount) columns, found \(row.fields.count)"
                )
            }

            var map: [String: String] = [:]
            for (idx, name) in headers.enumerated() {
                map[name] = row.fields[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            dataRows.append(RawRow(line: row.line, map: map))
        }

        guard !dataRows.isEmpty else {
            throw CSVImportError.emptyFile
        }

        // 1. Index active existing accounts and detect ambiguities
        var activeAccountsByName: [String: LedgerAccount] = [:]
        for acc in existingState.accounts where acc.deletedAt == nil {
            let key = acc.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if activeAccountsByName[key] != nil {
                throw CSVImportError.ambiguousAccount(acc.name)
            }
            activeAccountsByName[key] = acc
        }

        // 2. Index categories by id, name, and displayName
        var categoryLookup: [String: LedgerCategory] = [:]
        for cat in existingState.categories {
            let keys = [cat.id.rawValue, cat.name, cat.displayName].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            for key in keys where !key.isEmpty {
                if let existing = categoryLookup[key], existing.id != cat.id {
                    throw CSVImportError.ambiguousCategory(key)
                }
                categoryLookup[key] = cat
            }
        }

        // 3. Scan rows to identify missing accounts, infer currencies, and account types
        struct AccountObservation {
            var originalName: String
            var explicitType: AccountType?
            var isTypeDefaulted: Bool
            var referencedCurrencies: [CurrencyCode]
        }

        var accountObservations: [String: AccountObservation] = [:]

        for row in dataRows {
            let map = row.map
            let sourceAcct = map["account"] ?? ""
            guard !sourceAcct.isEmpty else {
                throw CSVImportError.lineError(line: row.line, message: "missing account name")
            }
            let normSource = sourceAcct.lowercased()

            let txCurrStr = map["currency"] ?? ""
            guard let txCurr = CurrencyCode(rawValue: txCurrStr.uppercased()) else {
                throw CSVImportError.lineError(line: row.line, message: "invalid currency \"\(txCurrStr)\"")
            }

            let acctCurrStr = map["account_currency"] ?? ""
            let acctCurr: CurrencyCode
            if acctCurrStr.isEmpty {
                acctCurr = txCurr
            } else if let parsed = CurrencyCode(rawValue: acctCurrStr.uppercased()) {
                acctCurr = parsed
            } else {
                throw CSVImportError.lineError(line: row.line, message: "invalid account currency \"\(acctCurrStr)\"")
            }

            let typeCol = map["account_type"]
            let explicitType = (typeCol?.isEmpty == false) ? AccountType.from(aliasOrRaw: typeCol!) : nil

            if activeAccountsByName[normSource] == nil {
                if var obs = accountObservations[normSource] {
                    if !obs.referencedCurrencies.contains(acctCurr) {
                        obs.referencedCurrencies.append(acctCurr)
                    }
                    if obs.explicitType == nil && explicitType != nil {
                        obs.explicitType = explicitType
                        obs.isTypeDefaulted = false
                    }
                    accountObservations[normSource] = obs
                } else {
                    accountObservations[normSource] = AccountObservation(
                        originalName: sourceAcct,
                        explicitType: explicitType,
                        isTypeDefaulted: explicitType == nil,
                        referencedCurrencies: [acctCurr]
                    )
                }
            }

            let typeRaw = (map["type"] ?? "expense").lowercased()
            if typeRaw == "transfer" {
                let destAcct = map["destination_account"] ?? ""
                guard !destAcct.isEmpty else {
                    throw CSVImportError.lineError(line: row.line, message: "transfer requires a destination account")
                }
                let normDest = destAcct.lowercased()

                let destCurrStr = map["destination_currency"] ?? ""
                let destCurr: CurrencyCode
                if destCurrStr.isEmpty {
                    destCurr = txCurr
                } else if let parsed = CurrencyCode(rawValue: destCurrStr.uppercased()) {
                    destCurr = parsed
                } else {
                    throw CSVImportError.lineError(line: row.line, message: "invalid destination currency \"\(destCurrStr)\"")
                }

                let destTypeCol = map["destination_account_type"]
                let explicitDestType = (destTypeCol?.isEmpty == false) ? AccountType.from(aliasOrRaw: destTypeCol!) : nil

                if activeAccountsByName[normDest] == nil {
                    if var obs = accountObservations[normDest] {
                        if !obs.referencedCurrencies.contains(destCurr) {
                            obs.referencedCurrencies.append(destCurr)
                        }
                        if obs.explicitType == nil && explicitDestType != nil {
                            obs.explicitType = explicitDestType
                            obs.isTypeDefaulted = false
                        }
                        accountObservations[normDest] = obs
                    } else {
                        accountObservations[normDest] = AccountObservation(
                            originalName: destAcct,
                            explicitType: explicitDestType,
                            isTypeDefaulted: explicitDestType == nil,
                            referencedCurrencies: [destCurr]
                        )
                    }
                }
            }
        }

        // 4. Create missing accounts
        var createdAccounts: [LedgerAccount] = []
        var createdAccountSummaries: [CreatedAccountSummary] = []
        var missingAccountWarnings: [String] = []

        for (normKey, obs) in accountObservations.sorted(by: { $0.key < $1.key }) {
            let primaryCurrency = obs.referencedCurrencies.first ?? .HKD
            let accountType = obs.explicitType ?? .checking
            let supportsMulti = accountType.supportsMultiCurrency
            let hasMultiplePockets = supportsMulti && obs.referencedCurrencies.count > 1

            let pockets: [AccountCurrencyPocket]
            if supportsMulti {
                pockets = obs.referencedCurrencies.map { AccountCurrencyPocket(currency: $0, openingBalance: 0) }
            } else {
                pockets = []
            }

            let newAccount = LedgerAccount(
                id: UUID(),
                userID: existingState.settings.userID,
                name: obs.originalName,
                type: accountType,
                currency: primaryCurrency,
                openingBalance: 0,
                budget: 0,
                includeInBudget: false,
                logo: AccountTag.sanitize(obs.originalName),
                cardStyle: CardStyle(startHex: "86C5DA", endHex: "C6E7CF"),
                isMultiCurrency: hasMultiplePockets,
                currencyPockets: pockets,
                createdAt: .now,
                updatedAt: .now,
                deletedAt: nil,
                version: 1,
                syncStatus: .pending
            )

            createdAccounts.append(newAccount)
            activeAccountsByName[normKey] = newAccount
            createdAccountSummaries.append(CreatedAccountSummary(
                id: newAccount.id,
                name: newAccount.name,
                type: newAccount.type,
                currency: newAccount.currency,
                isTypeDefaulted: obs.isTypeDefaulted
            ))

            if obs.isTypeDefaulted {
                missingAccountWarnings.append("Account '\(newAccount.name)' was created as Checking because the CSV did not specify an account type.")
            }
            if !supportsMulti && obs.referencedCurrencies.count > 1 {
                missingAccountWarnings.append("Account '\(newAccount.name)' was created as \(accountType.rawValue), which does not support multi-currency. Pockets were not created for additional currencies.")
            }
        }

        // Ensure existing multi-currency accounts have pockets for newly referenced currencies
        var mutableAccounts = existingState.accounts
        for (idx, acc) in mutableAccounts.enumerated() {
            guard acc.deletedAt == nil, acc.usesCurrencyPockets else { continue }
            let normKey = acc.name.lowercased()
            // Check if any row referenced a pocket currency not currently in acc
            var updatedPockets = acc.currencyPockets
            var pocketChanged = false
            for row in dataRows {
                let map = row.map
                if (map["account"] ?? "").lowercased() == normKey {
                    if let currStr = map["account_currency"] ?? map["currency"],
                       let code = CurrencyCode(rawValue: currStr.uppercased()),
                       !acc.pocketCurrencies.contains(code),
                       !updatedPockets.contains(where: { $0.currency == code }) {
                        updatedPockets.append(AccountCurrencyPocket(currency: code, openingBalance: 0))
                        pocketChanged = true
                    }
                }
                if (map["type"] ?? "").lowercased() == "transfer",
                   (map["destination_account"] ?? "").lowercased() == normKey {
                    if let currStr = map["destination_currency"] ?? map["currency"],
                       let code = CurrencyCode(rawValue: currStr.uppercased()),
                       !acc.pocketCurrencies.contains(code),
                       !updatedPockets.contains(where: { $0.currency == code }) {
                        updatedPockets.append(AccountCurrencyPocket(currency: code, openingBalance: 0))
                        pocketChanged = true
                    }
                }
            }
            if pocketChanged {
                mutableAccounts[idx].currencyPockets = updatedPockets
                activeAccountsByName[normKey] = mutableAccounts[idx]
            }
        }

        // 5. Working exchange rates dictionary
        var workingRates = existingState.settings.rates
        workingRates[.HKD] = 1.0

        // 6. Build and validate transactions
        var transactions: [LedgerTransaction] = []
        var existingTransactionsByID: [UUID: LedgerTransaction] = Dictionary(
            uniqueKeysWithValues: existingState.transactions.map { ($0.id, $0) }
        )
        var newTransactionsByID: [UUID: LedgerTransaction] = [:]

        var duplicateTransactionCount = 0
        var remappedLinkedCategoryCount = 0
        var fallbackCurrentRateCount = 0

        for row in dataRows {
            let map = row.map
            let line = row.line

            // Date & Time
            let dateStr = map["date"] ?? ""
            let timeStr = map["time"] ?? ""
            guard let date = parseDate(dateStr: dateStr, timeStr: timeStr) else {
                throw CSVImportError.lineError(line: line, message: "invalid date \"\(dateStr)\"")
            }

            // Type
            let rawType = (map["type"] ?? "expense").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let txType: LedgerTransactionType
            switch rawType {
            case "expense": txType = .expense
            case "income": txType = .income
            case "transfer": txType = .transfer
            default:
                throw CSVImportError.lineError(line: line, message: "unsupported transaction type \"\(rawType)\"")
            }

            // Source Account
            let sourceName = (map["account"] ?? "").lowercased()
            guard let sourceAccount = activeAccountsByName[sourceName] else {
                throw CSVImportError.lineError(line: line, message: "missing account \"\(map["account"] ?? "")\"")
            }

            // Currencies
            let currStr = (map["currency"] ?? "").uppercased()
            guard let currencyCode = CurrencyCode(rawValue: currStr) else {
                throw CSVImportError.lineError(line: line, message: "invalid currency \"\(currStr)\"")
            }

            let acctCurrRaw = map["account_currency"] ?? ""
            let acctCurrencyCode: CurrencyCode
            if acctCurrRaw.isEmpty {
                acctCurrencyCode = currencyCode
            } else if let parsed = CurrencyCode(rawValue: acctCurrRaw.uppercased()) {
                acctCurrencyCode = parsed
            } else {
                throw CSVImportError.lineError(line: line, message: "invalid account currency \"\(acctCurrRaw)\"")
            }

            // Amounts
            guard let amount = Double(map["amount"] ?? ""), amount.isFinite, amount > 0 else {
                throw CSVImportError.lineError(line: line, message: "amount must be finite and greater than zero")
            }

            let acctAmount: Double
            if let rawAcctAmt = map["account_amount"], !rawAcctAmt.isEmpty {
                guard let parsed = Double(rawAcctAmt), parsed.isFinite, parsed > 0 else {
                    throw CSVImportError.lineError(line: line, message: "account amount must be finite and greater than zero")
                }
                acctAmount = parsed
            } else {
                acctAmount = amount
            }

            // Destination Account (for transfer)
            let destAccountID: UUID?
            let destAmount: Double?
            let destCurrencyCode: CurrencyCode?

            if txType == .transfer {
                let destName = (map["destination_account"] ?? "").lowercased()
                guard let destAccount = activeAccountsByName[destName] else {
                    throw CSVImportError.lineError(line: line, message: "transfer destination account \"\(map["destination_account"] ?? "")\" does not exist")
                }

                let destCurrRaw = map["destination_currency"] ?? ""
                if destCurrRaw.isEmpty {
                    destCurrencyCode = currencyCode
                } else if let parsed = CurrencyCode(rawValue: destCurrRaw.uppercased()) {
                    destCurrencyCode = parsed
                } else {
                    throw CSVImportError.lineError(line: line, message: "invalid destination currency \"\(destCurrRaw)\"")
                }

                if let rawDestAmt = map["destination_amount"], !rawDestAmt.isEmpty {
                    guard let parsed = Double(rawDestAmt), parsed.isFinite, parsed > 0 else {
                        throw CSVImportError.lineError(line: line, message: "destination amount must be finite and greater than zero")
                    }
                    destAmount = parsed
                } else {
                    destAmount = acctAmount
                }

                // Transfer invariant checks
                let sourcePocket = sourceAccount.usesCurrencyPockets ? acctCurrencyCode : nil
                let destPocket = destAccount.usesCurrencyPockets ? destCurrencyCode : nil
                guard TransactionSemantics.validTransfer(
                    source: sourceAccount,
                    destinationID: destAccount.id,
                    sourceCurrency: sourcePocket,
                    destinationCurrency: destPocket
                ) else {
                    throw CSVImportError.lineError(line: line, message: "source and destination cannot form an invalid same-account transfer")
                }

                destAccountID = destAccount.id
            } else {
                destAccountID = nil
                destAmount = nil
                destCurrencyCode = nil
            }

            // Category Resolution & Compatibility
            var txCategoryID: LedgerCategoryID = .other
            var note = map["note"] ?? ""

            if txType == .transfer {
                txCategoryID = .other
            } else {
                let catKey = (map["category"] ?? "Other").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let matchedCategory = categoryLookup[catKey] else {
                    throw CSVImportError.lineError(line: line, message: "unknown category \"\(map["category"] ?? "")\"")
                }

                if matchedCategory.isSystemLinked {
                    if txType == .income {
                        txCategoryID = .otherIncome
                        remappedLinkedCategoryCount += 1
                        if note.isEmpty {
                            note = matchedCategory.name
                        }
                    } else {
                        throw CSVImportError.lineError(
                            line: line,
                            message: "system-linked category '\(matchedCategory.name)' cannot be used for \(txType.rawValue) transaction"
                        )
                    }
                } else {
                    if txType == .expense {
                        guard matchedCategory.kind == .expense else {
                            throw CSVImportError.lineError(
                                line: line,
                                message: "expense transaction cannot use income category \"\(matchedCategory.name)\""
                            )
                        }
                    } else if txType == .income {
                        guard matchedCategory.kind == .income else {
                            throw CSVImportError.lineError(
                                line: line,
                                message: "income transaction cannot use expense category \"\(matchedCategory.name)\""
                            )
                        }
                    }
                    txCategoryID = matchedCategory.id
                }
            }

            // Historical FX handling
            let exchangeRateAtTransaction: Double
            let explicitRateStr = map["exchange_rate_at_transaction"] ?? map["exchange_rate"]
            if let explicitRateStr, !explicitRateStr.isEmpty {
                guard let parsedRate = Double(explicitRateStr), parsedRate.isFinite, parsedRate > 0 else {
                    throw CSVImportError.lineError(line: line, message: "exchange_rate_at_transaction must be finite and greater than zero")
                }
                exchangeRateAtTransaction = parsedRate
                if workingRates[currencyCode] == nil {
                    workingRates[currencyCode] = parsedRate
                }
            } else if currencyCode == .HKD {
                exchangeRateAtTransaction = 1.0
            } else if acctCurrencyCode != currencyCode,
                      let refAcct = CurrencyRates.reference(acctCurrencyCode, in: workingRates) {
                exchangeRateAtTransaction = abs(acctAmount * refAcct) / abs(amount)
                if workingRates[currencyCode] == nil {
                    workingRates[currencyCode] = exchangeRateAtTransaction
                }
            } else if let refCurr = CurrencyRates.reference(currencyCode, in: workingRates) {
                exchangeRateAtTransaction = refCurr
                fallbackCurrentRateCount += 1
            } else if let bundled = SeedData.rates[currencyCode] {
                exchangeRateAtTransaction = bundled
                workingRates[currencyCode] = bundled
                fallbackCurrentRateCount += 1
            } else {
                throw CSVImportError.lineError(
                    line: line,
                    message: "no exchange rate available for currency \(currencyCode.rawValue)"
                )
            }

            // Transaction ID determination
            let csvId = map["id"] ?? ""
            let txID: UUID
            if let parsedUUID = UUID(uuidString: csvId) {
                txID = parsedUUID
            } else {
                txID = deterministicUUID(
                    csvId: csvId,
                    date: dateStr,
                    time: timeStr,
                    type: txType.rawValue,
                    account: sourceName,
                    destinationAccount: map["destination_account"] ?? "",
                    currency: currencyCode.rawValue,
                    amount: amount
                )
            }

            // Construct transaction
            var tx = LedgerTransaction(
                id: txID,
                userID: existingState.settings.userID,
                type: txType,
                accountID: sourceAccount.id,
                destinationAccountID: destAccountID,
                amount: amount,
                currency: currencyCode,
                accountAmount: acctAmount,
                destinationAmount: destAmount,
                accountCurrency: sourceAccount.usesCurrencyPockets ? acctCurrencyCode : nil,
                destinationAccountCurrency: (txType == .transfer && destAccountID != nil && (activeAccountsByName[map["destination_account"]?.lowercased() ?? ""]?.usesCurrencyPockets == true)) ? destCurrencyCode : nil,
                categoryID: txCategoryID,
                occurredAt: date,
                note: note.isEmpty ? nil : note,
                exchangeRateAtTransaction: exchangeRateAtTransaction,
                createdAt: date,
                updatedAt: date,
                deletedAt: nil,
                version: 1,
                syncStatus: .pending
            )

            // Tax validation
            if txType == .transfer {
                tx.taxRate = nil
                tx.taxAmount = nil
                tx.taxBaseAmount = nil
                tx.taxInputMode = nil
                tx.isTaxExempt = nil
            } else {
                let parsedTaxRateResult = parseTaxRate(map["tax_rate"])
                guard parsedTaxRateResult.isValid else {
                    throw CSVImportError.lineError(line: line, message: "invalid tax_rate \"\(map["tax_rate"] ?? "")\"")
                }

                let rawTaxRate = parsedTaxRateResult.rate
                let rawTaxAmount = Double(map["tax_amount"] ?? "")
                let rawTaxBase = Double(map["tax_base_amount"] ?? "")
                let rawTaxMode = map["tax_input_mode"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let isExempt = (map["is_tax_exempt"]?.lowercased() == "true")

                let hasTax = rawTaxRate != nil || rawTaxAmount != nil || rawTaxBase != nil || (rawTaxMode?.isEmpty == false)
                if hasTax {
                    guard let rate = rawTaxRate,
                          let taxAmt = rawTaxAmount,
                          let baseAmt = rawTaxBase,
                          let modeStr = rawTaxMode,
                          let mode = TaxInputMode(rawValue: modeStr) else {
                        throw CSVImportError.lineError(
                            line: line,
                            message: "incomplete tax snapshot: tax_rate, tax_amount, tax_base_amount, and tax_input_mode must all be present"
                        )
                    }

                    guard rate.isFinite, rate >= 0 else {
                        throw CSVImportError.lineError(line: line, message: "tax_rate must be finite and non-negative")
                    }
                    if txType == .income {
                        guard rate < 1.0 else {
                            throw CSVImportError.lineError(line: line, message: "income tax_rate must be less than 1.0 (100%)")
                        }
                    } else {
                        guard rate <= 10.0 else {
                            throw CSVImportError.lineError(line: line, message: "expense tax_rate exceeds maximum 10.0 (1000%)")
                        }
                    }

                    guard taxAmt.isFinite, taxAmt >= 0 else {
                        throw CSVImportError.lineError(line: line, message: "tax_amount must be finite and non-negative")
                    }
                    guard baseAmt.isFinite, baseAmt >= 0 else {
                        throw CSVImportError.lineError(line: line, message: "tax_base_amount must be finite and non-negative")
                    }

                    guard let resolved = TaxCalculations.resolve(
                        entered: tx.amount,
                        type: txType,
                        rate: rate,
                        mode: mode,
                        exempt: isExempt
                    ) else {
                        throw CSVImportError.lineError(line: line, message: "failed to compute tax snapshot")
                    }

                    let taxDiff = abs(TaxCalculations.rounded(resolved.tax) - taxAmt)
                    let baseDiff = abs(TaxCalculations.rounded(resolved.base) - baseAmt)
                    guard taxDiff <= 0.02, baseDiff <= 0.02 else {
                        throw CSVImportError.lineError(
                            line: line,
                            message: "inconsistent tax snapshot: expected tax \(TaxCalculations.rounded(resolved.tax)), base \(TaxCalculations.rounded(resolved.base)), found tax \(taxAmt), base \(baseAmt)"
                        )
                    }

                    tx.taxRate = rate
                    tx.taxAmount = taxAmt
                    tx.taxBaseAmount = baseAmt
                    tx.taxInputMode = mode
                    tx.isTaxExempt = isExempt ? true : nil
                }
            }

            // Duplicate detection and conflict prevention
            if let existing = existingTransactionsByID[tx.id] {
                if isEquivalent(tx1: tx, tx2: existing) {
                    duplicateTransactionCount += 1
                    continue
                } else {
                    throw CSVImportError.lineError(
                        line: line,
                        message: "transaction ID '\(csvId)' conflicts with an existing transaction with different content"
                    )
                }
            }

            if let pending = newTransactionsByID[tx.id] {
                if isEquivalent(tx1: tx, tx2: pending) {
                    duplicateTransactionCount += 1
                    continue
                } else {
                    throw CSVImportError.lineError(
                        line: line,
                        message: "transaction ID '\(csvId)' conflicts with another imported transaction with different content"
                    )
                }
            }

            newTransactionsByID[tx.id] = tx
            transactions.append(tx)
        }

        // 7. Reference rates preflight across all used currencies
        let allAccounts = mutableAccounts + createdAccounts
        let usedCurrencies = Set(
            allAccounts.map(\.currency) +
            allAccounts.flatMap { ($0.coupons ?? []).map(\.currency) } +
            allAccounts.flatMap { $0.pocketCurrencies } +
            transactions.map(\.currency) +
            transactions.compactMap(\.accountCurrency) +
            transactions.compactMap(\.destinationAccountCurrency) +
            [existingState.settings.baseCurrency, .HKD]
        )

        for curr in usedCurrencies {
            if CurrencyRates.reference(curr, in: workingRates) == nil {
                if let bundled = SeedData.rates[curr] {
                    workingRates[curr] = bundled
                } else if CurrencyCode.usdStablecoins.contains(curr),
                          let usdRate = CurrencyRates.reference(.USD, in: workingRates) {
                    workingRates[curr] = usdRate
                } else {
                    throw CSVImportError.missingRate(curr)
                }
            }
        }
        workingRates = CurrencyRates.mirroringUSDAliases(workingRates)

        // 8. Assemble imported state and normalize
        var importedState = existingState
        importedState.accounts = allAccounts
        importedState.transactions.append(contentsOf: transactions)
        importedState.settings.rates = workingRates
        SchemaMigration.normalize(&importedState)

        // 9. Strict integrity validation before returning preview
        do {
            try BackupCodec.validate(importedState)
        } catch {
            throw CSVImportError.validationFailed(error.localizedDescription)
        }

        // 10. Assemble warnings
        var warnings: [String] = []
        warnings.append(contentsOf: missingAccountWarnings)
        if remappedLinkedCategoryCount > 0 {
            warnings.append("\(remappedLinkedCategoryCount) linked-system category rows were imported as ordinary Other Income because CSV cannot reconstruct refund/reimbursement/settlement relationships.")
        }
        if fallbackCurrentRateCount > 0 {
            warnings.append("\(fallbackCurrentRateCount) transactions used current reference exchange rates because no historical conversion rate was specified.")
        }
        warnings.append(String(localized: "CSV imports transactions only. Group, split, installment, and CloudKit links are not reconstructed."))

        // Deduplicate warnings preserving order
        var seenWarnings = Set<String>()
        warnings = warnings.filter { seenWarnings.insert($0).inserted }

        let envelope = LedgerBackupEnvelope(
            metadata: BackupMetadata(
                app: "finsy",
                schemaVersion: BackupCodec.currentSchemaVersion,
                exportedAt: .now,
                userID: existingState.settings.userID,
                accountCount: importedState.accounts.filter { $0.deletedAt == nil }.count,
                transactionCount: importedState.transactions.filter { $0.deletedAt == nil }.count,
                categoryCount: importedState.categories.count,
                baseCurrency: importedState.settings.baseCurrency
            ),
            data: importedState
        )

        let report = CSVImportReport(
            parsedRowCount: dataRows.count,
            importedTransactionCount: transactions.count,
            createdAccountCount: createdAccounts.count,
            duplicateTransactionCount: duplicateTransactionCount,
            skippedRowCount: duplicateTransactionCount,
            remappedLinkedCategoryCount: remappedLinkedCategoryCount,
            rejectedRowCount: 0,
            createdAccounts: createdAccountSummaries,
            warnings: warnings
        )

        return ImportPreview(
            sourceName: sourceName,
            envelope: envelope,
            warnings: warnings,
            sourceKind: .csvFlat,
            csvReport: report
        )
    }
}
