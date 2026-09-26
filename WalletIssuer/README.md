# Finsy Wallet issuer

The Python service listens on `127.0.0.1:8765`. Caddy provides public HTTPS for
`finsy.yhxue.com`. It accepts the iOS snapshot JSON at `/account`,
`/purchase-receipt` and returns a signed `.pkpass`. Tax is an image export in the app.
Account passes use Apple's store card layout. Receipts use the coupon layout with
theme-colored serrated paper artwork. Both use dark text on a light surface.
Strip artwork renders left-aligned TOTAL or NET WORTH above a centered bold
currency-and-amount line using SF Pro. Native primary fields are empty to avoid
duplicate text. Amounts remain available in back fields. Apple Watch does not
show strip artwork. Wallet controls
the outer card shape. Both layouts show the app logo and Finsy name.
Account and receipt passes refresh when ledger data changes while Finsy is open.
Receipt serial numbers are stable per purchase so refunds update the installed
receipt. There is no background Wallet push service. Existing receipts created by
older versions with random serial numbers remain snapshots; add a new receipt to
enable refresh. Barcode content stays on the device and is sent only for signing.

The service requires these files in `/etc/finsy-wallet`, readable only by the
`finsy-wallet` service account:

- `account.crt.pem` and `account.key.pem`
- `receipt.crt.pem` and `receipt.key.pem`
- `wwdr.pem` (Apple WWDR G4 intermediate certificate)

The two private keys are extracted from the user's P12 files on the server.
No P12, PEM, or password belongs in this repository. The P12 files should be
removed from staging after extraction and validation. `FINSY_TEAM_ID` in the
systemd unit must match the team identifier in the pass certificates.

Before public use, set an A record for `finsy.yhxue.com` to the server's public
address and permit inbound TCP 80 and 443 in the host firewall and Azure network
security group. Caddy obtains and renews the HTTPS certificate. Set the GitHub
Actions secret `FINSY_WALLET_PASS_ISSUER_URL` to `https://finsy.yhxue.com` after
HTTPS and signed pass verification succeed.

The service keeps no snapshots on disk. It limits request size and rate, but its
public endpoint does not authenticate app users. Add stronger abuse protection
if it will be used beyond a small private deployment.

Typography requires python3-pil and operator-provided fonts (not included in Git):
/opt/finsy-wallet/fonts/SF-Pro-Display-Bold.otf and SF-Pro-Text-Semibold.otf.
Override paths with FINSY_WALLET_BOLD_FONT and FINSY_WALLET_LABEL_FONT.
