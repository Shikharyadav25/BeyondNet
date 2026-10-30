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
      version: 7,
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
        if (old < 6) await _createConnectionTable(db);
        if (old < 7) await _createDeliveryTables(db);
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
        await _createConnectionTable(db);
        await _createDeliveryTables(db);
      },
    );
  }

  static Future<void> _createDeliveryTables(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE delivery_proofs(id TEXT PRIMARY KEY,data TEXT NOT NULL,expiry INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE delivery_attempts(packet TEXT NOT NULL,peer TEXT NOT NULL,token TEXT NOT NULL,deadline INTEGER NOT NULL,state TEXT NOT NULL,at INTEGER NOT NULL,PRIMARY KEY(packet,peer))',
    );
    await db.execute(
      'ALTER TABLE relay_invitations ADD COLUMN offer_deadline INTEGER',
    );
    await db.execute(
      'ALTER TABLE relay_invitations ADD COLUMN offer_token TEXT',
    );
  }

  Future<List<Json>> proofs() async =>
      (await db.query(
            'delivery_proofs',
            where: 'expiry>?',
            whereArgs: [nowSeconds],
            orderBy: 'id',
            limit: 1000,
          ))
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String)),
          )
          .toList();

  Future<void> saveProof(Json proof) => db.transaction((tx) async {
    final b = proof['body'];
    final exists = await tx.query(
      'delivery_proofs',
      where: 'id=?',
      whereArgs: [b['packet_id']],
    );
    if (exists.isNotEmpty) {
      final previous = jsonDecode(exists.single['data'] as String)['body'];
      if (previous['recorded_at'] > b['recorded_at']) return;
    }
    if (exists.isEmpty &&
        Sqflite.firstIntValue(
              await tx.rawQuery(
                'SELECT COUNT(*) FROM delivery_proofs WHERE expiry>?',
                [nowSeconds],
              ),
            )! >=
            1000) {
      throw StateError('Delivery proof storage full');
    }
    await tx.insert('delivery_proofs', {
      'id': b['packet_id'],
      'data': jsonEncode(proof),
      'expiry': b['expires_at'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await tx.update(
      'packets',
      {'uploaded': 1},
      where: 'id=?',
      whereArgs: [b['packet_id']],
    );
  });

  Future<Json?> offerFor(
    String packet,
    String peer,
    int expiry,
  ) => db.transaction((tx) async {
    if (expiry <= nowSeconds) return null;
    final done = await tx.query(
      'delivery_proofs',
      where: 'id=? AND expiry>?',
      whereArgs: [packet, nowSeconds],
    );
    if (done.isNotEmpty) return null;
    final attempts = await tx.query(
      'delivery_attempts',
      where: 'packet=?',
      whereArgs: [packet],
    );
    final same = attempts.where((r) => r['peer'] == peer).firstOrNull;
    if (same != null && same['state'] == 'declined') return null;
    if (same != null &&
        same['state'] == 'pending' &&
        (same['deadline'] as int) > nowSeconds) {
      return Map<String, dynamic>.from(same);
    }
    // A disconnected custodian may still be delivering. Use a passive recovery
    // copy for at least 60 seconds before trying a different downstream carrier.
    if (attempts.any(
      (r) =>
          r['state'] != 'declined' &&
          (r['state'] == 'pending'
              ? (r['deadline'] as int) > nowSeconds
              : (r['at'] as int) > nowSeconds - 60),
    )) {
      return null;
    }
    // Revisit the same timed-out pending carrier without growing the copy
    // budget. A new offer generation cannot revive an old notification action.
    if (same != null && same['state'] == 'accepted') return null;
    if (same == null &&
        attempts.where((r) => r['state'] != 'declined').length >= 2) {
      return null;
    }
    if (attempts.length >= 32 && same == null) return null;
    final value = <String, dynamic>{
      'packet': packet,
      'peer': peer,
      'token': randomCapability(),
      'deadline': expiry < nowSeconds + 30 ? expiry : nowSeconds + 30,
      'state': 'pending',
      'at': nowSeconds,
    };
    await tx.insert(
      'delivery_attempts',
      value,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return value;
  });

  Future<void> offerResult(String packet, String peer, String state) async {
    await db.update(
      'delivery_attempts',
      {'state': state, 'at': nowSeconds},
      where: 'packet=? AND peer=?',
      whereArgs: [packet, peer],
    );
  }

  Future<void> deliveryText(String packet, String text) =>
      db.transaction((tx) async {
        for (final row in await tx.query('payments')) {
          final value = Map<String, dynamic>.from(
            jsonDecode(row['data'] as String),
          );
          if (value['packet_id'] == packet &&
              !['paid', 'rejected'].contains(value['state'])) {
            value['transport'] = text;
            await tx.update(
              'payments',
              {'data': jsonEncode(value)},
              where: 'id=?',
              whereArgs: [row['id']],
            );
          }
        }
      });

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

  static Future<void> _createConnectionTable(DatabaseExecutor db) => db.execute(
    'CREATE TABLE relay_connections(peer TEXT PRIMARY KEY, name TEXT NOT NULL, state TEXT NOT NULL, expiry INTEGER NOT NULL)',
  );

  Future<Json?> connection(String peer) async {
    final rows = await db.query(
      'relay_connections',
      where: 'peer=? AND expiry>?',
      whereArgs: [peer, nowSeconds],
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.single);
  }

  Future<bool> requestConnection(String peer, String name) => db.transaction((
    tx,
  ) async {
    await tx.delete(
      'relay_connections',
      where: 'expiry<=?',
      whereArgs: [nowSeconds],
    );
    if ((await tx.query(
      'relay_connections',
      where: 'peer=?',
      whereArgs: [peer],
    )).isNotEmpty) {
      return false;
    }
    final rows = await tx.query('relay_connections');
    if (rows.length >= 40) throw StateError('Too many connection requests.');
    await tx.insert('relay_connections', {
      'peer': peer,
      'name': name.substring(0, name.length.clamp(0, 80)),
      'state': 'pending',
      'expiry': nowSeconds + 180,
    });
    return true;
  });

  Future<List<Json>> connectionRequests() async => (await db.query(
    'relay_connections',
    where: "state='pending' AND expiry>? ",
    whereArgs: [nowSeconds],
  )).map((row) => Map<String, dynamic>.from(row)).toList();

  Future<void> decideConnection(String peer, bool allow) async {
    final changed = await db.update(
      'relay_connections',
      {'state': allow ? 'accepted' : 'declined', 'expiry': nowSeconds + 600},
      where: "peer=? AND state='pending' AND expiry>?",
      whereArgs: [peer, nowSeconds],
    );
    if (changed != 1) throw StateError('This connection request has expired.');
  }

  Future<String> invite(
    Json packet,
    String source,
    String name, {
    int? deadline,
    String? token,
  }) async {
    await checkPacket(packet);
    if (packet['expires_at'] <= nowSeconds) {
      throw StateError('Payment request expired');
    }
    return db.transaction((tx) async {
      final clock = nowSeconds;
      await tx.update(
        'relay_invitations',
        {'state': 'expired'},
        where: "state='pending' AND expiry<=?",
        whereArgs: [clock],
      );
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
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row['state'] == 'accepted' || row['state'] == 'declined') {
          return row['state'] as String;
        }
        if (deadline != null && token != row['offer_token']) {
          await tx.update(
            'relay_invitations',
            {
              'state': 'pending',
              'offer_deadline': deadline,
              'offer_token': token,
            },
            where: 'id=?',
            whereArgs: [packet['id']],
          );
          return 'pending';
        }
        if (row['offer_deadline'] != null &&
            (row['offer_deadline'] as int) <= clock) {
          return 'expired';
        }
        return row['state'] as String;
      }
      final count = Sqflite.firstIntValue(
        await tx.rawQuery(
          "SELECT COUNT(*) FROM relay_invitations WHERE state='pending' AND expiry>?",
          [clock],
        ),
      )!;
      final fromPeer = Sqflite.firstIntValue(
        await tx.rawQuery(
          "SELECT COUNT(*) FROM relay_invitations WHERE state='pending' AND source=? AND expiry>?",
          [source, clock],
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
        'offer_deadline': deadline,
        'offer_token': token,
      });
      return 'new';
    });
  }

  Future<List<Json>> invitations() async => (await db.query(
    'relay_invitations',
    where:
        "state='pending' AND expiry>? AND (offer_deadline IS NULL OR offer_deadline>?)",
    whereArgs: [nowSeconds, nowSeconds],
    orderBy: 'rowid DESC',
  )).map((r) => Map<String, dynamic>.from(r)).toList();

  Future<Json?> decideInvitation(String id, bool allow, {String? token}) async {
    return db.transaction((tx) async {
      final rows = await tx.query(
        'relay_invitations',
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty || rows.single['state'] != 'pending') return null;
      final row = rows.single;
      if (token != null && row['offer_token'] != token) {
        throw StateError('This offer has ended. Reopen the current request.');
      }
      if ((row['expiry'] as int) <= nowSeconds ||
          (row['offer_deadline'] != null &&
              (row['offer_deadline'] as int) <= nowSeconds)) {
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
        throw PacketStorageFull(
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
    if ((await tx.query(
      'delivery_proofs',
      where: 'id=? AND expiry>?',
      whereArgs: [p['packet_id'], nowSeconds],
    )).isNotEmpty) {
      return;
    }
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
      'delivery_proofs',
      where: 'expiry<=?',
      whereArgs: [nowSeconds],
    );
    await db.delete(
      'delivery_attempts',
      where: 'at<?',
      whereArgs: [nowSeconds - 7 * 86400],
    );
    await db.update(
      'relay_invitations',
      {'state': 'expired'},
      where: "state='pending' AND expiry<=?",
      whereArgs: [nowSeconds],
    );
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

class PacketStorageFull extends StateError {
  PacketStorageFull(super.message);
}
