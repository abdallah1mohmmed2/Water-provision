import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(
      '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db',
    );
    database = AppDatabase.instance;
    await database.db;
  });

  setUp(() async {
    await database.delete('sync_queue', '1=1', const []);
    await database.delete('beneficiaries', "name LIKE 'SYNC-TEST-%'", const []);
  });

  test('create, update and delete writes each create an atomic outbox event', () async {
    final now = DateTime.now().toIso8601String();
    final id = await database.insert('beneficiaries', {
      'name': 'SYNC-TEST-beneficiary',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });

    var events = await database.query(
      'sync_queue',
      where: 'table_name=? AND record_id=?',
      whereArgs: ['beneficiaries', id],
      orderBy: 'id',
    );
    expect(events, hasLength(1));
    expect(events.single['operation'], 'create');
    expect(events.single['event_id'], isNotEmpty);
    expect(jsonDecode(events.single['payload'] as String)['name'],
        'SYNC-TEST-beneficiary');

    await database.update(
      'beneficiaries',
      {'phone': '777000111', 'updated_at': now},
      'id=?',
      [id],
    );
    events = await database.query(
      'sync_queue',
      where: 'table_name=? AND record_id=?',
      whereArgs: ['beneficiaries', id],
      orderBy: 'id',
    );
    expect(events, hasLength(2));
    expect(events.last['operation'], 'update');
    expect(events.last['base_version'], 1);
    expect(jsonDecode(events.last['payload'] as String)['phone'],
        '777000111');

    await database.delete('beneficiaries', 'id=?', [id]);
    events = await database.query(
      'sync_queue',
      where: 'table_name=? AND record_id=?',
      whereArgs: ['beneficiaries', id],
      orderBy: 'id',
    );
    expect(events, hasLength(3));
    expect(events.last['operation'], 'delete');
    expect(jsonDecode(events.last['payload'] as String), {'id': id});
  });

  test('business write and its outbox event roll back together', () async {
    final now = DateTime.now().toIso8601String();
    await expectLater(
      database.transaction((tx) async {
        await tx.insert('beneficiaries', {
          'name': 'SYNC-TEST-rollback',
          'status': 'active',
          'created_at': now,
          'updated_at': now,
        });
        throw StateError('force rollback');
      }),
      throwsA(isA<StateError>()),
    );

    expect(
      await database.query(
        'beneficiaries',
        where: 'name=?',
        whereArgs: ['SYNC-TEST-rollback'],
      ),
      isEmpty,
    );
    expect(
      await database.query('sync_queue', where: 'table_name=?', whereArgs: ['beneficiaries']),
      isEmpty,
    );
  });

  test('multiple edits before push receive sequential base versions', () async {
    final now = DateTime.now().toIso8601String();
    final id = await database.insert('beneficiaries', {
      'name': 'SYNC-TEST-sequence',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
    await database.update('beneficiaries', {'phone': '1'}, 'id=?', [id]);
    await database.update('beneficiaries', {'phone': '2'}, 'id=?', [id]);

    final events = await database.query(
      'sync_queue',
      where: 'table_name=? AND record_id=?',
      whereArgs: ['beneficiaries', id],
      orderBy: 'id',
    );
    expect(events.map((e) => e['base_version']).toList(), [0, 1, 2]);
  });
}
