import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';

class IdEngine extends BeyondNetEngine {
  final pending = <String, Completer<Json>>{};
  bool delay = false;
  @override
  Future<Json> paymentIdChoices(
    String url,
    String fingerprint,
    String name,
    String id,
  ) async {
    if (delay) return (pending[id] = Completer<Json>()).future;
    return {
      'suggestions': [
        'shaurya23@beyondnet',
        'shaurya34@beyondnet',
        'shaurya12@beyondnet',
        'shaurya56@beyondnet',
      ],
      'valid': true,
      'available': id != 'taken@beyondnet',
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Future<void> reveal(WidgetTester t, String label) => t.scrollUntilVisible(
    field(label),
    180,
    scrollable: find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  Future<void> setup(WidgetTester t, IdEngine e) async {
    await t.pumpWidget(MaterialApp(home: LoginPage(engine: e)));
    await reveal(t, 'Your name');
    await t.enterText(field('Your name'), 'Shaurya');
    await reveal(t, 'Bank HTTPS URL');
    await t.enterText(field('Bank HTTPS URL'), 'https://bank.example');
    await reveal(t, 'Bank trust fingerprint');
    await t.enterText(field('Bank trust fingerprint'), 'a' * 64);
    await t.scrollUntilVisible(
      field('Payment ID'),
      -180,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }

  testWidgets(
    'suggestions can be selected and custom IDs are lowercased and checked',
    (t) async {
      final e = IdEngine();
      await setup(t, e);
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      expect(find.text('shaurya23@beyondnet'), findsOneWidget);
      await t.ensureVisible(find.text('shaurya23@beyondnet'));
      await t.tap(find.text('shaurya23@beyondnet'));
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      await t.scrollUntilVisible(
        field('Payment ID'),
        -120,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        t.widget<TextField>(field('Payment ID')).controller!.text,
        'shaurya23@beyondnet',
      );
      await t.enterText(field('Payment ID'), 'TAKEN@BEYONDNET');
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      await t.scrollUntilVisible(
        field('Payment ID'),
        -120,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        t.widget<TextField>(field('Payment ID')).controller!.text,
        'taken@beyondnet',
      );
      expect(find.text('Already taken. Choose another ID.'), findsOneWidget);
      await t.enterText(field('Payment ID'), 'custom55@beyondnet');
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      expect(find.text('Available — you can use this ID.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      e.dispose();
    },
  );
  testWidgets('old availability responses cannot overwrite a newer ID', (
    t,
  ) async {
    final e = IdEngine();
    await setup(t, e);
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    e.delay = true;
    await t.enterText(field('Payment ID'), 'first@beyondnet');
    await t.pump(const Duration(seconds: 1));
    await t.enterText(field('Payment ID'), 'second@beyondnet');
    await t.pump(const Duration(seconds: 1));
    e.pending['second@beyondnet']!.complete({
      'suggestions': <String>[],
      'valid': true,
      'available': true,
    });
    await t.pump();
    e.pending['first@beyondnet']!.complete({
      'suggestions': <String>[],
      'valid': true,
      'available': false,
    });
    await t.pump();
    expect(find.text('Available — you can use this ID.'), findsOneWidget);
    expect(find.text('Already taken. Choose another ID.'), findsNothing);
    await t.pumpWidget(const SizedBox());
    e.dispose();
  });
  test('unverified banks receive no name or payment ID', () async {
    final paths = <String>[];
    final e = BeyondNetEngine(
      client: MockClient((r) async {
        paths.add(r.url.path);
        return http.Response(
          jsonEncode({
            'sign_key': 'bad',
            'box_key': 'bad',
            'mesh_id': 'bad',
            'fingerprint': 'bad',
          }),
          200,
        );
      }),
    );
    await expectLater(
      e.paymentIdChoices(
        'https://bank.example',
        'a' * 64,
        'Shaurya',
        'test@beyondnet',
      ),
      throwsStateError,
    );
    expect(paths, ['/api/health']);
    e.dispose();
  });
}
