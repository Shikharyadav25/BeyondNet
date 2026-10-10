# BeyondNet

BeyondNet is an Android demo payment app that works online and can also send encrypted requests through nearby phones when the sender has no internet. A laptop runs the Java demo bank and operator console; this deployment stores its ledger in Neon PostgreSQL. Only a bank-verified receipt confirms payment.

**Version 1.2.1 (Android build 6). Uses free demo INR; no real UPI or bank integration.**

## Vision

Make payment initiation possible in places with poor connectivity. Participating phones carry encrypted requests until an online phone reaches the bank, then carry receipts back. Final settlement still needs a reachable bank.

## Accounts and experience

- **Personal:** pay by payment ID or QR, view receipts, and add demo money.
- **Merchant:** show a payment QR, receive payments, see incoming receipts, and add demo money.
- **Relay is a capability, not an account type.** Either account can enable it. Online relay phones automatically act as internet gateways.

Create an account with a name, password, and unique `yourname@beyondnet` ID. New accounts start at zero; tap **Add demo money** while online (₹1–₹10,000 per top-up). Interrupted top-ups retry the same saved request to prevent double credit.

On opening/resuming the app and periodically while open, Android checks internet connectivity and the app checks the bank. Online users pay directly. Offline users see a setup prompt: turn Bluetooth on, grant Nearby devices permission (Android 12+) or foreground Location permission with Location enabled (Android 10–11), keep the app open, scan for verified phones and tap **Connect** before paying. A bank outage is shown separately from internet being off.

## Architecture and flow

```text
Online phone ─────────── WSS / HTTPS ────────── Laptop demo bank
                                                   ↕
Offline sender ↔ optional relay(s) ↔ online phone ────┘
                  Bluetooth LE
```

1. Enroll online, verify the bank fingerprint and register device keys.
2. Set a payment PIN online, add demo money and choose a verified recipient by ID or QR.
3. Enter your six-digit demo payment PIN and authorize using the phone’s screen lock/biometrics. The app signs, encrypts and saves the request.
4. Submit directly online, or relay ciphertext through nearby phones (up to four hops).
5. The bank validates and atomically records the decision and matching ledger entries.
6. Signed, encrypted receipts return over the live connection or nearby network. Requests and receipts survive interruption; retries do not repeat the debit.

Two phones are enough: offline personal user and online merchant with relay enabled. Extra relays are optional. Receipts prefer the reverse route but can use another available path. A nearby connection does not prove the bank is reachable.

## Tech stack

| Layer | Technology |
|---|---|
| Android app | Flutter / Dart, Material 3; Android 10+ |
| Nearby transport | Bluetooth Low Energy GATT, central and peripheral roles |
| Online transport | Authenticated secure WebSocket; HTTPS fallback and recovery |
| Phone persistence | SQLite; OS-protected secure storage for keys/sessions |
| Authorization and QR | Native device authentication; camera QR scanning/rendering |
| Encryption and signatures | X25519, HKDF-SHA256, AES-256-GCM, Ed25519 |
| Demo bank | Java 21+, Spring Boot 4.1.1, PostgreSQL |
| Laptop console | HTML/CSS/JavaScript served by the bank |

## Run it

1. Extract the source ZIP. This Mac already has Java/Maven/PostgreSQL. On macOS open `Start-Bank.command` or use:

   ```sh
   cd /Users/shikharyadav/Desktop/Projects/BeyondNet
   ./start-bank.sh
   ```

   Java 21+, Maven and PostgreSQL 17+ are required. This laptop now uses Neon PostgreSQL and runs the Java bank on port 8080. Fresh local development setups can instead initialize the dedicated PostgreSQL cluster on port 5433. Existing SQLite bank data is backed up and imported once; normal operation then uses PostgreSQL. For other platforms/custom databases, follow [Java and PostgreSQL setup](docs/SPRING_BOOT_SETUP.md).

2. Open `http://localhost:8080` and unlock the console with `data/admin-token.txt`.
3. Provide a WebSocket-capable HTTPS route to the bank. For a free assigned fixed address, configure ngrok and open `Start-Ngrok.command` on macOS, or run:

   ```sh
   ngrok http http://127.0.0.1:8080 --inspect=false
   ```

4. Keep both processes running and the laptop awake and online. Use the HTTPS URL and the fingerprint from the console’s **Device setup** page on every phone. See [Ngrok setup](docs/NGROK.md) for this laptop's address and how to update existing phones.
5. Install the separately provided **BeyondNet-Android-1.2.1.apk**. Create one Personal and one Merchant account while online. Set a six-digit demo payment PIN online and fund the personal account, then try an online payment before the offline two-phone flow above.

Use the updated bank source with this APK. Existing bank data and app installations are preserved; legacy accounts remain usable through **Sign in**, and previous relay account records become personal accounts. Internal app IDs remain unchanged for upgrades. Do not uninstall to update if you need your history and device keys.

For source builds, install Flutter, the Android SDK and JDK described in [Development](docs/DEVELOPMENT.md), then run `flutter pub get` and `flutter build apk --release` inside `mobile/`.

## Completed and remaining

Implemented: signup, two account types, idempotent funding, connectivity-aware screens, optional relay, explicit nearby connection, ID/QR payments, live receipt delivery, HTTPS recovery, encrypted BLE forwarding, persistent history and demo ledger. Automated bank, mobile, UI and real Dart-to-Java integration tests cover these paths; see [Validation](docs/VALIDATION.md).

Next: physical two-phone/multi-hop Android acceptance and measured radio reliability. Planned extensions include background delivery, Wi-Fi mesh, stronger production operations and authorized financial integrations. The unfinished iPhone scaffold has been removed; iPhone support is future work. None of these future items is claimed complete.

## Know before testing

- First signup, funding and renewal need internet. All relay phones need BeyondNet, enrollment, Bluetooth permission and the app open.
- Offline ID lookup uses saved recipients or the connected relay’s directory/bank access. If unavailable, scan the recipient’s QR.
- “On its way” is pending. An expired request with no receipt has an unknown outcome; recover it before sending a replacement. Authorization lasts 10 minutes; reachable requests settle immediately.
- The laptop never uses Bluetooth. Wi-Fi is used for internet; Wi-Fi Direct/mesh is not implemented.
- Keep `data/` private and persistent. It contains bank identity, balances and operator credentials. Use a supervised demo tunnel; legacy rehearsal credentials and free funding remain enabled.
- The APK uses a development signing key. Real-money security, compliance, refunds and recovery require further work.

## Documentation

[Neon database and restart guide](docs/NEON_SETUP.md) · [Final APK and command guide](docs/RUN_GUIDE.md)

[First payment](docs/FIRST_PAYMENT.md) · [Architecture](docs/ARCHITECTURE.md) · [Protocol](docs/PROTOCOL.md) · [Development](docs/DEVELOPMENT.md) · [Security](docs/SECURITY.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Validation](docs/VALIDATION.md)

The source ZIP excludes runtime bank data, secrets, SDKs, caches and compiled APKs. Regenerate with `.venv/bin/python scripts/package_source.py`.


## Folder structure

```text
BeyondNet/
├── backend/       Java bank, dashboard resources and Java tests
├── mobile/        Flutter Android app and Dart tests
├── tests/         Independent wire/migration tests and synthetic fixtures
├── scripts/       Database, build, backup and installation helpers
├── docs/          Current guides and flowcharts
├── installers/    Current APK and public setup QR (local distribution)
├── dist/          Generated source ZIP (ignored)
└── data/          Private persistent bank state and backups (ignored)
```

Start with the [developer build flow](docs/BUILD_FLOW.md) and its [flowchart](docs/diagrams/build-flow.svg). No private bank data or compiled outputs belong in source distributions.

## Current Java release

The bank is now Java + PostgreSQL. Phone SQLite remains the offline queue/history. Payments process immediately when reachable and expire after **10 minutes only if not committed**; a late receipt cannot cancel an already-paid transfer. New payments require the updated APK and an online-configured demo PIN. Existing bank keys, trust fingerprint, operator key, account passwords and financial history are preserved by the verified importer. See [restart, PIN setup, backup and Java class guide](docs/SPRING_BOOT_SETUP.md) and [validation](docs/VALIDATION.md).

The obsolete Python server, iPhone scaffold, duplicate APKs and historical reconstruction guides have been removed from working source and archived privately under `data/backups/`. Python utilities and independent crypto tests remain; the running backend is entirely Java. The old SQLite ledger is retained privately as a migration snapshot and receives no new writes.


## Bank setup QR (1.2.1)

In the bank dashboard open **Device setup**, confirm the public HTTPS URL, and click **Generate setup QR**. Scan it from the phone or download its PNG to the phone and choose **Choose QR image** on signup/sign-in. The QR contains both the URL and bank fingerprint. Review the details, tap **Use bank details**, and complete your account fields. Fingerprint verification still happens before credentials are sent. Manual entry remains available. Version 1.2.0 phones can continue making PIN-authorized payments; 1.2.1 adds the QR setup UI.
