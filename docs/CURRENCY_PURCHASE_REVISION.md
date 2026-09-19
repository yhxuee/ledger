# Currency and Purchase revision — build 9

## Architecture and changed files

- Shared domain identities now live in `WalletLedgerShared/FinanceIdentifiers.swift`; purchase entities in `PurchaseModels.swift`. Both app and widget compile these sources.
- `Domain/CurrencyRates.swift` resolves live reference rates. `LedgerCalculations.swift`, `LedgerStore.swift`, `RefundEngine.swift`, and `BackupCodec.swift` use it. Financial totals remain derived.
- `Components/CurrencyPickerLink.swift` implements the hierarchical picker; `AccountsPortfolioSummaryView.swift` replaces only the Accounts dashboard card.
- `Features/Purchases/PurchaseModeView.swift` contains inline grouped editing and item-count active progress. `PurchaseSummaryView.swift` uses purchase units. `PurchaseLedgerPresentation.swift` owns presentation-only aggregation.
- `Data/PurchaseLiveActivity.swift`, shared attributes/state/progress ring/intent, and `WalletLedgerWidget/PurchaseLiveActivityWidget.swift` implement explicit activity results and updated presentations.
- Backup/local JSON/CloudKit migration paths are updated in `BackupCodec.swift`, `LedgerRepository.swift`, `PurchaseRules.swift`, and `CloudRecordMapper.swift`.
- `LedgerView.swift` uses a native large root title. Secondary screens remain inline.
- `Shared/MoneyFormatting.swift` centralizes the two monetary display semantics; `DesignSystem.swift` exposes them as `LedgerFormat`. `SettingsEditors.swift` locks stablecoin reference values and shows symbols next to budget allocation amounts.
- The test workflow now runs all WalletLedgerTests and exports rendering screenshots and an ActivityKit environment diagnostic.

## Stablecoins and FX

The five explicit identifiers are USDT, USDC, PYUSD, BUSD, GUSD. Three-letter ASCII ISO-style codes remain accepted; arbitrary longer identifiers do not. BTC is not added to the catalogue.

All five resolve through USD in `CurrencyRates.reference`, even if stale or contradictory stablecoin dictionary entries exist. Settings changes and successful fiat refreshes mirror the USD value for compatibility, but calculations do not depend on those copies. The Frankfurter service and endpoint are unchanged; the app merges stablecoins into the cached catalogue locally.

Creation snapshots USD's reference rate while retaining the stablecoin code. Note/category-only edits retain historical snapshots/account-side amounts; amount edits with unchanged currency/account scale original account-side amounts. Changing the transaction's currency or accounts explicitly resolves current FX. Historical transactions are not rewritten during migration or catalogue/rate refresh.

## Currency selection

Account Currency opens eight preferred codes in this order: HKD, USD, GBP, JPY, CNY, EUR, SGD, CHF. Other is searchable and excludes preferred currencies/stablecoins. Stablecoins opens exactly five code/English-name rows under a crypto SF Symbol. Purchase pickers use codes only. Missing-rate currencies explain that a rate must first be configured. The existing desired-balance conversion behavior remains.

Catalogue names from the network/locale are sanitized at the app boundary. Currency UI never relies on localized currency names.

## Schema-2 purchase payment and migration

A session owns `currency` and `accountID`; the latter may be nil only while a draft requires a selection, or for a historical development session with ambiguous old payment accounts. Items no longer choose accounts. `resolvedAccountID` is retained solely to decode development data.

Older schema-2 sessions infer the previous ledger base currency. A unique legacy item/child account is recovered where possible; ambiguous unfinished sessions return to draft and require an explicit payment account. Existing financial children are never rewritten or duplicated. No schema-3 bump is introduced.

Payment references are validated by backup decoding and the start/finalize rules. Deleting the payment account stops an unfinished active session and retains the unavailable reference for explicit repair. It never selects an unrelated account.

CloudKit session headers now carry currency/account/update metadata and item IDs. Header item IDs prevent an old cached/deleted draft item from reappearing. The existing zone/CKSyncEngine architecture is unchanged. Shared snapshots carry the full session and its code, with coordinated atomic file operations.

## Purchase entry, grouping, and finalization

Add Item immediately inserts a name/category/amount row and focuses its name. Category selection, numeric entry, swipe deletion and ordering happen inline. Each category is one subtly tinted native section using its category color; empty groups disappear. Draft mutations are saved immediately, not only when leaving the editor.

Every finalized child uses session.currency/session.accountID and the item's own amount/category/note. Account-side FX conversion still happens in normal transaction creation. No financial parent is created. List/active/summary/widget/aggregate totals use the session's currency. Search/filter still returns actual child transactions.

## Live Activity investigation and changes

Confirmed source defects in the prior implementation: disabled authorization returned silently, Activity.request used try?, and App Group write failures were discarded. The completion AppIntent was only in the widget target. The shared intent now conforms to LiveActivityIntent and belongs to both targets, following [Apple's interactivity guidance](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities).

Start now durably saves the active session, attempts the shared snapshot, then explicitly requests the activity. Typed results distinguish started/updated/disabled/shared-storage failure/request failure, plus a combined result for a running activity whose shared snapshot could not be written. NSError domain, code and description are surfaced through the app's error presentation. A request is always attempted even when the App Group snapshot fails, so a missing App Group entitlement can no longer suppress the visible activity. A denied activity never prevents in-app purchasing.

Expanded Island: circular item-count progress at left, completed amount at right, next three incomplete items with interactive checks below. All widget and Lock Screen amounts use session currency with symbol formatting (`$48.20`), never `USDT 48.20`. Compact: cart/check plus completion percentage. Minimal: circular gauge. Lock Screen: title, progress/count, completed/planned amounts. Completed sessions keep a deep link to the summary. The in-app screen uses the same item-count metric; monetary progress is independently calculated.

A previously installed unsigned/re-signed IPA may lack the required App Group authorization. CI deliberately builds unsigned and clears entitlements for the IPA; the checked-in entitlement files alone do not provision a device. This is a concrete configuration risk, not a confirmed diagnosis of a particular phone's request error. Use the new error details to identify that phone's failure.

## Monetary display rules

Two distinct semantics exist and are centralized in `LedgerMoneyFormat` (shared by app and widget):

- Normal money display uses the currency symbol: `LedgerFormat.money` / `LedgerMoneyFormat.symbol` produce `$1,234.00`, `£25.00`, `¥1,234`, `€20.00`. Compact form stays symbol-based and keeps one meaningful decimal (`$12.5k`, `$120k`, `£15k`). `SensitiveMoneyText`, portfolio/account balances, Weekly Activity, budgets, Analytics, the transaction editor, recurring summaries, purchase screens, aggregates and the Live Activity all use this path.
- Transaction-list display uses the canonical currency code: `LedgerFormat.transaction` / `LedgerMoneyFormat.code` produce `HKD 120.00`, `+USD 500.00`, `USDT 50.00`. Only `TransactionRow` (Overview > Latest Transactions and the main Ledger list, including purchase children) may use it.

Currencies without a distinct symbol keep their code as a separated fallback (`CHF 1,000.00`); `CurrencyCode.symbol` is the single source, and the five USD stablecoins map to `$` there. Selectors, metadata such as `Checking · HKD`, persisted identifiers and error/search text keep using `CurrencyCode.rawValue`; symbols are never persisted.

## Project configuration audited

- Existing `WalletLedgerWidget` target remains embedded via Embed App Extensions and target dependency.
- App ID: `org.medx.WalletLedger`; widget ID: `org.medx.WalletLedger.Widget`.
- Both targets compile `WalletLedgerShared` and use `group.org.medx.WalletLedger`.
- Both deployment targets remain iOS 17. NSSupportsLiveActivities remains true. App/extension versions match (build 9).
- No new target, permission key or entitlement is needed for this revision. Existing CloudKit/iCloud Documents configuration is preserved.

## Verification and device checklist

Automated coverage includes identifier codecs/rejection, aliases and historical snapshots, symbol-vs-code money formatting (`MoneyFormattingTests`), backup/CloudKit payment round trips, legacy development migration, session-currency unified finalization, idempotency, category moves, deleted accounts, progress/next-three ordering, and injected request failure presentation. Existing refund, budget, recurring, migration, filtering and Analytics rendering tests continue to run.

Simulator rendering tests cover purchase editing, active purchase and Accounts at phone/tablet-sized layouts, including privacy masking. The ActivityKit diagnostic records the production controller result and a separate real Activity.request attempt; it does not assert hardware UI behavior.

Required before device acceptance:

1. Select the same Developer team for app and widget; register both bundle IDs and enable the same App Group on both profiles.
2. Re-sign the app AND embedded extension with profiles that preserve App Group entitlements. Do not assume a generic IPA re-sign preserves them.
3. Install, allow Live Activities in iOS Settings, start a valid list while foregrounded, and check the explicit result. A "started but shared storage unavailable" result means the activity is visible while the App Group snapshot is not being written.
4. On compatible hardware inspect compact/minimal/expanded Island and Lock Screen; check/uncheck in app, check next-three controls, lock/unlock, terminate/relaunch, and return via deep link.
5. Verify shared ledgers with two iCloud users, including changed purchase payment metadata and removal of draft items.

Physical-device/Dynamic Island validation has not been performed from this Windows environment. CI/simulator results are reported separately in the delivery response.

