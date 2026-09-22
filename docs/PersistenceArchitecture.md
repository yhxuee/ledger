# Finsy persistence architecture

## Storage and state invariants

1. `ledger.sqlite` is the authoritative local store after a successful import. The `documents`
   table contains the manifest, one header per book, and one blob per entity.
2. The manifest contains every book ID exactly once and its active book ID must be in that set.
3. A book header contains the complete IDs for accounts, transactions, recurring rules, and
   purchase sessions. Every listed blob must exist, contain the same ID, and decode successfully.
   Extra blobs are also an integrity failure because an interrupted or older writer may have made
   the header incomplete.
4. `LedgerState.transactions` always means the complete canonical transaction set for that book.
   It is never a UI page and is never partially hydrated.
5. `LedgerTransactionCatalog` contains the complete durable ID set, including tombstones.
   `LedgerTransactionPage` and `recentTransactions` return detached bounded query results.
   Neither alters `LedgerState` nor can be passed to the normal save path as a canonical snapshot.
6. The transaction index is derived. Header IDs and transaction blobs remain authoritative.
   Index rows and a `(formatVersion, transactionCount, SHA-256(sorted transaction IDs))`
   certificate are committed in the same SQLite transaction as mutations. A missing/mismatched
   certificate, row count, or digest of the actual index IDs causes a transactional full rebuild
   before any index query runs. Indexed blob reads also verify each decoded transaction ID against
   its requested key; a mismatched payload is an integrity error.
7. `library.json` is a legacy one-way import source. SQLite saves do not update it, so it is not a
   current replica. If SQLite exists but fails structural or semantic validation, a valid JSON
   snapshot may be shown only in read-only recovery mode. It never overwrites SQLite automatically.
   An SQLite file with ledger rows but no manifest is incomplete, not a clean legacy import target.
   Mutations in recovery mode are rejected at their entry points; export remains available.
8. A save updates entity blobs, header, manifest, derived index, and index certificate in one
   `BEGIN IMMEDIATE` transaction. Termination before commit leaves the previous complete snapshot;
   termination after commit exposes the new complete snapshot.
   The repository also offers `applyTransactionDelta` for explicit upserts and hard removals. It
   leaves every unmentioned canonical ID and blob untouched and updates the header, index, and
   certificate atomically. Normal user deletion is a tombstone upsert. The running store has not
   switched to this path yet; it still saves complete snapshots until all domain consumers migrate.
9. Full `BackupCodec.validate` runs after complete materialization. It is never run against a page.
   `loadMetadata()` provides a separate nontransaction snapshot for the future lazy store. It
   verifies manifest/header/catalog/index structure without decoding transaction payloads when
   the index is healthy. It cannot prove the embedded ID or semantics of an unread payload; full
   validation remains mandatory at import, backup, and other complete-snapshot boundaries.
10. CloudKit generation, conflict merging, encryption migration, backup/export, calculations,
    recurring processing, undo, and ledger switching operate on fully materialized state.
11. Unsigned builds retain the `FINSY_UNSIGNED_BUILD` runtime gate and never initialize
    `CKContainer`. Signed builds retain the entitlement-backed path.
12. Startup does not save unless recurring processing creates a real mutation.

## Direct answers to the persistence audit

The authoritative transaction store is the header-reachable transaction blob set in SQLite.
`LedgerState.transactions` is always complete and cannot represent partial state. A visible page is
the array returned by the transaction repository query. Persistence, CloudKit, and backup obtain
complete data from `LedgerState`; storage tools can independently call `materializeFullLibrary()`.
Because partial canonical state is forbidden, there is no merge step between unsaved edits and
unloaded durable transactions.

Index completeness is established by the certificate, row count, and actual index ID digest. The certificate is published
atomically only after every row has been indexed. An interrupted rebuild rolls back, leaving the
old certificate/index or no certificate; the next query rebuilds it. The stable keyset order is:

```text
occurred_at DESC, transaction_id DESC
```

The cursor contains both values and the next predicate is `(date < cursorDate) OR
(date == cursorDate AND id < cursorID)`. Equal timestamps therefore cannot skip or duplicate rows.
`hasMoreTransactions` currently remains false because the production Ledger screen uses the fully
materialized state; repository pagination is available for bounded consumers but is not presented
as canonical state.

A corrupt SQLite store is one that cannot open, decode, satisfy its manifest/header/blob catalogs,
match entity IDs, or pass complete semantic validation. An older store with a valid manifest and
complete catalogs is accepted and its missing derived index certificate is rebuilt on demand.
Ambiguous stores are preserved for recovery instead of repaired by deletion.

Complete validation is required at startup, after CloudKit decode/merge, and during backup import.
Mutation, saving, CloudKit, encryption migration, backup/export, linked-record validation,
recurring/installment processing, balances, analytics, and statements require complete state.
Repository range/page queries are safe for presentation and range selection only when callers also
materialize any linked records their operation needs.

## Recovery and authority scenarios

| Case | Authority and behavior |
|---|---|
| A. Valid current SQLite | SQLite loads, fully materializes, normalizes, and validates. |
| B. Valid legacy JSON | JSON imports in memory; the first real mutation writes canonical SQLite. |
| C. Valid JSON plus corrupt SQLite | JSON opens read-only; SQLite and JSON remain untouched. |
| D. JSON plus incomplete SQLite | Same read-only recovery behavior after catalog/semantic failure. |
| E. Blobs exist outside header | SQLite is rejected as ambiguous; orphan data is preserved. |
| F. Partial transaction index | Certificate/count mismatch triggers an atomic rebuild. |
| G. Killed index build | SQLite rolls back; the next query rebuilds. |
| H. Killed mutation save | The SQLite transaction exposes either the old or new snapshot. |
| I. 100k startup | Correct but still full hydration; measured by the large-ledger XCTest suite. |
| J. 100k pagination | Bounded keyset queries decode only the requested page after index proof. |
| K. Equal timestamps | UUID is the deterministic secondary cursor and order key. |
| L. Switch large ledgers | Both books are already complete; switching performs no disk I/O. |
| M. Edit/delete/refund loaded row | Normal complete-state mutation and atomic incremental save. |
| N. Reference to an unloaded row | Canonical state has no unloaded rows; repository lookup exists for tools. |
| O. Backup with a UI page | Backup reads complete canonical state, never the page. |
| P. Monthly statement | Current engine reads complete state; range repository is not substituted silently. |
| Q. Analytics custom range | Current engine filters complete state with full domain semantics. |
| R. Cloud sync with paged UI | Cloud snapshots use complete state, independently of query pages. |
| S. Cloud deletion/conflict | Entity merge uses complete IDs and rejects duplicate remote IDs. |
| T. Encryption migration | Generates records from a complete merged book. |
| U. Unsigned/iLoader | CloudKit is unavailable without constructing `CKContainer`. |
| V. Signed/entitled | Normal CloudKit path; still requires physical two-device verification. |

## Scalability boundary

Incremental saves and bounded repository queries scale without rewriting or decoding unrelated
transactions. Startup still fully hydrates every book because the existing domain layer requires a
complete `LedgerState` for exact financial semantics. Reintroducing the former 300-active/0-inactive
scheme would violate the invariants above and risk data loss. Genuine lazy startup requires a new
repository-backed domain state/query layer for balances, linked records, recurring processing,
undo, CloudKit, backup, analytics, and statements. Until that layer exists, full hydration is the
intentional correctness boundary rather than an unsafe partial-state optimization.

`loadMetadata()`, typed pages, the complete ID catalog, and explicit transaction deltas are
preparation for that migration. Production `LedgerStore` has not switched to them, so normal
startup still decodes every transaction. This remains an open scalability limitation.
