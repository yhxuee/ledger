# Wallet Ledger for iOS

Native SwiftUI reconstruction of the `wallet-ledger-overview` personal-finance PWA. Open `WalletLedger.xcodeproj` in Xcode 26.

Version 1.3.0 separates the Overview/Accounts toolbar actions into native Liquid Glass controls, keeps the Ledger title visible above a glass calendar, fixes exchange-rate keyboard dismissal, adds Frankfurter daily reference-rate refresh with offline caching, and adds recurring expense, income, and transfer rules with weekly, monthly, yearly, or custom-day schedules.

## Requirements

- Xcode 26 with the iOS 26 SDK for Liquid Glass.
- Deployment target iOS 17. The app uses native Liquid Glass on iOS 26 and falls back to system materials on iOS 17–25.
- An Apple Development team for device builds and iCloud Documents.

## First build

1. Open `WalletLedger.xcodeproj`.
2. Select the `WalletLedger` target, Signing & Capabilities, and choose your team.
3. Change `org.medx.WalletLedger` if you need a different bundle identifier.
4. Add/verify the iCloud capability with **iCloud Documents** enabled.
5. If the bundle identifier changes, replace `iCloud.org.medx.WalletLedger` in `WalletLedger.entitlements` with a container owned by your team.
6. Select an iPhone or iPad simulator and Build. iCloud container operations require a signed app and an Apple ID; Files export/import works without iCloud.

## Architecture

- `Domain`: Codable entities, sample data and pure financial calculations.
- `Data`: local Application Support persistence, versioned backup codec, Web-backup conversion, Files document support and iCloud Documents backup.
- `Design`: shared colors, formatting, Liquid Glass compatibility and adaptive surfaces.
- `Features`: Overview, Ledger, Analytics, Accounts, Settings and transaction editor.

Balances are derived from `openingBalance + active ledger entries`. Expense, income and transfer effects are applied exactly once. Transfers never count as expense analytics. Monthly budget includes only participating accounts and only current-month expenses. Historical reporting uses each transaction’s saved FX snapshot.

Frankfurter refreshes HKD-reference rates at most once per local calendar day when automatic updates are enabled. A manual refresh remains available, and the last successful values stay available offline. Recurring rules are processed on launch, ledger switch, and whenever the app becomes active; missed due dates are caught up without creating the same occurrence twice.

## Backup formats

- Native exports use the `.walletledger` extension and JSON content.
- The importer validates IDs, account references, transfer destinations, values, rates and schema version before showing a confirmation preview.
- JSON backups exported by the Web PWA (`wallet-ledger-overview`, schema v2) are converted into the native schema during import.
- “Back Up Now” writes `WalletLedger-latest.walletledger` to the app’s iCloud Documents container.

## Verification

The `WalletLedgerTests` target covers expense/income/transfer balance effects, deleted-entry exclusion, budget semantics and backup round trips. This repository was generated on Windows, so the final SDK compile and simulator run must be performed in Xcode 26.
