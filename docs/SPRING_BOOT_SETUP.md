> **Current laptop configuration:** PostgreSQL is now on Neon. The launcher uses the private remote configuration and skips local database startup. See [Neon setup and restart guide](NEON_SETUP.md). Local-cluster instructions below apply only to a fresh local development setup.

# Bank setup QR in app 1.2.1

Open the bank dashboard → **Device setup**. Confirm the public HTTPS URL (this laptop's saved ngrok URL is prefilled), then click **Generate setup QR**. The QR embeds exactly the bank HTTPS URL and current trust fingerprint, plus a format/type version. It contains no password, PIN, account session or operator key.

On the phone's signup/sign-in screen use **Scan bank QR**, or download the dashboard's PNG to the phone and use **Choose QR image**. Review the decoded bank details and tap **Use bank details**. Both fields are filled; then complete normal account signup/login. Image selection uses the system picker, without starting the camera. A canceled selection/review leaves the fields unchanged. Camera access is required only for live scanning. Unreadable, wrong-type, insecure and ambiguous multiple-bank codes show an error; manual entry remains available.

Use a QR from your trusted dashboard. The QR is a convenient transfer of trust details, not independent proof of legitimacy. Enrollment still obtains the bank public keys, recomputes the fingerprint and compares it to the QR before sending credentials. An existing enrolled device also retains its bank identity checks. Regenerate the QR if the public URL changes; restart does not change the fingerprint.

Install `installers/BeyondNet-Android-1.2.1.apk` over the existing app. Version 1.2.0 payment/PIN behavior remains compatible; only the bank setup UI is new. The downloadable `installers/BeyondNet-bank-setup.png` is this laptop's current public setup QR. A fresh source checkout can set `BEYONDNET_PUBLIC_URL` or `data/public-url.txt` to prefill its dashboard URL, or enter it in Device setup.

The existing Java bank JAR artifact name remains `bank-1.2.0.jar`; launchers rebuild and run the updated code automatically. No database reset or key rotation is needed for this feature.

---

# BeyondNet 1.2.0: Java bank and PostgreSQL

The active bank is Java 21+ / Spring Boot 4.1.1 with PostgreSQL. The phone app remains Flutter/Dart. The production backend contains no Python server. The independent test oracle and utility scripts use Python; the one-time data importer is Java.

## Restart this Mac

Open Terminal, then run:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./start-bank.sh
```

Leave this terminal open. On this configured laptop it connects to Neon, builds Java if necessary, and starts the bank on **127.0.0.1:8080**. A fresh local development setup instead starts its dedicated PostgreSQL cluster on **127.0.0.1:5433**. It does not reset the database or regenerate the bank identity. Double-clicking `Start-Bank.command` does the same thing. First build requires internet to download Maven dependencies.

Open **http://localhost:8080** for the dashboard. In another terminal, read the existing operator key:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
cat data/admin-token.txt
```

Copy only the key, excluding any `%` prompt symbol. It unlocks the bank dashboard; it is not a phone password or database password.

For phones to reach the bank, open a separate terminal:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./Start-Ngrok.command
```

Keep an already-running ngrok process instead of launching a duplicate. This account's assigned URL remains **https://sublime-penalty-helper.ngrok-free.dev**. Use the URL actually printed by ngrok if running under a different account. The Mac must remain awake and online during testing. PostgreSQL continues storing records when the bank or tunnel is stopped; this is local hosting, not an always-online cloud deployment.

To stop the bank, press **Ctrl+C** in its terminal. PostgreSQL remains running. To also stop the dedicated database after the bank is stopped, run `./scripts/stop-postgres.sh`. Restart with the same bank command. Do not delete `data/`.

If Codex already started the bank, a second start correctly says port 8080 is occupied. Use the running dashboard. Ask Codex to stop its instance before starting your own terminal instance.

## Update the phones

1. Install `installers/BeyondNet-Android-1.2.1.apk` **over the existing app** on every test phone. Android 10+ is supported. Do not uninstall first: that would remove local device keys/history and require enrollment again.
2. Open the app while online. Keep the same bank URL and fingerprint. Existing accounts, passwords and enrolled device identities remain valid.
3. Set a **six-digit demo payment PIN** using your account password. This PIN is separate from your phone unlock code and account password. It is not a real UPI PIN. Setup/reset requires an online bank connection.
4. Add demo money online if needed. A new account begins at zero. Enroll the recipient's device while online before its first receipt.
5. For each payment, enter this PIN and complete native device authentication. The PIN travels only inside the signed, bank-encrypted instruction. Relays cannot read it; the bank stores a salted scrypt hash rather than the PIN.

**Old APK behavior:** old completed payments/receipts remain recoverable. New payments from the old PIN-less protocol are rejected with an update instruction. Update all participating phones for the current demo. The BLE envelope and certificates remain compatible, but this does not make old payment authorization acceptable.

## First two-phone test

- Personal phone: registered, PIN set, funded; recipient certificate cached or available by QR.
- Merchant phone: registered and online, relay enabled, app open.
- Turn off mobile data and internet Wi-Fi on the personal phone, keeping Bluetooth enabled. Android 10–11 also needs foreground Location permission and Location switched on. Android 12+ needs Nearby devices permissions; camera permission is needed only for QR scanning.
- Scan nearby, connect to the verified merchant/gateway, select its ID or scan its QR, and pay a small amount with your PIN.
- Observe the signed bank receipt and updated balances on both phones and the dashboard. A transport acknowledgment alone is not a successful payment.

Additional offline relay phones are optional. Keep their apps open with relay enabled and required permissions on. The laptop bank connects over the internet and does not participate in Bluetooth.

## The ten-minute deadline

There is **no ten-minute processing delay**. A valid payment reaching the bank is processed immediately. Its signed authorization expires 600 seconds after creation. A first submission at/after that deadline is rejected without a debit. Expired requests stop normal forwarding; they cannot later become a new debit. A payment already committed before expiry stays paid, even if its receipt arrives later. The phone retains its own intent for recovery and may show an unresolved outcome until a signed bank decision is obtained. Expiry is not a refund and cannot reverse a committed payment.

## What moved, and what stayed

- Financial state moved from the laptop's `data/bank.sqlite3` to PostgreSQL: accounts, password salts/hashes, sessions, devices/certificates/revocations, payments and their saved receipts, ledger, mailboxes, top-ups, receipt cursors and events.
- Bank signing/encryption keys and the operator token remain in `data/bank-keys.json` and `data/admin-token.txt`. Their identity is preserved; the trust fingerprint stays the same.
- New `payment_pins` stores salted hashes, failed attempts and lock expiry.
- The phone's local SQLite remains intentional: offline queue/history on Android must work without a database server. Only the **bank** moved to PostgreSQL.
- No real UPI, banking rail, real-money deposit, Wi-Fi mesh, iPhone release or background relay service is implemented.

## PostgreSQL setup on a fresh Mac

Install Java 21+, Maven and PostgreSQL 17+; this Mac already has them. A fresh macOS setup can use:

```sh
brew install openjdk@21 maven postgresql@18
```

Ensure `java` points to Java 21 or newer. Run `./start-bank.sh` from the project. `scripts/start-postgres.sh` initializes a **separate** `data/postgres` cluster; it does not modify Homebrew's other PostgreSQL clusters. The database listens only on loopback, and the bank's database role has no superuser/database-creation privileges. Host authentication uses a random SCRAM password saved in permission-restricted `data/postgres.properties`. The local administrative socket is inside permission-restricted `data/postgres-run`.

`BEYONDNET_PG_BIN` can identify the PostgreSQL binary directory on another installation. Do not move a running cluster or share `data/`. A source ZIP intentionally excludes all private runtime data; extracting source elsewhere creates a separate bank unless identity and database backups are restored deliberately.

### Existing PostgreSQL / Windows / Linux

Create an empty database owned by a restricted application role. Copy `backend/src/main/resources/postgres.properties.example` to `data/postgres.properties` and enter the actual URL/user/password. For Windows, start PostgreSQL with its installed service and use `./start-bank.ps1`. On Linux set `BEYONDNET_DB_URL`, `BEYONDNET_DB_USER`, `BEYONDNET_DB_PASSWORD` and run `./start-bank.sh`; setting the URL skips the Mac-specific local-cluster launcher. Use TLS (`sslmode=verify-full`) for remote database connections.

Java reads `BEYONDNET_DB_CONFIG` (default `data/postgres.properties`) and environment overrides. `KARO_DATA_DIR` selects identity/legacy data; its legacy spelling is preserved for compatibility. `BEYONDNET_DB_SCHEMA` defaults to `public`; tests explicitly use random `test_*` schemas. For manual builds:

```sh
mvn -f backend/pom.xml -DskipTests package
java -jar backend/target/bank-1.2.0.jar
```

The launcher's automatic backup/setup assumes this project's default local data/database. For custom or remote deployments, take a database dump and identity backup for that deployment before importing. Keep PostgreSQL private; expose only bank HTTPS/WSS through the tunnel.

## Database transfer and backups

The one-time Java importer reads SQLite in read-only mode, inserts all legacy tables into an empty PostgreSQL schema, compares **every row value** and count, resets sequences, then commits a migration marker. An interrupted/failed import rolls back. A nonempty unmarked target is refused; it is never silently merged or overwritten. A successful migration marker prevents repeating the old import after later PostgreSQL payments.

The normal launcher backs up the old bank before its first transfer. This laptop also has `data/migration-baseline.json` for preservation checks. Private backups are in `data/backups/`; they are excluded from the source ZIP.

Make another backup any time:

```sh
./scripts/backup-bank.sh
```

This saves a consistent PostgreSQL custom-format dump and bank identity/config files. The old SQLite snapshot is also saved if present. A backup contains private credentials; keep it private.

**Restoring:** stop the bank; restore a PostgreSQL dump into a separate empty recovery database with `pg_restore --exit-on-error --no-owner --no-privileges`, configure Java to that database, and restore the matching bank key/operator files. Verify counts, balances and fingerprint before reopening payments. Never overlay an old dump on a live ledger. The old SQLite snapshot is not a rollback of new PostgreSQL payments. Preserve a PostgreSQL backup and restore forward instead.

## Java code map

| File / class | Responsibility |
|---|---|
| `BankApplication` | Spring Boot entry point; `--migration-only` checks/imports the database without an HTTP listener |
| `BankController` | HTTP endpoints, account/operator authentication boundaries and safe error responses |
| `BankService` | Login/signup, device enrollment, PIN setup, funding, validation, immediate settlement and receipt recovery |
| `BankDatabase` | PostgreSQL JDBC connections, bounded transactions and per-bank advisory locking |
| `LegacySqliteImport` | One-time atomic read-only legacy transfer with row-by-row verification and sequence repair |
| `WireCrypto` | Canonical JSON, X25519/HKDF/AES-GCM, Ed25519 verification/signing and scrypt |
| `LiveSocket` | Authenticated live payment submissions and scoped receipt updates |
| `RequestLimits` | Body/rate bounds and request headers |
| `StaticAssets` | Dashboard assets served from the same bank |
| `RehearsalService` | Clearly labeled software demonstration using additional demo accounts, without deleting real records |
| `schema.sql` | PostgreSQL tables, constraints, sequences, indexes and migration marker |
| `mobile/lib/payment_pin.dart` | PIN setup/reset and payment-entry UI; input is cleared/disposed |
| `mobile/lib/engine.dart` | Signs/encrypts v2 payments, persists ciphertext, routes/retries and verifies receipts |

## Encryption and concurrency

The hybrid scheme is **X25519 + HKDF-SHA256 + AES-256-GCM**, with **Ed25519 signatures**. X25519 establishes a fresh per-message symmetric key, AES-GCM encrypts/authenticates the payload, and Ed25519 binds the exact instruction to an enrolled device. This retains the existing bank keys and mobile wire compatibility; replacing it with RSA was unnecessary. The envelope/domain remain v1, while the encrypted signed payment body is v2 with PIN and a maximum 600-second lifetime. This is not a claim of a cryptographic audit.

Every Java write transaction takes a PostgreSQL transaction-scoped advisory lock for that bank schema **before** reading mutable financial state. Concurrent gateways/Java instances therefore cannot both pass the same balance or idempotency check. The `(sender,id)` payment primary key is an additional uniqueness guard. A saved body hash binds a payment ID to the exact signed instruction: a changed request conflicts, while retransmission/reencryption returns the original persisted receipts. Debit, credit, ledger, receipt, mailbox and decision commit together or all roll back. Top-ups use their own account/request-ID key.

This intentionally serializes bank writes for a small demo. It trades throughput for straightforward correctness. Scaling would require carefully designed row locks, retry policies, coordination of pause/rate limits and operational controls; PostgreSQL alone does not make the bank production-ready.

## Verification

```sh
./scripts/check.sh
```

The check script starts PostgreSQL, runs Java tests in isolated schemas, runs the Flutter analyzer/tests, and runs migration/wire interoperability tests. Python is only needed for test orchestration and the independent wire oracle, not to serve the current bank. Existing `.venv` can run those tests; on a fresh checkout create it and install `requirements-test.txt`. Set `FLUTTER_BIN` if Flutter is not on PATH.

See `docs/VALIDATION.md` for this release's results. Physical Bluetooth exchange and native authorization still need the actual phones; software tests do not substitute for that acceptance test.
