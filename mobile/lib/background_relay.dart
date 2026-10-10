import 'package:flutter/services.dart';

/// Native opt-in is authoritative; stopping the notification must survive a
/// process restart and must never be overridden by a stale Flutter switch.
class BackgroundRelay {
  static const channel = MethodChannel('beyondnet/relay');

  void listen(Future<void> Function() refresh) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') await refresh();
    });
  }

  Future<Map<String, dynamic>> ready() async =>
      Map<String, dynamic>.from(await channel.invokeMethod('ready'));

  Future<void> start() async => channel.invokeMethod('start');
  Future<void> stop() async => channel.invokeMethod('stop');
  Future<void> update(String text) async =>
      channel.invokeMethod('update', {'text': text});
  Future<void> batterySettings() async =>
      channel.invokeMethod('batterySettings');
  void dispose() => channel.setMethodCallHandler(null);
}
