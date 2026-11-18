import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';
import 'package:beyondnet/bank_connection_policy.dart';

class SilentSubmitSocket extends Stream<dynamic> implements WebSocket {
  final incoming = StreamController<dynamic>();
  final submitted = <Json>[];
  @override
  Duration? pingInterval;
  @override
  void add(dynamic data) {
    final message = Map<String, dynamic>.from(jsonDecode(data as String));
    if (message['type'] == 'submit') {
      submitted.add(Map<String, dynamic>.from(message['packet']));
    } else {
      incoming.add(jsonEncode({'type': 'ready', 'fingerprint': 'trusted'}));
    }
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Future<void> close([int? code, String? reason]) async {
    await incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  final nodes = <BeyondNetEngine>[];
  Future<BeyondNetEngine> node(
    Future<http.Response> Function(http.Request) handler, {
    Future<WebSocket> Function(String)? connector,
  }) async {
    final e = BeyondNetEngine(
      client: MockClient(handler),
      socketConnector:
          connector ??
          (_) => Future.error(
            const SocketException('Live connection unavailable'),
          ),
    );
    nodes.add(e);
    await e.store.init(databasePath: '${dir.path}/${nodes.length}.db');
    e.profile = {
      'device_id': 'phone',
      'bank_url': 'https://bank.test',
      'account': {'id': 'payer@beyondnet', 'balance': 10000, 'revision': 0},
      'trust': {'fingerprint': 'trusted'},
    };
    e.working = true;
    return e;
  }

  http.Response okay(http.Request r) => http.Response(
    jsonEncode(
      r.url.path == '/api/health'
          ? {'online': true, 'fingerprint': 'trusted'}
          : r.url.path == '/api/me'
          ? {
              'account': {
                'id': 'payer@beyondnet',
                'balance': 10000,
                'revision': 0,
              },
              'merchants': [],
            }
          : {'receipts': [], 'cursor': 0},
    ),
    200,
  );
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('weak-bank-');
  });
  tearDown(() async {
    for (final e in nodes) {
      e.dispose();
      await e.store.db.close();
    }
    nodes.clear();
    await dir.delete(recursive: true);
  });
  test(
    'silent live submit falls back promptly using the identical payment packet',
    () async {
      final socket = SilentSubmitSocket();
      final posted = <Json>[];
      final received = Completer<void>();
      final e = await node((r) async {
        if (r.url.path == '/api/packets') {
          posted.add(Map<String, dynamic>.from(jsonDecode(r.body)));
          received.complete();
          return http.Response(jsonEncode({'via': 'https'}), 200);
        }
        return okay(r);
      }, connector: (_) async => socket);
      await e.openLive();
      await Future<void>.delayed(Duration.zero);
      expect(e.liveConnected, true);
      final packet = <String, dynamic>{
        'id': 'same-packet',
        'box': {'opaque': 'original'},
      };
      final result = e.submitPacket(packet);
      await received.future.timeout(
        BankConnectionPolicy.liveSubmitFallback + const Duration(seconds: 3),
      );
      expect((await result)['via'], 'https');
      expect(socket.submitted.single, packet);
      expect(posted.single, packet);
      expect(
        BankConnectionPolicy.timeout('/api/packets'),
        const Duration(seconds: 45),
      );
      expect(await e.store.payments(), isEmpty);
    },
  );
  test(
    'temporary health loss preserves cached balance and shows retry rather than payment failure',
    () async {
      final e = await node((_) async => throw TimeoutException('Weak signal'));
      await e.checkConnection();
      expect(e.connectionUnstable, true);
      expect(e.bankReachable, false);
      expect(e.bankAttention, isNull);
      expect(e.account!['balance'], 10000);
      expect(e.network, contains('saved payments will retry'));
      expect(await e.store.payments(), isEmpty);
    },
  );
  test(
    'bank identity mismatch is immediate and never hidden by weak network grace',
    () async {
      final e = await node(
        (_) async => http.Response(
          jsonEncode({'online': true, 'fingerprint': 'different'}),
          200,
        ),
      );
      await e.checkConnection();
      expect(e.bankReachable, false);
      expect(e.connectionUnstable, false);
      expect(e.bankAttention, contains('identity changed'));
    },
  );
  test(
    'authentication failure requires sign-in rather than endless transport retries',
    () async {
      final e = await node(
        (_) async =>
            http.Response(jsonEncode({'detail': 'Session expired'}), 401),
      );
      await e.checkConnection();
      expect(e.bankAttention, contains('Sign in again'));
      expect(e.connectionUnstable, false);
    },
  );
  test(
    'concurrent health and delivery workers share one in-flight probe',
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
      final monitor = e.checkConnection();
      final delivery = e.gatewayTick();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pending.complete(
        http.Response(
          jsonEncode({'online': true, 'fingerprint': 'trusted'}),
          200,
        ),
      );
      await Future.wait([monitor, delivery]);
      expect(probes, 1);
    },
  );
  test(
    'A temporary gateway outage allows the saved recipient and balance to be used offline',
    () async {
      final e = await node(
        (_) async => http.Response('{"detail":"temporarily busy"}', 503),
      );
      final cached = <String, dynamic>{
        'body': {
          'account_id': 'shop@beyondnet',
          'expires_at': nowSeconds + 600,
        },
      };
      e.merchants = [cached];
      e.bankReachable = true;
      expect(await e.findRecipient('shop@beyondnet'), cached);
      e.bankReachable = true;
      e.connectionUnstable = false;
      await e.preparePayment(1000);
      expect(e.bankReachable, false);
      expect(e.availableBalance, 10000);
    },
  );

  test('successful health check cannot erase payment retry backoff', () async {
    final e = await node(
      (r) async => r.url.path.startsWith('/api/receipts/')
          ? http.Response(jsonEncode({'detail': 'Temporarily busy'}), 503)
          : okay(r),
    );
    await e.gatewayTick();
    final retry = e.nextBankAttempt;
    expect(e.connectionUnstable, true);
    await e.checkConnection();
    expect(e.nextBankAttempt, retry);
  });
  test(
    'submission response loss keeps original packet and reservation for same-ID recovery',
    () async {
      final submitted = <String>[];
      final e = await node((r) async {
        if (r.url.path == '/api/packets') {
          submitted.add(jsonDecode(r.body)['id']);
          throw TimeoutException('Reply lost');
        }
        return okay(r);
      });
      final key = await x.newKeyPair();
      final p = await makePacket(
        'payment',
        await seal(base64Encode((await key.extractPublicKey()).bytes), {
          'test': 'opaque payment',
        }),
        randomCapability(),
        nowSeconds + 600,
      );
      await e.store.createPayment(p, {
        'payment_id': 'one-payment',
        'packet_id': p['id'],
        'state': 'queued',
        'sender': 'payer@beyondnet',
        'amount': 250,
        'sender_mailbox': p['mailbox'],
      });
      await e.reload();
      await e.gatewayTick();
      e.nextBankAttempt = DateTime.now();
      await e.gatewayTick();
      expect(submitted, [p['id'], p['id']]);
      expect((await e.store.payments()).single['state'], 'queued');
      expect(e.availableBalance, 9750);
      expect((await e.store.packets()).single['uploaded'], 0);
    },
  );
}
