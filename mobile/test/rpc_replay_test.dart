import 'dart:io';
import 'package:beyondnet/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory directory;
  late LocalStore store;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rpc-replay-');
    path = '${directory.path}/store.db';
    store = LocalStore();
    await store.init(databasePath: path);
  });
  tearDown(() async {
    await store.db.close();
    await directory.delete(recursive: true);
  });

  test('claims survive restart and future-clock acceptance window', () async {
    await store.claimRpc('a', 'id', 1120, now: 1000);
    await store.db.close();
    store = LocalStore();
    await store.init(databasePath: path);
    await expectLater(
      store.claimRpc('a', 'id', 1120, now: 1240),
      throwsStateError,
    );
    await expectLater(
      store.claimRpc('a', 'id', 1120, now: 1241),
      throwsStateError,
    );
    await store.claimRpc('a', 'fresh', 1241, now: 1241);
    expect(await store.db.query('rpc_replays'), hasLength(1));
  });

  test(
    'simultaneous duplicates execute at most once; IDs scoped to peer',
    () async {
      Future<bool> claim() async {
        try {
          await store.claimRpc('a', 'same', 1000, now: 1000);
          return true;
        } on StateError {
          return false;
        }
      }

      final results = await Future.wait(List.generate(8, (_) => claim()));
      expect(results.where((v) => v), hasLength(1));
      await store.claimRpc('b', 'same', 1000, now: 1000);
    },
  );

  test(
    'quota never evicts live replay protection and recovers after expiry',
    () async {
      for (var i = 0; i < 256; i++) {
        await store.claimRpc('a', '$i', 1000, now: 1000);
      }
      await expectLater(
        store.claimRpc('a', 'overflow', 1000, now: 1000),
        throwsStateError,
      );
      await expectLater(
        store.claimRpc('a', '0', 1000, now: 1000),
        throwsStateError,
      );
      await store.claimRpc('b', 'other', 1000, now: 1000);
      await store.claimRpc('a', 'fresh', 1121, now: 1121);
      expect(await store.db.query('rpc_replays'), hasLength(1));
    },
  );

  test('global capacity fails closed without deleting valid claims', () async {
    final batch = store.db.batch();
    for (var i = 0; i < 4096; i++) {
      batch.insert('rpc_replays', {
        'peer': 'peer-$i',
        'request': 'id',
        'expiry': 1120,
      });
    }
    await batch.commit(noResult: true);
    await expectLater(
      store.claimRpc('new', 'id', 1000, now: 1000),
      throwsStateError,
    );
    expect(await store.db.query('rpc_replays'), hasLength(4096));
    await store.claimRpc('new', 'id', 1121, now: 1121);
    expect(await store.db.query('rpc_replays'), hasLength(1));
  });

  test('clock rollback cannot resurrect a removed request', () async {
    await store.claimRpc('a', 'old', 1000, now: 1000);
    await store.claimRpc('a', 'new', 1121, now: 1121);
    await expectLater(
      store.claimRpc('a', 'old', 1000, now: 1000),
      throwsStateError,
    );
    await store.claimRpc('a', 'recovered', 1122, now: 1122);
  });

  test('v3 upgrade preserves pending data and adds replay storage', () async {
    await store.db.close();
    await deleteDatabase(path);
    final old = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE config(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE payments(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
        );
        await db.insert('payments', {'id': 'pending', 'data': '{}'});
        await db.insert('config', {'key': 'existing', 'value': '42'});
      },
    );
    await old.close();
    await store.init(databasePath: path);
    await store.claimRpc('a', 'first', 1000, now: 1000);
    expect((await store.db.query('payments')).single['id'], 'pending');
    expect(
      (await store.db.query(
        'config',
        where: 'key=?',
        whereArgs: ['existing'],
      )).single['value'],
      '42',
    );
  });
}
