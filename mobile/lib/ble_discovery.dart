import 'dart:async';

import 'package:flutter/services.dart';

/// Owns scan transitions independently of GATT transfers. Android keeps the
/// original scan alive when it rejects a duplicate start with error 1.
class BleDiscovery {
  final Future<void> Function() startScan, stopScan;
  final void Function(String) onEvent;
  final Duration startTimeout, stopTimeout, scanWindow, retryDelay;
  final int maxStartsInWindow;
  Future<void> _tail = Future<void>.value();
  bool _wanted = false, _active = false, _resetNeeded = true;
  int _generation = 0;
  final Stopwatch _clock = Stopwatch()..start();
  final List<Duration> _starts = [];
  int _failures = 0;
  Timer? _retry, _waitTimer;
  Completer<void>? _wait;

  BleDiscovery({
    required this.startScan,
    required this.stopScan,
    required this.onEvent,
    this.startTimeout = const Duration(seconds: 8),
    this.stopTimeout = const Duration(seconds: 3),
    this.scanWindow = const Duration(seconds: 30),
    this.maxStartsInWindow = 4,
    this.retryDelay = const Duration(seconds: 2),
  }) : assert(maxStartsInWindow > 0),
       assert(scanWindow > Duration.zero);

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    // An unsuccessful operation must not poison subsequent cleanup/recovery.
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  bool _current(int generation) => _wanted && generation == _generation;

  Future<void> _delay(Duration duration) async {
    if (duration <= Duration.zero) return;
    final wait = _wait = Completer<void>();
    _waitTimer = Timer(duration, wait.complete);
    await wait.future;
    if (_wait == wait) {
      _wait = null;
      _waitTimer = null;
    }
  }

  static int? _scanError(Object error) {
    if (error is! PlatformException) return null;
    final match = RegExp(
      r'Start discovery failed with error code:\s*(\d+)\b',
    ).firstMatch(error.message ?? '');
    return match == null ? null : int.tryParse(match[1]!);
  }

  Future<void> _start(int generation) async {
    if (!_current(generation) || _active) return;
    if (_resetNeeded) {
      await stopScan().timeout(stopTimeout);
      _resetNeeded = false;
      if (!_current(generation)) return;
    }
    while (_current(generation)) {
      final now = _clock.elapsed;
      _starts.removeWhere((at) => now - at >= scanWindow);
      if (_starts.length < maxStartsInWindow) break;
      // Normal starts are immediate. Defer only an actual burst; a monotonic
      // clock prevents a phone-clock adjustment from extending the cooldown.
      await _delay(scanWindow - (now - _starts.first));
    }
    if (!_current(generation)) return;
    _starts.add(_clock.elapsed);
    try {
      await startScan().timeout(startTimeout);
      _active = true;
      _failures = 0;
    } catch (error) {
      if (_scanError(error) != 1) {
        _active = false;
        _resetNeeded = true;
        rethrow;
      }
      // The same callback/settings are already registered. Stopping a healthy
      // scan here would create extra gaps and consume the scan-start quota.
      _active = true;
      _failures = 0;
      if (_current(generation)) {
        onEvent('Nearby discovery is already active; continuing.');
      }
    }
  }

  /// Initial startup remains strict: callers can show a failed-start message.
  Future<void> start() {
    _wanted = true;
    final generation = ++_generation;
    _retry?.cancel();
    return _serialize(() => _start(generation));
  }

  /// Resume failures retain queued packets and recover without another toggle.
  Future<void> resume() {
    _wanted = true;
    final generation = ++_generation;
    _retry?.cancel();
    return _serialize(() => _resume(generation));
  }

  Future<void> _resume(int generation, {bool recovering = false}) async {
    try {
      await _start(generation);
      if (recovering && _current(generation) && _active) {
        onEvent('Nearby discovery resumed.');
      }
    } catch (error) {
      if (!_current(generation)) return;
      final code = _scanError(error);
      onEvent(
        'Nearby discovery is temporarily unavailable'
        '${code == null ? '' : ' (Bluetooth code $code)'}. '
        'Retrying automatically; saved packets are retained.',
      );
      _failures++;
      final delay = code == 6
          ? const Duration(seconds: 30)
          : Duration(
              milliseconds:
                  (retryDelay.inMilliseconds *
                          (1 << (_failures - 1).clamp(0, 4)))
                      .clamp(0, 30000),
            );
      _retry = Timer(delay, () {
        if (_current(generation)) {
          unawaited(_serialize(() => _resume(generation, recovering: true)));
        }
      });
    }
  }

  void _cancelWait() {
    _retry?.cancel();
    _waitTimer?.cancel();
    final wait = _wait;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  /// A screen-state change selects a different Android scan filter. A newer
  /// pause or stop always wins over this queued reconfiguration.
  Future<void> reconfigure() {
    if (!_wanted) return Future<void>.value();
    final generation = ++_generation;
    _cancelWait();
    return _serialize(() async {
      if (!_current(generation)) return;
      _active = false;
      _resetNeeded = true;
      await _resume(generation);
    });
  }

  /// Invalidates delayed/retrying starts before queuing the native stop.
  Future<void> stop() {
    _wanted = false;
    _generation++;
    _cancelWait();
    return _serialize(() async {
      _active = false;
      _resetNeeded = true;
      await stopScan().timeout(stopTimeout);
      _resetNeeded = false;
    });
  }
}
