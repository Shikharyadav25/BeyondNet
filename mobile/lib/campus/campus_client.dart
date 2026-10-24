import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'campus_protocol.dart';

class CampusClient {
  final http.Client httpClient;
  final FlutterSecureStorage secureStorage;
  Database? _db;
  bool _closed = false;
  final String? databasePath;
  String? url, publisherKey, token;
  CampusClient({
    http.Client? client,
    FlutterSecureStorage? storage,
    this.databasePath,
  }) : httpClient = client ?? http.Client(),
       secureStorage = storage ?? const FlutterSecureStorage();
  bool get configured =>
      !_closed && url != null && publisherKey != null && token != null;
  Future<void> init() async {
    _db = await openDatabase(
      databasePath ?? '${await getDatabasesPath()}/beyondnet-campus-v1.db',
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE cache (id INTEGER PRIMARY KEY, envelope TEXT NOT NULL)',
        );
      },
    );
    if (_closed) {
      await _db?.close();
      _db = null;
      return;
    }
    final saved = await secureStorage.read(key: 'campus_config_v1');
    if (saved != null) {
      final c = jsonDecode(saved);
      url = c['url'];
      publisherKey = c['key'];
      token = c['token'];
    }
  }

  Future<void> configure(String endpoint, String key, String credential) async {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Use the institution’s HTTPS campus server address.',
      );
    }
    if (base64Decode(key.trim()).length != 44 || credential.trim().isEmpty) {
      throw const FormatException(
        'Enter the campus publisher key and enrollment token.',
      );
    }
    // Explicit replacement clears the old institution’s public cache.
    await secureStorage.write(
      key: 'campus_config_v1',
      value: jsonEncode({
        'url': uri.origin,
        'key': key.trim(),
        'token': credential.trim(),
      }),
    );
    await _db!.delete('cache');
    url = uri.origin;
    publisherKey = key.trim();
    token = credential.trim();
  }

  Future<CampusJson> _request(
    String path, {
    CampusJson? body,
    int limit = 65536,
  }) async {
    if (!configured) throw const FormatException('Set up Campus first.');
    final request =
        http.Request(
            body == null ? 'GET' : 'POST',
            Uri.parse('$url/campus/v1/$path'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
    if (body != null) request.body = jsonEncode(body);
    final response = await httpClient
        .send(request)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw FormatException(
        'Campus service unavailable (${response.statusCode}).',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 12),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > limit) {
        throw const FormatException('Campus response exceeds the size limit.');
      }
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  Future<void> refresh() async {
    final signed = await _request('cache');
    final body = await CampusProtocol.verify(signed, publisherKey!);
    if (body['kind'] != 'public_cache' ||
        body['records'] is! List ||
        (body['records'] as List).length > 50) {
      throw const FormatException('Invalid public cache');
    }
    // Prevent rollback to an older signed snapshot while the previous cache is still stored.
    final previous = await _db!.query('cache', where: 'id=1');
    if (previous.isNotEmpty) {
      final old = jsonDecode(previous.first['envelope'] as String)['body'];
      if ((old['created_at'] as int) > (body['created_at'] as int)) {
        throw const FormatException('Older cache rejected');
      }
    }
    await _db!.insert('cache', {
      'id': 1,
      'envelope': jsonEncode(signed),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<CampusJson> search(String input, {int page = 0}) async {
    final query = CampusProtocol.query(input);
    if (!configured) throw const FormatException('Set up Campus first.');
    final rows = await _db!.query('cache', where: 'id=1');
    if (rows.isNotEmpty) {
      try {
        final cache = await CampusProtocol.verify(
          Map<String, dynamic>.from(
            jsonDecode(rows.first['envelope'] as String),
          ),
          publisherKey!,
        );
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final words = query.toLowerCase().split(RegExp(r'\s+'));
        final matches = (cache['records'] as List)
            .where(
              (r) =>
                  r['expires_at'] is int &&
                  r['expires_at'] > now &&
                  words.every(
                    (w) =>
                        '${r['title']} ${r['body']}'.toLowerCase().contains(w),
                  ),
            )
            .toList();
        if (matches.isNotEmpty) {
          return {
            'results': matches.skip(page * 3).take(3).toList(),
            'source': 'Verified on-phone cache',
            'created_at': cache['created_at'],
            'has_more': matches.length > (page + 1) * 3,
          };
        }
      } on FormatException {
        /* Expired or corrupted cache must never be displayed. */
      }
    }
    final id = const Uuid().v4();
    final signed = await _request(
      'search',
      body: {'request_id': id, 'query': query, 'page': page},
      limit: 4096,
    );
    final result = await CampusProtocol.verify(signed, publisherKey!);
    if (result['kind'] != 'search_result' ||
        result['request_id'] != id ||
        result['query'] != query ||
        result['page'] != page) {
      throw const FormatException('Campus response does not match your query');
    }
    return result;
  }

  Future<void> close() async {
    _closed = true;
    httpClient.close();
    await _db?.close();
  }
}
