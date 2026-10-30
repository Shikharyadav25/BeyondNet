import 'dart:async';
import 'package:flutter/services.dart';

/// Native opt-in is authoritative; stopping the notification must survive a
/// process restart and must never be overridden by a stale Flutter switch.
class BackgroundRelay {
  static const channel = MethodChannel('beyondnet/relay');
  static const responseTimeout = Duration(seconds: 8);

  void listen(Future<void> Function() refresh) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') await refresh();
    });
  }

  Future<Map<String, dynamic>> ready() async => Map<String, dynamic>.from(
    await channel.invokeMethod('ready').timeout(responseTimeout),
  );

  Future<void> start() async {
    await channel.invokeMethod('start').timeout(responseTimeout);
    final deadline = DateTime.now().add(responseTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = Map<String, dynamic>.from(
        await channel
            .invokeMethod('status')
            .timeout(deadline.difference(DateTime.now())),
      );
      if (status['blocked'] != null) {
        throw StateError(status['blocked'] as String);
      }
      if (status['enabled'] != true) {
        throw StateError('Nearby relay startup was cancelled.');
      }
      if (status['running'] == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw TimeoutException('Android relay service did not finish starting.');
  }

  Future<void> stop() async =>
      channel.invokeMethod('stop').timeout(responseTimeout);
  Future<void> update(String text) async =>
      channel.invokeMethod('update', {'text': text});
  Future<void> batterySettings() async =>
      channel.invokeMethod('batterySettings');
  Future<void> noticeRequest(String id, String name) async =>
      channel.invokeMethod('noticeRequest', {'id': id, 'name': name});
  Future<void> noticeConnection(String id, String name) async =>
      channel.invokeMethod('noticeConnection', {'id': id, 'name': name});
  Future<void> noticeConnectionReady(String id) async =>
      channel.invokeMethod('noticeConnectionReady', {'id': id});
  Future<void> noticeSubmitted(String id) async =>
      channel.invokeMethod('noticeSubmitted', {'id': id});
  Future<void> noticeResult(String id, String status) async =>
      channel.invokeMethod('noticeResult', {'id': id, 'status': status});
  Future<void> clearRequest(String id) async =>
      channel.invokeMethod('clearRequest', {'id': id});
  void dispose() => channel.setMethodCallHandler(null);
}
