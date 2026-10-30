import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/ble_transport.dart';
import 'package:beyondnet/protocol.dart';

class SimulatedRadio implements PeerTransport {
  @override
  final discovered = <String, PeerRadio>{};
  @override
  bool running = true;
  @override
  Future<void> start() async {
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<T> connect<T>(
    PeerRadio peer,
    Future<T> Function(Future<Json> Function(Json)) run,
  ) => throw UnimplementedError('Test contacts are explicitly controlled');
}

// Test-only redirection: production always uses HTTPS/WSS and fingerprint pinning.
class LoopbackClient extends http.BaseClient {
  final int port;
  final http.Client inner = http.Client();
  final String? loseFirstResponseOn;
  bool responseLost = false;
  LoopbackClient(this.port, {this.loseFirstResponseOn});
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final redirected = http.Request(
      request.method,
      request.url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
    redirected.headers.addAll(request.headers);
    if (request is http.Request) redirected.bodyBytes = request.bodyBytes;
    final response = await inner.send(redirected);
    if (!responseLost && request.url.path == loseFirstResponseOn) {
      responseLost = true;
      await response.stream.drain<void>();
      throw const SocketException('Test drops response after server commit');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global =
      null; // This integration test deliberately uses a real loopback bank.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'Real Dart signup, top-up, live payment and merchant receipt against Spring Boot bank',
    () async {
      final python =
          Platform.environment['BEYONDNET_TEST_PYTHON'] ??
          '../.venv/bin/python';
      final process = await Process.start(python, [
        '../scripts/test_java_bank.py',
      ]);
      final startupErrors = StringBuffer();
      final errors = process.stderr
          .transform(utf8.decoder)
          .listen(startupErrors.write);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final nodes = <BeyondNetEngine>[];
      final dir = await Directory.systemTemp.createTemp('beyondnet-live-');
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 45)),
          isTrue,
          reason: startupErrors.toString(),
        );
        final setup = jsonDecode(lines.current);
        final port = setup['port'] as int;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              BeyondNetEngine.platform,
              (_) async => true,
            );
        Future<void> eventually(bool Function() ready) async {
          final until = DateTime.now().add(const Duration(seconds: 60));
          while (!ready() && DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(
            ready(),
            isTrue,
            reason: nodes
                .map(
                  (e) =>
                      '${e.profile?["device_id"]}: ${e.network}; live=${e.liveConnected}; error=${e.lastError}',
                )
                .join('\n'),
          );
        }

        Future<BeyondNetEngine> create(
          String id,
          String role, {
          String? loseResponseOn,
        }) async {
          FlutterSecureStorage.setMockInitialValues({});
          final e = BeyondNetEngine(
            transport: SimulatedRadio(),
            client: LoopbackClient(port, loseFirstResponseOn: loseResponseOn),
            authorizePayment: () async => true,
            socketConnector: (url) => WebSocket.connect(
              Uri.parse(
                url,
              ).replace(scheme: 'ws', host: '127.0.0.1', port: port).toString(),
            ),
          );
          nodes.add(e);
          await e.store.init(databasePath: '${dir.path}/$id.sqlite3');
          if (loseResponseOn != null) {
            await expectLater(
              e.enroll(
                'https://test.bank',
                '$id@beyondnet',
                'test-password',
                setup['fingerprint'],
                name: id,
                role: role,
              ),
              throwsA(
                isA<EnrollmentFailure>().having(
                  (error) => error.resumeSignIn,
                  'resume sign-in',
                  isTrue,
                ),
              ),
            );
            expect(e.profile, isNull);
          }
          final savedKeys = await e.secure.read(key: 'device_keys');
          await e.enroll(
            'https://test.bank',
            '$id@beyondnet',
            'test-password',
            setup['fingerprint'],
            name: loseResponseOn == null ? id : null,
            role: loseResponseOn == null ? role : null,
          );
          if (savedKeys != null) {
            expect(await e.secure.read(key: 'device_keys'), savedKeys);
          }
          await eventually(() => e.liveConnected && e.bankReachable);
          return e;
        }

        final merchant = await create(
          'shop',
          'merchant',
          loseResponseOn: '/api/devices',
        );
        final sender = await create(
          'customer',
          'customer',
          loseResponseOn: '/api/signup',
        );
        expect(sender.account!['balance'], 0);
        await sender.setPaymentPin('test-password', '123456');
        await sender.addDemoMoney(100000);
        expect(sender.account!['balance'], 100000);
        final cert = await sender.findRecipient('shop@beyondnet');
        expect(
          sender.relay,
          isFalse,
        ); // Online payments need no Bluetooth or relay toggle.
        final id = await sender.pay(cert, 12345, pin: '123456');
        await eventually(
          () => sender.payments.any(
            (p) => p['payment_id'] == id && p['state'] == 'paid',
          ),
        );
        await eventually(
          () => merchant.receipts.any((r) => r['payment_id'] == id),
        );
        expect(sender.account!['balance'], 87655);
        expect(merchant.account!['balance'], 12345);
        expect(
          sender.payments.single['receipt']['bank_ref'],
          merchant.receipts.single['bank_ref'],
        );
        // Lost live connection recovers via HTTPS, with the same signed request.
        sender.closeLive();
        final second = await sender.pay(cert, 100, pin: '123456');
        await sender.retryNow();
        await eventually(
          () => sender.payments.any(
            (p) => p['payment_id'] == second && p['state'] == 'paid',
          ),
        );
        expect(sender.account!['balance'], 87555);

        // Actual bank settlement through an OFFLINE intermediate. There is no
        // simulated direct edge from the sender to either online gateway.
        Future<void> pause(BeyondNetEngine e) async {
          e.timer?.cancel();
          e.connectionTimer?.cancel();
          await eventually(() => !e.working && !e.checkingConnection);
          e.closeLive();
          e.bankReachable = false;
          e.internet = false;
          e.relay = true;
        }

        await pause(sender);
        await pause(merchant);
        final intermediate = await create('offline-relay', 'customer');
        await pause(intermediate);
        final gateway = await create('mesh-gateway-one', 'customer');
        await pause(gateway);
        final secondGateway = await create('mesh-gateway-two', 'customer');
        await pause(secondGateway);
        Future<void> edge(BeyondNetEngine a, BeyondNetEngine b) async {
          Json? identity;
          await a.syncPackets((command) async {
            final rid = randomCapability();
            final response = await b.handleRpc(await a.signedRpc(command, rid));
            final checked = await a.validateRpc(response, expectedRequest: rid);
            identity = Map<String, dynamic>.from(checked['peer']);
            return Map<String, dynamic>.from(checked['command']);
          }, () => identity!);
        }

        // Payment-first: authorize with no internet, no discovered peer and
        // no pre-approved route. Exercise FIVE phones with controlled edges.
        final relayTwo = await create('offline-relay-two', 'customer');
        await pause(relayTwo);
        final relayThree = await create('offline-relay-three', 'customer');
        await pause(relayThree);
        final third = await sender.pay(cert, 50, pin: '123456');
        await eventually(() => !sender.working);
        final packetId =
            sender.payments.firstWhere(
                  (p) => p['payment_id'] == third,
                )['packet_id']
                as String;
        for (final pair in [
          [sender, intermediate],
          [intermediate, relayTwo],
          [relayTwo, relayThree],
          [relayThree, gateway],
        ]) {
          final a = pair[0], b = pair[1];
          await edge(a, b);
          expect(
            await b.store.packet(packetId),
            isNull,
            reason: 'No custody before consent',
          );
          b.working = true; // controlled topology, no real radio scheduler
          try {
            await b.decideRelayInvitation(packetId, true);
          } finally {
            b.working = false;
          }
          await edge(a, b); // durable acknowledgment and no duplicate prompt
          expect(b.invitations, isEmpty);
        }
        final forwarded = (await gateway.store.packet(packetId))!;
        expect(forwarded['hops'], 4);
        expect(forwarded['path'], [
          sender.deviceId,
          intermediate.deviceId,
          relayTwo.deviceId,
          relayThree.deviceId,
        ]);
        // A second authenticated gateway receives the identical instruction;
        // concurrent submissions still produce one debit and the same receipt.
        await secondGateway.receiveOffer(forwarded, {
          'device_id': relayThree.deviceId,
          'display_name': 'Relay',
        });
        await secondGateway.store.decideInvitation(packetId, true);
        gateway.bankReachable = true;
        secondGateway.bankReachable = true;
        final results = await Future.wait([
          gateway.submitPacket(forwarded),
          secondGateway.submitPacket(forwarded),
        ]);
        expect(results.first['receipts'], results.last['receipts']);
        final proof = Map<String, dynamic>.from(
          results.first['delivery_proof'],
        );
        await gateway.receiveDeliveryProof(proof);
        for (final raw in results.first['receipts']) {
          await gateway.accept(Map<String, dynamic>.from(raw));
        }
        // Return through the entire chain while the payer stays offline.
        for (final pair in [
          [relayThree, gateway],
          [relayTwo, relayThree],
          [intermediate, relayTwo],
          [sender, intermediate],
        ]) {
          await edge(pair[0], pair[1]);
        }
        await sender.reload();
        expect(
          sender.payments.firstWhere((p) => p['payment_id'] == third)['state'],
          'paid',
        );
        expect(sender.account!['balance'], 87505);
        expect(sender.bankReachable, isFalse);
        expect(intermediate.bankReachable, isFalse);
        expect((await intermediate.store.proofs()).isNotEmpty, isTrue);

        // An expired unresolved request keeps funds reserved offline. On
        // reconnection, the ORIGINAL ciphertext gets a signed bank decision,
        // releasing its reservation without ever extending authorization.
        final expiredId = const Uuid().v4();
        final deadline = nowSeconds - 1;
        final expiredBody = {
          'v': 2,
          'pin': '123456',
          'payment_id': expiredId,
          'sender': sender.accountId,
          'recipient': merchant.accountId,
          'amount': 100,
          'currency': 'INR',
          'device_id': sender.deviceId,
          'created_at': deadline - 600,
          'expires_at': deadline,
          'sender_mailbox': randomCapability(),
          'recipient_mailbox': randomCapability(),
        };
        final expiredPacket = await makePacket(
          'payment',
          await seal(
            sender.trust['box_key'],
            await sign(sender.signing, expiredBody),
          ),
          expiredBody['sender_mailbox'] as String,
          deadline,
        );
        await sender.store.createPayment(expiredPacket, {
          for (final entry in expiredBody.entries)
            if (entry.key != 'pin') entry.key: entry.value,
          'packet_id': expiredPacket['id'],
          'state': 'queued',
          'transport': 'Saved on this phone',
        });
        await sender.reload();
        expect(sender.availableBalance, 87405);
        sender.bankReachable = true;
        sender.nextBankAttempt = DateTime.fromMillisecondsSinceEpoch(0);
        await sender.gatewayTick();
        await sender.reload();
        final expired = sender.payments.firstWhere(
          (p) => p['payment_id'] == expiredId,
        );
        expect(expired['state'], 'rejected');
        expect(
          expired['receipt']['reason'],
          'Authorization expired before bank submission',
        );
        expect(sender.account!['balance'], 87505);
        expect(sender.availableBalance, 87505);
        expect(
          (await sender.store.packet(expiredPacket['id']))!['expires_at'],
          deadline,
        );
      } finally {
        for (final e in nodes) {
          e.timer?.cancel();
          e.connectionTimer?.cancel();
          final until = DateTime.now().add(const Duration(seconds: 45));
          while ((e.working || e.checkingConnection) &&
              DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          e.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await e.store.db.close();
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(BeyondNetEngine.platform, null);
        process.kill(ProcessSignal.sigterm);
        // Helper may spend 10s stopping Java, then remove its PostgreSQL schema.
        expect(
          await process.exitCode.timeout(const Duration(seconds: 20)),
          0,
          reason: startupErrors.toString(),
        );
        await lines.cancel();
        await errors.cancel();
        await dir.delete(recursive: true);
      }
    },
    tags: const ['integration'],
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
