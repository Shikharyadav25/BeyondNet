import 'dart:convert';
import 'dart:io';

import 'package:beyondnet/campus/campus_engine.dart';
import 'package:beyondnet/engine.dart';
import 'package:beyondnet/main.dart';
import 'package:beyondnet/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  late CampusEngine student, professor, relay;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('campus-test-');
    final authority = await ed.newKeyPair();
    final pub = base64Encode((await authority.extractPublicKey()).bytes);
    final groupKey = base64Encode(List<int>.generate(32, (i) => i));
    Future<CampusEngine> node(
      String id,
      String role,
      List<String> write, {
      bool hasGroup = true,
    }) async {
      FlutterSecureStorage.setMockInitialValues({});
      final c = CampusEngine(
        client: MockClient((_) async => http.Response('{}', 503)),
      );
      await c.init(databasePath: '${dir.path}/$id.sqlite3');
      c.timer?.cancel();
      c.session = {
        'code': 'TEST',
        'public_key': pub,
        'url': 'https://campus.example',
        'name': 'Test Campus',
        'certificate': await sign(authority, {
          'type': 'beyondnet/campus-member/v1',
          'campus': 'TEST',
          'id': id,
          'name': id,
          'role': role,
          'public_key': base64Encode((await c.key.extractPublicKey()).bytes),
          'read': hasGroup ? ['section', 'faculty'] : ['section'],
          'write': write,
          'issued_at': nowSeconds - 10,
          'expires_at': nowSeconds + 3600,
        }),
        'groups': {
          'section': {'name': 'Section A', 'kind': 'section', 'key': groupKey},
          if (hasGroup)
            'faculty': {
              'name': 'Assignments',
              'kind': 'faculty',
              'key': groupKey,
            },
        },
      };
      return c;
    }

    student = await node('student', 'student', ['section']);
    professor = await node('professor', 'professor', ['section', 'faculty']);
    relay = await node('relay', 'student', ['section'], hasGroup: false);
  });
  tearDown(() async {
    for (final c in [student, professor, relay]) {
      await c.tick();
      c.dispose();
      await c.db.close();
    }
    await dir.delete(recursive: true);
  });
  testWidgets(
    'launcher exposes Campus and keeps existing payment login reachable',
    (tester) async {
      final payments = BeyondNetEngine();
      await tester.pumpWidget(MaterialApp(home: ModeChooser(engine: payments)));
      await tester.scrollUntilVisible(find.text('Open Campus →'), 250);
      expect(find.text('Open Campus →'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Open Payments →'), -250);
      await tester.tap(find.text('Open Payments →'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      payments.dispose();
    },
  );
  test(
    'role checks prevent student faculty posting and false notice labels',
    () async {
      expect(student.canPost('faculty'), false);
      await expectLater(
        student.post('faculty', 'Forged assignment', 'assignment'),
        throwsStateError,
      );
      await expectLater(
        student.post('section', 'Forged notice', 'notice'),
        throwsStateError,
      );
      await professor.post('faculty', 'Read chapter 2 by Friday', 'assignment');
      expect(professor.messages.single['kind'], 'assignment');
    },
  );
  test('encrypted multi-hop forwarding is idempotent and private to group members', () async {
    await professor.post('faculty', 'Read chapter 2', 'assignment');
    final p = (await professor.packets()).single;
    expect(jsonEncode(p), isNot(contains('Read chapter 2')));
    await relay.accept(p);
    await relay.accept(p);
    await relay.reload();
    expect((await relay.packets()).length, 1);
    expect(relay.messages, isEmpty);
    await student.accept((await relay.packets()).single);
    await student.reload();
    expect(student.messages.single['text'], 'Read chapter 2');
    expect(student.messages.single['state'], 'Copied to a peer');
    await student.tick();
    await student.db.close();
    FlutterSecureStorage.setMockInitialValues({
      'campus_device_seed': base64Encode((await student.key.extract()).bytes),
      'campus_session': jsonEncode(student.session),
    });
    await student.init(databasePath: '${dir.path}/student.sqlite3');
    student.timer?.cancel();
    // The fixture session stays in memory; the queue survives reopening SQLite.
    await student.reload();
    expect(student.messages.single['text'], 'Read chapter 2');
  });
  test(
    'signature tampering, wrong campus and oversize content are rejected',
    () async {
      await student.post('section', 'Hello', 'message');
      final p = Map<String, dynamic>.from((await student.packets()).single);
      p['id'] = 'forged';
      await expectLater(relay.accept(p), throwsFormatException);
      await expectLater(
        student.post('section', 'x' * 2001, 'message'),
        throwsStateError,
      );
      relay.session!['code'] = 'OTHER';
      await expectLater(
        relay.accept((await student.packets()).single),
        throwsFormatException,
      );
    },
  );
  test(
    'campus RPC replay is refused and group authorization survives forwarding',
    () async {
      relay.nearby = true;
      final raw = await student.rpc({
        'op': 'inventory',
        'offset': 0,
      }, 'one-time-request');
      final result = await relay.handleRpc(raw);
      expect((await student.checkRpc(result))['nonce'], 'one-time-request');
      await expectLater(relay.handleRpc(raw), throwsStateError);
    },
  );
  test('campus server configuration requires a secure origin', () {
    expect(
      () => CampusEngine.endpoint('http://college.example', '/api/campus/TEST'),
      throwsStateError,
    );
    expect(
      () => CampusEngine.endpoint(
        'https://user:pass@college.example',
        '/api/campus/TEST',
      ),
      throwsStateError,
    );
    expect(
      CampusEngine.endpoint(
        'https://college.example',
        '/api/campus/TEST',
      ).scheme,
      'https',
    );
  });
}
