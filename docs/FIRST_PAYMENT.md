# Your first BeyondNet payment (Android)

Use the 1.1.1 APK (or 1.1.0 on Android 12+) with the existing 1.1.0 bank. This phone compatibility update does not require a bank restart. Keep the bank’s existing `data/` directory so its fingerprint and balances stay intact.

## 1. Laptop

Start `Start-Bank.command` (macOS), `start-bank.sh` (Linux) or `start-bank.ps1` (Windows). Open `http://localhost:8080`; unlock with `data/admin-token.txt`. Expose port 8080 through a trusted HTTPS tunnel that supports WebSockets, for example `cloudflared tunnel --url http://localhost:8080` after installing cloudflared. Keep both processes and the laptop awake.

Copy the HTTPS URL and the full bank fingerprint from **Device setup**. The operator key is only for the console; never enter it as a phone password. The laptop needs internet, not Bluetooth.

## 2. Create your accounts online

Install `BeyondNet-Android.apk` on two Android 10+ phones. Install over an existing version to retain its account/history. To keep that account, choose **Sign in**; account switching on an enrolled installation is intentionally unsupported while stored payments and keys belong to it.

On a fresh phone choose **Create account**:

- Phone A: **Personal**, your name, a unique ID such as `sam@beyondnet`, and a password of at least eight characters.
- Phone B: **Merchant**, your shop name, a unique ID such as `shop@beyondnet`, and its own password.
- On both, enter the same bank HTTPS URL and trust fingerprint. Compare the fingerprint with the laptop before continuing.

Both account types can act as relays. There is no relay or gateway account to select. Set a screen lock/PIN on the paying phone.

## 3. Add demo money

On Phone A tap **Add demo money**, enter ₹1,000 and confirm. New accounts start at zero. Funding requires the bank online and uses no real card/bank details. A lost response leaves the original top-up saved; the next attempt completes that top-up first without crediting it twice.

## 4. First try online

Keep both phones online. Phone B taps **Show my payment QR**. Phone A taps **Scan QR**, or **Pay by ID → enter shop@beyondnet → Find recipient**. Enter ₹10, review and authorize using the phone’s screen lock/biometrics.

Expect **Payment confirmed** with a bank reference on Phone A, an incoming receipt on Phone B, and the matching payment plus debit/credit entries in the laptop console. Online submission/status uses WSS; HTTPS recovery is automatic if the live connection is interrupted. No Bluetooth is needed for this step.

## 5. Try the same payment offline

1. Enable **Help as a nearby relay** / **Nearby relay** on both phones. Allow Nearby devices on Android 12+, or Location while using the app with Location switched on for Android 10–11; turn Bluetooth on, and keep both apps visible.
2. Keep Phone B’s internet on. It automatically forwards nearby requests to the bank.
3. Turn Phone A’s Wi-Fi and mobile data off, leaving Bluetooth on. The home screen shows **Your internet is off** after the connectivity check.
4. Tap **Set up offline payments → Scan for nearby phones**. Wait for a bank-verified phone to appear, then tap **Connect**.
5. Pay using the saved merchant ID or its QR. New IDs can be resolved through the connected relay when its directory or online bank access is available; otherwise use QR.
6. Keep both apps open until the bank-signed receipt returns. Compare its reference and amount with the laptop ledger.

Camera permission is required only for QR scanning. No manual Bluetooth pairing is needed. “Connected” means the nearby phone was authenticated recently; it does not guarantee an internet route. “On its way” means pending, not paid.

## 6. Optional third phone

Sign up another **Personal** or **Merchant** account, enable relay, then turn its internet off. It can carry packets between the sender and online phone. To require the middle hop when all devices are in range, use **Device → Allowed peers**: sender allows middle only; middle allows sender and online phone; online phone allows middle only. Clear the lists afterward.

## 7. Recovery checks

Interrupt gateway internet and restore it within the 15-minute authorization window. Repeat with relay disconnect/reconnect and app restart (enable relay again after restart). The original request ID must produce at most one debit; receipt recovery should finish the original payment.

An expired request without a receipt is **Outcome not yet known** because the bank may already have committed it. Do not create a replacement until you recover/check that outcome. Reconnecting the sender online automatically attempts recovery.

Record actual phone models, OS versions, payment ID, bank reference, connectivity and observed latency. Automated tests model radio exchanges; this physical test is still required. iPhone work remains deferred.

## Mixed APK compatibility test

Leave BeyondNet 1.1.0 on an Android 12+ phone and install 1.1.1 on an Android 10+ phone. Enroll both with the same bank URL and fingerprint; no server restart is needed. Fund the sender online. First make a small online payment and confirm its bank receipt. Then enable relay on both, turn the sender's internet off, leave the gateway online and perform a nearby payment. Match the payment ID, amount and bank reference in the sender receipt, recipient receipt and bank ledger. Repeat with the phones' roles reversed. Keep both apps open and clocks synchronized. This is the required real-phone acceptance check, not something the automated suite claims to have performed.
