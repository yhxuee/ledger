# Finsy Wallet issuer

The Python service listens on `127.0.0.1:8765`. Caddy provides public HTTPS for
`finsy.yhxue.com`. It accepts the iOS snapshot JSON at `/account`,
`/purchase-receipt`, and `/tax-receipt` and returns a signed `.pkpass`.
Receipt and tax passes use Apple's coupon layout with a transparent serrated
strip image. Wallet controls the outer card shape, so the teeth appear in the
strip artwork rather than changing the system card outline.
Receipt and tax passes are one-time snapshots: their pass data omits
`webServiceURL` and `authenticationToken`, and each export has a new serial
number so a later export cannot replace an earlier pass in Wallet.

The service requires these files in `/etc/finsy-wallet`, readable only by the
`finsy-wallet` service account:

- `account.crt.pem` and `account.key.pem`
- `receipt.crt.pem` and `receipt.key.pem`
- `tax.crt.pem` and `tax.key.pem`
- `wwdr.pem` (Apple WWDR G4 intermediate certificate)

The three private keys are extracted from the user's P12 files on the server.
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
