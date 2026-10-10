import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:beyondnet/ble_transport.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';
import 'package:beyondnet/relay_routing.dart';
import 'package:beyondnet/store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final fixture = Map<String, dynamic>.from(
    jsonDecode(File('test/fixtures/python-wire.json').readAsStringSync()),
  );
  late Directory directory;
  final nodes = <BeyondNetEngine>[];
  var requestNumber = 0;

  Future<BeyondNetEngine> node(String id, {bool online = false}) async {
    final e = BeyondNetEngine(authorizePayment: () async => true);
    await e.store.init(databasePath: '${directory.path}/$id.sqlite3');
    e.signing = await ed.newKeyPair();
    e.encryption = await x.newKeyPair();
    final bank = await ed.newKeyPairFromSeed(
      base64Decode(fixture['sign_seed']),
    );
    final certificate = await sign(bank, {
      'device_id': id,
      'account_id': '$id@beyondnet',
      'display_name': id,
      'sign_key': base64Encode((await e.signing.extractPublicKey()).bytes),
      'box_key': base64Encode((await e.encryption.extractPublicKey()).bytes),
      'mesh_id': 'test-mesh',
      'expires_at': nowSeconds + 86400,
    });
    e.profile = {
      'device_id': id,
      'account': {'id': '$id@beyondnet', 'balance': 100000, 'revision': 0},
      'certificate': certificate,
      'trust': {
        'sign_key': fixture['sign_public'],
        'box_key': fixture['box_public'],
        'mesh_id': 'test-mesh',
      },
    };
    e.relay = true;
    e.bankReachable = online;
    nodes.add(e);
    return e;
  }

  Json decodeFrames(Json value, {bool interrupted = false}) {
    final assembly = Assembly();
    final wire = frames(canonical(value));
    if (interrupted) {
      for (final frame in wire.take(wire.length ~/ 2)) {
        assembly.add(frame);
      }
      throw TimeoutException('Radio disconnected mid-message');
    }
    List<int>? complete;
    for (final frame in wire) {
      complete = assembly.add(frame);
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(complete!)));
  }

  // Only the requested edge exists. All messages use production signing,
  // authentication, framing, syncPackets, SQLite storage and routing decisions.
  Future<void> contact(
    BeyondNetEngine a,
    BeyondNetEngine b, {
    bool losePutAck = false,
    bool interrupt = false,
    bool legacy = false,
  }) async {
    Json? identity;
    await a.syncPackets((command) async {
      final requestId = 'edge-${requestNumber++}';
      final request = decodeFrames(
        await a.signedRpc(command, requestId),
        interrupted: interrupt && command['op'] == 'put',
      );
      var response = await b.handleRpc(request);
      if (losePutAck && command['op'] == 'put') {
        throw TimeoutException('Stored by peer; response lost');
      }
      if (legacy && command['op'] == 'inventory') {
        final body = Map<String, dynamic>.from(response['body']);
        final old = Map<String, dynamic>.from(body['command'])
          ..remove('routing')
          ..remove('routes');
        response = await b.signedRpc(old, requestId);
      }
      final checked = await a.validateRpc(
        decodeFrames(response),
        expectedRequest: requestId,
      );
      identity = Map<String, dynamic>.from(checked['peer']);
      return Map<String, dynamic>.from(checked['command']);
    }, () => identity!);
  }

  Future<Json> payment(BeyondNetEngine a) async {
    final p = await makePacket(
      'payment',
      Map<String, dynamic>.from(fixture['box']),
      'a' * 48,
      nowSeconds + 600,
    );
    await a.store.putPacket(p);
    return p;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('beyondnet-mesh-');
    nodes.clear();
    requestNumber = 0;
  });
  tearDown(() async {
    for (final e in nodes) {
      e.dispose();
      await e.store.db.close();
    }
    await directory.delete(recursive: true);
  });

  test(
    'A cannot reach C: offline A -> offline B -> gateway C -> offline A receipt',
    () async {
      final a = await node('A'),
          b = await node('B'),
          c = await node('C', online: true);
      final p = await payment(a);
      await contact(a, b);
      expect(await c.store.packet(p['id']), isNull);
      await contact(b, c);
      final arrived = (await c.store.packet(p['id']))!;
      expect(arrived['hops'], 2);
      expect(arrived['trail'], ['A', 'B']);
      expect(arrived['box'], p['box']);
      expect(a.bankReachable, isFalse);
      expect(b.bankReachable, isFalse);
      final bank = await ed.newKeyPairFromSeed(
        base64Decode(fixture['sign_seed']),
      );
      final receipt = await makePacket(
        'receipt',
        await seal(
          a.certificate['body']['box_key'],
          await sign(bank, {
            'v': 1,
            'device_id': 'A',
            'payment_id': 'payment-one',
            'status': 'paid',
            'sender': a.accountId,
            'recipient': 'shop@beyondnet',
            'amount': 100,
            'committed_at': nowSeconds,
            'balance': 99900,
            'balance_revision': 1,
          }),
        ),
        'a' * 48,
        nowSeconds + 86400,
        path: ['A', 'B'],
      );
      await c.accept(receipt);
      await contact(b, c);
      await contact(a, b);
      expect((await a.store.receipts()).single['status'], 'paid');
      expect(a.account!['balance'], 99900);
      expect(await b.store.receipts(), isEmpty); // relay cannot decrypt receipt
    },
  );

  test(
    'Triangle contacts never send a payment back along its visited route',
    () async {
      final a = await node('A'), b = await node('B'), c = await node('C');
      final p = await payment(a);
      await contact(a, b);
      await contact(b, c);
      for (var round = 0; round < 8; round++) {
        await contact(c, a);
        await contact(c, b);
        await contact(a, b);
      }
      expect((await a.store.packet(p['id']))!['hops'], 0);
      for (final n in [a, b, c]) {
        expect((await n.store.packets()).length, 1);
        final saved = (await n.store.packet(p['id']))!;
        expect(
          (saved['trail'] as List? ?? []).toSet().length,
          (saved['trail'] as List? ?? []).length,
        );
      }
      expect(
        RelayRouting.canForward((await c.store.packet(p['id']))!, 'C', 'A'),
        isFalse,
      );
    },
  );

  test(
    'Lost storage ACK retains original and signed inventory repairs custody state',
    () async {
      final a = await node('A'), b = await node('B');
      final p = await payment(a);
      await expectLater(
        contact(a, b, losePutAck: true),
        throwsA(isA<TimeoutException>()),
      );
      expect(await a.store.recentCustodians(p['id']), isEmpty);
      expect(await a.store.packet(p['id']), isNotNull);
      expect(await b.store.packet(p['id']), isNotNull);
      await contact(a, b);
      expect(await a.store.recentCustodians(p['id']), {'B'});
      expect((await b.store.packets()).length, 1);
    },
  );

  test(
    'Interrupted frames produce no storage ACK; a fresh transfer succeeds',
    () async {
      final a = await node('A'), b = await node('B');
      final p = await payment(a);
      await expectLater(
        contact(a, b, interrupt: true),
        throwsA(isA<TimeoutException>()),
      );
      expect(await b.store.packet(p['id']), isNull);
      expect(await a.store.recentCustodians(p['id']), isEmpty);
      await contact(a, b);
      expect(await b.store.packet(p['id']), isNotNull);
    },
  );

  test('Durable queue and custody survive a relay database reopen', () async {
    final a = await node('A'), b = await node('B'), c = await node('C');
    final p = await payment(a);
    await contact(a, b);
    await b.store.db.close();
    await b.store.init(databasePath: '${directory.path}/B.sqlite3');
    await contact(b, c);
    expect((await c.store.packet(p['id']))!['hops'], 2);
    await a.store.db.close();
    await a.store.init(databasePath: '${directory.path}/A.sqlite3');
    expect(await a.store.recentCustodians(p['id']), {'B'});
  });

  test(
    'Shorter authenticated route replaces a hop-exhausted copy without clearing uploaded',
    () async {
      final a = await node('A'), b = await node('B'), c = await node('C');
      final p = await payment(a);
      await b.store.putPacket({
        ...p,
        'hops': 4,
        'path': ['X', 'Y', 'Z', 'W'],
        'trail': ['X', 'Y', 'Z', 'W'],
      });
      await b.store.uploaded(p['id']);
      await contact(a, b);
      final saved = (await b.store.packets()).single;
      expect(saved['hops'], 1);
      expect(saved['uploaded'], 1);
      await contact(b, c);
      expect((await c.store.packet(p['id']))!['hops'], 2);
      expect((await b.store.packets()).length, 1);
    },
  );

  test(
    'Receipt uses alternative route when original intermediate is unavailable',
    () async {
      final a = await node('A'), c = await node('C'), d = await node('D');
      final bank = await ed.newKeyPairFromSeed(
        base64Decode(fixture['sign_seed']),
      );
      final receipt = await makePacket(
        'receipt',
        await seal(
          a.certificate['body']['box_key'],
          await sign(bank, {
            'v': 1,
            'device_id': 'A',
            'payment_id': 'alternate',
            'status': 'paid',
            'sender': a.accountId,
            'recipient': 'shop@beyondnet',
            'amount': 50,
            'committed_at': nowSeconds,
            'balance': 99950,
            'balance_revision': 2,
          }),
        ),
        'a' * 48,
        nowSeconds + 86400,
        path: ['A', 'unavailable-B'],
      );
      await c.accept(receipt);
      await contact(c, d);
      await contact(d, a);
      expect((await a.store.receipts()).single['payment_id'], 'alternate');
      expect((await a.store.packet(receipt['id']))!['trail'], ['C', 'D']);
    },
  );

  test(
    'Fanout is bounded for push and pull but permits gateway and recovery after lease ages',
    () async {
      final a = await node('A');
      final p = await payment(a);
      final peers = <BeyondNetEngine>[];
      for (var i = 0; i < 5; i++) {
        peers.add(await node('P$i', online: i == 4));
      }
      for (final b in peers.take(3)) {
        await contact(a, b);
      }
      await contact(a, peers[3]);
      await contact(peers[3], a);
      expect(await peers[3].store.packet(p['id']), isNull);
      await contact(a, peers[4]);
      expect(await peers[4].store.packet(p['id']), isNotNull);
      await a.store.db.update('relay_acks', {'at': nowSeconds - 91});
      await contact(a, peers[3]);
      expect(await peers[3].store.packet(p['id']), isNotNull);
    },
  );

  test(
    'Expired payment is never relayed; tampering is never acknowledged',
    () async {
      final a = await node('A'), b = await node('B');
      final p = await makePacket(
        'payment',
        Map<String, dynamic>.from(fixture['box']),
        'a' * 48,
        nowSeconds - 1,
      );
      await a.store.putPacket(p);
      await contact(a, b);
      expect(await b.store.packet(p['id']), isNull);
      final live = await payment(a);
      final changed = {...live, 'mailbox': 'b' * 48};
      await expectLater(
        b.handleRpc(
          await a.signedRpc({'op': 'put', 'packet': changed}, 'tamper'),
        ),
        throwsFormatException,
      );
      expect(await b.store.packet(live['id']), isNull);
    },
  );

  test(
    'Old v1 peer inventories still exchange the unchanged encrypted protocol',
    () async {
      final a = await node('A'), b = await node('B');
      final p = await payment(a);
      await contact(a, b, legacy: true);
      expect((await b.store.packet(p['id']))!['box'], p['box']);
      final old = Map<String, dynamic>.from(p)..remove('trail');
      await checkPacket(old);
    },
  );

  test(
    'Version 1 database upgrades in place preserving config and history',
    () async {
      final path = '${directory.path}/old-phone.sqlite3';
      final old = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE packets(id TEXT PRIMARY KEY, data TEXT NOT NULL, expiry INTEGER NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0)',
          );
          for (final table in ['payments', 'receipts', 'peers']) {
            await db.execute(
              'CREATE TABLE $table(id TEXT PRIMARY KEY,data TEXT NOT NULL)',
            );
          }
          await db.execute(
            'CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT,at INTEGER NOT NULL,text TEXT NOT NULL)',
          );
        },
      );
      final p = Map<String, dynamic>.from(fixture['packet']);
      await old.insert('packets', {
        'id': p['id'],
        'data': jsonEncode(p),
        'expiry': p['expires_at'],
        'uploaded': 1,
      });
      await old.insert('payments', {
        'id': 'pending',
        'data': jsonEncode({'payment_id': 'pending', 'state': 'queued'}),
      });
      await old.insert('config', {'key': 'allowlist', 'value': '["B"]'});
      await old.close();
      final upgraded = LocalStore();
      await upgraded.init(databasePath: path);
      try {
        expect((await upgraded.packets()).single['uploaded'], 1);
        expect((await upgraded.payments()).single['payment_id'], 'pending');
        expect(await upgraded.config('allowlist'), ['B']);
        await upgraded.acknowledge(p['id'], 'B', 1, p['expires_at']);
        expect(await upgraded.recentCustodians(p['id']), {'B'});
      } finally {
        await upgraded.db.close();
      }
    },
  );

  test('Receipt backlog cannot consume the entire payment transfer budget', () {
    final ordered = [
      for (var i = 0; i < 20; i++) {'id': 'r$i', 'kind': 'receipt'},
      for (var i = 0; i < 20; i++) {'id': 'p$i', 'kind': 'payment'},
    ];
    final first = RelayRouting.fairOrder(ordered).take(8).toList();
    expect(first.where((p) => p['kind'] == 'payment').length, 4);
    expect(first.where((p) => p['kind'] == 'receipt').length, 4);
  });

  test(
    'Storage exhaustion fails before acknowledging or deleting sender copy',
    () async {
      final a = await node('A'), b = await node('B');
      final p = await payment(a);
      await b.store.db.transaction((tx) async {
        for (var i = 0; i < 1000; i++) {
          await tx.insert('packets', {
            'id': 'full-$i',
            'data': '{}',
            'expiry': nowSeconds + 600,
            'uploaded': 0,
          });
        }
      });
      await expectLater(
        b.handleRpc(
          await a.signedRpc({'op': 'put', 'packet': a.forwarded(p)}, 'full'),
        ),
        throwsStateError,
      );
      expect(await b.store.packet(p['id']), isNull);
      expect(await a.store.packet(p['id']), isNotNull);
    },
  );
}
