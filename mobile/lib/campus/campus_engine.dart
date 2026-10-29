import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../ble_transport.dart';
import '../protocol.dart';

/// An independent campus identity, database, encrypted queue and BLE namespace.
class CampusEngine extends ChangeNotifier {
  final http.Client client;
  final FlutterSecureStorage secure;
  CampusEngine({
    http.Client? client,
    this.secure = const FlutterSecureStorage(),
  }) : client = client ?? http.Client();
  late Database db;
  late SimpleKeyPair key;
  Json? session;
  Json? discoveredCampus;
  String status = 'Connect to your college once to enroll.';
  List<Json> messages = [];
  bool busy = false, nearby = false;
  bool _ticking = false, _disposed = false;
  Completer<void>? _tickDone;
  Timer? timer;
  BleTransport? _radio;
  BleTransport get radio =>
      _radio ??= BleTransport(handleRpc, (_) {}, campus: true);
  Json get member => Map<String, dynamic>.from(session!['certificate']['body']);
  Json get groups => Map<String, dynamic>.from(session!['groups']);
  bool get enrolled => session != null && member['expires_at'] > nowSeconds;
  String get campus => session!['code'];
  String get authority => session!['public_key'];
  Future<void> init({String? databasePath}) async {
    db = await openDatabase(
      databasePath ??
          '${(await getApplicationSupportDirectory()).path}/beyondnet-campus.sqlite3',
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE packets(id TEXT PRIMARY KEY, campus TEXT NOT NULL, expiry INTEGER NOT NULL, data TEXT NOT NULL, state TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE config(id TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
    );
    final seed = await secure.read(key: 'campus_device_seed');
    key = seed == null
        ? await ed.newKeyPair()
        : await ed.newKeyPairFromSeed(base64Decode(seed));
    if (seed == null)
      await secure.write(
        key: 'campus_device_seed',
        value: base64Encode((await key.extract()).bytes),
      );
    final saved = await secure.read(key: 'campus_session');
    if (saved != null) session = Map<String, dynamic>.from(jsonDecode(saved));
    await reload();
    timer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(tick()),
    );
  }

  static Uri endpoint(String url, String path) {
    final u = Uri.parse(url.trim());
    if (u.scheme != 'https' ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        (u.path.isNotEmpty && u.path != '/')) {
      throw StateError(
        'Use your college’s HTTPS server origin, without a path.',
      );
    }
    return u.replace(path: path);
  }

  Future<Json> api(String url, String path, [Json? body]) async {
    final uri = endpoint(url, path);
    final response =
        await (body == null
                ? client.get(uri)
                : client.post(
                    uri,
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 12));
    if (response.bodyBytes.length > 16384)
      throw StateError('Campus response too large.');
    final result = Map<String, dynamic>.from(jsonDecode(response.body));
    if (response.statusCode != 200)
      throw StateError(result['detail'] ?? 'Campus service unavailable');
    return result;
  }

  Future<void> discover(String url, String code, String fingerprint) async {
    code = code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9-]{3,32}$').hasMatch(code))
      throw StateError('Enter your college campus code.');
    final c = await api(url, '/api/campus/$code');
    final hash = hex(
      (await Sha256().hash(base64Decode(c['public_key']))).bytes,
    );
    if (hash != fingerprint.trim().toLowerCase())
      throw StateError(
        'Campus fingerprint does not match. Check the details with your college.',
      );
    discoveredCampus = {...c, 'url': url.trim()};
    if (!_disposed) notifyListeners();
  }

  Future<void> enroll(String id, String password, String role) async {
    final c = discoveredCampus!;
    final result = await api(c['url'], '/api/campus/enroll', {
      'code': c['code'],
      'id': id.trim(),
      'password': password,
      'public_key': base64Encode((await key.extractPublicKey()).bytes),
    });
    final body = await verify(
      c['public_key'],
      Map<String, dynamic>.from(result['certificate']),
    );
    if (body['campus'] != c['code'] ||
        body['id'] != id.trim() ||
        body['role'] != role ||
        body['public_key'] !=
            base64Encode((await key.extractPublicKey()).bytes) ||
        body['expires_at'] <= nowSeconds)
      throw StateError(
        'Your college roster does not match this role or device.',
      );
    session = {
      ...result,
      'code': c['code'],
      'url': c['url'],
      'public_key': c['public_key'],
    };
    await secure.write(key: 'campus_session', value: jsonEncode(session));
    await reload();
  }

  bool canPost(String group) =>
      enrolled && (member['write'] as List).contains(group);
  Future<Json> validate(Json p) async {
    if (canonical(p).length > 8192 || await digest(p['signed']) != p['id'])
      throw const FormatException('Invalid campus packet');
    final cert = await verify(
      authority,
      Map<String, dynamic>.from(p['certificate']),
    );
    if (cert['type'] != 'beyondnet/campus-member/v1' ||
        cert['campus'] != campus ||
        cert['expires_at'] <= nowSeconds)
      throw const FormatException('Invalid campus membership');
    final b = await verify(
      cert['public_key'],
      Map<String, dynamic>.from(p['signed']),
    );
    if (b['type'] != 'beyondnet/campus-message/v1' ||
        ![0, 1].contains(b['priority']) ||
        (b['priority'] == 1 && !['hod', 'authority'].contains(cert['role'])) ||
        b['campus'] != campus ||
        !(cert['write'] as List).contains(b['group']) ||
        !(cert['read'] as List).contains(b['group']) ||
        b['expires_at'] <= nowSeconds ||
        b['expires_at'] > cert['expires_at'] ||
        b['expires_at'] > b['created_at'] + 86400 ||
        b['expires_at'] <= b['created_at'] ||
        b['created_at'] < cert['issued_at'] ||
        b['created_at'] > nowSeconds + 120)
      throw const FormatException(
        'Invalid campus message permissions or lifetime',
      );
    return b;
  }

  Future<void> accept(Json p, {String state = 'Copied to a peer'}) async {
    final b = await validate(p);
    await db.transaction((tx) async {
      await tx.delete('packets', where: 'expiry <= ?', whereArgs: [nowSeconds]);
      final exists = await tx.query(
        'packets',
        columns: ['id'],
        where: 'id=?',
        whereArgs: [p['id']],
      );
      if (exists.isNotEmpty) return;
      if ((Sqflite.firstIntValue(
                await tx.rawQuery('SELECT COUNT(*) FROM packets'),
              ) ??
              0) >=
          512)
        throw StateError('Campus cache full; wait for messages to expire.');
      await tx.insert('packets', {
        'id': p['id'],
        'campus': campus,
        'expiry': b['expires_at'],
        'data': jsonEncode(p),
        'state': state,
        'priority': b['priority'],
      });
    });
  }

  Future<void> post(String group, String text, String kind) async {
    if (!canPost(group)) throw StateError('Your campus role cannot post here.');
    text = text.trim();
    if (text.isEmpty ||
        utf8.encode(text).length > 2000 ||
        !['message', 'assignment', 'notice'].contains(kind))
      throw StateError('Enter up to 2,000 bytes of text.');
    final g = Map<String, dynamic>.from(groups[group]);
    if ((kind == 'assignment' && member['role'] == 'student') ||
        (kind == 'notice' && !['hod', 'authority'].contains(member['role'])))
      throw StateError('Your campus role cannot publish this type.');
    final aad = canonical({
      'campus': campus,
      'group': group,
      'type': 'beyondnet/campus-content/v1',
    });
    final box = await AesGcm.with256bits().encrypt(
      canonical({'text': text, 'kind': kind}),
      secretKey: SecretKey(base64Decode(g['key'])),
      aad: aad,
    );
    final signed = await sign(key, {
      'type': 'beyondnet/campus-message/v1',
      'campus': campus,
      'group': group,
      'created_at': nowSeconds,
      'expires_at': member['expires_at'],
      'nonce_id': randomCapability(),
      'priority': kind == 'notice' ? 1 : 0,
      'box': {
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
      },
    });
    await accept({
      'id': await digest(signed),
      'certificate': session!['certificate'],
      'signed': signed,
    }, state: 'Saved locally');
    await reload();
    unawaited(tick());
  }

  Future<void> reload() async {
    messages = [];
    if (session != null) {
      for (final row in await db.query(
        'packets',
        where: 'campus=? AND expiry>?',
        whereArgs: [campus, nowSeconds],
      )) {
        try {
          final p = Map<String, dynamic>.from(
            jsonDecode(row['data'] as String),
          );
          final b = await validate(p);
          if (!groups.containsKey(b['group'])) continue;
          final box = b['box'], ct = base64Decode(box['ciphertext']);
          final content = await AesGcm.with256bits().decrypt(
            SecretBox(
              ct.sublist(0, ct.length - 16),
              nonce: base64Decode(box['nonce']),
              mac: Mac(ct.sublist(ct.length - 16)),
            ),
            secretKey: SecretKey(base64Decode(groups[b['group']]['key'])),
            aad: canonical({
              'campus': campus,
              'group': b['group'],
              'type': 'beyondnet/campus-content/v1',
            }),
          );
          final plain = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(content)),
          );
          final sender = p['certificate']['body'];
          if (plain['kind'] == 'assignment' && sender['role'] == 'student' ||
              plain['kind'] == 'notice' &&
                  !['hod', 'authority'].contains(sender['role']))
            continue;
          messages.add({
            ...b,
            ...plain,
            'id': p['id'],
            'sender': sender['name'],
            'role': sender['role'],
            'state': row['state'],
          });
        } catch (_) {
          /* Invalid or inaccessible data never enters the feed. */
        }
      }
      messages.sort((a, b) {
        final priority = (b['kind'] == 'notice' ? 1 : 0).compareTo(
          a['kind'] == 'notice' ? 1 : 0,
        );
        return priority != 0
            ? priority
            : (a['created_at'] as int).compareTo(b['created_at'] as int);
      });
    }
    if (!_disposed) notifyListeners();
  }

  Future<List<Json>> packets() async =>
      (await db.query(
            'packets',
            where: 'campus=? AND expiry>?',
            whereArgs: [campus, nowSeconds],
            orderBy: 'priority DESC,id',
          ))
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String)),
          )
          .toList();
  Future<Json> rpc(Json command, String nonce) async => {
    'certificate': session!['certificate'],
    'signed': await sign(key, {
      'type': 'beyondnet/campus-rpc/v1',
      'campus': campus,
      'at': nowSeconds,
      'nonce': nonce,
      'command': command,
    }),
  };
  final Map<String, int> _replays = {};
  Future<Json> checkRpc(Json raw) async {
    if (!enrolled) throw StateError('Renew campus access online.');
    final cert = await verify(
      authority,
      Map<String, dynamic>.from(raw['certificate']),
    );
    if (cert['type'] != 'beyondnet/campus-member/v1' ||
        cert['campus'] != campus ||
        cert['expires_at'] <= nowSeconds)
      throw StateError('Wrong campus or expired membership.');
    final b = await verify(
      cert['public_key'],
      Map<String, dynamic>.from(raw['signed']),
    );
    if (b['type'] != 'beyondnet/campus-rpc/v1' ||
        b['campus'] != campus ||
        (b['at'] - nowSeconds).abs() > 120 ||
        b['nonce'] is! String ||
        (b['nonce'] as String).length > 100)
      throw StateError('Invalid campus RPC.');
    return b;
  }

  Future<Json> handleRpc(Json raw) async {
    if (!nearby) throw StateError('Campus nearby relay is off.');
    final b = await checkRpc(raw);
    _replays.removeWhere((_, expiry) => expiry < nowSeconds);
    final replay = '${raw['certificate']['body']['public_key']}:${b['nonce']}';
    if (_replays.containsKey(replay) || _replays.length >= 1024)
      throw StateError('Repeated or excessive campus request.');
    _replays[replay] = nowSeconds + 240;
    final cmd = Map<String, dynamic>.from(b['command']);
    Json result;
    switch (cmd['op']) {
      case 'inventory':
        final offset = cmd['offset'];
        if (offset is! int || offset < 0 || offset > 512)
          throw StateError('Invalid inventory cursor');
        final all = await packets();
        result = {
          'ids': all.skip(offset).take(16).map((p) => p['id']).toList(),
          'next': offset + 16 < all.length ? offset + 16 : 0,
        };
      case 'get':
        final found = (await packets())
            .where((p) => p['id'] == cmd['id'])
            .firstOrNull;
        result = {'packet': found};
      case 'offer':
        await accept(Map<String, dynamic>.from(cmd['packet']));
        await reload();
        result = {'accepted': cmd['packet']['id']};
      default:
        throw StateError('Unknown campus command');
    }
    return rpc(result, b['nonce']);
  }

  Future<void> startNearby() async {
    if (!enrolled)
      throw StateError('Enroll or renew campus access online first.');
    try {
      await radio.start();
      nearby = true;
      status = 'Campus Bluetooth on · keep Campus open';
    } catch (_) {
      await radio.stop();
      rethrow;
    }
    if (!_disposed) notifyListeners();
    unawaited(tick());
  }

  Future<void> stopNearby() async {
    nearby = false;
    await _radio?.stop();
    if (!_disposed) notifyListeners();
  }

  int peerRound = 0;
  final Map<String, int> offsets = {};
  final Map<String, int> offers = {};
  Future<void> tick() async {
    if (_ticking) return _tickDone!.future;
    if (!enrolled || _disposed) return;
    _ticking = true;
    final done = _tickDone = Completer<void>();
    try {
      final pending = await db.query(
        'packets',
        where: "campus=? AND expiry>? AND state!='Server accepted'",
        whereArgs: [campus, nowSeconds],
        limit: 1,
        orderBy: 'priority DESC,rowid',
      );
      final cursorKey = 'cursor:$campus';
      final saved = await db.query(
        'config',
        where: 'id=?',
        whereArgs: [cursorKey],
      );
      final cursor = saved.isEmpty
          ? 0
          : int.parse(saved.first['value'] as String);
      final rid = randomCapability();
      try {
        final result = await api(session!['url'], '/api/campus/sync', {
          'code': campus,
          'certificate': session!['certificate'],
          'request': await sign(key, {
            'type': 'beyondnet/campus-sync/v1',
            'campus': campus,
            'at': nowSeconds,
            'request_id': rid,
            'after': cursor,
            'packet': pending.isEmpty
                ? null
                : jsonDecode(pending.first['data'] as String),
          }),
        });
        final body = await verify(authority, result);
        if (body['type'] != 'beyondnet/campus-receipt/v1' ||
            body['request_id'] != rid ||
            body['after'] is! int ||
            body['after'] < cursor)
          throw StateError('Invalid campus receipt');
        if (body['packet'] != null)
          await accept(
            Map<String, dynamic>.from(body['packet']),
            state: 'Server accepted',
          );
        await db.transaction((tx) async {
          if (pending.isNotEmpty && body['accepted'] == pending.first['id'])
            await tx.update(
              'packets',
              {'state': 'Server accepted'},
              where: 'id=?',
              whereArgs: [body['accepted']],
            );
          await tx.insert('config', {
            'id': cursorKey,
            'value': '${body['after']}',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        });
        status = 'Campus server synchronized';
      } catch (_) {
        status = nearby
            ? 'Server unavailable · carrying messages nearby'
            : 'Server unavailable · messages saved on this phone';
      }
      if (nearby && radio.running) {
        final peers = radio.discovered.values
            .where((p) => DateTime.now().difference(p.seen).inSeconds < 30)
            .toList();
        if (peers.isNotEmpty) {
          final peer = peers[peerRound++ % peers.length],
              peerId = peers[(peerRound - 1) % peers.length].peripheral.uuid
                  .toString();
          try {
            await radio.connect(peer, (send) async {
              Future<Json> call(Json cmd) async {
                final nonce = randomCapability();
                final b = await checkRpc(await send(await rpc(cmd, nonce)));
                if (b['nonce'] != nonce)
                  throw StateError('Campus response mismatch');
                return Map<String, dynamic>.from(b['command']);
              }

              final inventory = await call({
                'op': 'inventory',
                'offset': offsets[peerId] ?? 0,
              });
              final ids = (inventory['ids'] as List).cast<String>();
              if (ids.length > 16) throw StateError('Invalid inventory');
              offsets[peerId] = inventory['next'] as int;
              final local = await packets();
              final known = local.map((p) => p['id']).toSet();
              for (final id in ids.where((id) => !known.contains(id)).take(2)) {
                final r = await call({'op': 'get', 'id': id});
                if (r['packet'] != null)
                  await accept(Map<String, dynamic>.from(r['packet']));
              }
              if (local.isNotEmpty) {
                final index = (offers[peerId] ?? 0) % local.length;
                offers[peerId] = index + 1;
                final p = local[index];
                final result = await call({'op': 'offer', 'packet': p});
                if (result['accepted'] == p['id'])
                  await db.update(
                    'packets',
                    {'state': 'Copied to a peer'},
                    where: "id=? AND state='Saved locally'",
                    whereArgs: [p['id']],
                  );
              }
            });
          } catch (_) {
            /* Bounded radio failures retry on a later tick. */
          }
        }
      }
      await reload();
    } catch (_) {
      status = 'Campus sync interrupted · saved messages will retry';
      if (!_disposed) notifyListeners();
    } finally {
      _ticking = false;
      done.complete();
    }
  }

  Future<void> leave() async {
    await stopNearby();
    if (_ticking) await _tickDone!.future;
    session = null;
    await secure.delete(key: 'campus_session');
    await db.delete('packets');
    await db.delete('config');
    await reload();
  }

  @override
  void dispose() {
    _disposed = true;
    timer?.cancel();
    nearby = false;
    if (_radio != null) unawaited(_radio!.stop());
    client.close();
    super.dispose();
  }
}
