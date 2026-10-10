# Troubleshooting

| Symptom | Check / action |
|---|---|
| Bank console will not open | Start the bank process, check port 8080, and inspect the launch terminal. The operator key is in that bank’s `data/admin-token.txt`. |
| Phone cannot enroll | Use the public HTTPS origin, not `localhost` or the laptop’s private address from another network. Check tunnel/laptop internet and matching fingerprint. |
| Fingerprint mismatch | Compare all 64 characters with the intended laptop. Do not bypass it. A new bank data directory has new keys. |
| No recipients | Ask the recipient to sign up/enroll, then find their payment ID online or scan their QR. Offline ID lookup needs a cached certificate or a connected relay that can resolve it. |
| Nearby relay will not start | Enable Bluetooth and grant Nearby devices/Bluetooth permissions. Open app settings after a permanent denial. Android must support BLE peripheral advertising. |
| No verified peers | All phones must be enrolled in the same bank, have Nearby relay on, remain in the foreground, and be within actual BLE range. Confirm allowlists in both directions and reasonably synchronized clocks. |
| Bluetooth radio on but no peers | Having Bluetooth on alone does not make another phone a BeyondNet relay. The app must be installed, enrolled, open, and opted in. The simulator cannot test this. |
| Direct path bypasses middle phone | Use the documented allowlists. With an unrestricted mesh, a direct path is valid behavior. |
| Bank connection says unavailable | Confirm mobile data/Wi-Fi internet, correct bank origin, laptop/tunnel running, and bank not paused. Retries back off to 60 seconds; the refresh action checks again. |
| Gateway says renew login | Go online and renew the account session in Device settings. Preserve the existing device keys and queue. |
| Payment stays queued | Start Nearby relay. Check for verified peers and an eventual reachable gateway. Peer storage is not settlement. |
| Payment was submitted but sender still pending | Keep the return relay route available. The gateway persists receipts and recovers the committed result through the original request capability. Reconnecting the sender online automatically recovers its own receipts. |
| Authorization expired | Leave the original payment in history. An earlier attempt may have settled. No receipt means unknown outcome, not automatic failure. Recover before creating another payment. |
| Relay storage full | Original copies remain with senders. The store caps ciphertext at 10 MiB/1,000 packets. Let expired relay packets age out; do not erase app data while owned payments are unresolved. |
| Device authentication fails | Set a secure passcode/PIN or biometric on the phone. On Android, use the supplied FragmentActivity/AppCompat configuration. |
| Receipt balance looks old | It is explicitly a snapshot. Refresh online or wait for the newer signed ledger revision. Pending requests are not locally settled balances. |
| QR scanning is unavailable | Grant camera access. You can still select a cached recipient without camera permission. |
| Android build fails on Java version | Use a JDK supported by the generated Gradle/Android plugin, and confirm `flutter doctor -v`. Do not change payment code to work around build-tool setup. |
| Bank rejects a packet without a signed decision | Malformed, unauthorized, or conflicting instructions do not create a success. The phone retains an unknown financial outcome; inspect the operator ledger by payment ID. |

## Evidence to collect

Before restarting or changing configuration, record the payment ID, visible state, bank reference if any, phone models/OS versions, peer names/IDs, and redacted Nearby logs. Look up the payment in the bank console. A bank ledger entry is authoritative for the demo; a phone transport status is not.

Avoid sharing private keys, account sessions, operator keys, or complete bank data directories in logs or screenshots. The included phone event log omits amount, ciphertext, and mailbox capabilities.

## Safe recovery sequence

1. Keep the original app installations and laptop data directory.
2. Restore the bank and HTTPS tunnel; update the URL through session renewal if it changed.
3. Start Nearby relay again after an app restart; online gateway participation is automatic while relay is enabled.
4. Restore the participating phone path and allow retry time.
5. Match the returned receipt’s bank reference and amount with the laptop ledger.

Restarting the bank does not reset balances or decisions. A duplicate original payment returns the stored result and does not repeat the debit.

## Build components on the development Mac

The Android configuration requires **NDK 28.2.13676358**. Install it in **Android Studio → SDK Manager → SDK Tools → NDK (Side by side) → Show Package Details**, or use:

```sh
sdkmanager 'ndk;28.2.13676358'
```

Then rerun `flutter build apk --release`. Build success must be confirmed before treating an APK as installable; source analysis and unit tests alone do not establish that.

## New signup and live updates

Use the current Java bank with APK 1.2.1. A 404 on signup/top-up usually means an older bank process is running. IDs must use `3-to-32-characters@beyondnet`; existing IDs sign in as before. A duplicate signup after an interrupted enrollment can be completed through Sign in. New accounts need Add demo money before spending.

If WSS is blocked by a proxy, HTTPS recovery still works; allow WebSocket upgrades for live status. Internet is off means Android reports no validated internet route. Cannot reach the bank can instead mean a stopped bank, paused service, expired login, stale tunnel URL or trust mismatch. Offline payments still need a verified nearby peer; they cannot settle until a gateway reaches the bank.

## APK will not install on Android 10–11

Use BeyondNet 1.1.1/build 4 or newer, whose minimum API is 29. The older 1.1.0 APK requires Android 12. Download the complete APK again if Android 10+ reports a parsing error; a damaged or incomplete transfer is a separate issue. Install over an existing BeyondNet app without uninstalling to preserve device enrollment and history.

## Android 10–11 cannot find nearby phones

Turn Bluetooth on, allow Location while using BeyondNet, and turn the phone's Location switch on. Keep both apps awake and visible. Android requires this location gate for BLE scanning even though BeyondNet does not read coordinates. Android 12+ uses Nearby devices instead. If discovery still fails, check BLE advertising support on the phone and test at close range. The bank and trust fingerprint are the same for both APK versions.
