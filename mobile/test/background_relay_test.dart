import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:beyondnet/background_relay.dart';
import 'package:beyondnet/ble_transport.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestRadio implements PeerTransport {
  @override
  final discovered = <String, PeerRadio>{};
  @override
  bool running = false;
  int starts = 0;
  Future<void>? startWait;
  Object? startError;
  @override
  Future<void> start() async {
    await startWait;
    if (startError != null) throw startError!;
    running = true;
    starts++;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<T> connect<T>(
    PeerRadio p,
    Future<T> Function(Future<Json> Function(Json)) run,
  ) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final fixture = Map<String, dynamic>.from(
    jsonDecode(File('test/fixtures/python-wire.json').readAsStringSync()),
  );
  late Directory directory;
  late BeyondNetEngine engine;
  late TestRadio radio;
  var enabled = false, running = false;
  String? blocked;
  final calls = <String>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('beyondnet-service-');
    enabled = false;
    running = false;
    blocked = null;
    calls.clear();
    radio = TestRadio();
    messenger.setMockMethodCallHandler(BackgroundRelay.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'ready' || call.method == 'status') {
        return {'enabled': enabled, 'running': running, 'blocked': blocked};
      }
      if (call.method == 'start') {
        enabled = true;
        running = true;
        return true;
      }
      if (call.method == 'stop') {
        enabled = false;
        running = false;
        return true;
      }
      return true;
    });
    messenger.setMockMethodCallHandler(
      BeyondNetEngine.platform,
      (call) async => false,
    );
    FlutterSecureStorage.setMockInitialValues({
      'device_keys': jsonEncode({
        'sign': fixture['sign_seed'],
        'box': fixture['box_seed'],
      }),
      'profile': jsonEncode({
        'device_id': 'background-device',
        'bank_url': 'https://bank.invalid',
        'account': {'id': 'background@beyondnet', 'balance': 0, 'revision': 0},
        'certificate': {
          'body': {'expires_at': nowSeconds + 3600},
        },
        'trust': {'sign_key': fixture['sign_public'], 'mesh_id': 'test'},
      }),
    });
    engine = BeyondNetEngine(
      transport: radio,
      backgroundRelay: BackgroundRelay(),
    );
  });
  tearDown(() async {
    engine.dispose();
    await engine.store.db.close();
    await directory.delete(recursive: true);
    messenger.setMockMethodCallHandler(BackgroundRelay.channel, null);
    messenger.setMockMethodCallHandler(BeyondNetEngine.platform, null);
  });

  test(
    'start waits for Android service before opening the Bluetooth radio',
    () async {
      await engine.init(databasePath: '${directory.path}/phone.db');
      var polls = 0;
      messenger.setMockMethodCallHandler(BackgroundRelay.channel, (call) async {
        if (call.method == 'start') {
          enabled = true;
          return true;
        }
        if (call.method == 'status') {
          expect(radio.starts, 0);
          polls++;
          running = polls >= 3;
        }
        if (call.method == 'status' || call.method == 'ready') {
          return {'enabled': enabled, 'running': running, 'blocked': null};
        }
        return true;
      });
      await engine.startRelay();
      expect(polls, 3);
      expect(radio.starts, 1);
      expect(engine.relay, isTrue);
    },
  );
  test('Fresh install never starts relay until explicit user opt-in', () async {
    await engine.init(databasePath: '${directory.path}/phone.db');
    expect(radio.running, isFalse);
    expect(calls, isNot(contains('start')));
    await engine.startRelay();
    expect(radio.running, isTrue);
    expect(engine.relayEnabled, isTrue);
    await engine.stopRelay();
    expect(radio.running, isFalse);
    expect(enabled, isFalse);
  });
  test(
    'Service-created headless engine restores saved opt-in without UI or permission dialog',
    () async {
      enabled = true;
      running = true;
      await engine.init(databasePath: '${directory.path}/phone.db');
      expect(engine.relay, isTrue);
      expect(radio.starts, 1);
      await engine.restoreBackgroundRelay();
      expect(radio.starts, 1);
      expect(calls, isNot(contains('start')));
    },
  );
  test(
    'Bluetooth off pauses and on resumes; notification stop stays stopped',
    () async {
      enabled = true;
      running = true;
      blocked = 'Turn Bluetooth on';
      await engine.init(databasePath: '${directory.path}/phone.db');
      expect(engine.relay, isFalse);
      expect(engine.relayEnabled, isTrue);
      blocked = null;
      await engine.restoreBackgroundRelay();
      expect(engine.relay, isTrue);
      enabled = false;
      running = false;
      await engine.restoreBackgroundRelay();
      expect(engine.relay, isFalse);
      expect(engine.relayEnabled, isFalse);
      await engine.restoreBackgroundRelay();
      expect(radio.starts, 1);
    },
  );
  test(
    'Permission revocation pauses safely and leaves packet queue intact',
    () async {
      enabled = true;
      running = true;
      await engine.init(databasePath: '${directory.path}/phone.db');
      final p = Map<String, dynamic>.from(fixture['packet']);
      await engine.store.putPacket(p);
      blocked = 'Bluetooth permissions need attention';
      await engine.restoreBackgroundRelay();
      expect(engine.relay, isFalse);
      expect(await engine.store.packet(p['id']), isNotNull);
      expect(engine.relayBlocked, contains('permissions'));
    },
  );
  test(
    'Failed radio startup releases transition and allows another toggle',
    () async {
      await engine.init(databasePath: '${directory.path}/phone.db');
      radio.startError = StateError('Bluetooth did not finish starting');
      await expectLater(engine.startRelay(), throwsStateError);
      expect(engine.relayChanging, isFalse);
      expect(engine.relayEnabled, isFalse);
      expect(enabled, isFalse);
      expect(engine.relayBlocked, contains('did not finish'));
      radio.startError = null;
      await engine.startRelay();
      await Future<void>.delayed(Duration.zero); // Immediate monitoring tick.
      expect(engine.relay, isTrue);
      expect(engine.relayChanging, isFalse);
      expect(engine.relayBlocked, isNull);
    },
  );
  test(
    'Stop waits for lifecycle startup and cannot be undone by its late completion',
    () async {
      await engine.init(databasePath: '${directory.path}/phone.db');
      enabled = true;
      running = true;
      final pending = Completer<void>();
      radio.startWait = pending.future;
      final restore = engine.restoreBackgroundRelay();
      await Future<void>.delayed(Duration.zero);
      expect(engine.relayChanging, isTrue);
      final stop = engine.stopRelay();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNot(contains('stop')));
      pending.complete();
      await Future.wait([restore, stop]);
      expect(engine.relayChanging, isFalse);
      expect(engine.relay, isFalse);
      expect(radio.running, isFalse);
      expect(enabled, isFalse);
      await engine.restoreBackgroundRelay();
      expect(engine.relayEnabled, isFalse);
    },
  );
  test(
    'Failed background restore stays paused until Bluetooth changes or explicit retry',
    () async {
      await engine.init(databasePath: '${directory.path}/phone.db');
      enabled = true;
      running = true;
      radio.startError = StateError('Bluetooth callback timed out');
      await engine.restoreBackgroundRelay();
      expect(engine.relayEnabled, isTrue);
      expect(engine.relay, isFalse);
      expect(engine.relayChanging, isFalse);
      radio.startError = null;
      await engine.restoreBackgroundRelay();
      expect(radio.starts, 0);
      expect(engine.relayBlocked, contains('timed out'));
      blocked = 'Turn Bluetooth on';
      await engine.restoreBackgroundRelay();
      blocked = null;
      await engine.restoreBackgroundRelay();
      expect(radio.starts, 1);
      expect(engine.relay, isTrue);
    },
  );
}
