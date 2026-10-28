# BeyondNet 1.4.3 — Nearby relay switch recovery

Release date: 28 October 2026. Android version **1.4.3+17**.

## Problem and fix

The relay switch was disabled while startup waited for Android. Bluetooth service removal, advertising, discovery and stop operations had unbounded waits. A missing native reply could therefore leave a grey switch with its thumb still in the on position. A screenshot alone cannot identify which Android operation failed on the reporting phone; that device was not available over USB during this fix.

This release gives Bluetooth setup operations an eight-second response deadline and performs best-effort cleanup with three-second deadlines. The GATT lifecycle adapter already limits its native replies. Cleanup attempts to stop discovery, stop advertising and close the server independently, and detaches packet handlers even if a stop reply is lost. Registration timeouts stop the attempt instead of stacking retries on an unanswered callback; explicit native refusals retain bounded retries. A late reply cannot resume the abandoned Dart startup or mark it running.

Native foreground-relay start, stop and readiness calls have eight-second deadlines. Permission requests have a sixty-second deadline in the UI. These are individual operation deadlines, not a promise that the entire startup finishes in eight seconds.

Both Home and Nearby now display starting, stopping, on, off or paused status. A failed background restore stays paused instead of retrying on every monitoring tick. Explicit retry or a detected Bluetooth/permission readiness change permits another attempt. The UI releases its busy state before opening an error dialog, and stop failures are handled through the same dialog path. Start/restore and stop transitions are serialized so a pending start cannot complete after the app's stop and turn the relay back on.

## Verification

- Full Flutter suite: **120 passed**, including real Dart-to-Java enrollment/payment/receipt recovery against a separate PostgreSQL test instance.
- Flutter static analysis: **no issues**.
- Thirteen added regressions cover missing setup and stop replies, late completion, retry, background readiness/start/stop deadlines, failed restore recovery, stop during restore, startup progress, dialog recovery and turning a paused opt-in off.
- Existing bank/native/Python baseline: 36/20/5 passing tests from 27 October 2026. Those sources are unchanged by this release; these baseline suites were not rerun for this app-only patch.
- Signed Android release build and artifact identity: recorded in `docs/releases/1.4.3-validation.json` and `installers/SHA256SUMS.txt`.

Radio and UI regressions use controlled transports, native-channel mocks and widget tests. They reproduce the missing-reply failure paths but do not prove device-specific radio operation. No Android phone was visible over ADB, so physical installation and a new two-phone payment remain acceptance steps.

## Upgrade and check on the phone

1. Install `installers/BeyondNet-Android-1.4.3.apk` **over the existing app**. Do not uninstall or clear app data. The application ID, signing identity and SQLite schema are unchanged; version code 17 supports in-place upgrade from 1.4.2/code 16.
2. If the old version is currently stuck, close and reopen BeyondNet, then install the update. Saved keys and queued payment records must be retained.
3. Turn Bluetooth on and allow Nearby devices permissions (Android 12+) or Location permission plus Location service (Android 10–11).
4. Enable Nearby relay. Confirm that startup changes to “Nearby relay is on” or an actionable paused/error message, rather than remaining silently greyed out.
5. Turn relay off and confirm “Nearby relay is off.” Repeat from both Home and Nearby.
6. With relay enabled, turn Bluetooth off. Confirm the paused reason and that relay can still be turned off. Re-enable Bluetooth and relay, then use “Scan for nearby phones” to retry if paused after a startup failure.
7. On two enrolled phones, keep the gateway online, disconnect only the sender's internet, connect to the verified gateway and make a small demo payment. Match the signed bank reference in Activity and the bank ledger. A saved relay acknowledgment is not settlement.

The bank wire format is unchanged. An already updated 1.4.2 bank needs no rebuild for this mobile-only patch. Demo funds remain simulated INR with no real UPI or banking integration.
