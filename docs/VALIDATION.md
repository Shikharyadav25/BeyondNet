# BeyondNet 1.1.1 — Android 10 compatibility validation

Updated 9 October 2026.

- Minimum supported phone API: Android 10 / API 29. Android 12+ still uses Nearby devices permissions; Android 10–11 uses foreground Location permission and requires the Location switch on before scanning. No GPS coordinates are read or sent by BeyondNet.
- App suite: **34 passed**, including seven new permission tests for API 29/30/31+, denied permissions, Location off, incomplete grants and unavailable/unsupported API levels.
- Bank checks: **21 passed** across the main suite and the Dart interoperability check after its test vector was generated.
- Static analysis: **No issues found**.
- Android release build: **Passed**, 1.1.1/build 4, minimum SDK 29, target SDK 36, ARM32 / ARM64 / x86_64 libraries. APK archive integrity and signature verification with minimum SDK 29 passed; the Android SDK-version channel is present in the APK. Signing certificate SHA-256 matches 1.1.0: `87631ca5716266c5e82f64acff27185b6b1d84bd126128546545847427a07ff2`.
- APK SHA-256: `2dc5bd61dd60bc66eb3efef727a7bfc711535315416932559758a68fc7c237bd`.
- Compatibility: bank code, protocol, payment engine, local store and the previous release's Python/Dart wire fixture are byte-for-byte unchanged from the 1.1.0 source archive. The existing 1.1.0 APK can continue to share the same bank and mesh with 1.1.1; no bank restart is needed.
- Android 10 hardware, native authorization and physical exchange between old/new APKs are **not yet verified**. No Android phone or emulator is connected/available on this Mac. This release has software and packaging validation, not physical radio acceptance.

The earlier release evidence below is retained as historical context.

---

# BeyondNet 1.1.0 validation

Updated 6 October 2026. Software evidence is separate from physical radio acceptance.

| Check | Result |
|---|---|
| Bank suite | **21 passed**: cryptography, settlement, duplicate recovery, concurrency, signup, top-ups, live receipt delivery and authentication |
| Flutter suite | **27 passed**: protocol/framing, durable queues, signed RPCs, receipt verification, new screens, connectivity states, funding recovery and live bank integration |
| Flutter static analysis | **No issues found** |
| Dart-to-Python live integration | Passed against a real temporary loopback bank: signup → zero balance → funding → encrypted payment → matching sender/merchant receipts → HTTPS fallback |
| UI previews | Passed: actual signup, online/offline home, merchant home, funding and receipt widgets rendered at phone size |
| Bank console | Passed: actual HTML/CSS/JS rendered with isolated rehearsal state; responsive layout, title and JavaScript checks |
| Python/console syntax | Passed |
| Android 1.1.0 build 3 | **Passed**: version 1.1.0/build 3, BeyondNet label, unchanged application ID/signing certificate, ARM32/ARM64/x86_64 Flutter libraries, and native connectivity method/permission verified. Checksum in `installers/SHA256SUMS.txt` |
| Physical installation / BLE | **Not performed for this release**: Android device inventory is empty |
| iPhone | Deferred at the user’s request; no signed/verified iPhone release claimed |
| Real UPI | Not implemented; all balances and funding are demo money |

## What the tests establish

Bank tests exercise atomic debit/credit posting, insufficient-funds persistence, re-encrypted duplicate instructions, changed-ID conflicts, concurrent spending, tampered payloads/signatures, expired authorization, mailbox recovery, restarts and revocation. New tests cover customer/merchant signup, rejected relay account types, zero starting balances, funding bounds/authentication, concurrent duplicate top-ups, changed-amount conflicts and durable funding recovery.

WebSocket tests submit real encrypted instructions, verify both parties’ receipts, reconnect and replay persisted receipts, reject invalid sessions and other users’ devices, detect revocation, and retry bank-paused requests using the original packet. Any enrolled customer can forward another customer’s packet; no relay-specific account is required.

The Flutter suite runs the actual Dart engine against the actual Python bank using isolated temporary accounts/data. It uses test-only loopback HTTP/WS redirection and a mocked device authorization result; the production app enforces HTTPS/WSS and native device authentication. This validates code interoperability, not physical Bluetooth, real mobile TLS/proxy configuration or biometric hardware.

Other mobile tests cover QR/ID recipient validation, stale balance protection, top-up response loss and saved request IDs, authenticated RPCs, paged inventories, persistence, forged/mismatched receipt rejection, old relay acknowledgments arriving after confirmation, expired unknown outcomes, offline connection gating, and Android-reported offline versus reachable-but-paused-bank states. Screen tests verify the two signup types, online payment without relay, merchant receiving, offline setup and offline funding restrictions.

## Physical acceptance still required

Follow [First payment](FIRST_PAYMENT.md) on actual Android 12+ devices:

1. Create Personal and Merchant accounts online; fund the sender.
2. Complete an online payment and match both receipts to the bank ledger.
3. Enable relay on both phones, disable sender internet, scan/connect and complete the two-phone BLE payment.
4. Repeat with an optional offline middle phone and explicit allowlists.
5. Test Bluetooth permission denial, radio off/on, gateway/relay loss, app restart, authorization expiry and receipt recovery.

Record phone models, OS versions, payment ID, bank reference and observed latency. Verify one debit and one credit for each successful payment (funding has its own separately identified ledger pair). Keep apps visible. Radio range, throughput, battery behavior and background delivery have not been established.

`docs/screenshots/` contains actual rendered UI with sample data. Screenshots and software-modeled hops are not proof of a hardware payment. The APK is signed with the existing development key for in-place demo upgrades.
