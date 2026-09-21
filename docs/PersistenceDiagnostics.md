# Persistence and synchronization diagnostics

## Storage and compatibility

- Local saves use `ledger.sqlite`, with an indexed document table and atomic transactions. Accounts, transactions, recurring rules, and purchases are separate rows. Only changed entities are encoded and written after the first save. Ordered identifiers and ledger metadata commit in the same transaction.
- Existing `library.json` and native v1 libraries remain readable. The original JSON remains available for recovery after migration. New saves use SQLite; the retained JSON is not a current backup. Portable `.fsy` and legacy import formats are unchanged.
- SQLite uses bound parameters, WAL, full synchronous commits, secure deletion, and complete file protection. A load uses one read transaction so it cannot combine two library revisions.
- The application still holds its domain state in memory and loads the library at startup. This change does not introduce UI pagination. Measure cold-start cost and peak resident memory on the target device for exceptionally large libraries.
- Each CloudKit database has a disk journal containing record bodies, server change tags, durable pending changes, stable asset copies, engine state, and pending local delivery. The engine state alone is never treated as a record store.
- Encryption configuration has its own backward-compatible optional timestamp. The outbox retains the last known encryption requirement, so an older plaintext snapshot cannot bypass it after relaunch or a concurrent server update. A deliberate later owner disable still works.

## Logging

Apple unified logging uses subsystem `com.finsy.app` with categories:

| Category | Evidence |
| --- | --- |
| `persistence` | Load/save duration, book and transaction counts, database/save failures |
| `cloud-sync` | Queued, saved, failed and deleted record counts; outbox, decode and merge errors |
| `security` | Encryption migration batch progress, completion/failure and asset cleanup failures |
| `market-data` | Provider operation and request duration |
| `live-activity` | Foreground alert requests, standard requests, disabled activities and request failures |

Use the macOS Console app with a connected device, filtering by subsystem. For a booted simulator:

```sh
xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "com.finsy.app"'
```

Logs deliberately exclude payloads, financial values, attachment filenames, symbols, API keys and credential-bearing request URLs. Error logging records the operation, error domain, and numeric code. Existing widget and Live Activity diagnostics remain available.

## Regression tests

`FinsyTests/PersistenceSecurityTests.swift` covers missing-key rejection, attachment traversal/symlink rejection, malicious cloud attachments, entity-level merging, active-ledger preservation, timestamp stability, SQLite round-trip/delta writes, rollback, durable record/asset recovery, bounded caches, changed-record selection, and encryption-policy conflict/recovery cases.

Run the complete existing XCTest suite as well as these tests on macOS with the iOS SDK. Select an installed simulator with `xcrun simctl list devices available`, then:

```sh
xcodebuild test -project Finsy.xcodeproj -scheme Finsy \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-UUID>'
```

## Device verification

1. On two iCloud accounts, independently edit different transactions and the same transaction. Verify both ledgers, pending changes and final balances; verify that updates to an inactive ledger do not switch the visible ledger.
2. Edit offline, switch ledgers, terminate and relaunch. Reconnect and verify every pending save and deletion. Terminate during incoming synchronization to verify delivery replays after restart.
3. Enable encryption with existing receipts, interrupt connectivity between batches and relaunch. Confirm migration resumes with the same key, all payloads/assets are encrypted, and failures never produce a success state.
4. Join an encrypted ledger without a key. Verify no placeholder data uploads. Import the grant while offline, then reconnect and verify that actual data is restored before unlocking normal synchronization.
5. Remove a share and verify the last local copy is retained without recreating the remote zone. Reset local data with pending work and verify that cancelled coordinators do not recreate the old library.
6. Profile cold launch, single-transaction saves and cloud catch-up at 10k/50k/100k transactions with Instruments Time Profiler and Allocations. Use Leaks/Memory Graph to verify lifetimes; source inspection is not evidence that there are no runtime leaks.

Windows validation can check Swift syntax and SQL statements, but cannot compile Apple SDK integrations or execute XCTest, CloudKit, Keychain and Instruments checks.

## Remaining-issues follow-up

- Recent Transaction now issues an alerting update immediately after creating its foreground transient activity. Background shortcuts use a standard activity. Operation identity checks prevent an older request from replacing the newer request's lifecycle task. Presentation and background expiry still require device testing; an in-process timer cannot be guaranteed to run while iOS suspends the app.
- `RecordTransactionIntent` records directly, requires device authentication, and exposes numeric amount, currency and category selections. Category labels distinguish expense and income. The amount is the final amount posted, with the existing tax calculation applied. Expense categories use their mapped available account, falling back to the first available account; income uses the first available account. The original navigation intent remains available. A failed save throws and removes that insertion; a failed activity does not report the saved transaction as failed.
- Account reordering uses an explicit rounded preview and drop handling, with no `onMove` or `EditMode`. Order changes only on a valid same-ledger drop, so cancelling a drag does not change order. VoiceOver move actions remain available. Verify the drag preview, scrolling, swipe actions and drop placement on hardware.
- Account/transaction merge and CKRecord conflict handling compare logical versions before timestamps. Equal versions still use timestamps; this does not establish causal ordering for concurrent same-version edits. Entities without meaningful versions and encryption policy still use their existing timestamp rules.
- SQLite hydration reuses a prepared bound statement and releases temporary decoding objects per row. **Startup still eagerly loads the full library.** Lazy transaction hydration is not implemented. It requires changing the complete-array contract used by calculations, backups, recurring processing and synchronization.
- Encryption migration checks the persisted key before each upload batch and completion. Cancellation or a missing/changed key aborts completion. The failure recovery state is durably saved when storage remains available. These checks do not replace interruption or two-device validation.

### Runtime scale tests (added, not executed on Windows)

`LargeLedgerPerformanceTests` includes 10k, 50k and 100k SQLite reopen/load tests with XCTest clock and memory metrics, full initial writes, one-record delta writes, and equality checks after reload. Each attaches timings plus database and live WAL byte counts to the result bundle. A 10k outbox test writes durable records, reopens, acknowledges a 200-record batch and verifies 9,800 entries remain after another reopen. These are warm-filesystem reopen measurements, not device cold-launch measurements.

```sh
xcodebuild test -project Finsy.xcodeproj -scheme Finsy \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-UUID>' \
  -only-testing:FinsyTests/PersistenceSecurityTests \
  -only-testing:FinsyTests/LargeLedgerPerformanceTests \
  -resultBundlePath PersistenceScale.xcresult
```

Still unverified: large JSON migration, large attachment collections, CloudKit network throughput and peak sync memory, actual process termination between CloudKit batches, remote deletion versus pending edits, encryption migration conflicts, participant edits during owner migration, and zone removal with queued local edits. Record device/OS, ledger size, database/WAL bytes, latency, peak memory, pending counts before/after, and resulting balances for each device run. Do not treat the SQL checks or these unexecuted tests as proof of end-to-end scalability.

API references: [ActivityKit presentation and background intents](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [intent authentication](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy).

## Validation performed on 2026-09-21

- `git diff --check`: passed.
- Tree-sitter Swift parsing compared with the repository baseline: no added diagnostics in the modified files. The parser has existing diagnostics in `SettingsView.swift`; this is not a Swift compiler result.
- Executed the actual repository SQL statements with SQLite: parameter binding, no-op updates, rollback, an indexed 100,000-row range lookup, and a one-row update passed. This checks SQL behavior, not the Swift/iOS integration or end-to-end performance.
- Compared the two edited Settings view files against their prior versions: layout and control declarations are unchanged; edits are confined to action handlers.
- XCTest, Xcode build, signed-device synchronization, and Instruments profiling: not run in the Windows environment.

Follow-up validation: `git diff --check` passed using the repository's normal line-ending configuration. The 13 modified Swift files produced no added tree-sitter diagnostics. A 100,000-row SQLite check passed ordered/repeated bound lookups and missing/hostile-key checks. The newly added XCTest cases and performance metrics have not been executed. No timing or memory improvement is claimed from source inspection.
