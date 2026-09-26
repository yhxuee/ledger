# Apple Wallet Passes

## Account pass

- Uses Apple's `storeCard` layout with the app logo and Finsy name.
- The fixed serial `finsy-primary-account-pass` prevents duplicate account cards.
- Source is All (net worth) or one account in its own currency.
- Header: current month. Primary: balance. Secondary: monthly expenses and income.
- Auxiliary: entry count and account budget remaining, or today's spending when category budgets are selected.
- Back: source account and the most recent five posted entries.
- Up to ten relevant locations can provide Lock Screen suggestions.

## Receipt pass

- Uses Apple's `coupon` layout with a subtle theme-colored serrated strip.
- Header: transaction date in the chosen Settings order. Primary: actual paid total.
- Secondary: item count and account tag. Auxiliary: invoice number and ledger refund status.
- Back: store, tax and itemized details.
- Add-to-Wallet asks whether to include a barcode. Scan a real receipt or import a photo, then choose QR or Code 128.
- Stable serial `purchase-{sessionID}` allows ledger changes to replace the installed receipt.
- Invoice numbers are assigned in creation order and retained in the purchase session. Legacy sessions receive numbers when saved.

## Updates and compatibility

While Finsy is open, ledger changes, synchronization and relevant settings changes
refresh installed passes through the HTTPS issuer and `PKPassLibrary.replacePass`.
The app also refreshes on foreground entry. A manual update remains available.
There is no Wallet web-service registration or background APNs pass update.
Older receipts with random serial numbers remain snapshots; add a new receipt to enable refresh.
Tax Pass has been removed. Tax analytics exports a serrated receipt image.

See [issuer setup](WALLET_PASS_ISSUER.md) and [server instructions](../WalletIssuer/README.md).
