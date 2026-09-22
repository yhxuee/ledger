# Apple Wallet Pass Signing Architecture (`WalletPassIssuer`)

## 1. Security Architecture & Boundary

Apple Wallet `.pkpass` bundles require cryptographic signatures using a Pass Type ID Certificate issued by Apple Developer and an Apple Worldwide Developer Relations (WWDR) certificate.

### Client-Side Security Rule
**Private keys must NEVER reside on client iOS devices.** 
Storing `.p12` certificates or private keys within the application bundle or client keychain poses a severe security risk:
- Binaries can be disassembled and private keys extracted.
- Revoking a compromised certificate breaks pass generation for all existing users.

Consequently, Finsy strictly enforces a **server-side signing boundary**.

### External Signing Server Notice
> [!IMPORTANT]
> The codebase in this repository (`yhxuee/ledger`) is strictly the client iOS application. It does **not** contain the server-side signing service or Apple Developer private signing keys. Pass signing is performed externally by a service configured via the `FINSY_WALLET_PASS_ISSUER_URL` environment variable or `Info.plist` key.
>
> The client now sends the complete itemized payload including `items`, `taxAmount`, and `formattedTax`. **The external signing server must be upgraded according to the contract below before issued `.pkpass` files will visually display itemized lines and tax in Apple Wallet.**

---

## 2. The `WalletPassIssuer` Client Architecture

Pass issuance is abstracted behind the `WalletPassIssuer` protocol in `Finsy/Data/WalletPassIssuer.swift`:

```swift
protocol WalletPassIssuer: Sendable {
    var isConfigured: Bool { get }
    func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass
    func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass
    func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass
}
```

### Client Implementations

1. **`NetworkWalletPassIssuer` (Production)**:
   - Configured via `FINSY_WALLET_PASS_ISSUER_URL`.
   - Sends HTTP POST requests with JSON snapshot payloads to `{FINSY_WALLET_PASS_ISSUER_URL}/{endpointSuffix}`.
   - Accepts binary `application/vnd.apple.pkpass` responses and initializes `PKPass(data: data)`.
   - If no endpoint is configured or the network request fails, surfaces a clear localized error.

2. **`MockWalletPassIssuer` (Test & Debug)**:
   - Available under `#if DEBUG`.
   - Records incoming snapshots (`lastAccountSnapshot`, `lastPurchaseSnapshot`, `lastTaxSnapshot`) for assertions in unit tests without requiring live network calls.

---

## 3. Purchase Receipt Signing Endpoint Contract

### HTTP Request
- **Method**: `POST`
- **Path**: `{FINSY_WALLET_PASS_ISSUER_URL}/purchase-receipt`
- **Headers**:
  ```http
  Content-Type: application/json
  Accept: application/vnd.apple.pkpass
  ```

### HTTP Response
- **Status 200 OK**:
  - `Content-Type: application/vnd.apple.pkpass`
  - Body: Valid signed `.pkpass` ZIP archive.
- **Status 4xx / 5xx**:
  - `Content-Type: application/json`
  - Body: `{"error": "Description of failure"}`

---

## 4. Inbound JSON Payload Schema (`PurchaseReceiptPassSnapshot`)

The client serializes `PurchaseReceiptPassSnapshot` to JSON. Outbound requests from the client always include all fields below:

```json
{
  "passTypeIdentifier": "pass.com.finsy.receipt",
  "serialNumber": "purchase-B8A4E391-7C6B-4C0E-92B1-5674751A29D4",
  "sessionID": "B8A4E391-7C6B-4C0E-92B1-5674751A29D4",
  "storeName": "Supermarket Supplies",
  "totalAmount": 128.50,
  "currency": "HKD",
  "formattedTotal": "HK$128.50",
  "itemCount": 3,
  "itemsSummary": "Apples, Whole Wheat Bread, Fresh Milk",
  "items": [
    {
      "name": "Apples",
      "category": "Groceries",
      "amount": 28.50,
      "formattedAmount": "HK$28.50"
    },
    {
      "name": "Whole Wheat Bread",
      "category": "Groceries",
      "amount": 35.00,
      "formattedAmount": "HK$35.00"
    },
    {
      "name": "Fresh Milk",
      "category": "Groceries",
      "amount": 65.00,
      "formattedAmount": "HK$65.00"
    }
  ],
  "taxAmount": 10.50,
  "formattedTax": "HK$10.50",
  "finalizedAt": "2026-09-22T12:30:00Z"
}
```

### Field Descriptions

| Field | Type | Required | Description |
|---|---|---|---|
| `passTypeIdentifier` | String | Yes | Apple Pass Type Identifier registered in Apple Developer Portal. |
| `serialNumber` | String | Yes | Unique pass serial number (`purchase-{sessionID}`). |
| `sessionID` | String (UUID) | Yes | Purchase session unique identifier. |
| `storeName` | String | Yes | Name of the store or purchase session. |
| `totalAmount` | Number | Yes | Total purchase amount in session currency. |
| `currency` | String | Yes | 3-letter currency code (e.g. `HKD`, `USD`, `EUR`). |
| `formattedTotal` | String | Yes | Formatted total with currency symbol (e.g. `HK$128.50`). |
| `itemCount` | Integer | Yes | Count of canonical items in the purchase session. |
| `itemsSummary` | String | Yes | Comma-separated summary of first items (backward compatibility). |
| `items` | Array | Yes | Complete array of itemized purchase items (`PurchaseReceiptPassItem`). |
| `items[].name` | String | Yes | Item note or category name fallback. |
| `items[].category` | String | Yes | Display name of the item category. |
| `items[].amount` | Number | Yes | Item cost in session currency. |
| `items[].formattedAmount` | String | Yes | Formatted item amount with currency symbol. |
| `taxAmount` | Number | Yes | Resolved tax amount. |
| `formattedTax` | String | Yes | Formatted tax amount with currency symbol (e.g. `HK$10.50`). |
| `finalizedAt` | String (ISO 8601) | Yes | UTC timestamp when session was completed or created. |

---

## 5. Expected Server-Side `pass.json` Field Mapping

The signing server must map the snapshot payload into `pass.json` fields using stable keys (never localized display strings as keys):

### Pass Structure
- **Pass Style**: `storeCard` (or `generic`)

### Header Fields
- `key`: `"store"`
  - `label`: `"STORE"`
  - `value`: `snapshot.storeName`

### Primary Fields (Card Front - Large Value)
- `key`: `"total"`
  - `label`: `"TOTAL"`
  - `value`: `snapshot.formattedTotal`

### Secondary Fields (Card Front - Mid-Row)
- `key`: `"tax"`
  - `label`: `"TAX"`
  - `value`: `snapshot.formattedTax`
- `key`: `"itemCount"`
  - `label`: `"ITEMS"`
  - `value`: `"\(snapshot.itemCount) items"`

### Auxiliary Fields (Card Front - Lower Row)
- `key`: `"date"`
  - `label`: `"DATE"`
  - `value`: `snapshot.finalizedAt`
  - `dateStyle`: `"PKDateStyleShort"`
  - `timeStyle`: `"PKDateStyleShort"`

### Back Fields (Card Back - Itemized Details)
Because Apple Wallet front-of-card space is strictly constrained, full itemization must be rendered in back fields:
- Itemized rows:
  - For each `(index, item)` in `snapshot.items`:
    - `key`: `"item-\(index)"`
    - `label`: `"\(item.name) (\(item.category))"`
    - `value`: `item.formattedAmount`
- Legacy fallback:
  - If `snapshot.items` is empty, render:
    - `key`: `"itemsSummary"`
    - `label`: `"ITEMS SUMMARY"`
    - `value`: `snapshot.itemsSummary`
- Historical receipt note:
  - `key`: `"receiptNotice"`
  - `label`: `"RECEIPT"`
  - `value`: `"Historical purchase receipt finalized in Finsy."`

---

## 6. Client / Server Compatibility & Migration

- **Client Forward Transmission**: The iOS client always transmits `items`, `taxAmount`, and `formattedTax` in all outbound requests.
- **Client Backward Decoding**: The client's `PurchaseReceiptPassSnapshot` implements custom decoding with default fallbacks (`items = []`, `taxAmount = 0.0`, `formattedTax = ""`) so legacy cached or stored snapshot payloads decode cleanly without throwing exceptions.
- **Server Backward Compatibility**: If the signing server receives older payloads lacking `items` or `taxAmount`, it should gracefully fall back to `itemsSummary` and omit the tax secondary field.

---

## 7. Historical Receipt Semantics

- **Snapshot Invariance**: For completed purchase sessions:
  - Item data is taken from canonical `session.orderedItems`.
  - Total is taken from `session.plannedAmount`.
  - Tax is taken from historical recorded transaction snapshots (`PurchaseReceiptCalculations.historicalTax`).
- **Configuration Independence**:
  - Changing category tax settings at a later date does NOT alter previously finalized purchase receipts.
  - Live FX rate updates do NOT rewrite historical item amounts or totals.
