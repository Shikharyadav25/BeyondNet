# BeyondNet mobile

See [the project README](../README.md) and [first-payment guide](../docs/FIRST_PAYMENT.md).

Build with Flutter 3.44+ stable and Dart 3.12+. The project includes native Android and iOS runners. Android requires API 31+; iOS requires 15+. Use physical phones for Bluetooth. Keep the app in the foreground. For iPhone field tests use a signed release build so it can launch without an attached debugger.

```sh
flutter pub get
flutter analyze
flutter test
flutter run --release -d <device-id>
```

Do not uninstall while payments are unresolved: uninstalling can remove the local queue and device keys. The app intentionally has no destructive reset button.
