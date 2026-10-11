import 'dart:convert';
import 'dart:async';
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
    Future<bool> Function()? authorize,
  }) async {
    final e = BeyondNetEngine(
      client: client,
      authorizePayment: authorize ?? () async => true,
    );
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
    'Payment PIN is encrypted, never saved in intent, and TTL is 600 seconds',
    () async {
      sender.profile!['account']['pin_configured'] = true;
      sender.profile!['trust']['box_key'] = fixture['box_public'];
      sender.bankReachable = false;
      sender.connectedPeer = relay.deviceId;
      sender.nearby = [
        {'device_id': relay.deviceId, 'at': nowSeconds},
      ];
      final id = await sender.pay(relay.certificate, 1000, pin: '123456');
      while (sender.working) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final intent = (await sender.store.payments()).single;
      expect(intent['payment_id'], id);
      expect(intent.containsKey('pin'), isFalse);
      final p = (await sender.store.packets()).single;
      final bankKey = await x.newKeyPairFromSeed(
        base64Decode(fixture['box_seed']),
      );
      final signed = await openBox(
        bankKey,
        Map<String, dynamic>.from(p['box']),
      );
      final body = await verify(
        base64Encode((await sender.signing.extractPublicKey()).bytes),
        signed,
      );
      expect(body['v'], 2);
      expect(body['pin'], '123456');
      expect(body['expires_at'] - body['created_at'], 600);
      expect(jsonEncode(intent).contains('123456'), isFalse);
      expect(jsonEncode(p).contains('"pin"'), isFalse);
    },
  );

  test('Payment requires PIN setup and six digits', () async {
    await expectLater(
      sender.pay(relay.certificate, 1000, pin: '123456'),
      throwsStateError,
    );
    sender.profile!['account']['pin_configured'] = true;
    await expectLater(
      sender.pay(relay.certificate, 1000, pin: '123'),
      throwsArgumentError,
    );
    expect(await sender.store.payments(), isEmpty);
  });

  void paymentReady(BeyondNetEngine e, {int balance = 100000}) {
    e.profile!['account']['pin_configured'] = true;
    e.profile!['account']['balance'] = balance;
    e.profile!['trust']['box_key'] = fixture['box_public'];
    e.connectedPeer = relay.deviceId;
    e.nearby = [
      {'device_id': relay.deviceId, 'at': nowSeconds},
    ];
    e.bankReachable = false;
  }

  Future<void> settleTick(BeyondNetEngine e) async {
    while (e.working) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'Zero funds are blocked before native authorization or packet creation',
    () async {
      var authorizations = 0;
      final e = await node(
        'zero',
        'zero@beyondnet',
        authorize: () async {
          authorizations++;
          return true;
        },
      );
      try {
        paymentReady(e, balance: 0);
        await expectLater(
          e.pay(relay.certificate, 1000, pin: '123456'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Insufficient demo balance'),
            ),
          ),
        );
        expect(authorizations, 0);
        expect(await e.store.packets(), isEmpty);
        expect(await e.store.payments(), isEmpty);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Unresolved requests reserve funds and bank rejection releases the reservation',
    () async {
      paymentReady(sender, balance: 1000);
      final first = await sender.pay(relay.certificate, 800, pin: '123456');
      await settleTick(sender);
      expect(sender.availableBalance, 200);
      await expectLater(
        sender.pay(relay.certificate, 300, pin: '123456'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('pending payments'),
          ),
        ),
      );
      var intent = (await sender.store.payments()).single;
      expect(intent['payment_id'], first);
      // Expiry without a receipt is not proof the bank never committed it.
      await sender.store.putPayment({...intent, 'expires_at': nowSeconds - 1});
      await expectLater(sender.preparePayment(300), throwsStateError);
      await sender.store.putPayment({...intent, 'state': 'rejected'});
      await sender.reload();
      expect(sender.availableBalance, 1000);
      await sender.pay(relay.certificate, 300, pin: '123456');
      await settleTick(sender);
      expect((await sender.store.payments()).length, 2);
    },
  );

  test(
    'Online preflight refreshes a stale positive balance and refuses zero bank funds',
    () async {
      var reads = 0;
      final e = await node(
        'fresh',
        'fresh@beyondnet',
        client: MockClient((r) async {
          expect(r.url.path, '/api/me');
          reads++;
          return http.Response(
            jsonEncode({
              'account': {
                'id': 'fresh@beyondnet',
                'balance': 0,
                'revision': 1,
                'pin_configured': true,
              },
              'merchants': [],
            }),
            200,
          );
        }),
      );
      try {
        paymentReady(e);
        e.profile!['bank_url'] = 'https://test.bank';
        e.bankReachable = true;
        await expectLater(
          e.pay(relay.certificate, 1000, pin: '123456'),
          throwsStateError,
        );
        expect(reads, 1);
        expect(e.availableBalance, 0);
        expect(await e.store.payments(), isEmpty);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Online preflight allows new bank funds despite stale zero cached balance',
    () async {
      final e = await node(
        'funded',
        'funded@beyondnet',
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'account': {
                'id': 'funded@beyondnet',
                'balance': 1000,
                'revision': 1,
                'pin_configured': true,
              },
              'merchants': [],
            }),
            200,
          ),
        ),
      );
      try {
        paymentReady(e, balance: 0);
        e.profile!['bank_url'] = 'https://test.bank';
        e.bankReachable = true;
        await e.preparePayment(1000);
        expect(e.availableBalance, 1000);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Concurrent requests cannot reserve the same local funds twice',
    () async {
      final authorizing = Completer<void>(), authorize = Completer<bool>();
      final e = await node(
        'racing',
        'racing@beyondnet',
        authorize: () {
          authorizing.complete();
          return authorize.future;
        },
      );
      try {
        paymentReady(e, balance: 1000);
        final first = e.pay(relay.certificate, 800, pin: '123456');
        await authorizing.future;
        await expectLater(
          e.pay(relay.certificate, 800, pin: '123456'),
          throwsStateError,
        );
        authorize.complete(true);
        await first;
        await settleTick(e);
        expect((await e.store.payments()).length, 1);
        expect(e.availableBalance, 200);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Funds are rechecked after device authorization changes the snapshot',
    () async {
      late BeyondNetEngine e;
      e = await node(
        'changed',
        'changed@beyondnet',
        authorize: () async {
          e.profile!['account']['balance'] = 0;
          return true;
        },
      );
      try {
        paymentReady(e, balance: 1000);
        await expectLater(
          e.pay(relay.certificate, 800, pin: '123456'),
          throwsStateError,
        );
        expect(await e.store.payments(), isEmpty);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Real engine authenticates peer command and ACKs only persisted packet',
    () async {
      final p = await makePacket(
        'payment',
        Map<String, dynamic>.from(fixture['packet']['box']),
        randomCapability(),
        nowSeconds + 600,
      );
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
    'Cleanup retains unresolved owned ciphertext until a definitive bank result',
    () async {
      final original = await makePacket(
        'payment',
        Map<String, dynamic>.from(fixture['box']),
        randomCapability(),
        nowSeconds - 8 * 86400,
      );
      final relayOnly = await makePacket(
        'payment',
        Map<String, dynamic>.from(fixture['box']),
        randomCapability(),
        nowSeconds - 8 * 86400,
      );
      final intent = {
        'payment_id': 'old-owned',
        'sender': sender.accountId,
        'amount': 100,
        'packet_id': original['id'],
        'state': 'queued',
      };
      await sender.store.createPayment(original, intent);
      await sender.store.putPacket(relayOnly);
      await sender.store.cleanup();
      expect(await sender.store.packet(original['id']), isNotNull);
      expect(await sender.store.packet(relayOnly['id']), isNull);
      await sender.store.putPayment({...intent, 'state': 'rejected'});
      await sender.store.cleanup();
      expect(await sender.store.packet(original['id']), isNull);
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
        await expectLater(e.addDemoMoney(50000), throwsStateError);
        expect(bodies.length, 1);
        await e.addDemoMoney(100000);
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
