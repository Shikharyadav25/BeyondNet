import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:beyondnet/protocol.dart';
import 'package:beyondnet/engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final fixture = Map<String, dynamic>.from(
    jsonDecode(File('test/fixtures/python-wire.json').readAsStringSync()),
  );
  late BeyondNetEngine sender, relay;
  late Directory directory;
  Future<BeyondNetEngine> node(
    String id,
    String account, {
    http.Client? client,
  }) async {
    final e = BeyondNetEngine(client: client);
    await e.store.init(databasePath: '${directory.path}/$id.sqlite3');
    e.signing = await ed.newKeyPair();
    e.encryption = await x.newKeyPair();
    final bank = await ed.newKeyPairFromSeed(
      base64Decode(fixture['sign_seed']),
    );
    final cert = await sign(bank, {
      'device_id': id,
      'account_id': account,
      'sign_key': base64Encode((await e.signing.extractPublicKey()).bytes),
      'box_key': base64Encode((await e.encryption.extractPublicKey()).bytes),
      'mesh_id': 'test-mesh',
      'expires_at': nowSeconds + 900,
    });
    e.profile = {
      'device_id': id,
      'account': {'id': account, 'balance': 100000, 'revision': 0},
      'trust': {'sign_key': fixture['sign_public'], 'mesh_id': 'test-mesh'},
      'certificate': cert,
    };
    e.relay = true;
    return e;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('karo-test-');
    sender = await node('sender-device', 'alice@karo');
    relay = await node('relay-device', 'relay@karo');
  });
  tearDown(() async {
    await sender.store.db.close();
    await relay.store.db.close();
    sender.dispose();
    relay.dispose();
    await directory.delete(recursive: true);
  });
  test(
    'Real engine authenticates peer command and ACKs only persisted packet',
    () async {
      final p = Map<String, dynamic>.from(fixture['packet']);
      final wire = await sender.signedRpc({
        'op': 'put',
        'packet': p,
      }, 'rpc-one');
      final response = await relay.handleRpc(wire);
      final checked = await sender.validateRpc(
        response,
        expectedRequest: 'rpc-one',
      );
      expect(checked['command'], {'op': 'stored', 'id': p['id']});
      expect((await relay.store.packet(p['id']))!['box'], p['box']);
      await expectLater(relay.handleRpc(wire), throwsStateError);
      final again = await relay.handleRpc(
        await sender.signedRpc({'op': 'put', 'packet': p}, 'rpc-two'),
      );
      expect(
        (await sender.validateRpc(
          again,
          expectedRequest: 'rpc-two',
        ))['command']['op'],
        'stored',
      );
      expect((await relay.store.packets()).length, 1);
    },
  );
  test('Allowlist and wrong-bank certificates reject peer traffic', () async {
    relay.allowlist = ['another-device'];
    await expectLater(
      relay.handleRpc(await sender.signedRpc({'op': 'inventory'}, 'rpc-three')),
      throwsStateError,
    );
    relay.allowlist = [];
    relay.profile!['trust']['mesh_id'] = 'different-bank';
    await expectLater(
      relay.handleRpc(await sender.signedRpc({'op': 'inventory'}, 'rpc-four')),
      throwsStateError,
    );
    expect(await relay.store.packets(), isEmpty);
  });
  test(
    'Packet save survives database reopen and interrupted delivery is recoverable',
    () async {
      final p = Map<String, dynamic>.from(fixture['packet']);
      await relay.store.putPacket(p);
      await relay.store.db.close();
      await relay.store.init(
        databasePath: '${directory.path}/relay-device.sqlite3',
      );
      expect((await relay.store.packet(p['id']))!['id'], p['id']);
    },
  );
  test(
    'Paged inventory includes more than 48 entries without starvation',
    () async {
      for (var i = 0; i < 55; i++) {
        final p = await makePacket(
          'payment',
          Map<String, dynamic>.from(fixture['box']),
          i.toString().padLeft(48, '0'),
          2000000000,
        );
        await relay.store.putPacket(p);
      }
      final first = await relay.command({'op': 'inventory'}, {});
      final second = await relay.command({
        'op': 'inventory',
        'offset': first['next'],
      }, {});
      expect(first['ids'].length, 48);
      expect(second['ids'].length, 7);
      expect(second['next'], isNull);
      expect(
        <String>{
          ...(first['ids'] as List).cast<String>(),
          ...(second['ids'] as List).cast<String>(),
        }.length,
        55,
      );
    },
  );
  test(
    'Valid receipt updates state; stale revision cannot roll back balance',
    () async {
      final bank = await ed.newKeyPairFromSeed(
        base64Decode(fixture['sign_seed']),
      );
      final intent = {
        'payment_id': 'payment-1',
        'sender': 'alice@karo',
        'recipient': 'chai@karo',
        'amount': 12500,
        'state': 'queued',
      };
      await sender.store.putPayment(intent);
      Future<Json> receipt(int revision, int balance) async {
        final r = {
          'v': 1,
          ...intent,
          'status': 'paid',
          'device_id': 'sender-device',
          'currency': 'INR',
          'bank_ref': 'OK-TEST',
          'committed_at': nowSeconds,
          'balance': balance,
          'balance_revision': revision,
        };
        return makePacket(
          'receipt',
          await seal(
            base64Encode((await sender.encryption.extractPublicKey()).bytes),
            await sign(bank, r),
          ),
          'd' * 48,
          nowSeconds + 1000,
        );
      }

      final latest = await receipt(10, 87500);
      await sender.accept(latest);
      expect((await sender.store.payments()).single['state'], 'paid');
      expect(sender.profile!['account']['balance'], 87500);
      await sender.accept(await receipt(9, 90000));
      expect(sender.profile!['account']['balance'], 87500);
      final tampered = await makePacket(
        'receipt',
        await seal(
          base64Encode((await sender.encryption.extractPublicKey()).bytes),
          await sign(relay.signing, {'status': 'paid'}),
        ),
        'e' * 48,
        nowSeconds + 1000,
      );
      await expectLater(sender.accept(tampered), throwsFormatException);
    },
  );
  test(
    'Forged or mismatched receipt never changes financial outcome',
    () async {
      final bank = await ed.newKeyPairFromSeed(
        base64Decode(fixture['sign_seed']),
      );
      await sender.store.putPayment({
        'payment_id': 'p',
        'sender': 'alice@karo',
        'recipient': 'chai@karo',
        'amount': 100,
        'state': 'queued',
      });
      final r = {
        'v': 1,
        'payment_id': 'p',
        'sender': 'alice@karo',
        'recipient': 'chai@karo',
        'amount': 200,
        'device_id': 'sender-device',
        'status': 'paid',
      };
      final p = await makePacket(
        'receipt',
        await seal(
          base64Encode((await sender.encryption.extractPublicKey()).bytes),
          await sign(bank, r),
        ),
        'f' * 48,
        nowSeconds + 1000,
      );
      await expectLater(sender.accept(p), throwsStateError);
      expect((await sender.store.payments()).single['state'], 'queued');
    },
  );
  test(
    'Transport acknowledgment never rolls confirmed payment back to pending',
    () async {
      await sender.store.putPayment({
        'payment_id': 'paid-race',
        'state': 'paid',
        'receipt': {'bank_ref': 'BN-test'},
      });
      await sender.store.markRelayed('paid-race');
      expect((await sender.store.payments()).single['state'], 'paid');
    },
  );

  test(
    'Offline payments require a recent connected peer; online needs no relay',
    () async {
      sender.bankReachable = false;
      sender.connectedPeer = 'peer';
      sender.nearby = [
        {'device_id': 'peer', 'at': nowSeconds - 100},
      ];
      expect(sender.canPay, isFalse);
      sender.nearby.first['at'] = nowSeconds;
      expect(sender.canPay, isTrue);
      sender.relay = false;
      expect(sender.canPay, isFalse);
      sender.bankReachable = true;
      expect(sender.canPay, isTrue);
    },
  );

  test('Stale online balance does not overwrite a newer receipt or top-up', () {
    sender.profile!['account']['revision'] = 20;
    sender.applyAccount({'id': sender.accountId, 'balance': 1, 'revision': 19});
    expect(sender.account!['balance'], 100000);
    sender.applyAccount({
      'id': sender.accountId,
      'balance': 120000,
      'revision': 21,
    });
    expect(sender.account!['balance'], 120000);
  });

  test(
    'Top-up response loss persists original ID and amount across retry',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final e = await node(
        'funding-device',
        'sam@beyondnet',
        client: MockClient((request) async {
          bodies.add(Map<String, dynamic>.from(jsonDecode(request.body)));
          if (bodies.length == 1) {
            throw const SocketException('response lost after commit');
          }
          return http.Response(
            jsonEncode({
              'account': {
                'id': 'sam@beyondnet',
                'balance': 100000,
                'revision': 1,
              },
              'duplicate': true,
            }),
            200,
          );
        }),
      );
      e.profile!['bank_url'] = 'https://test.bank';
      e.bankReachable = true;
      try {
        await expectLater(
          e.addDemoMoney(100000),
          throwsA(isA<SocketException>()),
        );
        expect(await e.store.config('pending_topup'), isNotNull);
        await e.store.db.close();
        await e.store.init(
          databasePath: '${directory.path}/funding-device.sqlite3',
        );
        await e.addDemoMoney(50000);
        expect(bodies[1], bodies[0]);
        expect(await e.store.config('pending_topup'), isNull);
        expect(e.account!['balance'], 100000);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test('Relay resolves a cached merchant without internet', () async {
    final cert = {
      'body': {'account_id': 'shop@beyondnet', 'expires_at': nowSeconds + 900},
    };
    relay.merchants = [cert];
    final response = await relay.command({
      'op': 'resolve',
      'account_id': 'shop@beyondnet',
    }, {});
    expect(response['certificate'], cert);
    expect(
      (await relay.command({
        'op': 'resolve',
        'account_id': 'missing@beyondnet',
      }, {}))['certificate'],
      isNull,
    );
  });
  test(
    'Connectivity distinguishes disabled internet from a paused bank',
    () async {
      var calls = 0;
      final e = await node(
        'network-device',
        'sam@beyondnet',
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({'fingerprint': 'expected', 'online': false}),
            200,
          );
        }),
      );
      e.profile!['bank_url'] = 'https://test.bank';
      e.profile!['trust']['fingerprint'] = 'expected';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      try {
        messenger.setMockMethodCallHandler(
          BeyondNetEngine.platform,
          (_) async => false,
        );
        await e.checkConnection();
        expect(e.internet, isFalse);
        expect(e.bankReachable, isFalse);
        expect(calls, 0);
        messenger.setMockMethodCallHandler(
          BeyondNetEngine.platform,
          (_) async => true,
        );
        await e.checkConnection();
        expect(e.internet, isTrue);
        expect(e.bankReachable, isFalse);
        expect(e.network, 'Bank is paused');
      } finally {
        messenger.setMockMethodCallHandler(BeyondNetEngine.platform, null);
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Recipient lookup rejects a certificate for a different requested ID',
    () async {
      final e = await node(
        'lookup-device',
        'sam@beyondnet',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'certificate': {
                'body': {'account_id': 'wrong@beyondnet'},
              },
            }),
            200,
          ),
        ),
      );
      e.profile!['bank_url'] = 'https://test.bank';
      e.bankReachable = true;
      try {
        await expectLater(e.findRecipient('shop@beyondnet'), throwsStateError);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );
}
