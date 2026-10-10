# Your first BeyondNet payment (Android)

Use the **1.3.0 APK** with the Java/PostgreSQL bank. Install over the existing app to retain keys/history. See [background relay and controlled three-phone acceptance](BACKGROUND_RELAY.md); the existing bank identity needs no update.

## 1. Laptop

Start `Start-Bank.command` (macOS), `start-bank.sh` (Linux) or `start-bank.ps1` (Windows). Open `http://localhost:8080`; unlock with `data/admin-token.txt`. Start `Start-Ngrok.command` on macOS or run `ngrok http http://127.0.0.1:8080 --inspect=false` after configuring ngrok's free account. See [Ngrok setup](NGROK.md) for the fixed address and existing-phone update steps. Keep both processes and the laptop awake and online.

In **Device setup**, confirm the HTTPS URL and generate the bank setup QR. Scan it on the phone or download it and select its image; this fills the URL and fingerprint together. Manual entry remains available. The operator key is only for the console; never enter it as a phone password. The laptop needs internet, not Bluetooth.

## 2. Create your accounts online

Install `BeyondNet-Android.apk` on two Android 10+ phones. Install over an existing version to retain its account/history. To keep that account, choose **Sign in**; account switching on an enrolled installation is intentionally unsupported while stored payments and keys belong to it.

On a fresh phone choose **Create account**:

- Phone A: **Personal**, your name, a unique ID such as `sam@beyondnet`, and a password of at least eight characters.
- Phone B: **Merchant**, your shop name, a unique ID such as `shop@beyondnet`, and its own password.
- On both, scan/select the same bank setup QR, or enter the same bank HTTPS URL and trust fingerprint. Compare the fingerprint with the laptop before continuing.

Both account types can act as relays. There is no relay or gateway account to select. Set a screen lock on the paying phone. While online, tap **Set payment PIN** and choose a separate six-digit demo PIN, authenticated with your account password.

## 3. Add demo money

On Phone A tap **Add demo money**, enter ₹1,000 and confirm. New accounts start at zero. Funding requires the bank online and uses no real card/bank details. A lost response leaves the original top-up saved; the next attempt completes that top-up first without crediting it twice.

## 4. First try online

Keep both phones online. Phone B taps **Show my payment QR**. Phone A taps **Scan QR**, or **Pay by ID → enter shop@beyondnet → Find recipient**. Enter ₹10, review, enter your demo payment PIN, and authorize using the phone’s screen lock/biometrics.

Expect **Payment confirmed** with a bank reference on Phone A, an incoming receipt on Phone B, and the matching payment plus debit/credit entries in the laptop console. Online submission/status uses WSS; HTTPS recovery is automatic if the live connection is interrupted. No Bluetooth is needed for this step.

## 5. Try the same payment offline

1. Enable **Help as a nearby relay** / **Nearby relay** while visible. Allow Nearby devices on Android 12+, or Location while using the app with Location on for Android 10–11. Turn Bluetooth on and confirm the relay notification.
2. Keep Phone B’s internet on. It automatically forwards nearby requests to the bank.
3. Turn Phone A’s Wi-Fi and mobile data off, leaving Bluetooth on. The home screen shows **Your internet is off** after the connectivity check.
4. Tap **Set up offline payments → Scan for nearby phones**. Wait for a bank-verified phone to appear, then tap **Connect**.
5. Pay using the saved merchant ID or its QR. New IDs can be resolved through the connected relay when its directory or online bank access is available; otherwise use QR.
6. The relay phone may leave the app or lock its screen. Compare the returned signed receipt with the laptop ledger. Stop relay afterward; it uses battery.

Camera permission is required only for QR scanning. No manual Bluetooth pairing is needed. “Connected” means the nearby phone was authenticated recently; it does not guarantee an internet route. “On its way” means pending, not paid.

## 6. Optional third phone

Sign up another **Personal** or **Merchant** account, enable relay, then turn its internet off. It can carry packets between the sender and online phone. To require the middle hop when all devices are in range, use **Device → Allowed peers**: sender allows middle only; middle allows sender and online phone; online phone allows middle only. Clear the lists afterward.

## 7. Recovery checks

Interrupt gateway internet and restore it within the 10-minute window. Repeat relay disconnect/reconnect, background screen removal and restart. A running service retains the queue and saved opt-in; after reboot/force-stop reopen the app. The original request ID must produce at most one debit.

An expired request without a receipt is **Outcome not yet known** because the bank may already have committed it. Do not create a replacement until you recover/check that outcome. Reconnecting the sender online automatically attempts recovery.

Record actual phone models, OS versions, payment ID, bank reference, connectivity and observed latency. Automated tests model radio exchanges; this physical test is still required. iPhone work remains deferred.

## APK compatibility

Use 1.3.0 throughout the chain for the stronger routing and background service. Versions 1.2.0/1.2.1 retain compatible PIN-authorized payment envelopes but lack the new background/path-trail behaviour. Old PIN-less new authorizations are rejected; completed old payments remain recoverable.
