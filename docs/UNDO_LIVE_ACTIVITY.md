# Recent Transaction Undo & Refund Live Activity and Scoped Undo Architecture

## 1. Overview

Finsy provides an immediate, 10-second interactive Undo & Refund Live Activity on the Lock Screen and Dynamic Island whenever a new transaction is recorded. This feature operates in tandem with a complete replacement of whole-state undo with deterministic, operation-scoped undo.

## 2. Operation-Scoped Undo Architecture

### The Problem with Whole-State Undo
Previously, the ledger retained a copy of the entire ledger state in `undoState: LedgerState?`. If a user deleted transaction A, then added transaction B, and subsequently tapped "Undo", the entire ledger would be reverted to the pre-A snapshot. This catastrophically erased transaction B and all intervening mutations (such as exchange rate updates, account balance edits, or cloud synchronization changes).

### The Scoped Undo Solution (`LedgerUndoOperation`)
Whole-state undo has been completely removed from the repository. All undo operations now use `LedgerUndoOperation`:
- **Entity Snapshots**: Only captures pre-mutation snapshots of the exact entities modified or soft-deleted by the specific operation (`transactionSnapshots`, `accountSnapshots`, `recurringRuleSnapshots`, `purchaseSessionSnapshots`).
- **Created Entity Trackers**: Records `createdTransactionIDs` so that operations creating new entities (e.g. combined payment refund support reversals) undo by soft-deleting only the created IDs.
- **Version Guards**: Captures `expectedTransactionVersions` and `expectedAccountVersions`. Before applying an undo, `applyUndo` verifies that current versions match expected post-operation versions. If any entity was subsequently modified, undo fails safely and cleanly rather than overwriting newer user data.

## 3. 10-Second Live Activity Architecture

### Attributes & Independence
- `RecentTransactionActivityAttributes`: Defined in `FinsyShared/` and strictly decoupled from `PurchaseActivityAttributes`.
- Independent lifecycle: Starts when a standalone transaction or transfer is added; expires automatically after exactly 10 seconds.
- Superseding: If a second transaction is recorded while an activity is active, the coordinator immediately supersedes and replaces the existing activity.
- Exclusion: Transactions committed as part of an active Purchase Session do not trigger this activity, allowing the dedicated Purchase Mode Live Activity to maintain exclusive focus.

### Dynamic Island & Lock Screen Presentations
- **Dynamic Island Compact**:
  - Leading: Directional glyph (`arrow.counterclockwise.circle.fill`).
  - Trailing: Live 10-second countdown timer (`Text(timerInterval: ...)`).
- **Dynamic Island Expanded**:
  - Leading: Directional type indicator (`arrow.down.right.circle.fill` / `arrow.up.left.circle.fill`), title, account name.
  - Trailing: Monospaced amount formatted with currency symbol, countdown timer.
  - Bottom: Interactive action buttons (`UndoRecentTransactionIntent`, and `RefundRecentTransactionIntent` if refundable).
- **Lock Screen**:
  - Full-width card with frosted glass styling, status updates ("Undone", "Refunded"), and instant dismissal policy.

### Cross-Process Coordination (`RecentTransactionSharedStore`)
- App Group container storage (`group.com.finsy.app`) with `RecentTransactionActionSnapshot`.
- When an intent runs from Lock Screen or Dynamic Island:
  - Updates the shared store snapshot status (`isUndone` or `isRefunded`).
  - Immediately updates the Live Activity UI state to display confirmation and sets dismissal policy.
  - Posts in-process notification or reconciles on launch/foreground via `FinsyMaintenanceCoordinator`.
