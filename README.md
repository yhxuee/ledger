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

### Currency controls and market data

- `PopupSelectionButton` uses the existing presentation-layer overlay, anchored to the compact value button. It expands over that frame, chooses upward/downward placement, clamps to the visible container, and closes on selection or an outside tap. The transition lasts 0.22 seconds. Only Other opens the searchable currency screen; stablecoins remain available there.
- Settings > Market Data stores the Alpha Vantage key in a non-synchronizing, device-only Keychain item. Requests use an ephemeral URL session. The key is not a field of any ledger, preferences, CloudKit record, App Group snapshot, or exported backup.
- Stocks use market-derived settlement currency, cost price and quantity. Account and portfolio values use the cached quote, or cost basis when unavailable. Legacy stock metadata decodes with zero cost and quantity; enter holdings to establish its valuation. No trades or P/L transactions are generated.
- Symbol search waits 500 ms and requires two characters. Requests and results are shared across market filters. Provider symbols are retained verbatim; manual HK/CN codes require selection of a provider result before quotes can be fetched, because exchange suffixes are never guessed.
- `StockQuoteRefreshService` reserves per-market/date/slot attempts durably before requests, deduplicates symbols across ledgers, retains prices on errors, and applies cached results to all matching accounts. Quote trading dates and fetch timestamps are distinct from Frankfurter timestamps. The UI deliberately labels prices as last available, following [Alpha Vantage's quote freshness documentation](https://www.alphavantage.co/documentation/).
- The bundled holiday calendar covers 2026, including early-close session checks. Sources: [NYSE](https://www.nyse.com/trade/hours-calendars), [HKEX](https://www.hkex.com.hk/-/media/HKEX-Market/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2025/ce_SEHK_CT_075_2025.pdf), [SSE](https://www.sse.com.cn/disclosure/announcement/general/c/c_20251222_10802507.shtml). Future years require positive market-open evidence until annual calendars are added; unconfirmed after-hours days are skipped. A closed status during a normal session suppresses quotes, including later slots until an open status is observed.
- Launch, foreground and BGAppRefreshTask use the same catch-up path. Missing slots from the current market day are coalesced into one quote fetch per symbol. Background requests specify the next slot as an earliest start, never a guaranteed execution time. Frankfurter remains an independent once-per-successful-calendar-day pipeline with an in-flight guard.

For this change, Swift syntax parsing, plist validation and whitespace checks are available on Windows. The unsigned Release build requires macOS/Xcode; no XCTest was run. The existing `.github/workflows/build-ipa.yml` builds unsigned Release with tests disabled by default.

`WalletLedgerTests` covers balance semantics, soft deletion, native backup round-trip, native v1 migration, legacy Web conversion, flexible currencies, refund idempotency and deletion, both budget modes, multi-currency budgets, dynamic loan interest, deleted default-account mappings, PurchaseSession finalization/grouping, and CloudKit record mapping without network access.

This checkout is authored from Windows, where SwiftUI, ActivityKit, EventKit and CloudKit SDK compilation is unavailable. Run the included Xcode test target or the existing macOS GitHub Actions workflow before signing a release archive.
