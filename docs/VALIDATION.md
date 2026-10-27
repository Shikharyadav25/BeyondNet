# Validation and source audit — updated 27 October 2026

Current phone release: **1.4.2+16**, Android 10+. Current backend: Java 21+ / Spring Boot 4.1.1 / PostgreSQL, artifact `bank-1.3.3.jar`.

Current release checks and audit fixes: [1.4.2 validation](RELEASE_1.4.2.md). The physical reports below are historical results for their stated versions; they do not validate the new APK.

## Physical two-phone test and BLE framing — 17 October 2026

Tested OPPO CPH2565 (Android 15) as payer and OPPO CPH2127 (Android 12)
as the online gateway. The gateway initially had 1.3.4; both phones were updated
in place. Accounts, enrollment and history were retained. The bank and ngrok
were started against the existing PostgreSQL bank. Payer Wi-Fi and mobile data
were disabled; Android reported `Active default network: none` before and after
the successful offline run.

The initial physical exchange reproduced GATT read/timeouts and malformed JSON
responses. Release 1.3.6 adds an indexed GATT characteristic with transfer tags,
sequence checks and explicit response cursors. Repeated reads no longer consume
response chunks. Duplicate identical writes do not append bytes or reexecute the
handler. MTU negotiation reduces operation count on supported phones; native
logs confirmed successful negotiation. The original characteristic remains for
older peers. Interrupted read callbacks are caught rather than escaping as
unhandled asynchronous exceptions, and a successful sync clears stale errors.

The Nearby page now offers a payer connection only when the bank is unreachable
and no incoming/forwarding request needs attention. Online gateways show approval
controls without a redundant payer Connect button. Offline intermediates retain
their dedicated next-phone controls. The installed gateway's pending invitation
screen was inspected during the Krishna payment and contained Allow relay and
Decline, with no Connect button.

| Physical scenario | Observed result |
|---|---|
| Incorrect supplied payment PIN, offline Ajay to Ashwani | Signed bank rejection returned over BLE; no debit or credit. |
| PIN reset through the normal authenticated app flow | Saved successfully; payer returned offline before authorizing another payment. |
| Offline Ajay to Ashwani, INR 1 | Paid; reference `OK-614EBE60915F46CD`; exactly one debit and credit; signed receipt displayed while payer stayed offline. |
| Offline Ajay to Krishna Enterprises, INR 1, final APK | Paid; payment ID `b8bc746f-0023-43cd-be58-0c39e75f880a`, reference `OK-8E171FDAA96546A5`; one debit of 100 paise and one credit of 100 paise; receipt verified on offline payer. |
| Awaiting relay approval | Bank had no new decision or balance movement before approval. |
| App update/restart | The earlier verified receipt and account state survived the in-place update. |

The non-integration Flutter suite passed **93 tests** after the transport change.
Three additional contextual-action widget regressions were then added; the
targeted widget/framing/startup run passed **24 tests**, including those cases.
Final Flutter analysis reported no issues. Release APK build and signing check
passed with the existing signing identity. No bank financial code was changed.

Limits: these are two specific physical phones, not a physical three/four-phone
chain or an independent security certification. Intermittent Android GATT
disconnects occurred during earlier sessions and retries recovered; this does
not establish zero radio errors on all hardware. The foreground service stayed
running with the gateway app backgrounded; notification-drawer visibility was
not independently established. The Krishna recording contains actual phone
screen captures; its condensed presentation version shortens waiting intervals.

APK SHA-256: `5b52d4771a0667e21ed6804dffb55d260b9a263a02d6e669ec524bd947288c0d`.

The release notes below are historical records of their stated versions.

## Security roadmap update — mobile 1.3.4

Release APK build passed. Verified package `com.offlinekaro.offline_karo`, version `1.3.4` / code `11`, minimum Android API 29, and unchanged signing certificate SHA-256 `87631ca5716266c5e82f64acff27185b6b1d84bd126128546545847427a07ff2`. This retains the existing development signing identity for in-place updates; it does not introduce production signing.

See [security assessment and implementation decisions](SECURITY_ROADMAP.md). Persistent replay admission replaces the memory-only cache; SQLite upgrades to version 4 in place. Financial cryptography, bank implementation, peer wire format and installed signing identity remain unchanged.

Audit: the full Flutter suite passed 84 tests, including actual Dart-to-Java/PostgreSQL integration against an isolated schema, simulated multi-hop routing, mixed protocol peers, restart replay rejection, concurrent duplicates, expiry/skew boundaries, per-peer quota, clock rollback and v1/v3 database upgrades. A subsequently added global 4,096-entry capacity regression passed with all six storage replay tests. Flutter analysis reported no issues. Physical Android chain/locked-screen testing was not performed; automated tests do not prove radio performance. The broader HPKE, hardware signing, revocation, at-rest encryption and routing proposals are documented migration work, not shipped features.

## Earlier-review improvements — release 1.3.3

See [the full observation-by-observation review](REVIEW_IMPROVEMENTS.md) for fixes, previously implemented features and deliberately deferred work. This release adds credential migration, protected PIN hashes, hashed sessions, connection pooling, route/account rate limits, local-only administration, signed authenticated rejections, commit-triggered socket updates, resumable receipt cursors, reduced polling, owned-payment storage reservations and stricter relay admission.

New checks include credential rotation without balance/device loss, legacy PIN upgrade, session revocation, missing-recipient/revoked-device signed rejections, bounded rate-limit state, trusted-proxy handling, administrative access, canonical control escapes, per-peer packet quota and future-expiry admission. Integration tests use isolated PostgreSQL schemas, never the public ledger.

Final 1.3.3 checks on 11 October 2026:

| Check | Result |
|---|---|
| Flutter analysis | No issues |
| Flutter unit/widget/protocol/reliability tests | 77 passed |
| Java checks | 34 distinct checks passed across the full run and targeted reruns; the initial Unicode fixture failure was corrected before packaging. Additional cases cover concurrent legacy PIN upgrade and protected idempotency commitments. |
| Independent Python HTTP/WebSocket/legacy-import/QR/Dart compatibility checks | 5 passed |
| Actual Dart engine against isolated Java/Neon bank | 1 passed; signup, PIN, top-up, online payment, live receipt, HTTP recovery, offline intermediate, duplicate gateways and expired original recovery |
| Native Android application checks | 20 passed on the configured API 29/34 Robolectric targets; use `./gradlew :app:testDebugUnitTest` to avoid unrelated plugin test discovery tasks |
| Release APK | Built and signature verified; version 1.3.3 / build 10, minimum API 29 |
| Private bank backup | PostgreSQL dump and pre-update identity/configuration saved before live migration; excluded from source ZIP |

Existing production records were not used for test transfers. Live credential/PIN/session migrations activate when the updated bank is started. The checks below marked 1.3.2 are historical evidence for that release.

## Funds and Bluetooth startup fixes — release 1.3.2

The running bank's recent ₹10 rejection was read without modifying records: its reason was **Insufficient demo balance**. Bank funds enforcement was already present. The mobile app lacked preflight checks, so it could queue an unaffordable request and label it pending before receiving the bank rejection.

The screenshot's R8 map ID matches the retained 1.3.1 release mapping. Frame `es0.l:1273` resolves to `PeripheralManagerImpl.addService:183`: Android's GATT registration returned false. This is independent of bank connectivity and payment PIN setup.

Release 1.3.2 adds online balance refresh/offline cached-funds preflight, unresolved-request reservations, serialized authorization and a second funds check after device authentication. The UI warns before the PIN dialog, displays available funds and highlights the bank's signed rejection reason. Expired unknown requests retain their reservation until a bank result; online recovery resubmits the original expired ciphertext only if mailbox recovery finds no receipt, producing either the original paid outcome or a signed expiry rejection without renewing TTL.

Bluetooth startup checks BLE advertising support, opens a fresh GATT session, retries registration up to three times and cleans listeners/server/service state after failure. Device errors use readable messages rather than raw native stack traces. The compatibility adapter pins Android plugin 6.2.1; tests execute its actual generated host bindings.

| Check | Result |
|---|---|
| Flutter analyzer | No issues |
| Flutter non-integration suite | **74 passed** |
| Native Android tests, API 29/34 | **20 passed**: service/readiness 12, startup SQLite 4, real plugin channel contract 4 |
| Java/Neon financial tests | **3 passed**: zero-balance signed rejection with unchanged ledger, duplicate gateways, overspending race |
| Actual Dart/Java/Neon integration | **1 passed**, including multi-hop/duplicate gateways and signed expiry resolution releasing reserved funds |

**98 automated tests passed for this release.** Flutter faults include zero funds without biometric authorization or packet creation, stale online snapshots in both directions, pending/expired reservations, concurrent authorizations, changed funds after authentication, retention of unresolved original ciphertext past relay cleanup, refused GATT registration/retry/cleanup, readable dialogs and prominent rejection reasons. Tests use temporary identities and isolated PostgreSQL schemas. Production bank code, private keys and records are unchanged. No phone was connected; manufacturer-specific BLE registration and background delivery remain physical acceptance checks.

## Earlier Android startup fix — release 1.3.1

A physical phone reported `Queries can be performed using SQLiteDatabase query or rawQuery methods only` for `PRAGMA busy_timeout=5000`. Release 1.3.0 incorrectly sent this row-producing PRAGMA through `execute`; the desktop SQLite test adapter accepted it and the prior service tests did not exercise native database configuration. Consequently the earlier 77-test pass did not establish successful Android database startup.

Release 1.3.1 sends that setting through `rawQuery`, preserving the 5-second lock timeout, FULL synchronous durability, schema version 2 and existing queue/history. It does not delete or reset data. Version code 8 and the existing application ID/signing certificate allow an in-place update. Install over 1.3.0 or the prior compatible release; do not uninstall or clear storage.

Flutter analyzer: **no issues**. Flutter non-integration suite: **60 passed**. New native SQLite regression: **4 passed** on API 29/34. This test reads the actual production startup SQL/methods and executes them through the real Android sqflite adapter with Robolectric native SQLite. It reproduces the original `execute` failure, checks corrected settings, and verifies preserved data after closing/reopening. No phones were connected for an APK installation test. The bank and wire protocol are unchanged; the live bank tests below were not repeated for this SQL dispatch-only fix.

## Background relay and reliability checks — release 1.3.0

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

`installers/BeyondNet-Android-1.3.3.apk` is the current release; `BeyondNet-Android.apk` is an alias. Install over the existing app. Do not uninstall or clear app data. Restart the Java bank once; retain its URL, fingerprint and ledger. Affected legacy demo accounts must renew login using the private rotated-password file. Earlier APKs are retained for reference; 1.3.0 has the startup defect described above.

Current APK SHA-256: `082f52535eb1b643efec3a086af37147ff79b1172f503ae0b80620902ee2ca52`, also recorded in `installers/SHA256SUMS.txt`. Signature, version-code and minimum-SDK checks passed; certificate matches previous releases. Previous 1.3.2 SHA-256: `ee1aacf0f11598ea576502ec84979c89890f0a46f614be84f9c9d2a62d53e084`. Previous 1.3.1 SHA-256: `7951edbe36686d7be322d0ff18919421bef37e2b50036dbc6fa942fa81ac47ca`. Previous 1.3.0 SHA-256: `d192be52ff0fc5dc4c2d764f83aaa5c147dd23af8c4ac17174c6c8226cabbf5b`. Previous 1.2.1 SHA-256: `a73f813741f08587f4b21b3cce63c731c827205027981e6cd4516e014b9952de`.

API minimum 29, target 36, compile 37. Existing signing certificate SHA-256: `87631ca5716266c5e82f64acff27185b6b1d84bd126128546545847427a07ff2`. Distribution uses a development signing certificate; source ZIP does not contain its secret key.

## Limits of this check

This is a source review and functional test pass, not an independent security audit or certification for real-money use. No phones were connected: physical BLE range, background/locked-screen delivery, manufacturer battery restrictions, native authorization and camera/gallery acceptance still need device testing. Background relay is implemented as an explicitly enabled Android foreground service with a notification, not guaranteed execution after force-stop, reboot or OS termination. No real UPI, Wi-Fi mesh or iPhone release is claimed. The local bank/tunnel requires the laptop awake and online. Historical endpoint health checks below do not establish that the bank/tunnel is currently running.

See [BUILD_FLOW.md](BUILD_FLOW.md) for the complete developer order and [FIRST_PAYMENT.md](FIRST_PAYMENT.md) for hardware acceptance.

## Neon deployment validation

The production ledger was transferred to the separate free Neon BeyondNet project. All values in all eleven public tables and bank-key/operator-file hashes were verified, then rechecked after the bank restarted and the local PostgreSQL service stopped. Remote JDBC and dump/cleanup connections verify TLS certificates and hostnames. Dashboard login/setup-QR and the public HTTPS bank endpoint passed; the existing APK requires no update.

The independent API/WebSocket/wire/migration suite passed all five checks on Neon after fixing its cleanup helper to prefer the installed PostgreSQL 18 client over the older PostgreSQL 14 client on PATH. Actual Dart signup/funding/payment/receipt integration also passed on Neon.

The full Java run passed twenty tests; its late-receipt recovery test initially failed because its two-second first-submission allowance expired during remote database round trips. The test now uses one timestamp and a thirty-second first-commit allowance, then still waits for authorization expiry before recovering the committed receipt. This changes only test timing, not the production 600-second deadline or payment behavior. The targeted late-receipt rerun passed (54.89 seconds), so all 21 Java checks have now passed on Neon across the full run and this corrected rerun.

The cloud recovery branch `migration-backup-2026-10-10` was created and every original row was verified there too. Retired local PostgreSQL/SQLite storage, local database dump copies and unused runtime JAR copies were deleted, freeing **196.4 MiB**. Local PostgreSQL is stopped and no longer exists; local helpers do not recreate it with Neon configured. The public bank endpoint still works with the same fingerprint after deletion. A user-triggered rehearsal during migration added separate demo records in Neon without changing the original rows.
