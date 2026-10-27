# BeyondNet 1.4.2 — offline payment reliability fixes

Release date: 27 October 2026. Android version **1.4.2+16**. The Java bank keeps its compatible `bank-1.3.3.jar` artifact name and must be rebuilt/restarted from this release. The release contains the payment app and addresses all five findings from the audit of commit `329e04c`.

## Fixed behavior

| Audit finding | Result |
| --- | --- |
| A saved outcome could not be delivered after receipt expiry | Replaying the original signed request returns fresh delivery copies of the bank's saved outcome when necessary. Payment identity, parties, amount, status, reason, reference and original commit time stay unchanged. No new debit or ledger entry is created. Fresh copies are also saved to inboxes/mailboxes. |
| Invisible expired invitations exhausted capacity | Admission and cleanup transition expired pending invitations out of the active state. Counts include only unexpired pending requests. Both per-peer and global limits still apply to active requests. |
| Packet/peer substitution during nearby exchange | A selected device must match its reply certificate. Responses stay bound to the initial peer's device/account/mesh and signing/encryption keys. Inventory identity and returned packet ID must match before storage or acknowledgment. |
| Signup timeouts exposed raw errors and left partial enrollment confusing | Errors distinguish failure before credentials are sent, unconfirmed account creation and incomplete device setup. Partial signup offers sign-in with the same ID/password and preserves entered credentials and saved device keys. The progress indicator stops on error. No automatic signup or payment POST retry was introduced. |
| Python checks selected an incompatible psql executable | Cleanup uses the pinned Python PostgreSQL driver with safely quoted, test-only schema names. The live-bank test now asserts successful helper shutdown and cleanup. Explicit database configuration is respected by the project checker. |

Account creation and device enrollment still require internet. Offline operation begins after enrollment, demo funding and PIN setup. A bank-signed result is required for a final payment outcome; a relay acknowledgment means only custody. The 10-minute payment authorization window has not been extended. Expired relay packets remain invalid; refreshing delivery never renews an expired financial authorization.

## Automated verification

Tests use a separate disposable PostgreSQL 18.6 instance, isolated schemas and temporary identities. Existing user bank accounts, funds and keys are not used by regression tests.

| Check | Result |
| --- | --- |
| Flutter static analysis | No issues |
| Full Flutter suite | 107 passed |
| Java bank suite | 36 passed; no failures, errors or skips |
| Independent Python HTTP/WebSocket/crypto/migration suite | 5 passed, with normal driver-based cleanup and no workaround |
| Android native service/BLE tests | 20 passed; no failures, errors or skips |
| Android release APK | Built; signature, application ID and version code verified |

New coverage includes paid and rejected decisions after receipt delivery expiry, preservation of the original outcome without another ledger entry, refresh of inbox/mailbox delivery, expiry of both invitation quotas, refusal of packet/device substitution, actionable timeout messages, preservation of form credentials, and real signup/device-enrollment response loss followed by successful sign-in with the same saved device identity. Existing tests exercise online settlement, simulated offline forwarding, durable queues, tampering, replay protection, duplicate gateways and receipt recovery.

The receipt-expiry regression advances stored delivery expiry in an isolated fixture; it does not wait seven days in real time. Native tests use Robolectric and mocked Flutter JNI where required. Simulated BLE uses the actual application routing/storage logic and cryptography but does not establish radio range or device-specific reliability.

## Install and use

Install `installers/BeyondNet-Android-1.4.2.apk` on every participating Android 10+ phone **over the existing app**. Do not uninstall or clear app data. Version code 16 supports upgrades from the earlier builds, while the application ID, signing certificate, payment keys and SQLite schema are retained.

Restart the bank from the new source so that receipt refresh is enabled. Preserve the bank's PostgreSQL database and private `data/` files. The existing bank URL, fingerprint and enrolled identities remain valid. Run `~/.local/bin/beyondnet-start` on the configured development Mac, or follow the repository bank/database setup instructions on another computer. That personal launcher is outside this repository and is not required for building the app.

1. While each phone is online, scan the current bank setup QR and sign in or create its account.
2. Configure the sender's demo PIN and device screen lock, then add demo funds.
3. Keep the gateway/recipient phone online with BeyondNet open. Enable Nearby relay and Bluetooth permissions on both phones.
4. Turn the sender's Wi-Fi/mobile internet off, keeping Bluetooth enabled. Use Nearby to connect to the verified gateway phone.
5. Authorize a small demo payment by ID or signed recipient QR. Accept the incoming relay request on the gateway phone.
6. Confirm the same signed bank reference in sender Activity, recipient receipts and the bank ledger. Verify exactly one debit and credit.
7. For a third offline relay, accept the request there and explicitly choose the next online phone. Follow the [physical mesh guide](MESH_TEST_GUIDE.md).
8. Test disconnection/reconnection and receipt recovery without creating a replacement payment while the original outcome is unknown.

## Artifact identity

- Application ID: `com.offlinekaro.offline_karo`
- Version: `1.4.2`, code `16`
- Minimum Android: API 29 / Android 10
- APK SHA-256: `296ce3e39f2d7b46339c2d10eaad5e4ab3594c7070b7176ca2238a63ccc638f2`
- Signing certificate SHA-256: `87631ca5716266c5e82f64acff27185b6b1d84bd126128546545847427a07ff2`

The existing development signing identity is retained for in-place upgrades. It is not a production signing/key-management deployment.

## Acceptance limits

No Android phone was visible to USB debugging during this release's checks. Physical two/three-phone BLE delivery, screen-locked behavior, battery saver, range, latency and an actual on-device upgrade are therefore still acceptance tasks. Earlier dated hardware reports belong to their original app versions. The code and APK are software-tested; this document does not claim that a new physical payment was observed.

The Android build reports the existing Bluetooth plugin's future Kotlin migration warning. The current supported build is verified separately above. Simulated INR remains demo money; no real UPI or banking integration is included. The Mac must remain awake and online while it hosts the bank and tunnel.
