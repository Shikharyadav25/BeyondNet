# Android installation

Use `installers/BeyondNet-Android-1.3.0.apk` (Android 10 or newer). `BeyondNet-Android.apk` is an alias to it. Install over the existing app to retain keys/history. Enabled relay now continues with the screen closed through an Android foreground service; see [setup and acceptance](BACKGROUND_RELAY.md).

Install over the existing app to preserve device keys/history. Updates require the same application ID and signing certificate. Do not uninstall to solve an update failure if payments are unresolved. Android versions below 10 are unsupported. Some older phones lack BLE peripheral advertising even when the OS version is supported.

For USB installation, enable USB debugging, unlock and authorize the laptop, then run `Install-Android.command`. `Share-Android.command` temporarily serves the APK over the local Wi-Fi network; stop it after transfer. Neither changes bank data.

## Setup

1. Open the bank dashboard → Device setup → generate/download its bank QR.
2. In the app scan it or choose its image; review and accept the HTTPS URL and fingerprint.
3. Sign up as Personal or Merchant, or sign in to an existing account while online.
4. Set the six-digit demo payment PIN using the account password, and add demo money online.
5. Set a phone screen lock so native device authentication works.
6. For nearby relay, enable Bluetooth. Android 12+ needs Nearby devices grants. Android 10–11 needs foreground Location permission and Location switched on; the app does not read coordinates. Enable Nearby relay while the app is visible and confirm its service notification; the screen can then close or lock. See [BACKGROUND_RELAY.md](BACKGROUND_RELAY.md) for restart and battery restrictions. Camera access is required only for live QR scanning; selecting an image uses the system picker.

The bank QR contains no account password, PIN or operator key. Manual bank entry remains supported. First enrollment/funding and PIN setup require internet. See [FIRST_PAYMENT.md](FIRST_PAYMENT.md) for two-phone testing. An iPhone build is not included.

## Build from source

Inside `mobile/`, run `flutter pub get` then `flutter build apk --release`. The APK is at `build/app/outputs/flutter-apk/app-release.apk`. The source ZIP intentionally excludes local signing material; a build on another machine may have a different development certificate. Use a fresh test installation or deliberately supply the matching signing identity before upgrading an existing enrolled phone.
