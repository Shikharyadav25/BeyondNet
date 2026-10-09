# Phone installation

## Android

Android 10 or newer is required. On each phone enable Developer options (tap Build number seven times in Settings → About phone), enable USB debugging, connect it by USB, unlock it, and approve the computer's debugging prompt. Choose File transfer if the phone defaults to charging only.

When `installers/BeyondNet-Android.apk` is present, double-click `Install-Android.command` on the Mac. It installs on all connected authorized Android devices, preserves existing app data, verifies the package is installed, and opens the app. It does not automatically grant Bluetooth or camera permissions; complete the app's setup screens.

Alternatively, transfer the APK to the phone, open it, and allow installation from that source when Android asks. This is a demo build signed with the local development key; it is not a Play Store release. Keep the same signing key for updates to enrolled devices.

If USB is unavailable, double-click `Share-Android.command`. Put the phones on the same Wi-Fi as the Mac and open the address it prints in each phone's browser. Download the APK, open it, approve Android's installation prompt, and launch BeyondNet. This temporary server shares only the APK and checksum; stop it with Control-C after downloading. No USB debugging is needed for this installation method. A guest Wi-Fi network with client isolation may prevent access; use USB or a Wi-Fi network that permits devices to reach the Mac.

To build from source with Flutter installed:

```sh
cd mobile
flutter pub get
flutter build apk --release
mkdir -p ../installers
cp build/app/outputs/flutter-apk/app-release.apk ../installers/BeyondNet-Android.apk
```

## iPhone

Apple requires an Apple account, a valid development signing identity and provisioning, and a connected trusted iPhone. An unsigned `.app` or APK cannot be installed on an iPhone. A personal Apple account can provision a demo through Xcode, subject to Apple's personal-team limits.

1. Open Xcode → Settings → Accounts and sign in with your own Apple account.
2. In Xcode → Settings → Components, install the available iOS platform for the selected Xcode. On this Mac the UI offers **iOS 26.5.1 + iOS 26.5 Simulator (10.6 GB)**, although the command-line request for 26.5 reported unavailable. Free at least 15 GB before attempting this installation; leave additional space for extraction and compilation if Xcode requests it.
3. Connect the unlocked iPhone by USB, approve Trust This Computer, and enable Settings → Privacy & Security → Developer Mode if requested. Restart and confirm the Developer Mode prompt.
4. Run `flutter pub get` in `mobile`, then open `mobile/ios/Runner.xcworkspace` in Xcode.
5. Select Runner → Signing & Capabilities. Enable Automatically manage signing and choose your Apple team. If the existing bundle identifier is unavailable to your team, change it to a unique identifier you control.
6. Select the connected iPhone as the run destination and press Run. If iOS requests developer trust, follow its Settings prompt.
7. Complete account enrollment while online, then grant Bluetooth and camera access in the app. Keep the app in the foreground for the mesh test.

After installing the platform, signing in, and connecting one trusted iPhone, you can also double-click `Install-iPhone.command`. It finds your sole configured Apple team, builds the native app, requests automatic development provisioning from Apple, verifies its signature, installs it, and opens it. A development identity/profile may be created by Xcode. If there are multiple teams or phones, use `python3 scripts/install_iphone.py --team TEAM_ID --device DEVICE_ID`. You may need to approve a macOS Keychain prompt on the computer and enable Developer Mode on the phone. This helper uses a team-specific demo bundle identifier.

This Mac initially had no Apple signing identities or connected devices. Apple account sign-in was subsequently confirmed, with a Personal Team available. These are installation prerequisites, not successful device-install evidence. See VALIDATION.md for current build results.

## After installation

Follow [FIRST_PAYMENT.md](FIRST_PAYMENT.md) to create Personal/Merchant accounts on two or more phones against the same trusted HTTPS bank. Add demo money while online. Enrollment and recipient caching need internet once. Only then disable internet on the sender and relay. Keep Bluetooth enabled, keep the apps visible, and leave internet enabled on the gateway phone.

## Android 10–11 Bluetooth setup

The 1.1.1/build 4 APK supports Android 10 and newer. Android 10–11 requires Location permission while using BeyondNet and the phone's Location switch on for Bluetooth discovery; BeyondNet does not request or transmit coordinates. Android 12+ keeps Nearby devices permissions and does not request Location. Bluetooth must be on and the app must stay visible. Permission denial or Location off is reported before starting a relay. Some older phones lack BLE advertising support and cannot run the full nearby relay; physical hardware testing is still required.

The old 1.1.0 APK and new 1.1.1 APK use the same bank and BLE protocol. They can coexist on different phones. The old APK still requires Android 12+. No bank restart is required for this compatibility update. Install the new APK over the existing app to preserve enrollment, keys, payment history and queued messages; do not uninstall first.
