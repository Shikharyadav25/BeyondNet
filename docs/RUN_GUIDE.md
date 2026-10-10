> **Current laptop configuration:** PostgreSQL is now on Neon. The launcher uses the private remote configuration and skips local database startup. See [Neon setup and restart guide](NEON_SETUP.md). Local-cluster instructions below apply only to a fresh local development setup.

# Final APK and command guide

Release: **BeyondNet 1.2.1, build 6**. Android **10 or newer**. Demo funds only; no real UPI/bank integration. Use the Java/PostgreSQL bank in this source release.

## 1. Install the APK

Copy/download `installers/BeyondNet-Android-1.2.1.apk` onto each phone, open it, and allow installation from your browser/file manager when Android asks. Install over the existing BeyondNet app; do not uninstall first if you need its keys/history. Existing users choose Sign in. The current release adds setup-QR import and retains the encrypted PIN payment behavior.

Optional USB installation, with phones unlocked, USB debugging enabled and the laptop authorized:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./Install-Android.command
```

Optional local Wi-Fi download:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./Share-Android.command
```

Open the address printed by that helper on a phone on the same Wi-Fi. Stop the helper with Ctrl+C after downloading. This is only an APK file-transfer helper, not the payment bank.

## 2. Start the bank — Terminal 1

This Mac is already configured. After stopping the previous bank, run:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./start-bank.sh
```

Leave this terminal open. It connects to Neon PostgreSQL, builds Java if necessary, and runs the bank on port **8080**. No local PostgreSQL cluster is started on this configured Mac. If port 8080 is already in use by BeyondNet, use the running bank; do not start a second one.

Open **http://localhost:8080**. To read the dashboard operator key, use another terminal:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
cat data/admin-token.txt
```

Copy just the key, without the `%` prompt symbol. It unlocks the dashboard; it is not a phone password or PIN. Restarting with the same `data/` preserves the operator key and fingerprint.

## 3. Start the internet tunnel — Terminal 2

If ngrok is already running, keep that instance. Otherwise:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./Start-Ngrok.command
```

Keep it open. This laptop's configured address is:

```text
https://sublime-penalty-helper.ngrok-free.dev
```

Use the HTTPS address printed by your running ngrok process. `ERR_NGROK_334` means that endpoint already has a running instance; use it or stop that instance before restarting. Do not add pooling for this demo.

Keep the laptop awake and connected to the internet. To prevent idle sleep during a test, open another terminal and run:

```sh
caffeinate -i
```

Stop it with Ctrl+C afterward. Closing the laptop lid can still suspend it. The bank never needs Bluetooth or proximity to the phones; it is reached over the internet.

## 4. Configure both phones

In the dashboard open **Device setup**, confirm the HTTPS URL and generate the bank setup QR. On the phone use **Scan bank QR** or **Choose QR image**, review and accept the details. The QR fills both bank URL and fingerprint.

If entering manually, this existing bank's fingerprint is:

```text
2f51ebea827536d3feba922adf6e817e8ec4d95e0b226c2641f827b3ea85c855
```

On another fresh bank, use its dashboard fingerprint instead. The bank QR contains no operator key, password or PIN. First enrollment and funding require internet.

- Phone A: Personal account, unique ID such as `sam@beyondnet`, password at least eight characters.
- Phone B: Merchant account, another unique ID such as `shop@beyondnet`, its own password.
- These IDs are examples to create, not guaranteed pre-existing login credentials. If already registered, sign in with your original account.
- Set a six-digit **demo payment PIN** online using your account password. Set a phone screen lock for device authentication. Do not use a real banking PIN.
- Add demo money on Phone A while online. New accounts start at zero.

## 5. Test online, then offline

First keep both phones online. Show Phone B's payment QR, scan it on Phone A or find B's payment ID, enter ₹10, confirm PIN and native authentication. Check the bank-signed receipt on the phones and the matching ledger entries in the dashboard.

Then:

1. Enable nearby relay on both phones; turn Bluetooth on and keep both apps visible.
2. Android 12+ needs Nearby devices permission. Android 10–11 needs foreground Location permission and Location switched on. The app does not read coordinates. Camera permission is only for live QR scanning.
3. Keep Phone B online. Turn off mobile data and internet Wi-Fi on Phone A, leaving Bluetooth on.
4. On A scan for nearby devices and connect to verified B. Pay using B's saved ID or payment QR.
5. Keep both apps open until the receipt returns. Verify **one** debit/credit and the same payment reference in the dashboard.

Two phones are enough. Extra offline relay phones are optional. BLE advertising support and real radio range vary by phone. Wi-Fi Direct mesh and background relay are not implemented.

“On its way” means pending. The signed authorization lasts **10 minutes**; a reachable payment processes immediately. An already-paid transfer is not canceled by a late receipt. If the outcome is unknown, recover/check the original payment before making a replacement.

## 6. Stop, back up and restart

Use Ctrl+C in the bank and ngrok terminals. Neon keeps the records saved when the local bank is stopped. Do not delete `data/`, clear app data or uninstall while outcomes are unresolved.

Private backup:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./scripts/backup-bank.sh
```

On this Neon deployment there is no local PostgreSQL to stop. For a separate local development setup only:

```sh
./scripts/stop-postgres.sh
```

Restart later with steps 2 and 3 using the same folder. Keep backups private: they contain credentials and bank identity. The source ZIP excludes these files; extracting source elsewhere does not move existing balances/accounts.

## 7. Developer commands

The current APK is already built. To build again on this configured Mac:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet/mobile
/Users/shikharyadav/.local/share/beyondnet-flutter/bin/flutter pub get
/Users/shikharyadav/.local/share/beyondnet-flutter/bin/flutter build apk --release
```

Output: `mobile/build/app/outputs/flutter-apk/app-release.apk`. On other machines use `flutter` from PATH and configure Android SDK/JDK first. Existing-phone updates need the same signing identity; signing secrets are deliberately absent from the source ZIP.

Full verification from the project root:

```sh
./scripts/check.sh
```

Java build only:

```sh
mvn -f backend/pom.xml package
```

Clean source package:

```sh
python3 scripts/package_source.py
```

Output: `dist/BeyondNet-source.zip`. Python is used only for utilities/independent tests; the bank is Java. See [BUILD_FLOW.md](BUILD_FLOW.md) for all file responsibilities, crypto/database/BLE implementation and flowcharts, and [SPRING_BOOT_SETUP.md](SPRING_BOOT_SETUP.md) for fresh-machine setup.

## Verified artifact

APK SHA-256:

```text
a73f813741f08587f4b21b3cce63c731c827205027981e6cd4516e014b9952de
```

70 automated tests passed in the source audit. Physical Bluetooth and native camera/gallery acceptance still need actual phones. This remains a proof of concept using demo funds.
