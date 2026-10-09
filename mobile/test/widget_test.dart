import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/engine.dart';

Future<void> scroll(WidgetTester tester, Finder finder, double delta) =>
    tester.scrollUntilVisible(
      finder,
      delta,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );

void main() {
  testWidgets('Payment detail never labels an expired unknown request Paid', (
    tester,
  ) async {
    final e = BeyondNetEngine();
    e.payments = [
      {
        'payment_id': 'test-payment',
        'sender': 'alice@karo',
        'recipient': 'chai@karo',
        'name': 'Chai & Co.',
        'amount': 12500,
        'created_at': 1,
        'expires_at': 2,
        'state': 'relayed',
        'transport': 'Peer stored packet',
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: PaymentDetails(engine: e, id: 'test-payment'),
      ),
    );
    expect(find.text('Outcome not yet known'), findsOneWidget);
    expect(find.text('Payment confirmed'), findsNothing);
    e.payments.first['state'] = 'paid';
    e.payments.first['receipt'] = {'bank_ref': 'OK-TEST', 'committed_at': 3};
    e.notifyListeners();
    await tester.pump();
    expect(find.text('Payment confirmed'), findsOneWidget);
  });
  testWidgets('Signup has two account types and collects bank trust', (
    tester,
  ) async {
    final e = BeyondNetEngine();
    await tester.pumpWidget(MaterialApp(home: LoginPage(engine: e)));
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Merchant'), findsOneWidget);
    await tester.tap(find.text('Merchant'));
    await tester.pump();
    await scroll(tester, find.text('Business name'), 180);
    expect(find.text('Business name'), findsOneWidget);
    await scroll(tester, find.text('Bank HTTPS URL'), 180);
    expect(find.text('Bank HTTPS URL'), findsOneWidget);
    await scroll(tester, find.text('Payment ID'), 180);
    expect(find.text('Payment ID'), findsOneWidget);
    await scroll(tester, find.text('Bank trust fingerprint'), 180);
    expect(find.text('Bank trust fingerprint'), findsOneWidget);
    expect(find.text('Use a demo account'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  BeyondNetEngine sample({bool online = false, bool merchant = false}) {
    final e = BeyondNetEngine();
    e.profile = {
      'account': {
        'id': 'sam@beyondnet',
        'name': 'Sam',
        'role': merchant ? 'merchant' : 'customer',
        'balance': 0,
        'revision': 0,
      },
      'balance_checked_at': 1,
      'device_id': 'test-device',
      'bank_url': 'https://test.bank',
      'trust': {'fingerprint': 'a' * 64},
    };
    e.internet = online;
    e.bankReachable = online;
    return e;
  }

  testWidgets('Offline payment directs to permissions and relay discovery', (
    tester,
  ) async {
    final e = sample();
    await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
    expect(find.text('Your internet is off'), findsOneWidget);
    await tester.tap(find.text('Set up offline payments'));
    await tester.pump();
    expect(find.text('Before you connect'), findsOneWidget);
    expect(find.text('Bank gateway'), findsNothing);
    await scroll(tester, find.text('Scan for nearby phones'), 180);
    expect(find.text('Scan for nearby phones'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Online personal account can pay without a relay', (
    tester,
  ) async {
    final e = sample(online: true);
    await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
    expect(find.text('You’re online'), findsOneWidget);
    await scroll(tester, find.text('Pay by ID'), 180);
    await tester.tap(find.text('Pay by ID'));
    await tester.pumpAndSettle();
    expect(find.text('Recipient payment ID'), findsOneWidget);
    expect(find.byTooltip('Scan QR'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Merchant has receive-first home and can add demo money', (
    tester,
  ) async {
    final e = sample(online: true, merchant: true);
    await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
    await scroll(tester, find.text('Show my payment QR'), 180);
    expect(find.text('Show my payment QR'), findsOneWidget);
    expect(find.text('Pay by ID'), findsNothing);
    expect(find.text('Add demo money'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Demo funding is disabled offline', (tester) async {
    final e = sample();
    await tester.pumpWidget(MaterialApp(home: AddMoneyPage(engine: e)));
    await scroll(
      tester,
      find.widgetWithText(FilledButton, 'Add demo money'),
      180,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add demo money'),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });
}
