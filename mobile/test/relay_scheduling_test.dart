import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beyondnet/ble_transport.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class NearbyPhone implements Peripheral {
  @override
  final UUID uuid;
  NearbyPhone([String id = '12345678-1234-1234-1234-123456789abc'])
    : uuid = UUID.fromString(id);
}

class AvailableRadio implements PeerTransport {
  @override
  bool running = true;
  @override
  final discovered = <String, PeerRadio>{};
  @override
  Future<void> start() async => running = true;
  @override
  Future<void> stop() async => running = false;
  @override
  Future<T> connect<T>(
    PeerRadio peer,
    Future<T> Function(Future<Json> Function(Json)) run,
  ) => throw UnimplementedError('Scheduling tests override the peer exchange');
}

class SchedulingEngine extends BeyondNetEngine {
  int contacts = 0;
  SchedulingEngine({required super.client, required super.transport});
  @override
  Future<void> syncPeer(PeerRadio peer) async {
    contacts++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory directory;
  final nodes = <SchedulingEngine>[];
  http.Response okay(http.Request r) => http.Response(
    jsonEncode(
      r.url.path == '/api/health'
          ? {'fingerprint': 'trusted', 'online': true}
          : {'receipts': [], 'cursor': 0},
    ),
    200,
  );
  Future<SchedulingEngine> node(
    Future<http.Response> Function(http.Request) handler,
  ) async {
    final radio = AvailableRadio();
    final peer = NearbyPhone();
    radio.discovered[peer.uuid.toString()] = PeerRadio(peer, -40);
    final e = SchedulingEngine(client: MockClient(handler), transport: radio);
    nodes.add(e);
    await e.store.init(databasePath: '${directory.path}/${nodes.length}.db');
    e.profile = {
      'device_id': 'relay',
      'bank_url': 'https://bank.test',
      'account': {'id': 'relay@beyondnet', 'balance': 10000, 'revision': 0},
      'trust': {'fingerprint': 'trusted'},
    };
    e.bankReachable = true;
    e.relay = true;
    return e;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('beyondnet-scheduling-');
  });
  tearDown(() async {
    for (final e in nodes) {
      e.dispose();
      await e.store.db.close();
    }
    nodes.clear();
    await directory.delete(recursive: true);
  });

  test(
    'A slow bank request cannot hold nearby discovery or its work lock',
    () async {
      final pending = Completer<http.Response>();
      var probes = 0;
      final e = await node((r) async {
        if (r.url.path == '/api/health') {
          probes++;
          return pending.future;
        }
        return okay(r);
      });
      try {
        await e.tick().timeout(const Duration(seconds: 1));
        expect(probes, 1);
        expect(e.contacts, 1);
        expect(e.working, isFalse);
      } finally {
        pending.complete(
          http.Response(
            jsonEncode({'online': true, 'fingerprint': 'trusted'}),
            200,
          ),
        );
        await e.gatewayTick();
      }
    },
  );

  test(
    'Two gateways in backoff leave the connection budget for the third phone',
    () async {
      final e = await node((r) async => okay(r));
      e.bankReachable = false;
      final phones = e.radio.discovered;
      final second = NearbyPhone('12345678-1234-1234-1234-123456789ab2');
      final third = NearbyPhone('12345678-1234-1234-1234-123456789ab3');
      phones[second.uuid.toString()] = PeerRadio(second, -52);
      phones[third.uuid.toString()] = PeerRadio(third, -53);
      for (final key in phones.keys.take(2)) {
        e.identityByRadio[key] = key;
        e.nearby.add({'device_id': key, 'online': true, 'at': nowSeconds});
        e.peerRetry[key] = DateTime.now().add(const Duration(seconds: 20));
      }
      await e.tick();
      expect(e.contacts, 1);
      expect(e.peerFailures[third.uuid.toString()], 0);
    },
  );

  test('Concurrent bank delivery calls share one complete worker', () async {
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    var inboxRequests = 0;
    final e = await node((r) async {
      if (r.url.path.startsWith('/api/receipts/')) {
        inboxRequests++;
        if (!entered.isCompleted) entered.complete();
        return pending.future;
      }
      return okay(r);
    });
    final first = e.gatewayTick();
    await entered.future;
    final second = e.gatewayTick();
    expect(identical(first, second), true);
    pending.complete(
      http.Response(jsonEncode({'receipts': [], 'cursor': 0}), 200),
    );
    await Future.wait([first, second]);
    expect(inboxRequests, 1);
  });

  test(
    'Approval during another bank request queues delivery immediately after it',
    () async {
      final pending = Completer<http.Response>();
      final entered = Completer<void>();
      var submissions = 0;
      final e = await node((r) async {
        if (r.url.path.startsWith('/api/receipts/') && !entered.isCompleted) {
          entered.complete();
          return pending.future;
        }
        if (r.url.path == '/api/packets') {
          submissions++;
          return http.Response(
            jsonEncode({'detail': 'Temporary test outage'}),
            503,
          );
        }
        return okay(r);
      });
      final box = await x.newKeyPair();
      final packet = await makePacket(
        'payment',
        await seal(base64Encode((await box.extractPublicKey()).bytes), {
          'opaque': true,
        }),
        randomCapability(),
        nowSeconds + 600,
      );
      await e.store.invite(
        packet,
        'payer',
        'Payer',
        deadline: nowSeconds + 30,
        token: randomCapability(),
      );
      final original = e.gatewayTick();
      await entered.future;
      expect(submissions, 0);
      e.working =
          true; // A Bluetooth exchange must not swallow the approval wake-up.
      await e.decideRelayInvitation(packet['id'], true);
      pending.complete(
        http.Response(jsonEncode({'receipts': [], 'cursor': 0}), 200),
      );
      await original;
      await e.gatewayTick();
      expect(submissions, 1);
      expect(await e.store.packet(packet['id']), isNotNull);
      expect(e.connectionUnstable, true);
      e.working = false;
    },
  );
}
