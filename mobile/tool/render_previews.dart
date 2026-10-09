// Render real Flutter widgets with sample display data. These are UI previews,
// not screenshots from a hardware payment. Run as described in docs/DEVELOPMENT.md.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/protocol.dart';

void main() {
  testWidgets('Render phone UI previews', (tester) async {
    final font = Platform.environment['KARO_PREVIEW_FONT'];
    if (font == null) {
      throw StateError(
        'Set KARO_PREVIEW_FONT to Roboto-Regular.ttf in your Flutter SDK',
      );
    }
    await (FontLoader('PreviewRoboto')..addFont(
          Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
        ))
        .load();
    final icons = File('${File(font).parent.path}/MaterialIcons-Regular.otf');
    await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync()))))
        .load();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final e = BeyondNetEngine();
    e.profile = {
      'device_id': 'sample-device',
      'account': {
        'id': 'sam@beyondnet',
        'role': 'customer',
        'name': 'Aanya Sharma',
        'balance': 87500,
        'revision': 1,
      },
      'balance_checked_at': nowSeconds,
      'bank_url': 'https://your-bank.example',
      'trust': {'fingerprint': 'a' * 64},
    };
    e.relay = true;
    e.queueSize = 2;
    e.payments = [
      {
        'payment_id': 'preview-payment',
        'sender': 'alice@karo',
        'recipient': 'chai@karo',
        'name': 'Chai & Co.',
        'amount': 12500,
        'state': 'paid',
        'transport': 'Bank signature verified',
        'created_at': nowSeconds - 20,
        'expires_at': nowSeconds + 880,
        'receipt': {'bank_ref': 'OK-PREVIEW', 'committed_at': nowSeconds},
      },
    ];
    final key = GlobalKey();
    Future<void> capture(Widget page, String name) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'PreviewRoboto',
              scaffoldBackgroundColor: canvas,
              colorScheme: ColorScheme.fromSeed(
                seedColor: teal,
                primary: teal,
                surface: Colors.white,
              ),
              appBarTheme: const AppBarTheme(
                backgroundColor: canvas,
                foregroundColor: ink,
              ),
              textTheme: const TextTheme(
                headlineMedium: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: ink,
                  letterSpacing: -.7,
                ),
                headlineLarge: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: ink,
                  letterSpacing: -1.2,
                ),
              ),
              inputDecorationTheme: InputDecorationTheme(
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('../docs/screenshots/$name.png');
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    e.internet = true;
    e.bankReachable = true;
    await capture(Shell(engine: e), 'phone-home-preview');
    await capture(AddMoneyPage(engine: e), 'phone-funding-preview');
    e.internet = false;
    e.bankReachable = false;
    await capture(Shell(engine: e), 'phone-offline-preview');
    e.profile!['account']['role'] = 'merchant';
    e.internet = true;
    e.bankReachable = true;
    await capture(Shell(engine: e), 'phone-merchant-preview');
    await capture(
      PaymentDetails(engine: e, id: 'preview-payment'),
      'phone-receipt-preview',
    );
    await capture(
      LoginPage(engine: BeyondNetEngine()),
      'phone-enrollment-preview',
    );
  });
}
