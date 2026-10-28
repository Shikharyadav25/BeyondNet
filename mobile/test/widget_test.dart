import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class RelayUiEngine extends BeyondNetEngine {
  Completer<void> attempt = Completer<void>();
  int stops = 0;
  @override
  Future<void> startRelay() async {
    relayEnabled = true;
    notifyListeners();
    try {
      await attempt.future;
      relay = true;
    } catch (_) {
      relayEnabled = false;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  @override
  Future<void> stopRelay() async {
    stops++;
    relay = relayEnabled = false;
    relayBlocked = null;
    notifyListeners();
  }
}

void main() {
  test(
    'Platform exception dialogs use actionable copy instead of native stack traces',
    () {
      expect(
        userErrorMessage(
          PlatformException(
            code: 'IllegalStateException',
            message: 'java.lang.IllegalStateException Stacktrace: at es0.l',
          ),
        ),
        isNot(contains('Stacktrace')),
      );
      expect(
        userErrorMessage(
          PlatformException(
            code: 'relay',
            message: 'Turn Bluetooth on to resume relaying.',
          ),
        ),
        'Turn Bluetooth on to resume relaying.',
      );
    },
  );
  testWidgets(
    'Bank insufficient-funds rejection is prominent above delivery steps',
    (tester) async {
      final e = BeyondNetEngine();
      e.payments = [
        {
          'payment_id': 'rejected',
          'sender': 'sam@beyondnet',
          'recipient': 'shop@beyondnet',
          'amount': 1000,
          'created_at': 1,
          'expires_at': 2,
          'state': 'rejected',
          'transport': 'Bank signature verified',
          'receipt': {
            'reason': 'Insufficient demo balance',
            'bank_ref': 'OK-TEST',
            'committed_at': 3,
          },
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: PaymentDetails(engine: e, id: 'rejected'),
        ),
      );
      expect(find.text('Payment rejected'), findsOneWidget);
      expect(
        find.text('Insufficient demo balance').hitTestable(),
        findsOneWidget,
      );
      expect(find.text('On its way'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      e.dispose();
    },
  );
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

  BeyondNetEngine sample({
    bool online = false,
    bool merchant = false,
    BeyondNetEngine? engine,
  }) {
    final e = engine ?? BeyondNetEngine();
    e.profile = {
      'account': {
        'id': 'sam@beyondnet',
        'name': 'Sam',
        'role': merchant ? 'merchant' : 'customer',
        'balance': 0,
        'pin_configured': true,
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

  testWidgets(
    'Relay startup shows progress and failure unlocks the switch before dismissal',
    (tester) async {
      final e = RelayUiEngine();
      sample(engine: e);
      await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
      await tester.tap(find.text('Nearby'));
      await tester.pump();
      await scroll(tester, find.byType(SwitchListTile), 180);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(find.text('Starting nearby relay…'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      e.attempt.completeError(StateError('Bluetooth did not finish starting'));
      await tester.pumpAndSettle();
      expect(find.text('Needs your attention'), findsOneWidget);
      expect(find.text('Starting nearby relay…'), findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNotNull,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      e.attempt = Completer<void>();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      e.attempt.complete();
      await tester.pumpAndSettle();
      expect(find.text('Nearby relay is on'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Nearby relay is off'), findsOneWidget);
      expect(e.stops, 1);
      await tester.pumpWidget(const SizedBox());
      e.dispose();
    },
  );

  testWidgets('Home explains paused opt-in and lets the user turn it off', (
    tester,
  ) async {
    final e = RelayUiEngine();
    sample(engine: e);
    e.relayEnabled = true;
    e.relayBlocked = 'Turn Bluetooth on';
    await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
    await scroll(tester, find.byType(SwitchListTile), 180);
    expect(find.text('Relay paused: Turn Bluetooth on'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNotNull,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Nearby relay is off'), findsOneWidget);
    expect(e.stops, 1);
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

  testWidgets(
    'Online gateway only offers relay approval, not payer connection',
    (tester) async {
      final e = sample(online: true);
      e.nearby = [
        {'device_id': 'other', 'name': 'Alex', 'online': false},
      ];
      e.invitations = [
        {'id': 'a' * 64, 'name': 'Alex'},
      ];
      await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
      await tester.tap(find.text('Nearby'));
      await tester.pump();
      await scroll(tester, find.text('Allow relay'), 300);
      expect(find.text('Allow relay'), findsOneWidget);
      await scroll(tester, find.text('Alex'), 300);
      expect(find.text('Connect for payment'), findsNothing);
      expect(find.text('Connected · continue'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      e.dispose();
    },
  );

  testWidgets('Offline helper shows forwarding actions, not payer connection', (
    tester,
  ) async {
    final e = sample();
    e.nearby = [
      {'device_id': 'next', 'name': 'Alex', 'online': true},
    ];
    e.relayQueue = [
      {'id': 'a' * 64, 'source': 'previous', 'next_peer': null},
    ];
    await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
    await tester.tap(find.text('Nearby'));
    await tester.pump();
    await scroll(tester, find.text('Request Alex · internet on'), 300);
    expect(find.text('Request Alex · internet on'), findsOneWidget);
    await scroll(tester, find.text('Alex'), 300);
    expect(find.text('Connect for payment'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('Offline payer can select a relay for its own payment', (
    tester,
  ) async {
    final e = sample();
    e.nearby = [
      {'device_id': 'next', 'name': 'Alex', 'online': true},
    ];
    await tester.pumpWidget(MaterialApp(home: Shell(engine: e)));
    await tester.tap(find.text('Nearby'));
    await tester.pump();
    await scroll(tester, find.text('Connect for payment'), 300);
    expect(find.text('Connect for payment'), findsOneWidget);
    expect(find.text('Allow relay'), findsNothing);
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
