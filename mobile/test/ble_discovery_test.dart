import 'dart:async';

import 'package:beyondnet/ble_discovery.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

PlatformException scanFailure(int code) => PlatformException(
  code: 'IllegalStateException',
  message:
      'java.lang.IllegalStateException: '
      'Start discovery failed with error code: $code',
);

void main() {
  late BleDiscovery discovery;
  late List<String> events;
  late List<String> calls;
  Future<void> Function()? scan, stop;
  setUp(() {
    events = [];
    calls = [];
    scan = null;
    stop = null;
    discovery = BleDiscovery(
      startScan: () async {
        calls.add('start');
        await scan?.call();
      },
      stopScan: () async {
        calls.add('stop');
        await stop?.call();
      },
      onEvent: events.add,
      startTimeout: const Duration(milliseconds: 80),
      stopTimeout: const Duration(milliseconds: 80),
      retryDelay: const Duration(milliseconds: 30),
    );
  });
  tearDown(() async {
    stop = null;
    await discovery.stop();
  });

  test('Android duplicate-scan code 1 retains the existing scanner', () async {
    scan = () async => throw scanFailure(1);
    await discovery.start();
    await discovery.resume();
    expect(calls, ['stop', 'start']);
    expect(events.single, contains('already active'));
    expect(events.single, isNot(contains('Exception')));
  });

  test(
    'A real resume failure resets and retries without another toggle',
    () async {
      await discovery.start();
      await discovery.stop();
      var attempts = 0;
      final recovered = Completer<void>();
      scan = () async {
        if (++attempts == 1) throw scanFailure(3);
        recovered.complete();
      };
      await discovery.resume();
      expect(events.single, contains('Retrying automatically'));
      await recovered.future.timeout(const Duration(seconds: 1));
      await discovery.resume();
      expect(attempts, 2);
      expect(calls, ['stop', 'start', 'stop', 'start', 'stop', 'start']);
    },
  );

  test('Stopping cancels scheduled recovery', () async {
    scan = () async => throw scanFailure(6);
    await discovery.resume();
    await discovery.stop();
    final stopped = List.of(calls);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(calls, stopped);
  });

  test(
    'Stopping drains an in-flight start and cannot resurrect scanning',
    () async {
      final pending = Completer<void>();
      scan = () => pending.future;
      final starting = discovery.start();
      await Future<void>.delayed(Duration.zero);
      final stopping = discovery.stop();
      expect(calls, ['stop', 'start']);
      pending.complete();
      await Future.wait([starting, stopping]);
      expect(calls, ['stop', 'start', 'stop']);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(calls.last, 'stop');
      expect(calls.length, 3);
    },
  );

  test(
    'Missing native start reply times out and still permits cleanup',
    () async {
      scan = () => Completer<void>().future;
      await expectLater(discovery.start(), throwsA(isA<TimeoutException>()));
      await discovery.stop();
      scan = null;
      await discovery.start();
      expect(calls, ['stop', 'start', 'stop', 'start']);
    },
  );

  test(
    'A failed stop does not poison recovery or hide a genuine error',
    () async {
      await discovery.start();
      stop = () async => throw StateError('adapter busy');
      await expectLater(discovery.stop(), throwsStateError);
      await discovery.resume();
      expect(events.single, contains('temporarily unavailable'));
      stop = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls.where((call) => call == 'start').length, 2);
    },
  );

  test(
    'Normal discovery resumes immediately; only a burst waits and stop cancels it',
    () async {
      await discovery.stop();
      final times = <DateTime>[];
      discovery = BleDiscovery(
        startScan: () async => times.add(DateTime.now()),
        stopScan: () async {},
        onEvent: events.add,
        scanWindow: const Duration(milliseconds: 100),
        maxStartsInWindow: 2,
      );
      await discovery.start();
      await discovery.stop();
      await discovery.resume();
      // The second start uses the available budget without any blanket delay.
      expect(times.length, 2);
      await discovery.stop();
      final resuming = discovery.resume();
      await Future<void>.delayed(Duration.zero);
      expect(times.length, 2);
      await discovery.stop();
      await resuming;
      expect(times.length, 2);
    },
  );

  test('A genuine burst resumes when the rolling scan budget opens', () async {
    await discovery.stop();
    var starts = 0;
    discovery = BleDiscovery(
      startScan: () async => starts++,
      stopScan: () async {},
      onEvent: events.add,
      scanWindow: const Duration(milliseconds: 80),
      maxStartsInWindow: 1,
    );
    await discovery.start();
    await discovery.stop();
    final resuming = discovery.resume();
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    await resuming;
    expect(starts, 2);
  });

  test('Concurrent duplicate starts use one native scan', () async {
    await Future.wait([
      discovery.start(),
      discovery.start(),
      discovery.resume(),
    ]);
    expect(calls, ['stop', 'start']);
  });
}
