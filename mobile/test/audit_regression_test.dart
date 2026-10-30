import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:io';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/protocol.dart';
import 'package:beyondnet/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  late LocalStore store;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('beyondnet-audit-probe-');
    store = LocalStore();
    await store.init(databasePath: '${dir.path}/payments.db');
  });

  test(
    'A response from another bank-certified peer cannot replace the selected peer',
    () async {
      final e = BeyondNetEngine();
      await e.store.init(databasePath: '${dir.path}/peer-binding.db');
      final bank = await ed.newKeyPair();
      final selectedKey = await ed.newKeyPair();
      final otherKey = await ed.newKeyPair();
      final selected = {
        'device_id': 'selected',
        'account_id': 'selected@beyondnet',
        'mesh_id': 'audit',
        'sign_key': base64Encode((await selectedKey.extractPublicKey()).bytes),
        'box_key': 'selected-box',
        'expires_at': nowSeconds + 600,
      };
      final other = {
        ...selected,
        'device_id': 'other',
        'account_id': 'other@beyondnet',
        'sign_key': base64Encode((await otherKey.extractPublicKey()).bytes),
      };
      e.profile = {
        'device_id': 'local',
        'trust': {
          'sign_key': base64Encode((await bank.extractPublicKey()).bytes),
          'mesh_id': 'audit',
        },
      };
      final body = {
        'at': nowSeconds,
        'request_id': 'same-request',
        'command': {'op': 'inventory'},
      };
      try {
        final good = {
          ...await sign(selectedKey, body),
          'certificate': await sign(bank, selected),
        };
        final bad = {
          ...await sign(otherKey, body),
          'certificate': await sign(bank, other),
        };
        expect(
          (await e.validateRpc(
            good,
            expectedRequest: 'same-request',
            expectedPeer: selected,
          ))['peer']['device_id'],
          'selected',
        );
        await expectLater(
          e.validateRpc(
            bad,
            expectedRequest: 'same-request',
            expectedPeer: selected,
          ),
          throwsStateError,
        );
        await expectLater(
          e.validateRpc(
            bad,
            expectedRequest: 'same-request',
            expectedDevice: 'selected',
          ),
          throwsStateError,
        );
        expect(
          await e.store.db.query('peers', where: 'id=?', whereArgs: ['other']),
          isEmpty,
        );
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test(
    'Health timeout sends no credentials and does not claim an account exists',
    () async {
      var calls = 0;
      final e = BeyondNetEngine(
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'GET');
          throw TimeoutException('Test network stalled');
        }),
      );
      try {
        await expectLater(
          e.enroll(
            'https://bank.example',
            'user@beyondnet',
            'test-password',
            'a' * 64,
            name: 'User',
            role: 'customer',
          ),
          throwsA(
            isA<EnrollmentFailure>()
                .having(
                  (error) => error.resumeSignIn,
                  'sign-in needed',
                  isFalse,
                )
                .having(
                  (error) => error.message,
                  'safe guidance',
                  contains('No account details were sent'),
                ),
          ),
        );
        expect(calls, 1);
      } finally {
        e.dispose();
      }
    },
  );

  test(
    'Unconfirmed signup is not retried and directs recovery to sign-in',
    () async {
      final health = {'sign_key': 'sign', 'box_key': 'box', 'mesh_id': 'mesh'};
      health['fingerprint'] = await digest(health);
      final posts = <String>[];
      final e = BeyondNetEngine(
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode(health), 200);
          }
          posts.add(request.url.path);
          throw TimeoutException('Signup response lost');
        }),
      );
      try {
        await expectLater(
          e.enroll(
            'https://bank.example',
            'user@beyondnet',
            'test-password',
            health['fingerprint']!,
            name: 'User',
            role: 'customer',
          ),
          throwsA(
            isA<EnrollmentFailure>().having(
              (error) => error.resumeSignIn,
              'sign-in needed',
              isTrue,
            ),
          ),
        );
        expect(posts, ['/api/signup']);
        expect(await e.secure.read(key: 'device_keys'), isNull);
      } finally {
        e.dispose();
      }
    },
  );
  tearDown(() async {
    await store.db.close();
    await dir.delete(recursive: true);
  });

  test(
    'Expired invitations release per-peer capacity while retaining history',
    () async {
      for (var i = 0; i < 8; i++) {
        final packet = await makePacket(
          'payment',
          {'audit': i},
          randomCapability(),
          nowSeconds + 600,
        );
        await store.invite(packet, 'same-enrolled-peer', 'Peer');
      }
      await store.db.update('relay_invitations', {'expiry': nowSeconds - 1});
      await store.cleanup();
      expect(await store.invitations(), isEmpty);
      final next = await makePacket(
        'payment',
        {'audit': 9},
        randomCapability(),
        nowSeconds + 600,
      );
      expect(await store.invite(next, 'same-enrolled-peer', 'Peer'), 'new');
      expect(await store.invitations(), hasLength(1));
      expect(
        await store.db.query('relay_invitations', where: "state='expired'"),
        hasLength(8),
      );
    },
  );

  test(
    'Expired invitations release the global cap before scheduled cleanup',
    () async {
      for (var i = 0; i < 40; i++) {
        final packet = await makePacket(
          'payment',
          {'audit': i},
          randomCapability(),
          nowSeconds + 600,
        );
        await store.invite(packet, 'peer-${i ~/ 8}', 'Peer');
      }
      final next = await makePacket(
        'payment',
        {'audit': 'next'},
        randomCapability(),
        nowSeconds + 600,
      );
      await expectLater(
        store.invite(next, 'new-peer', 'Peer'),
        throwsStateError,
      );
      await store.db.update('relay_invitations', {'expiry': nowSeconds - 1});
      expect(await store.invite(next, 'new-peer', 'Peer'), 'new');
      expect(await store.invitations(), hasLength(1));
    },
  );

  test(
    'A substituted packet is rejected before storage or custody acknowledgement',
    () async {
      final e = BeyondNetEngine();
      await e.store.init(databasePath: '${dir.path}/engine.db');
      e.profile = {
        'device_id': 'local',
        'account': {'id': 'local@beyondnet', 'balance': 0, 'revision': 0},
      };
      final requested = await makePacket(
        'receipt',
        {'audit': 'requested'},
        randomCapability(),
        nowSeconds + 600,
      );
      final substitute = {
        ...await makePacket(
          'receipt',
          {'audit': 'substitute'},
          randomCapability(),
          nowSeconds + 600,
        ),
        'hops': 1,
        'trail': ['peer'],
        'path': ['peer'],
      };
      String? acknowledged;
      try {
        await expectLater(
          e.syncPackets((cmd) async {
            switch (cmd['op']) {
              case 'inventory':
                return {
                  'op': 'inventory',
                  'ids': [requested['id']],
                  'next': null,
                  'device_id': 'peer',
                  'routing': 2,
                  'routes': [
                    {'id': requested['id'], 'hops': 0, 'kind': 'receipt'},
                  ],
                };
              case 'get':
                expect(cmd['id'], requested['id']);
                return {'op': 'packet', 'packet': substitute};
              case 'ack':
                acknowledged = cmd['id'];
                return {'op': 'acknowledged', 'id': cmd['id']};
              default:
                throw StateError('Unexpected operation ${cmd['op']}');
            }
          }, () => {'device_id': 'peer', 'account_id': 'peer@beyondnet'}),
          throwsStateError,
        );
        expect(await e.store.packet(requested['id']), isNull);
        expect(await e.store.packet(substitute['id']), isNull);
        expect(acknowledged, isNull);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );

  test('Inventory identity must match the verified peer', () async {
    final e = BeyondNetEngine();
    await e.store.init(databasePath: '${dir.path}/identity.db');
    e.profile = {
      'device_id': 'local',
      'account': {'id': 'local@beyondnet'},
    };
    try {
      await expectLater(
        e.syncPackets(
          (_) async => {
            'op': 'inventory',
            'ids': [],
            'next': null,
            'device_id': 'different-device',
            'routing': 2,
            'routes': [],
          },
          () => {'device_id': 'verified-peer', 'account_id': 'peer@beyondnet'},
        ),
        throwsStateError,
      );
      expect(e.nearby, isEmpty);
    } finally {
      e.dispose();
      await e.store.db.close();
    }
  });

  test(
    'Connection timeout copy gives recovery guidance instead of a stack trace',
    () {
      expect(
        userErrorMessage(
          TimeoutException('Future not completed', const Duration(seconds: 12)),
        ),
        allOf(isNot(contains('TimeoutException')), contains('check Activity')),
      );
    },
  );
  test(
    'Bank refresh of an old committed receipt resolves the original intent',
    () async {
      final bank = await ed.newKeyPair();
      final deviceBox = await x.newKeyPair();
      final mailbox = randomCapability();
      final old = await makePacket(
        'payment',
        {'audit': 'original ciphertext'},
        mailbox,
        nowSeconds - 8 * 86400,
      );
      final decision = await sign(bank, {
        'v': 1,
        'payment_id': 'old-paid',
        'device_id': 'local',
        'sender': 'local@beyondnet',
        'recipient': 'shop@beyondnet',
        'amount': 100,
        'currency': 'INR',
        'status': 'paid',
        'reason': '',
        'bank_ref': 'OK-AUDIT',
        'committed_at': nowSeconds - 8 * 86400,
        'balance': 9000,
        'balance_revision': 1,
      });
      final receipt = await makePacket(
        'receipt',
        await seal(
          base64Encode((await deviceBox.extractPublicKey()).bytes),
          decision,
        ),
        mailbox,
        nowSeconds - 86400,
      );
      final refreshed = await makePacket(
        'receipt',
        Map<String, dynamic>.from(receipt['box']),
        mailbox,
        nowSeconds + 7 * 86400,
      );
      final proof = await sign(bank, {
        'v': 1,
        'type': 'delivery_proof',
        'mesh_id': 'audit-mesh',
        'packet_id': old['id'],
        'receipt_ids': [refreshed['id']],
        'recorded_at': nowSeconds,
        'expires_at': nowSeconds + 7 * 86400,
      });
      var duplicateRecovered = false;
      final e = BeyondNetEngine(
        client: MockClient((req) async {
          if (req.url.path == '/api/health') {
            return http.Response(
              jsonEncode({'fingerprint': 'audit', 'online': true}),
              200,
            );
          }
          if (req.url.path == '/api/packets') {
            duplicateRecovered = true;
            return http.Response(
              jsonEncode({
                'duplicate': true,
                'delivery_proof': proof,
                'receipts': [refreshed],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'receipts': [], 'cursor': 0}), 200);
        }),
      );
      await e.store.init(databasePath: '${dir.path}/old-paid.db');
      e.encryption = deviceBox;
      e.profile = {
        'device_id': 'local',
        'bank_url': 'https://audit.invalid',
        'account': {'id': 'local@beyondnet', 'balance': 9000, 'revision': 1},
        'trust': {
          'mesh_id': 'audit-mesh',
          'fingerprint': 'audit',
          'sign_key': base64Encode((await bank.extractPublicKey()).bytes),
        },
      };
      try {
        await e.store.createPayment(old, {
          'payment_id': 'old-paid',
          'packet_id': old['id'],
          'sender_mailbox': mailbox,
          'sender': 'local@beyondnet',
          'recipient': 'shop@beyondnet',
          'amount': 100,
          'state': 'queued',
        });
        await e.reload();
        e.bankReachable = true;
        await e.gatewayTick();
        await e.reload();
        expect(duplicateRecovered, isTrue);
        expect(e.payments.single['state'], 'paid');
        expect(e.bankReachable, isTrue);
        expect(e.availableBalance, 9000);
        expect(
          (await e.store.packet(old['id']))!['expires_at'],
          old['expires_at'],
        );
        await expectLater(e.accept(receipt), throwsStateError);
        // Financial verification stays unchanged; expired relay envelopes are still refused.
        await e.deliverReceipt(receipt);
        await e.reload();
        expect(e.payments.single['state'], 'paid');
        expect(e.availableBalance, 9000);
      } finally {
        e.dispose();
        await e.store.db.close();
      }
    },
  );
}
