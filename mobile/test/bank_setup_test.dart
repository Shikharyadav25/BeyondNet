import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:beyondnet/bank_setup_code.dart';
import 'package:beyondnet/bank_setup_scan.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';

String code({String url = 'https://bank.example/', String? fingerprint}) =>
    jsonEncode({
      'type': 'beyondnet-bank-setup',
      'v': 1,
      'bank_url': url,
      'fingerprint': fingerprint ?? 'a' * 64,
    });
Future<void> reveal(WidgetTester tester, String text) =>
    tester.scrollUntilVisible(
      find.text(text),
      180,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Setup payload contains both fields and normalizes a trailing slash',
    () {
      final setup = BankSetupCode.parse(code());
      expect(setup.url, 'https://bank.example');
      expect(setup.fingerprint, 'a' * 64);
    },
  );
  test(
    'Malformed, insecure, recipient and credential-bearing QRs are rejected',
    () {
      for (final raw in [
        'not json',
        jsonEncode({
          'body': {'account_id': 'shop@beyondnet'},
        }),
        code(url: 'http://bank.example'),
        code(url: 'https://user:password@bank.example'),
        code(url: 'https://bank.example/api'),
        code(url: 'https://bank.example?token=secret'),
        code(url: 'https://bank.example#extra'),
        code(url: 'https://bank.example:99999'),
        code(fingerprint: 'short'),
        code(fingerprint: 'g' * 64),
        jsonEncode({...jsonDecode(code()), 'password': 'secret'}),
        jsonEncode({...jsonDecode(code()), 'v': 2}),
        'x' * 4097,
      ]) {
        expect(() => BankSetupCode.parse(raw), throwsFormatException);
      }
    },
  );
  test('Multiple codes ignore unrelated values but reject ambiguous banks', () {
    expect(bankSetupFromValues([null, 'recipient', code(), code()]), code());
    expect(bankSetupFromValues(['recipient']), isNull);
    expect(
      () => bankSetupFromValues([code(), code(url: 'https://other.example')]),
      throwsFormatException,
    );
  });
  test(
    'Gallery decoder analyzes a selected file without starting camera',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel(
        'dev.steenbakker.mobile_scanner/scanner/method',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'analyzeImage') {
          return {
            'data': [
              {'rawValue': code(), 'format': 256},
            ],
          };
        }
        return null;
      });
      try {
        expect(await readBankSetupImage('/selected/qr.png'), code());
        expect(
          calls
              .where((c) => c.method == 'analyzeImage')
              .single
              .arguments['filePath'],
          '/selected/qr.png',
        );
        expect(
          calls.any((c) => c.method == 'start' || c.method == 'request'),
          isFalse,
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  for (final gallery in [false, true]) {
    testWidgets(
      '${gallery ? 'Gallery' : 'Camera'} setup fills both fields only after review',
      (tester) async {
        final engine = BeyondNetEngine();
        await tester.pumpWidget(
          MaterialApp(
            home: LoginPage(
              engine: engine,
              scanBankCode: () async => code(),
              pickBankCode: () async => code(),
            ),
          ),
        );
        final label = gallery ? 'Choose QR image' : 'Scan bank QR';
        await reveal(tester, label);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text('Use this bank?'), findsOneWidget);
        expect(find.text('https://bank.example'), findsOneWidget);
        await tester.tap(find.text('Use bank details'));
        await tester.pumpAndSettle();
        final fields = tester
            .widgetList<TextField>(find.byType(TextField))
            .toList();
        expect(
          fields
              .firstWhere((f) => f.decoration?.labelText == 'Bank HTTPS URL')
              .controller!
              .text,
          'https://bank.example',
        );
        expect(
          fields
              .firstWhere(
                (f) => f.decoration?.labelText == 'Bank trust fingerprint',
              )
              .controller!
              .text,
          'a' * 64,
        );
        expect(engine.profile, isNull);
        await tester.pumpWidget(const SizedBox());
        engine.dispose();
      },
    );
  }
  testWidgets('Canceling QR review leaves manual fields unchanged', (
    tester,
  ) async {
    final engine = BeyondNetEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(engine: engine, pickBankCode: () async => code()),
      ),
    );
    await reveal(tester, 'Choose QR image');
    await tester.tap(find.text('Choose QR image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    final field = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.decoration?.labelText == 'Bank HTTPS URL');
    expect(field.controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    engine.dispose();
  });
  test('Wrong QR fingerprint cannot send signup credentials to bank', () async {
    final health = {'sign_key': 'one', 'box_key': 'two', 'mesh_id': 'mesh'};
    health['fingerprint'] = await digest(health);
    final requests = <http.Request>[];
    final engine = BeyondNetEngine(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(health), 200);
      }),
    );
    final setup = BankSetupCode.parse(code());
    await expectLater(
      engine.enroll(
        setup.url,
        'sam@beyondnet',
        'password123',
        setup.fingerprint,
        name: 'Sam',
        role: 'customer',
      ),
      throwsStateError,
    );
    expect(requests.length, 1);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/health');
    engine.dispose();
  });
}
