import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:beyondnet/campus/campus_client.dart';
import 'package:beyondnet/campus/campus_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory directory;
  late SimpleKeyPair pair;
  late String key;
  late int now;
  Future<Map<String, dynamic>> sign(Map<String, dynamic> body) async {
    final signature = await Ed25519().sign([
      ...utf8.encode(CampusProtocol.domain),
      ...CampusProtocol.canonical(body),
    ], keyPair: pair);
    return {'body': body, 'signature': base64Encode(signature.bytes)};
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('campus-client-');
    pair = await Ed25519().newKeyPair();
    key = base64Encode([
      0x30,
      0x2a,
      0x30,
      0x05,
      0x06,
      0x03,
      0x2b,
      0x65,
      0x70,
      0x03,
      0x21,
      0x00,
      ...(await pair.extractPublicKey()).bytes,
    ]);
    now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'Verified cache persists across restart and answers without uplink',
    () async {
      final envelope = await sign({
        'v': 1,
        'kind': 'public_cache',
        'created_at': now,
        'expires_at': now + 86400,
        'records': [
          {
            'id': 'library',
            'title': 'Library',
            'body': 'Test information',
            'source': 'Test publisher',
            'updated_at': now,
            'expires_at': now + 1000,
          },
        ],
      });
      final client = CampusClient(
        databasePath: '${directory.path}/cache.db',
        client: MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer enrollment-token');
          return http.Response(jsonEncode(envelope), 200);
        }),
      );
      await client.init();
      await client.configure('https://campus.example', key, 'enrollment-token');
      await client.refresh();
      await client.close();
      final offline = CampusClient(
        databasePath: '${directory.path}/cache.db',
        client: MockClient((r) async => throw StateError('No connection')),
      );
      await offline.init();
      final result = await offline.search('library');
      expect(result['source'], 'Verified on-phone cache');
      expect((result['results'] as List).length, 1);
      await offline.close();
    },
  );
  test('Wrong query response and altered cache are rejected', () async {
    var cache = await sign({
      'v': 1,
      'kind': 'public_cache',
      'created_at': now,
      'expires_at': now + 100,
      'records': [],
    });
    cache['body']['records'] = [
      {'title': 'tampered'},
    ];
    final client = CampusClient(
      databasePath: '${directory.path}/cache.db',
      client: MockClient((r) async {
        if (r.method == 'GET') return http.Response(jsonEncode(cache), 200);
        final request = jsonDecode(r.body);
        return http.Response(
          jsonEncode(
            await sign({
              'v': 1,
              'kind': 'search_result',
              'created_at': now,
              'expires_at': now + 60,
              'request_id': request['request_id'],
              'query': 'wrong query',
              'page': 0,
              'results': [],
            }),
          ),
          200,
        );
      }),
    );
    await client.init();
    await client.configure('https://campus.example', key, 'token');
    await expectLater(client.refresh(), throwsFormatException);
    await expectLater(client.search('library'), throwsFormatException);
    await client.close();
  });
  test('Only an explicitly configured HTTPS origin is accepted', () async {
    final client = CampusClient(databasePath: '${directory.path}/cache.db');
    await client.init();
    for (final url in [
      'http://campus.example',
      'https://campus.example/proxy',
      'https://user@campus.example',
      'https://campus.example?url=internal',
    ]) {
      await expectLater(
        client.configure(url, key, 'token'),
        throwsFormatException,
      );
    }
    await client.close();
  });
}
