import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:beyondnet/engine.dart';

// Test-only redirection: production always uses HTTPS/WSS and fingerprint pinning.
class LoopbackClient extends http.BaseClient {
  final int port;
  final http.Client inner = http.Client();
  LoopbackClient(this.port);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final redirected = http.Request(
      request.method,
      request.url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
    redirected.headers.addAll(request.headers);
    if (request is http.Request) redirected.bodyBytes = request.bodyBytes;
    return inner.send(redirected);
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
    'Real Dart signup, top-up, live payment and merchant receipt against Python bank',
    () async {
      final python =
          Platform.environment['BEYONDNET_TEST_PYTHON'] ??
          '../.venv/bin/python';
      final process = await Process.start(python, [
        '../scripts/test_live_bank.py',
      ]);
      process.stderr.drain<void>();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final nodes = <BeyondNetEngine>[];
      final dir = await Directory.systemTemp.createTemp('beyondnet-live-');
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        final setup = jsonDecode(lines.current);
        final port = setup['port'] as int;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              BeyondNetEngine.platform,
              (_) async => true,
            );
        Future<void> eventually(bool Function() ready) async {
          final until = DateTime.now().add(const Duration(seconds: 20));
          while (!ready() && DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(ready(), isTrue);
        }

        Future<BeyondNetEngine> create(String id, String role) async {
          FlutterSecureStorage.setMockInitialValues({});
          final e = BeyondNetEngine(
            client: LoopbackClient(port),
            authorizePayment: () async => true,
            socketConnector: (url) => WebSocket.connect(
              Uri.parse(
                url,
              ).replace(scheme: 'ws', host: '127.0.0.1', port: port).toString(),
            ),
          );
          nodes.add(e);
          await e.store.init(databasePath: '${dir.path}/$id.sqlite3');
          await e.enroll(
            'https://test.bank',
            '$id@beyondnet',
            'test-password',
            setup['fingerprint'],
            name: id,
            role: role,
          );
          await eventually(() => e.liveConnected && e.bankReachable);
          return e;
        }

        final merchant = await create('shop', 'merchant');
        final sender = await create('customer', 'customer');
        expect(sender.account!['balance'], 0);
        await sender.addDemoMoney(100000);
        expect(sender.account!['balance'], 100000);
        final cert = await sender.findRecipient('shop@beyondnet');
        expect(
          sender.relay,
          isFalse,
        ); // Online payments need no Bluetooth or relay toggle.
        final id = await sender.pay(cert, 12345);
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
        final second = await sender.pay(cert, 100);
        await sender.retryNow();
        await eventually(
          () => sender.payments.any(
            (p) => p['payment_id'] == second && p['state'] == 'paid',
          ),
        );
        expect(sender.account!['balance'], 87555);
      } finally {
        for (final e in nodes) {
          e.timer?.cancel();
          e.connectionTimer?.cancel();
          final until = DateTime.now().add(const Duration(seconds: 15));
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
        await process.exitCode.timeout(const Duration(seconds: 5));
        await lines.cancel();
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
