# Static Apple Wallet Passes

## 1. Scope and Design Principles

Finsy integrates static Apple Wallet passes using native `PassKit` (`PKPassLibrary`) without introducing any external services or compromising user privacy.

### Explicit Non-Goals & Out-of-Scope Items
- **Zero FinanceKit**: Absolutely no FinanceKit APIs, entitlements, or models.
- **Zero Bank Reading**: No access to Apple Pay, Wallet bank card numbers, or bank transaction history.
- **Zero Background Updates**: No PassKit Web Service registrations (`/v1/devices/...`), no APNs push certificates, no silent background wakeups.
- **Zero Automatic Pass Updates**: The Account Pass is intentionally updated solely via manual user initiation ("Update Pass in Wallet").

---

## 2. Supported Passes

### 1. Primary Account Pass (Single Static Pass)
- **Identity**: Fixed `passTypeIdentifier` (`pass.com.finsy.account`) and deterministic `serialNumber` (`finsy-primary-account-pass`).
- **Configuration**: Managed in `SettingsView -> Functions -> Apple Wallet` (`WalletSettingsView.swift`).
- **Source Selection**:
  - `All Accounts (Net Worth)`: Calculates cumulative net worth converted into the user's primary currency.
  - `Specific Account`: Tracks a designated account's current balance in its native currency.
- **Relevant Locations**:
  - Supports up to 10 user-configured geofenced coordinates (`latitude`, `longitude`, `relevantText`).
  - Enables iOS Lock Screen pass suggestions when the user is physically near designated supermarkets, shops, or transit stops.
- **Manual Refresh**:
  - User explicitly taps **Update Pass in Wallet**.
  - Calls `PKPassLibrary.replacePass(with:)` directly in place without creating duplicate cards.

### 2. Purchase Receipt Pass
- **Style**: Coupon pass with a serrated paper strip image.
- **Trigger**: Generated upon completion of a Purchase Session from `PurchaseSummaryView`.
- **Content**: Store/merchant name, items summary (e.g. top items), total amount spent, currency, finalization timestamp.

### 3. Monthly Expense Tax Statement Pass
- **Style**: Coupon pass with a serrated paper strip image.
- **Trigger**: Generated from `TaxAnalyticsPage`.
- **Content**:
  - Monthly taxable expenses and total tax paid.
  - **Expense Tax Only**: Income tax is strictly excluded to preserve accurate business expense deductibility records.
  - Parity with `LedgerCalculations.taxAnalytics`.
