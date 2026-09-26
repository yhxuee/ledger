# Wallet Pass Issuer

## Signing boundary

Pass Type ID private keys and the WWDR certificate remain on the signing server.
The app posts account or receipt snapshots over HTTPS and receives signed `.pkpass`
data. It never stores pass signing keys or reads bank transactions from Wallet.

## Setup

1. Register `pass.com.finsy.account` and `pass.com.finsy.receipt`, with matching certificates.
2. Include those pass identifiers in the app's Wallet capability and distribution profile.
3. Deploy the server and logo assets from `WalletIssuer/`. It provides `POST /account`, `POST /purchase-receipt`, and `GET /health`.
4. Set `FINSY_WALLET_PASS_ISSUER_URL` to the HTTPS base URL. It is injected into the app's Info.plist by the build workflow.
5. Validate installation, replacement, refund updates and barcode scanning on a signed iPhone build.

`/tax-receipt` is no longer supported. Tax exports are generated in the app.

## Snapshot contract

The Swift definitions in `WalletPassModels.swift` and `WalletIssuer/server.py` are
the contract. Foundation dates use seconds since 2001-01-01; human-readable dates
and amounts are formatted by the client to honor Settings and currency prefixes.

| Receipt field | Wallet region |
| --- | --- |
| `formattedDate` | Header |
| `formattedTotal` | Primary |
| `itemCount`, `payment` | Secondary |
| `invoiceNumber`, `transactionStatus` | Auxiliary |
| `storeName`, `formattedTax`, `items` | Back |
| `themeColorHex` | Generated strip artwork |
| Optional `barcode.message`, `barcode.format` | QR or Code 128 |

| Account field | Wallet region |
| --- | --- |
| `monthTitle` | Header |
| `formattedBalance` | Primary |
| `formattedExpenses`, `formattedIncome` | Secondary |
| `entries`, `remainingLabel`, `formattedRemaining` | Auxiliary |
| `title`, `recentEntries` | Back |

Receipt totals use recorded item payments after coupon discounts. Refund status
comes from linked ledger transactions. Existing tax snapshots remain historical;
changing tax settings does not recompute previously recorded tax.

## Verification

Run `python -m unittest discover -s WalletIssuer -p test_layout.py` to verify fields,
barcode validation and strip PNG output without keys or network. With a deployed
issuer and its signing material, `WalletIssuer/smoke.py` verifies signed bundles.
Compilation does not verify server deployment or Wallet rendering on a device.
