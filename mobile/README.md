# BeyondNet Android app

Flutter 3.44+ / Dart 3.12+, Android 10+ (API 29), compile SDK 37, target SDK 36. Native runners currently include Android only. Use physical phones for Bluetooth; keep participating apps visible.

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The APK is created at `build/app/outputs/flutter-apk/app-release.apk`. Install over an existing BeyondNet installation with the same application ID and signing certificate to retain device keys and history. Do not uninstall while a payment outcome is unresolved.

See the [developer build flow](../docs/BUILD_FLOW.md), [installation guide](../docs/PHONE_INSTALLATION.md), and [first payment](../docs/FIRST_PAYMENT.md).
