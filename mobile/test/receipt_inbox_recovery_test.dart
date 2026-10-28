import 'dart:convert';
import 'dart:io';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  for (final failure in [
    'malformed receipt',
    'database failure',
    'storage quota',
  ]) {
    test('Inbox recovers after $failure without losing valid receipts', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('beyondnet-inbox-');
      final bank = await ed.newKeyPair();
      final box = await x.newKeyPair();
      final mailbox = randomCapability();
      final receipt = await makePacket(
        'receipt',
        await seal(
          base64Encode((await box.extractPublicKey()).bytes),
          await sign(bank, {
            'v': 1,
            'device_id': 'local',
            'payment_id': 'inbox-payment',
            'sender': 'payer@beyondnet',
            'recipient': 'local@beyondnet',
            'amount': 100,
            'currency': 'INR',
            'status': 'paid',
            'reason': '',
            'bank_ref': 'OK-INBOX',
            'committed_at': nowSeconds,
            'balance': 100,
            'balance_revision': 1,
          }),
        ),
        mailbox,
        nowSeconds + 3600,
      );
      final poison = {
        ...receipt,
        'path': ['relay', 'relay'],
      };
      final cursors = <String?>[];
      final e = BeyondNetEngine(
        client: MockClient((request) async {
          if (request.url.path == '/api/health') {
            return http.Response(
              jsonEncode({'fingerprint': 'inbox-bank', 'online': true}),
              200,
            );
          }
          cursors.add(request.url.queryParameters['after']);
          return http.Response(
            jsonEncode({
              'receipts': request.url.queryParameters['after'] == '7'
                  ? []
                  : [42, poison, receipt],
              'cursor': 7,
            }),
            200,
          );
        }),
      );
      await e.store.init(databasePath: '${dir.path}/phone.db');
      e.encryption = box;
      e.profile = {
        'device_id': 'local',
        'bank_url': 'https://inbox.invalid',
        'account': {'id': 'local@beyondnet', 'balance': 0, 'revision': 0},
        'trust': {
          'fingerprint': 'inbox-bank',
          'sign_key': base64Encode((await bank.extractPublicKey()).bytes),
        },
      };
      try {
        if (failure == 'database failure') {
          await e.store.db.execute(
            "CREATE TRIGGER unavailable BEFORE INSERT ON packets BEGIN SELECT RAISE(FAIL, 'storage unavailable'); END",
          );
        } else if (failure == 'storage quota') {
          await e.store.db.rawInsert(
            "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000) INSERT INTO packets(id,data,expiry,uploaded) SELECT 'quota-'||x,'{}',?,0 FROM n",
            [nowSeconds + 3600],
          );
        }
        e.bankReachable = true;
        await e.gatewayTick();
        if (failure != 'malformed receipt') {
          expect(await e.store.config('inbox_cursor:local'), isNull);
          expect(await e.store.receipts(), isEmpty);
          if (failure == 'database failure') {
            await e.store.db.execute('DROP TRIGGER unavailable');
          } else {
            await e.store.db.delete('packets');
          }
          e.nextBankAttempt = DateTime.fromMillisecondsSinceEpoch(0);
          e.bankReachable = true;
          await e.gatewayTick();
        }
        expect(await e.store.config('inbox_cursor:local'), 7);
        expect((await e.store.receipts()).single['bank_ref'], 'OK-INBOX');
        expect(e.account!['balance'], 100);
        e.nextBankAttempt = DateTime.fromMillisecondsSinceEpoch(0);
        await e.gatewayTick();
        expect(cursors.last, '7');
      } finally {
        e.dispose();
        await e.store.db.close();
        await dir.delete(recursive: true);
      }
    });
  }

  test(
    'A temporary bank 500 keeps the original queued authorization for retry',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('beyondnet-retry-');
      var submissions = 0;
      final submittedIds = <Object?>[];
      final e = BeyondNetEngine(
        client: MockClient((request) async {
          if (request.url.path == '/api/health') {
            return http.Response(
              jsonEncode({'fingerprint': 'retry-bank', 'online': true}),
              200,
            );
          }
          if (request.url.path == '/api/packets') {
            submissions++;
            submittedIds.add((jsonDecode(request.body) as Map)['id']);
            if (submissions == 1) {
              return http.Response(
                '{"detail":"Temporary database failure"}',
                500,
              );
            }
          }
          return http.Response('{"receipts":[],"cursor":0}', 200);
        }),
      );
      await e.store.init(databasePath: '${dir.path}/phone.db');
      e.profile = {
        'device_id': 'local',
        'bank_url': 'https://retry.invalid',
        'account': {'id': 'local@beyondnet', 'balance': 1000, 'revision': 0},
        'trust': {'fingerprint': 'retry-bank'},
      };
      final payment = await makePacket(
        'payment',
        {'test': 'opaque'},
        randomCapability(),
        nowSeconds + 600,
      );
      try {
        await e.store.createPayment(payment, {
          'payment_id': 'original',
          'packet_id': payment['id'],
          'sender_mailbox': payment['mailbox'],
          'sender': 'local@beyondnet',
          'recipient': 'shop@beyondnet',
          'amount': 100,
          'state': 'queued',
        });
        await e.reload();
        await e.gatewayTick();
        expect(
          (await e.store.db.query(
            'packets',
            where: 'id=?',
            whereArgs: [payment['id']],
          )).single['uploaded'],
          0,
        );
        expect((await e.store.payments()).single['state'], 'queued');
        e.nextBankAttempt = DateTime.fromMillisecondsSinceEpoch(0);
        await e.gatewayTick();
        expect(submissions, 2);
        expect(submittedIds, [payment['id'], payment['id']]);
        expect(
          (await e.store.db.query(
            'packets',
            where: 'id=?',
            whereArgs: [payment['id']],
          )).single['uploaded'],
          1,
        );
        expect((await e.store.payments()).single['state'], 'queued');
        // Transport success without a bank-signed outcome must never mean Paid.
        expect(e.availableBalance, 900);
      } finally {
        e.dispose();
        await e.store.db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
