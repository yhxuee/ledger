# Wallet Ledger for iOS

Wallet Ledger 2.0 is a local-first SwiftUI personal-finance application. It preserves the existing Liquid Glass design while replacing prototype aggregates with a versioned domain model, derived balances/analytics, durable local persistence, purchase workflows, and optional CloudKit-shared ledgers.

## Requirements

- Xcode 26 and the iOS 26 SDK for native Liquid Glass; deployment target iOS 17.
- An Apple Developer team for device signing, App Groups, Live Activities, push notifications, and CloudKit sharing.
- The app remains useful offline. Private local ledgers never require CloudKit.

## Architecture

- `Domain`: schema-v2 entities, v1 migration mirrors, pure balance/budget/analytics/refund/purchase presentation calculations.
- `Data`: `LedgerRepository`, local Application Support persistence, backup codecs, cached Frankfurter catalogue/rates, privacy controller, EventKit import, ActivityKit bridge, receipt storage, CloudKit record mapper and `CKSyncEngine` coordinators.
- `Features`: the existing Overview, Ledger, Analytics, Accounts and four-section Settings design plus dedicated editors, Budget Detail and Purchase Mode/Summary.
- `WalletLedgerWidget`: interactive Lock Screen/Dynamic Island Live Activity. The App Group snapshot coordinates active-purchase item completion; the main ledger remains a durable source of truth.

Balances, budget use and analytics are always derived from active transactions. There is no mutable stored total. Transfers are balance movements, refunds are linked exact reversals, and PurchaseSession aggregate rows are presentation-only.

## Schema v2 and migration

The native state schema is version 2. `SchemaMigration` decodes native v1 state/library/backup shapes and migrates legacy account budgets into an account-mode `BudgetPlan`. `LegacyWebBackup` converts supported Web backups. IDs, original amounts, `accountAmount`, `destinationAmount`, and historical `exchangeRateAtTransaction` snapshots are preserved.

Device-only preferences are stored in `app-preferences.json` and never enter a ledger backup or CloudKit record. Ledger finance configuration remains in `LedgerSettings`. Currency identifiers accept any valid three-letter ISO-style code; the Frankfurter catalogue and latest successful rates are cached for offline use.

## Privacy and destructive behavior

Biometric protection is centralized through `PrivacyController`. When locked, reusable sensitive-value views mask financial numbers while navigation remains usable. Disabling protection and Reset App Data authenticate when protection is enabled. Reset removes only local application state/caches/preferences and active-purchase App Group snapshots; it never deletes collaborators' CloudKit data.

Transactions and accounts keep soft-deletion behavior. Deleting a refund restores the original transaction's refundable state and Undo restores the linked pair.

## Backup and sharing

- `.walletledger` JSON exports remain the complete portable finance backup.
- iCloud Documents Back Up/Restore remains available.
- A backup imported while a shared ledger is active becomes a new local ledger.
- Shared ledgers use one custom CloudKit zone per logical LedgerBook and a zone-wide `CKShare`; they do not copy the JSON backup file.
- Accounts, transactions, categories, settings, budget plan, recurring rules, purchase sessions, purchase items, and receipt `CKAsset` references have explicit CloudKit record mappings.

## Apple capability setup

Source and project target changes are included, but these account-bound steps must be completed in Xcode/Developer Portal:

1. Select a development team for both `WalletLedger` and `WalletLedgerWidget`.
2. Register `org.medx.WalletLedger` and `org.medx.WalletLedger.Widget` (or change both identifiers consistently).
3. Create/enable `iCloud.org.medx.WalletLedger` with CloudKit and iCloud Documents, then select it on the app target.
4. Create/enable App Group `group.org.medx.WalletLedger` for both targets.
5. Enable Push Notifications and Background Modes > Remote notifications on the app target.
6. Enable Live Activities for the Widget Extension and confirm it is embedded in the app.
7. In CloudKit Dashboard development, deploy record types after a signed development build writes sample records; promote the schema to production before distribution.
8. Validate CloudKit invitations with two real iCloud accounts and Live Activity/AppIntent behavior on a real Dynamic Island device. Simulators do not provide full push/biometric/CloudKit validation.

## Verification

`WalletLedgerTests` covers balance semantics, soft deletion, native backup round-trip, native v1 migration, legacy Web conversion, flexible currencies, refund idempotency and deletion, both budget modes, multi-currency budgets, dynamic loan interest, deleted default-account mappings, PurchaseSession finalization/grouping, and CloudKit record mapping without network access.

This checkout is authored from Windows, where SwiftUI, ActivityKit, EventKit and CloudKit SDK compilation is unavailable. Run the included Xcode test target or the existing macOS GitHub Actions workflow before signing a release archive.
