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
| `persistence` | Save duration, book count, database/save failures |
| `cloud-sync` | Queued, saved, failed and deleted record counts; outbox, decode and merge errors |
| `security` | Encryption migration completion/failure and asset cleanup failures |
| `market-data` | Provider operation and request duration |

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

## Validation performed on 2026-09-21

- `git diff --check`: passed.
- Tree-sitter Swift parsing compared with the repository baseline: no added diagnostics in the modified files. The parser has existing diagnostics in `SettingsView.swift`; this is not a Swift compiler result.
- Executed the actual repository SQL statements with SQLite: parameter binding, no-op updates, rollback, an indexed 100,000-row range lookup, and a one-row update passed. This checks SQL behavior, not the Swift/iOS integration or end-to-end performance.
- Compared the two edited Settings view files against their prior versions: layout and control declarations are unchanged; edits are confined to action handlers.
- XCTest, Xcode build, signed-device synchronization, and Instruments profiling: not run in the Windows environment.
