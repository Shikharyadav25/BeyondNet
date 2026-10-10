import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android 10–11 use foreground location for BLE discovery; newer phones use
/// Nearby devices. Online payment does not call this permission gate.
class NearbyPermissions {
  static const platform = MethodChannel('beyondnet/network');

  static Future<void> ensureAndroidReady() async {
    final sdk = await platform.invokeMethod<int>('androidSdkVersion');
    if (sdk == null || sdk < 29) {
      throw StateError('Nearby payments require Android 10 or newer.');
    }
    if (sdk >= 31) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ].request();
      if (statuses.length != 3 || statuses.values.any((s) => !s.isGranted)) {
        throw StateError(
          'Allow Nearby devices in Settings to discover, connect and relay.',
        );
      }
      // Optional: Android permits an FGS without this grant, but allowing it
      // makes the notification's Stop relay control visible in the drawer.
      if (sdk >= 33) await Permission.notification.request();
    } else {
      final status = await Permission.locationWhenInUse.request();
      if (!status.isGranted) {
        throw StateError(
          'Android 10–11 requires Location permission for Bluetooth scanning. '
          'Allow location while using BeyondNet in Settings.',
        );
      }
      if (!(await Permission.locationWhenInUse.serviceStatus).isEnabled) {
        throw StateError(
          'Turn Location on in phone Settings for Bluetooth scanning on '
          'Android 10–11. BeyondNet does not read or send your GPS location.',
        );
      }
    }
  }
}
