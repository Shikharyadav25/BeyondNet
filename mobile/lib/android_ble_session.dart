import 'package:flutter/services.dart';

/// Session lifecycle adapter for the pinned bluetooth_low_energy_android 6.2.1
/// Pigeon API. Public PeripheralManager does not expose reopening its GATT
/// server. These two void calls use only standard-codec values; no generated
/// private classes or reflection are required. Contract tests cover names and
/// error replies. Keep the plugin version pinned when changing this adapter.
class AndroidBleSession {
  static const prefix =
      'dev.flutter.pigeon.bluetooth_low_energy_android.PeripheralManagerHostApi.';

  Future<void> _call(String method) async {
    final channel = BasicMessageChannel<Object?>(
      '$prefix$method',
      const StandardMessageCodec(),
    );
    final reply = await channel.send(null).timeout(const Duration(seconds: 4));
    if (reply is! List || reply.isEmpty) {
      throw StateError('Bluetooth service is unavailable. Restart BeyondNet.');
    }
    if (reply.length > 1) {
      throw PlatformException(
        code: reply[0] as String,
        message: reply[1] as String?,
      );
    }
  }

  Future<void> close() async {
    try {
      await _call('closeGATTServer');
    } catch (_) {
      // First startup or Bluetooth off may have no open server to close.
    }
  }

  Future<void> reopen() async {
    await close();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _call('openGATTServer');
  }
}
