## Multi-currency accounts and account-side postings

### Account model
`LedgerAccount` gained `isMultiCurrency`, `currencyPockets: [AccountCurrencyPocket]` and `stockMetadata: StockMetadata?`. Pockets are **not** separate accounts. Multi-currency is only offered for `checking`, `savings` and `credit` (`LedgerAccount.multiCurrencyTypes`); every other type keeps single-currency behaviour. `currency` remains the primary currency, and for single-currency accounts `normalizedPockets` always resolves to exactly one pocket built from `currency` + `openingBalance`, so their behaviour is unchanged. Decoding lives in an extension, so accounts written before this feature load as a single-pocket account with no data loss.

### Pocket balances and account totals
`LedgerCalculations.pocketBalance` computes each pocket from its own opening balance plus only the postings routed to it. `balance(for:)` converts every pocket into the account's primary currency and sums the result, so changing the primary currency changes the displayed total only — never the underlying pocket balances. The account row shows `Checking · HKD · 4 currencies`, or `Stocks · US · AAPL`.

### Three amounts per transaction
- `amount` + `currency` — the original transaction denomination (never overwritten).
- `accountAmount` + `accountCurrency` — the actual posting on the source account pocket.
- `destinationAmount` + `destinationAccountCurrency` — the actual posting on the destination account pocket (transfers).

Balances always use the account-side postings; `accountAmount` is authoritative and is never recomputed from today's rate. When the transaction currency differs from the account pocket currency the editor shows an editable **Account Amount** (or **From/To Account Amount** for transfers), prefilled from the cached FX rate with an "Estimated from current FX rate" hint and a "Reset to estimated …" action once the user types their own value. A manually entered value is stored as-is; only an untouched value follows an amount or currency edit.

### Pocket selection
Transactions and recurring rules store the pocket they post to (`accountCurrency`, `destinationAccountCurrency`). The editor defaults to the transaction currency when the account already holds it, otherwise to the primary currency, and `LedgerStore.resolvedPocket` rejects an unknown pocket instead of silently redirecting money. A pocket that still holds a balance cannot be removed (`LedgerStore.pocketRemovalMessage`).

### Refunds
`RefundEngine` reverses the original pockets and the original account-side amounts exactly (`accountCurrency`, `accountAmount`, `destinationAccountCurrency`, `destinationAmount`); a refund never re-prices the original posting with the current FX rate.

### Transaction currency selector
`TransactionCurrencySheet` replaces the previous all-currencies menu: HKD, USD, GBP, JPY, CNY, EUR, SGD, CHF first, then an **Other Currencies** disclosure that expands inline with a live code search over the remaining fiat currencies and USD stablecoins. Currencies are identified by code, amounts keep using symbols. The existing account currency picker is untouched.

### Stocks
`StockMarket` (US/HK/CN) determines the settlement currency (USD/HKD/CNY) and `StockMetadata` holds the market + manually typed symbol. Stocks accounts show Market and Stock Code instead of a currency picker; symbols are normalised offline (US `AAPL`, HK `0700`, CN `600519`) and a "Market data lookup is not configured yet." note makes clear that no quote service exists. Nothing is priced, fetched or auto-completed.

### Persistence
`SchemaMigration.normalize` runs on local load, CloudKit decode and backup import. It fills in single pockets for legacy accounts, keeps the primary currency mirrored in `openingBalance`, and re-creates a pocket that an active posting still references so money can never disappear from a total. `BackupCodec.validate` checks pocket presence, primary membership and that transaction/rule pockets belong to their accounts.
