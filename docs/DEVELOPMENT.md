# Development and operation

## Project layout

```text
bank/
  app.py              HTTP API, enrollment, validation, atomic settlement
  crypto.py           Canonical JSON, signatures, encryption, packet integrity
  db.py               SQLite schema, seed accounts, password hashing
  demo.py             Software-only phone/hop rehearsal using the real bank API
  static/             Laptop console HTML/CSS/JS
mobile/
  lib/main.dart       Enrollment, home, pay, receive QR, activity, relay, settings
  lib/engine.dart     Enrollment, authorization, routing, gateway, receipt delivery
  lib/ble_transport.dart  Native BLE GATT adapter and bounded framing
  lib/protocol.dart   Wire crypto matching bank/crypto.py
  lib/store.dart      Durable phone SQLite state
  android/, ios/     Native runners and permissions
  test/              Protocol, framing, engine/persistence, UI-state tests
scripts/              Launch, rehearsal, verification helpers
tests/                Bank and cross-language integration tests
docs/                 Setup, architecture, protocol, security, troubleshooting
```

## Prerequisites

- Python 3.11+ for the laptop bank. Development was performed with Python 3.13.
- Flutter 3.44+ stable with Dart 3.12+ for the mobile app. Use the package lockfile.
- Android compile SDK 37, NDK 28.2.13676358, and JDK 21 for the checked-in Gradle project; use `flutter doctor`. Version 1.1.1 supports Android 10 (API 29) and newer; Android 10–11 uses foreground Location permission and Location enabled for BLE discovery.
- Xcode and an Apple signing team for physical iPhone installation. The iOS runner uses Flutter’s generated Swift Package Manager integration with compatible plugins.

The implementation has no PostgreSQL, Java server, Node frontend, Docker, or paid cloud requirement. A public HTTPS route is needed for a gateway on an external mobile network to reach the laptop.

## Laptop commands

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python scripts/run_bank.py
```

Optional arguments: `--port 8081`, `--host 127.0.0.1`, `--no-browser`. Default bind is loopback; expose it with an HTTPS reverse proxy or tunnel. Do not point the mobile app at `localhost`: on a phone that means the phone itself.

For a separate bank identity/database:

```sh
KARO_DATA_DIR=data/alternate .venv/bin/python scripts/run_bank.py --port 8081
```

This creates a **different trust identity**. Do not silently substitute that directory for a bank already trusted by phones. Stop the bank before copying the complete `data/` directory for a consistent backup. Bank keys, database, and operator token belong together. Do not delete/reset data while payments are unresolved.

`bank.app:create_app` is an application factory. For manual serving:

```sh
.venv/bin/python -m uvicorn bank.app:create_app --factory --host 127.0.0.1 --port 8080 --no-proxy-headers
```

Run one process/worker. API documentation is at `/docs`. The operator console is served by the same process at `/`; it is a laptop browser app, not a separately packaged desktop executable.

## Mobile commands

```sh
cd mobile
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run --release -d <device-id>
```

Build an Android APK with `flutter build apk --release`. Build a signed iOS archive through Xcode or `flutter build ipa` after provisioning. `flutter build ios --simulator --debug` checks a simulator build but cannot validate BLE.

The Android manifest includes internet, scan/connect/advertise, camera, and biometric permissions. Minimum API is 31 to keep the demo’s permissions predictable. `FlutterFragmentActivity` and AppCompat themes support native device authentication. iOS includes Bluetooth, camera, and Face ID descriptions plus keychain entitlements. No background modes are claimed.

Do not replace the app with a browser/PWA to run the radio test: the required cross-platform GATT server functionality is native.

## Tests

BeyondNet 1.1.0 keeps the previous native app IDs and wire protocol for in-place Android upgrades. The Dart package is now `beyondnet`, and user-facing names in the app, native runners, bank console, launch helpers, and documentation are BeyondNet.

From the project root:

```sh
(cd mobile && flutter pub get && flutter analyze && flutter test)
.venv/bin/python -m pytest -q
```

Or `./scripts/check.sh` with Flutter on PATH. Flutter tests emit `mobile/build/dart-wire.json`; the Python interoperability test then decrypts that exact Dart-generated envelope. If Flutter has not run, that one test is explicitly skipped; the bank suite still runs.

Tests cover duplicate/re-encrypted instructions, conflicting IDs, insufficient funds, concurrent spending, tampering, unauthorized requests, receipt recovery, restart persistence, revocation, actual mobile routing handlers, paged inventories, storage persistence, receipt signature/matching, stale balance revisions, frame reassembly, and unknown-outcome UI behavior. Physical radio tests are a separate acceptance step.

## Account and credential operation

Users create customer or merchant accounts with `/api/signup`. IDs end in `@beyondnet`; new balances are zero. `/api/topups` mints demo money with idempotent request IDs. Legacy seed accounts remain only for compatibility and software rehearsals; old relay roles migrate to customer. Their balances are not reset. SMS/identity verification is not implemented.

The operator key is created randomly in `data/admin-token.txt`; keep it local. To revoke a device, call `POST /api/admin/revoke/{device_id}` with operator authorization. Revocation prevents new bank submissions from that key; offline peers do not immediately learn revocation.

Phone sessions expire after seven days, certificates after 30. **Device → Renew login / update bank URL** renews the same device identity and caches new bank-signed material. It cannot switch an existing installation to a different account or bank.

## Extension points

The transport owns bytes and GATT sessions. `engine.dart` owns identity, inventory, persistence, forwarding, and gateway behavior. A future Wi-Fi transport should call the same authenticated RPC handler and leave financial authorization unchanged. A real bank integration would replace the demo accounting layer and enrollment assumptions, not merely rename the demo UPI IDs.

The bank startup adds `topups` and `device_receipts` tables and migrates legacy relay account roles without resetting data. Phone SQLite schema remains version 1; do not run this as a rolling multi-version bank service. Pin/upgrade native plugins deliberately and repeat physical-device testing after upgrades.

## UI previews

`docs/screenshots/phone-*-preview.png` are renders of the actual Flutter widgets with sample display data. They are not evidence of a hardware transfer. Regenerate from `mobile` with:

```sh
KARO_PREVIEW_FONT=/path/to/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf \
  flutter test tool/render_previews.dart
```

Bank screenshots use the real console with isolated software-rehearsal state.

## Live integration test

Install root Python requirements before `flutter test`. `test/live_bank_test.dart` launches `scripts/test_live_bank.py` on an ephemeral loopback port with a temporary bank directory. It runs actual Dart signup, funding, WSS-message handling (test-only local WS), signed payment creation, Python settlement, merchant receipt delivery and HTTPS fallback. Set `BEYONDNET_TEST_PYTHON` if the Python environment is not `../.venv/bin/python`. Production app URLs still require HTTPS/WSS.

Live API: `POST /api/signup`, `POST /api/topups`, `GET /api/recipients/{id}`, `GET /api/receipts/{device_id}?after={cursor}` and WebSocket `/api/live`. Use a reverse proxy that forwards WebSocket upgrades. Existing `/api/packets` and mailbox APIs remain recovery paths.
