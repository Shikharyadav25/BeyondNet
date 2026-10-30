import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/demo_identity.dart';
import 'package:beyondnet/protocol.dart';

class SignupEngine extends BeyondNetEngine {
  int signups = 0;
  @override
  Future<Json> paymentIdChoices(
    String url,
    String fingerprint,
    String name,
    String id,
  ) async => {'suggestions': <String>[], 'valid': true, 'available': true};
  @override
  Future<void> enroll(
    String url,
    String id,
    String password,
    String fingerprint, {
    String? name,
    String? role,
  }) async {
    signups++;
  }
}

void main() {
  Future<void> reveal(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(
      f,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(f);
    await t.pumpAndSettle();
  }

  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Future<void> form(WidgetTester t, SignupEngine e) async {
    await t.pumpWidget(MaterialApp(home: LoginPage(engine: e)));
    expect(find.byType(DemoIdentityStep), findsNothing);
    for (final entry in {
      'Your name': 'Demo user',
      'Bank HTTPS URL': 'https://bank.example',
      'Payment ID': 'newuser@beyondnet',
      'Password (at least 8 characters)': 'demo-pass123',
      'Bank trust fingerprint': 'a' * 64,
    }.entries) {
      await reveal(t, field(entry.key));
      await t.enterText(field(entry.key), entry.value);
    }
    await reveal(t, find.text('Create account & continue'));
    await t.tap(find.text('Create account & continue'));
    await t.pumpAndSettle();
    expect(find.byType(DemoIdentityStep), findsOneWidget);
    expect(e.signups, 0);
  }

  testWidgets(
    'identity step follows completed signup and skip creates the account',
    (t) async {
      final e = SignupEngine();
      await form(t, e);
      await reveal(t, find.text('Skip for now'));
      await t.tap(find.text('Skip for now'));
      await t.pumpAndSettle();
      expect(e.signups, 1);
      expect(find.byType(DemoIdentityStep), findsNothing);
      await t.pumpWidget(const SizedBox());
      e.dispose();
    },
  );
  testWidgets('sample document continues to account creation', (t) async {
    final e = SignupEngine();
    await form(t, e);
    await reveal(t, find.byType(TextField));
    await t.enterText(find.byType(TextField), 'DEMO-1234');
    await t.pumpAndSettle();
    await reveal(t, find.text('Continue to BeyondNet'));
    await t.tap(find.text('Continue to BeyondNet'));
    await t.pumpAndSettle();
    expect(e.signups, 1);
    await t.pumpWidget(const SizedBox());
    e.dispose();
  });
  testWidgets(
    'all document options accept sample input without claiming verified status',
    (t) async {
      for (final document in [
        'Aadhaar',
        'Passport',
        'PAN card',
        'Driving licence',
      ]) {
        var continued = false;
        await t.pumpWidget(
          MaterialApp(
            home: DemoIdentityStep(
              key: ValueKey(document),
              onContinue: () => continued = true,
              onSkip: () {},
              onSignIn: () {},
            ),
          ),
        );
        await reveal(t, find.text(document));
        await t.tap(find.text(document));
        await t.pumpAndSettle();
        await reveal(t, find.byType(TextField));
        await t.enterText(find.byType(TextField), 'DEMO-1234');
        await t.pumpAndSettle();
        await reveal(t, find.text('Continue to BeyondNet'));
        await t.tap(find.text('Continue to BeyondNet'));
        await t.pumpAndSettle();
        expect(continued, isTrue);
      }
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('existing users can sign in without document setup', (t) async {
    final e = SignupEngine();
    await t.pumpWidget(MaterialApp(home: LoginPage(engine: e)));
    await reveal(t, find.text('Sign in'));
    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();
    expect(find.byType(DemoIdentityStep), findsNothing);
    await reveal(t, find.text('Sign in securely'));
    expect(find.text('Sign in securely'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    e.dispose();
  });
}
