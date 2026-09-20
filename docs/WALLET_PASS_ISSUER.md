# Apple Wallet Pass Signing Architecture (`WalletPassIssuer`)

## 1. Security Architecture

Apple Wallet `.pkpass` bundles require cryptographic signatures using a Pass Type ID Certificate issued by Apple Developer and an Apple Worldwide Developer Relations (WWDR) certificate.

### Client-Side Security Rule
**Private keys must NEVER reside on client iOS devices.** 
Storing `.p12` certificates or private keys within the application bundle or client keychain poses a severe security risk:
- Binaries can be disassembled and private keys extracted.
- Revoking a compromised certificate breaks pass generation for all existing users.

Consequently, Finsy enforces a **server-side signing boundary**.

---

## 2. The `WalletPassIssuer` Protocol

Pass issuance is abstracted behind the `WalletPassIssuer` protocol in `Finsy/Data/WalletPassIssuer.swift`:

```swift
public protocol WalletPassIssuer: Sendable {
    func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass
    func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass
    func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass
}
```

### Implementations

1. **`NetworkWalletPassIssuer` (Production)**:
   - Takes an optional server signing endpoint URL.
   - Serializes pass snapshot JSON payloads to the backend signing service over HTTPS.
   - The backend service creates the `pass.json`, bundles assets, computes `manifest.json`, signs with the server-held Apple certificate, and returns signed `.pkpass` data (`application/vnd.apple.pkpass`).
   - Initializes `PKPass(data: data)` on the client.
   - If no endpoint is configured or the server is unavailable, returns a clear localized error informing the user that server-side signing is required.

2. **`MockWalletPassIssuer` (Test & Debug)**:
   - Available under `#if DEBUG`.
   - Records incoming snapshots (`lastAccountSnapshot`, `lastPurchaseSnapshot`, `lastTaxSnapshot`) for assertion in unit tests without requiring live network calls.
