import 'dart:async';
import 'dart:convert';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/payment_pin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class PinPageEngine extends BeyondNetEngine {
  int checks = 0, saves = 0;
  bool connectOnCheck = false;
  Object? saveFailure;
  @override
  Future<void> checkConnection() async {
    checks++;
    bankReachable = connectOnCheck;
    network = bankReachable ? 'Connected to bank' : 'Bank unavailable';
    notifyListeners();
  }

  @override
  Future<void> setPaymentPin(String password, String pin) async {
    saves++;
    if (saveFailure != null) throw saveFailure!;
  }
}

class ConnectionProbeEngine extends BeyondNetEngine {
  ConnectionProbeEngine()
    : super(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'fingerprint': 'expected', 'online': true}),
            200,
          ),
        ),
      );
  @override
  Future<void> openLive() async {}
  @override
  Future<void> refreshProfile() async {}
  @override
  Future<void> tick() async {}
}

void main() {
  Future<void> showPage(WidgetTester tester, PinPageEngine e) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PaymentPinPage(engine: e),
                ),
              ),
              child: const Text('Open PIN'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open PIN'));
    await tester.pumpAndSettle();
  }

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Save payment PIN'),
  );

  Future<void> fill(WidgetTester tester) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'test-password');
    await tester.enterText(fields.at(1), '123456');
    await tester.enterText(fields.at(2), '123456');
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Save payment PIN'),
    );
  }

  testWidgets('PIN page reacts immediately when bank connectivity changes', (
    tester,
  ) async {
    final e = PinPageEngine();
    await showPage(tester, e);
    expect(e.checks, 1);
    expect(saveButton(tester).onPressed, isNull);
    e.bankReachable = true;
    e.notifyListeners();
    await tester.pump();
    expect(saveButton(tester).onPressed, isNotNull);
    expect(
      find.text('Bank connected. You can save your payment PIN.'),
      findsOneWidget,
    );
    e.bankReachable = false;
    e.notifyListeners();
    await tester.pump();
    expect(saveButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Connection retry enables PIN setup without leaving the page', (
    tester,
  ) async {
    final e = PinPageEngine();
    await showPage(tester, e);
    e.connectOnCheck = true;
    await tester.ensureVisible(find.text('Check bank connection'));
    await tester.tap(find.text('Check bank connection'));
    await tester.pumpAndSettle();
    expect(e.checks, 2);
    expect(saveButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Failed PIN save keeps form values and releases Save for retry', (
    tester,
  ) async {
    final e = PinPageEngine()..connectOnCheck = true;
    e.saveFailure = BankFailure(401, 'Account password is incorrect');
    await showPage(tester, e);
    await fill(tester);
    await tester.tap(find.text('Save payment PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Account password is incorrect'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNotNull);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      '123456',
    );
    e.saveFailure = null;
    await tester.ensureVisible(find.text('Save payment PIN'));
    await tester.tap(find.text('Save payment PIN'));
    await tester.pumpAndSettle();
    expect(e.saves, 2);
    expect(find.text('Open PIN'), findsOneWidget);
    expect(find.text('Payment PIN saved at the bank'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Incomplete PIN is explained before any bank submission', (
    tester,
  ) async {
    final e = PinPageEngine()..connectOnCheck = true;
    await showPage(tester, e);
    await tester.ensureVisible(find.text('Save payment PIN'));
    await tester.tap(find.text('Save payment PIN'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter your account password and all six PIN digits'),
      findsOneWidget,
    );
    expect(e.saves, 0);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final nativeStalls in [false, true]) {
    testWidgets(
      nativeStalls
          ? 'A missing Android connectivity reply cannot block the bank probe forever'
          : 'Verified bank response overrides a false Android internet hint',
      (tester) async {
        final e = ConnectionProbeEngine();
        e.profile = {
          'bank_url': 'https://test.bank',
          'trust': {'fingerprint': 'expected'},
        };
        messenger.setMockMethodCallHandler(
          BeyondNetEngine.platform,
          (_) => nativeStalls ? Completer<bool>().future : Future.value(false),
        );
        try {
          final probe = e.checkConnection();
          await tester.pump();
          if (nativeStalls) await tester.pump(const Duration(seconds: 2));
          await probe;
          expect(e.bankReachable, isTrue);
          expect(e.internet, isTrue);
          expect(e.checkingConnection, isFalse);
        } finally {
          messenger.setMockMethodCallHandler(BeyondNetEngine.platform, null);
          e.dispose();
        }
      },
    );
  }
}
