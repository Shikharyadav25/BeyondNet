import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'protocol.dart';

class LocalStore {
  late Database db;
  Future<void> init({String? databasePath}) async {
    final path =
        databasePath ??
        '${(await getApplicationSupportDirectory()).path}/offline-karo.sqlite3';
    db = await openDatabase(
      path,
      version: 5,
      onConfigure: (db) async {
        // This assignment returns a row. Android's execSQL rejects statements
        // with results, so use the query path even though it sets a value.
        await db.rawQuery('PRAGMA busy_timeout=5000');
        await db.execute('PRAGMA synchronous=FULL');
      },
      onUpgrade: (db, old, _) async {
        if (old < 2) await _createRelayTables(db);
        if (old < 3) {
          await db.execute('ALTER TABLE packets ADD COLUMN source TEXT');
        }
        if (old < 4) await _createReplayTable(db);
        if (old < 5) await _createInvitationTables(db);
      },
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE packets(id TEXT PRIMARY KEY, data TEXT NOT NULL, expiry INTEGER NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0, source TEXT)',
        );
        await db.execute(
          'CREATE TABLE payments(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE receipts(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, text TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE config(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE peers(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
        );
        await _createRelayTables(db);
        await _createReplayTable(db);
        await _createInvitationTables(db);
      },
    );
  }

  static Future<void> _createReplayTable(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE rpc_replays(peer TEXT NOT NULL, request TEXT NOT NULL, expiry INTEGER NOT NULL, PRIMARY KEY(peer,request))',
    );
    await db.execute('CREATE INDEX rpc_replays_expiry ON rpc_replays(expiry)');
  }

  /// Claim before executing a command. Persist through its entire signed clock
  /// window, including future-dated requests. Never evict still-valid claims.
  Future<void> claimRpc(String peer, String request, int at, {int? now}) async {
    final clock = now ?? nowSeconds;
    if (request.isEmpty || request.length > 80 || (at - clock).abs() > 120) {
      throw StateError('Invalid or expired peer request');
    }
    await db.transaction((tx) async {
      final watermark = await tx.query(
        'config',
        where: 'key=?',
        whereArgs: ['rpc_clock_watermark'],
      );
      if (watermark.isNotEmpty &&
          clock < int.parse(watermark.single['value'] as String)) {
        throw StateError(
          'Device clock moved backwards. Correct the time before relaying.',
        );
      }
      await tx.delete('rpc_replays', where: 'expiry<?', whereArgs: [clock]);
      if ((await tx.query(
        'rpc_replays',
        where: 'peer=? AND request=?',
        whereArgs: [peer, request],
      )).isNotEmpty) {
        throw StateError('Replayed peer request');
      }
      final total = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COUNT(*) FROM rpc_replays'),
      )!;
      final perPeer = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COUNT(*) FROM rpc_replays WHERE peer=?', [
          peer,
        ]),
      )!;
      if (total >= 4096 || perPeer >= 256) {
        throw StateError(
          'Peer request limit. Retry after the replay window expires.',
        );
      }
      await tx.insert('rpc_replays', {
        'peer': peer,
        'request': request,
        'expiry': at + 120,
      });
      await tx.insert('config', {
        'key': 'rpc_clock_watermark',
        'value': '$clock',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static Future<void> _createRelayTables(DatabaseExecutor db) => db.execute(
    'CREATE TABLE IF NOT EXISTS relay_acks(packet TEXT NOT NULL, peer TEXT NOT NULL, hops INTEGER NOT NULL, expiry INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(packet,peer))',
  );

  static Future<void> _createInvitationTables(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE relay_invitations(id TEXT PRIMARY KEY, source TEXT NOT NULL, name TEXT NOT NULL, data TEXT NOT NULL, expiry INTEGER NOT NULL, state TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE relay_routes(packet TEXT PRIMARY KEY, next_peer TEXT NOT NULL)',
    );
  }

  Future<String> invite(Json packet, String source, String name) async {
    await checkPacket(packet);
    if (packet['expires_at'] <= nowSeconds) {
      throw StateError('Payment request expired');
    }
    return db.transaction((tx) async {
      if ((await tx.query(
        'packets',
        where: 'id=?',
        whereArgs: [packet['id']],
      )).isNotEmpty) {
        return 'accepted';
      }
      final existing = await tx.query(
        'relay_invitations',
        where: 'id=?',
        whereArgs: [packet['id']],
      );
      if (existing.isNotEmpty) return existing.single['state'] as String;
      final count = Sqflite.firstIntValue(
        await tx.rawQuery(
          "SELECT COUNT(*) FROM relay_invitations WHERE state='pending'",
        ),
      )!;
      final fromPeer = Sqflite.firstIntValue(
        await tx.rawQuery(
          "SELECT COUNT(*) FROM relay_invitations WHERE state='pending' AND source=?",
          [source],
        ),
      )!;
      if (count >= 40 || fromPeer >= 8) {
        throw StateError('Too many relay invitations');
      }
      await tx.insert('relay_invitations', {
        'id': packet['id'],
        'source': source,
        'name': name.length > 80 ? name.substring(0, 80) : name,
        'data': jsonEncode(packet),
        'expiry': packet['expires_at'],
        'state': 'pending',
      });
      return 'new';
    });
  }

  Future<List<Json>> invitations() async => (await db.query(
    'relay_invitations',
    where: "state='pending' AND expiry>?",
    whereArgs: [nowSeconds],
    orderBy: 'rowid DESC',
  )).map((r) => Map<String, dynamic>.from(r)).toList();

  Future<Json?> decideInvitation(String id, bool allow) async {
    return db.transaction((tx) async {
      final rows = await tx.query(
        'relay_invitations',
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty || rows.single['state'] != 'pending') return null;
      final row = rows.single;
      if ((row['expiry'] as int) <= nowSeconds) {
        await tx.update(
          'relay_invitations',
          {'state': 'expired'},
          where: 'id=?',
          whereArgs: [id],
        );
        return null;
      }
      final packet = Map<String, dynamic>.from(
        jsonDecode(row['data'] as String),
      );
      if (allow) {
        final count = Sqflite.firstIntValue(
          await tx.rawQuery('SELECT COUNT(*) FROM packets'),
        )!;
        final used = Sqflite.firstIntValue(
          await tx.rawQuery(
            'SELECT COALESCE(SUM(LENGTH(data)),0) FROM packets',
          ),
        )!;
        final peerCount = Sqflite.firstIntValue(
          await tx.rawQuery('SELECT COUNT(*) FROM packets WHERE source=?', [
            row['source'],
          ]),
        )!;
        if (count >= 900 ||
            used + canonical(packet).length > 8 * 1024 * 1024 ||
            peerCount >= 100) {
          throw StateError(
            'Relay storage is full. Decline or try again later.',
          );
        }
        // Store and approve in one SQLite transaction. A sender only treats an
        // accepted inventory entry as custody once this transaction commits.
        await tx.insert('packets', {
          'id': id,
          'data': jsonEncode(packet),
          'expiry': packet['expires_at'],
          'uploaded': 0,
          'source': row['source'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await tx.update(
        'relay_invitations',
        {'state': allow ? 'accepted' : 'declined'},
        where: 'id=?',
        whereArgs: [id],
      );
      return packet;
    });
  }

  Future<void> chooseRoute(String packet, String peer) => db.insert(
    'relay_routes',
    {'packet': packet, 'next_peer': peer},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> clearRoute(String packet) =>
      db.delete('relay_routes', where: 'packet=?', whereArgs: [packet]);

  Future<String?> route(String packet) async {
    final rows = await db.query(
      'relay_routes',
      where: 'packet=?',
      whereArgs: [packet],
    );
    return rows.isEmpty ? null : rows.single['next_peer'] as String;
  }

  Future<bool> requiresRoute(String packet) async {
    final rows = await db.query(
      'relay_invitations',
      columns: ['id'],
      where: "id=? AND state='accepted'",
      whereArgs: [packet],
    );
    return rows.isNotEmpty;
  }

  Future<String?> packetSource(String packet) async {
    final rows = await db.query(
      'packets',
      columns: ['source'],
      where: 'id=?',
      whereArgs: [packet],
    );
    return rows.isEmpty ? null : rows.single['source'] as String?;
  }

  Future<List<Json>> awaitingRoute() async {
    final rows = await db.rawQuery(
      "SELECT p.id, p.source, p.expiry, r.next_peer FROM packets p "
      "JOIN relay_invitations i ON i.id=p.id AND i.state='accepted' "
      "LEFT JOIN relay_routes r ON r.packet=p.id "
      "WHERE p.source IS NOT NULL AND p.uploaded=0 AND p.expiry>? LIMIT 40",
      [nowSeconds],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> acknowledge(String packet, String peer, int hops, int expiry) =>
      db.insert('relay_acks', {
        'packet': packet,
        'peer': peer,
        'hops': hops,
        'expiry': expiry,
        'at': nowSeconds,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Set<String>> recentCustodians(String packet) async => (await db.query(
    'relay_acks',
    columns: ['peer'],
    where: 'packet=? AND expiry>? AND at>?',
    whereArgs: [packet, nowSeconds, nowSeconds - 90],
  )).map((row) => row['peer'] as String).toSet();

  Future<bool> putPacket(Json p, {bool owned = false, String? source}) async {
    await checkPacket(p);
    return db.transaction((tx) async {
      final existing = await tx.query(
        'packets',
        where: 'id=?',
        whereArgs: [p['id']],
      );
      final clean = Map<String, dynamic>.from(p)..remove('uploaded');
      if (existing.isNotEmpty) {
        final old = Map<String, dynamic>.from(
          jsonDecode(existing.single['data'] as String),
        );
        // Preserve financial content and upload state; only a strictly shorter
        // authenticated handoff replaces the local copy's routing metadata.
        if (p['hops'] < old['hops']) {
          await tx.update(
            'packets',
            {'data': jsonEncode(clean)},
            where: 'id=?',
            whereArgs: [p['id']],
          );
          return true;
        }
        return false;
      }
      final used = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COALESCE(SUM(LENGTH(data)),0) FROM packets'),
      )!;
      final count = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COUNT(*) FROM packets'),
      )!;
      final peerCount = source == null
          ? 0
          : Sqflite.firstIntValue(
              await tx.rawQuery('SELECT COUNT(*) FROM packets WHERE source=?', [
                source,
              ]),
            )!;
      // Reserve 100 slots and 2 MiB for this phone's own payment authorizations.
      if (count >= (owned ? 1000 : 900) ||
          used + canonical(p).length > (owned ? 10 : 8) * 1024 * 1024 ||
          (!owned && peerCount >= 100)) {
        throw StateError(
          'Relay storage full. Retain the sender copy and retry later.',
        );
      }
      await tx.insert('packets', {
        'id': p['id'],
        'data': jsonEncode(clean),
        'expiry': p['expires_at'],
        'uploaded': 0,
        'source': source,
      });
      return true;
    });
  }

  Future<List<Json>> packets({bool activeOnly = true}) async {
    final rows = await db.query(
      'packets',
      where: activeOnly ? 'expiry>?' : null,
      whereArgs: activeOnly ? [nowSeconds] : null,
      limit: 1000,
    );
    return rows
        .map(
          (r) =>
              Map<String, dynamic>.from(jsonDecode(r['data'] as String))
                ..['uploaded'] = r['uploaded'],
        )
        .toList();
  }

  Future<Json?> packet(String id) async {
    final rows = await db.query('packets', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String));
  }

  Future<void> uploaded(String id) =>
      db.update('packets', {'uploaded': 1}, where: 'id=?', whereArgs: [id]);
  Future<void> createPayment(Json packet, Json payment) async {
    await checkPacket(packet);
    await db.transaction((tx) async {
      final used = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COALESCE(SUM(LENGTH(data)),0) FROM packets'),
      )!;
      final count = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COUNT(*) FROM packets'),
      )!;
      if (count >= 1000 || used + canonical(packet).length > 10 * 1024 * 1024) {
        throw StateError('Relay storage is full');
      }
      await tx.insert('packets', {
        'id': packet['id'],
        'data': jsonEncode(packet),
        'expiry': packet['expires_at'],
        'uploaded': 0,
      });
      await tx.insert('payments', {
        'id': payment['payment_id'],
        'data': jsonEncode(payment),
      });
    });
  }

  Future<void> markRelayed(String id) => db.transaction((tx) async {
    final rows = await tx.query('payments', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final p = Map<String, dynamic>.from(
      jsonDecode(rows.first['data'] as String),
    );
    if (['paid', 'rejected'].contains(p['state'])) return;
    p['state'] = 'relayed';
    p['transport'] =
        'Another phone acknowledged storage; awaiting bank receipt';
    await tx.update(
      'payments',
      {'data': jsonEncode(p)},
      where: 'id=?',
      whereArgs: [id],
    );
  });

  Future<void> putPayment(Json p) => db.insert('payments', {
    'id': p['payment_id'],
    'data': jsonEncode(p),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<List<Json>> payments() async =>
      (await db.query('payments', orderBy: 'rowid DESC'))
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String)),
          )
          .toList();
  Future<void> putReceipt(Json r) => db.insert('receipts', {
    'id': '${r['payment_id']}:${r['device_id']}',
    'data': jsonEncode(r),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  Future<List<Json>> receipts() async =>
      (await db.query('receipts', orderBy: 'rowid DESC'))
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String)),
          )
          .toList();
  Future<void> event(String text) async {
    await db.insert('events', {'at': nowSeconds, 'text': text});
    await db.execute(
      'DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 150)',
    );
  }

  Future<List<Json>> events() async => (await db.query(
    'events',
    orderBy: 'id DESC',
    limit: 40,
  )).map((r) => Map<String, dynamic>.from(r)).toList();
  Future<void> saveConfig(String k, Object value) => db.insert('config', {
    'key': k,
    'value': jsonEncode(value),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<dynamic> config(String k) async {
    final r = await db.query('config', where: 'key=?', whereArgs: [k]);
    return r.isEmpty ? null : jsonDecode(r.first['value'] as String);
  }

  Future<void> savePeer(String id, Json cert) => db.insert('peers', {
    'id': id,
    'data': jsonEncode(cert),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<void> cleanup() async {
    await db.delete(
      'relay_invitations',
      where: 'expiry<?',
      whereArgs: [nowSeconds - 7 * 86400],
    );
    await db.delete('relay_acks', where: 'expiry<=?', whereArgs: [nowSeconds]);
    // Keep original ciphertext for unresolved owned requests, even beyond
    // relay retention, so the bank can later return a definitive expiry result
    // or recover a prior commit and release its local funds reservation.
    final unresolved = (await payments())
        .where((p) => !['paid', 'rejected'].contains(p['state']))
        .map((p) => p['packet_id'])
        .toSet();
    await db.transaction((tx) async {
      final old = await tx.query(
        'packets',
        columns: ['id'],
        where: 'expiry<?',
        whereArgs: [nowSeconds - 7 * 86400],
      );
      for (final row in old) {
        if (!unresolved.contains(row['id'])) {
          await tx.delete('packets', where: 'id=?', whereArgs: [row['id']]);
        }
      }
      await tx.execute(
        'DELETE FROM relay_routes WHERE packet NOT IN (SELECT id FROM packets)',
      );
    });
  }
}
