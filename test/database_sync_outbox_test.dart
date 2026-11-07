import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory testDatabaseDirectory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    testDatabaseDirectory = await Directory.systemTemp.createTemp(
      'saqia_database_sync_outbox_test_',
    );
    await databaseFactory.setDatabasesPath(testDatabaseDirectory.path);
    await databaseFactory.deleteDatabase(
      '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db',
    );
    database = AppDatabase.instance;
    await database.db;
  });

  tearDownAll(() async {
    await database.close();
    await testDatabaseDirectory.delete(recursive: true);
  });

  setUp(() async {
    await database.delete(
      'booking_requests',
      "beneficiary_id IN (SELECT id FROM beneficiaries WHERE name LIKE 'SYNC-TEST-%')",
      const [],
    );
    await database.delete('beneficiaries', "name LIKE 'SYNC-TEST-%'", const []);
    await database.delete('sync_queue', '1=1', const []);
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
    final deletePayload = jsonDecode(events.last['payload'] as String)
        as Map<String, dynamic>;
    expect(deletePayload['id'], id);
    expect(deletePayload['_global_id'], isA<String>());
    expect(deletePayload['_global_refs'], isEmpty);
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
  test('repository booking saves are captured without manual enqueue calls', () async {
    final now = DateTime.now().toIso8601String();
    final beneficiaryId = await database.insert('beneficiaries', {
      'name': 'SYNC-TEST-booking-party',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });

    final repository = StationRepository(database);
    final bookingId = await repository.createBooking(
      beneficiaryId,
      'طلب حجز تجريبي',
      userId: 1,
    );

    final events = await database.query(
      'sync_queue',
      where: 'table_name=? AND record_id=?',
      whereArgs: ['booking_requests', bookingId],
    );
    expect(events, hasLength(1));
    expect(events.single['operation'], 'create');
    final bookingPayload = jsonDecode(events.single['payload'] as String)
        as Map<String, dynamic>;
    expect(bookingPayload['beneficiary_id'], beneficiaryId);
    expect(bookingPayload['_global_id'], isA<String>());
    final globalRefs = bookingPayload['_global_refs'] as Map<String, dynamic>;
    final beneficiaryGlobalId = (await database.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: ['beneficiaries', beneficiaryId],
    )).single['global_id'];
    expect(globalRefs['beneficiary_id']['table'], 'beneficiaries');
    expect(globalRefs['beneficiary_id']['global_id'], beneficiaryGlobalId);
  });

  test('remote repository writes can opt out of echoing into the outbox', () async {
    final now = DateTime.now().toIso8601String();
    await database.transaction((tx) async {
      await tx.insert('beneficiaries', {
        'name': 'SYNC-TEST-remote',
        'status': 'active',
        'created_at': now,
        'updated_at': now,
      });
    }, captureSync: false);

    expect(
      await database.query('sync_queue', where: 'table_name=?', whereArgs: ['beneficiaries']),
      isEmpty,
    );
  });

  test('global identities are unique across tables and stable across updates', () async {
    final now = DateTime.now().toIso8601String();
    final beneficiaryId = await database.insert('beneficiaries', {
      'name': 'SYNC-TEST-global-beneficiary',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
    final workerId = await database.insert('workers', {
      'name': 'SYNC-TEST-global-worker',
      'pay_type': 'fixed',
      'fixed_salary': 0,
      'active': 1,
    });
    final beneficiaryGlobalId = (await database.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: ['beneficiaries', beneficiaryId],
    )).single['global_id'];
    final workerGlobalId = (await database.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: ['workers', workerId],
    )).single['global_id'];
    expect(beneficiaryGlobalId, isNot(workerGlobalId));

    await database.update(
      'beneficiaries',
      {'phone': '777111222'},
      'id=?',
      [beneficiaryId],
    );
    final update = (await database.query(
      'sync_queue',
      where: 'table_name=? AND record_id=?',
      whereArgs: ['beneficiaries', beneficiaryId],
      orderBy: 'id DESC',
      limit: 1,
    )).single;
    final payload = jsonDecode(update['payload'] as String) as Map<String, dynamic>;
    expect(payload['_global_id'], beneficiaryGlobalId);
  });

}
