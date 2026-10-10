# Validation and source audit — 10 October 2026

Current phone release: **1.3.0+7**, Android 10+. Current backend: Java 21+ / Spring Boot 4.1.1 / PostgreSQL. Maven artifact remains `bank-1.2.0.jar`.

## Background relay and reliability checks

| Check | Result |
|---|---|
| Flutter analyzer | No issues |
| Flutter tests excluding live integration | **60 passed** |
| Actual Dart / Java / Neon integration | **1 passed**, including offline A → offline B → two competing online gateways and receipts back to A |
| Android service tests, API 29 and 34 | **10 passed**, zero failures/errors/skips |
| Focused Java / PostgreSQL financial safety tests | **6 passed**, zero failures/errors/skips |

**77 tests passed for this change.** The live test uses production signing, encryption, routing, storage and the packaged Java bank with isolated Neon schemas. It disables internet on the payer/intermediate in the controlled transport, submits the same request concurrently through two gateways, verifies identical receipts and one debit, and returns the result through the offline intermediate. It does not use a physical Bluetooth radio or production accounts.

Fault tests cover loop avoidance, lost custody ACKs, incomplete frames, durable restart, v1 queue migration, shorter routes, alternate receipt routes, bounded fanout and lease recovery, fair queues, expiry, tampering, full storage and legacy inventories. Android tests check saved opt-in, sticky restart, task removal, notification Stop and Bluetooth pause/resume; they replace Flutter JNI only. Focused bank tests cover concurrent duplicates, overspending, separate-instance database locking, tampering, expired requests and atomic receipt-failure rollback.

See [BACKGROUND_RELAY.md](BACKGROUND_RELAY.md) for implementation, reproducible commands and the physical-phone acceptance procedure. The original organization/migration validation below is historical and separate from these 77 checks.

## Earlier checks after organization (release 1.2.1)

| Check | Result |
|---|---|
| Maven package and PostgreSQL Java suite | **21 passed**: 19 bank tests + 2 setup-QR tests, zero failures/errors/skips |
| Flutter analyzer | No issues |
| Flutter suite | **44 passed**, including actual Dart engine against Java/PostgreSQL |
| Independent API/wire/migration suite | **5 passed**, using temporary identities and isolated test schemas |

Additional checks: rebuilt JAR dashboard/login/setup-QR generation and download passed in a browser with no JavaScript errors; local and public ngrok health both report Java/PostgreSQL and the preserved bank fingerprint. Verified all original table counts, account balances, ledger sum and bank-key/operator-file hashes against the migration baseline after restart. All current local documentation links resolve.

Total: **70 automated tests passed** after backend paths/resources and test fixtures were reorganized. Live bank accounts were not used for test payments. The legacy migration fixture contains only synthetic public test data and is restored into an isolated schema; the removed Python bank is not needed.

Covered behavior includes canonical wire/signature interoperability, immediate payment settlement, PIN setup/privacy/lock/replay, duplicate submissions and re-encryption, conflicting payment IDs, overspending races, separate bank-instance concurrency, tampering, 600-second expiry and late recovery of committed decisions, v1 authorization downgrade refusal, restart persistence, idempotent funding, revocation, atomic rollback when receipts fail, low-order key rejection, migration refusal into a nonempty target, and QR parsing/validation/UI.

## Organized source

- `backend/` contains all executable bank code in Java and standard packaged resources, including the dashboard.
- Removed old FastAPI modules/launchers, Python server requirements/tests, obsolete reconstruction guides, unfinished iPhone runner/install helper, unused preview generators and duplicate old APKs.
- Exact removed files were preserved privately in `data/backups/source-cleanup-20261010-183729/removed-source.zip` before removal. This archive is excluded from source distribution.
- Python remains for independent test support, installation/download/package utilities; no Python bank server remains.
- The Java SQLite importer is retained for old-bank data preservation. Android SQLite is retained for its offline queue/history. Live bank storage is PostgreSQL only.
- Existing application ID, certificate, BLE UUIDs, wire domain, bank identity and private data are preserved. Internal compatibility names are intentional.
- Build/dependency caches remain locally ignored and excluded from the clean source ZIP. They are useful local tool state, not product source.

## Android artifact

`installers/BeyondNet-Android-1.3.0.apk` is the current release; `BeyondNet-Android.apk` is an alias. Install the new APK over the existing app on every phone in the test chain. Do not uninstall or clear app data. The prior 1.2.1 APK is retained for reference. Bank URL, fingerprint, API and stored ledger are unchanged; no backend restart is needed for this update.

Current APK SHA-256: `d192be52ff0fc5dc4c2d764f83aaa5c147dd23af8c4ac17174c6c8226cabbf5b`, also recorded in `installers/SHA256SUMS.txt`. APK signature verification and packaged version/service/permission checks passed; the certificate matches the previous release for in-place updates. Previous 1.2.1 SHA-256: `a73f813741f08587f4b21b3cce63c731c827205027981e6cd4516e014b9952de`.

API minimum 29, target 36, compile 37. Existing signing certificate SHA-256: `87631ca5716266c5e82f64acff27185b6b1d84bd126128546545847427a07ff2`. Distribution uses a development signing certificate; source ZIP does not contain its secret key.

## Limits of this check

This is a source review and functional test pass, not an independent security audit or certification for real-money use. No phones were connected: physical BLE range, background/locked-screen delivery, manufacturer battery restrictions, native authorization and camera/gallery acceptance still need device testing. Background relay is implemented as an explicitly enabled Android foreground service with a notification, not guaranteed execution after force-stop, reboot or OS termination. No real UPI, Wi-Fi mesh or iPhone release is claimed. The local bank/tunnel requires the laptop awake and online. Historical endpoint health checks below do not establish that the bank/tunnel is currently running.

See [BUILD_FLOW.md](BUILD_FLOW.md) for the complete developer order and [FIRST_PAYMENT.md](FIRST_PAYMENT.md) for hardware acceptance.

## Neon deployment validation

The production ledger was transferred to the separate free Neon BeyondNet project. All values in all eleven public tables and bank-key/operator-file hashes were verified, then rechecked after the bank restarted and the local PostgreSQL service stopped. Remote JDBC and dump/cleanup connections verify TLS certificates and hostnames. Dashboard login/setup-QR and the public HTTPS bank endpoint passed; the existing APK requires no update.

The independent API/WebSocket/wire/migration suite passed all five checks on Neon after fixing its cleanup helper to prefer the installed PostgreSQL 18 client over the older PostgreSQL 14 client on PATH. Actual Dart signup/funding/payment/receipt integration also passed on Neon.

The full Java run passed twenty tests; its late-receipt recovery test initially failed because its two-second first-submission allowance expired during remote database round trips. The test now uses one timestamp and a thirty-second first-commit allowance, then still waits for authorization expiry before recovering the committed receipt. This changes only test timing, not the production 600-second deadline or payment behavior. The targeted late-receipt rerun passed (54.89 seconds), so all 21 Java checks have now passed on Neon across the full run and this corrected rerun.

The cloud recovery branch `migration-backup-2026-10-10` was created and every original row was verified there too. Retired local PostgreSQL/SQLite storage, local database dump copies and unused runtime JAR copies were deleted, freeing **196.4 MiB**. Local PostgreSQL is stopped and no longer exists; local helpers do not recreate it with Neon configured. The public bank endpoint still works with the same fingerprint after deletion. A user-triggered rehearsal during migration added separate demo records in Neon without changing the original rows.
