# BeyondNet

BeyondNet is an Android demo payment app that works online and can also send encrypted requests through nearby phones when the sender has no internet. A laptop runs the demo bank and operator console. Only a bank-verified receipt confirms payment.

**Version 1.1.1 (Android build 4). Uses free demo INR; no real UPI or bank integration.**

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
2. Add demo money and choose a verified recipient by ID or QR.
3. Authorize using the phone’s screen lock/biometrics. The app signs, encrypts and saves the request.
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
| Demo bank | Python 3.11+, FastAPI, Uvicorn, SQLite |
| Laptop console | HTML/CSS/JavaScript served by the bank |

## Run it

1. Extract the source ZIP. On macOS open `Start-Bank.command`; Linux: `./start-bank.sh`; Windows: `./start-bank.ps1`. Python 3.11+ is needed. Alternatively on macOS/Linux:

   ```sh
   python3 -m venv .venv
   .venv/bin/python -m pip install -r requirements.txt
   .venv/bin/python scripts/run_bank.py
   ```

2. Open `http://localhost:8080` and unlock the console with `data/admin-token.txt`.
3. Provide a WebSocket-capable HTTPS route to the bank. For a free assigned fixed address, configure ngrok and open `Start-Ngrok.command` on macOS, or run:

   ```sh
   ngrok http http://127.0.0.1:8080 --inspect=false
   ```

4. Keep both processes running and the laptop awake and online. Use the HTTPS URL and the fingerprint from the console’s **Device setup** page on every phone. See [Ngrok setup](docs/NGROK.md) for this laptop's address and how to update existing phones.
5. Install the separately provided **BeyondNet-Android.apk**. Create one Personal and one Merchant account while online. Fund the personal account, then try an online payment before the offline two-phone flow above.

Use the updated bank source with this APK. Existing bank data and app installations are preserved; legacy accounts remain usable through **Sign in**, and previous relay account records become personal accounts. Internal app IDs remain unchanged for upgrades. Do not uninstall to update if you need your history and device keys.

For source builds, install Flutter, the Android SDK and JDK described in [Development](docs/DEVELOPMENT.md), then run `flutter pub get` and `flutter build apk --release` inside `mobile/`.

## Completed and remaining

Implemented: signup, two account types, idempotent funding, connectivity-aware screens, optional relay, explicit nearby connection, ID/QR payments, live receipt delivery, HTTPS recovery, encrypted BLE forwarding, persistent history and demo ledger. Automated bank, mobile, UI and real Dart-to-Python integration tests cover these paths; see [Validation](docs/VALIDATION.md).

Next: physical two-phone/multi-hop Android acceptance and measured radio reliability. Planned extensions include background delivery, Wi-Fi mesh, stronger production operations and authorized financial integrations. iOS source exists, but building/testing iPhone was deferred. None of these future items is claimed complete.

## Know before testing

- First signup, funding and renewal need internet. All relay phones need BeyondNet, enrollment, Bluetooth permission and the app open.
- Offline ID lookup uses saved recipients or the connected relay’s directory/bank access. If unavailable, scan the recipient’s QR.
- “On its way” is pending. An expired request with no receipt has an unknown outcome; recover it before sending a replacement. Authorization lasts 15 minutes.
- The laptop never uses Bluetooth. Wi-Fi is used for internet; Wi-Fi Direct/mesh is not implemented.
- Keep `data/` private and persistent. It contains bank identity, balances and operator credentials. Use a supervised demo tunnel; legacy rehearsal credentials and free funding remain enabled.
- The APK uses a development signing key. Real-money security, compliance, refunds and recovery require further work.

## Documentation

[First payment](docs/FIRST_PAYMENT.md) · [Architecture](docs/ARCHITECTURE.md) · [Protocol](docs/PROTOCOL.md) · [Development](docs/DEVELOPMENT.md) · [Security](docs/SECURITY.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Validation](docs/VALIDATION.md)

The source ZIP excludes runtime bank data, secrets, SDKs, caches and compiled APKs. Regenerate with `.venv/bin/python scripts/package_source.py`.
