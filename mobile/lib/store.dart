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
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE packets(id TEXT PRIMARY KEY, data TEXT NOT NULL, expiry INTEGER NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0)',
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
      },
    );
  }

  Future<bool> putPacket(Json p, {bool owned = false}) async {
    await checkPacket(p);
    return db.transaction((tx) async {
      if ((await tx.query(
        'packets',
        where: 'id=?',
        whereArgs: [p['id']],
      )).isNotEmpty) {
        return false;
      }
      final used = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COALESCE(SUM(LENGTH(data)),0) FROM packets'),
      )!;
      final count = Sqflite.firstIntValue(
        await tx.rawQuery('SELECT COUNT(*) FROM packets'),
      )!;
      if (count >= 1000 || used + canonical(p).length > 10 * 1024 * 1024) {
        throw StateError(
          'Relay storage full. Retain the sender copy and retry later.',
        );
      }
      await tx.insert('packets', {
        'id': p['id'],
        'data': jsonEncode(p),
        'expiry': p['expires_at'],
        'uploaded': 0,
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
    // Preserve expired owned payment intents and receipts. Their financial outcome remains unknown until verified.
    await db.delete(
      'packets',
      where: 'expiry<?',
      whereArgs: [nowSeconds - 7 * 86400],
    );
  }
}
