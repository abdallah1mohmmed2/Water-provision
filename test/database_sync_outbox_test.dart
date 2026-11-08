import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';

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
      'beneficiary_manual_debts',
      "beneficiary_id IN (SELECT id FROM beneficiaries WHERE name LIKE 'SYNC-TEST-%')",
      const [],
    );
    await database.delete(
      'journal_lines',
      "beneficiary_id IN (SELECT id FROM beneficiaries WHERE name LIKE 'SYNC-TEST-%')",
      const [],
    );
    await database.delete(
      'booking_requests',
      "beneficiary_id IN (SELECT id FROM beneficiaries WHERE name LIKE 'SYNC-TEST-%')",
      const [],
    );
    await database.delete('worker_transactions', "notes LIKE 'SYNC-TEST-PREVIOUS-DEBT-%'", const []);
    await database.delete('partner_transactions', "notes LIKE 'SYNC-TEST-PREVIOUS-DEBT-%'", const []);
    await database.delete('journal_lines', "journal_entry_id IN (SELECT id FROM journal_entries WHERE reference_type IN ('worker_opening','partner_opening'))", const []);
    await database.delete('journal_entries', "reference_type IN ('worker_opening','partner_opening')", const []);
    await database.delete('accounts', "code LIKE '2100.W%' OR code LIKE '2200.P%'", const []);
    await database.delete('workers', "name LIKE 'SYNC-TEST-PREVIOUS-DEBT-%'", const []);
    await database.delete('partners', "name LIKE 'SYNC-TEST-PREVIOUS-DEBT-%'", const []);
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

  test('irrigation outbox contains only the business command while derived rows keep identities', () async {
    await database.update('pumps', {'system_type': 'solar'}, 'id=?', [1]);
    await database.update('workers', {'active': 0}, 'id>? ', [0]);
    await database.update('partners', {'active': 0}, 'id>? ', [0]);
    final now = DateTime(2099, 5, 6, 8);
    final beneficiaryId = await database.insert('beneficiaries', {
      'name': 'SYNC-TEST-projection-beneficiary',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    final irrigationId = await AccountingService(database).recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: beneficiaryId,
      start: now,
      end: now.add(const Duration(hours: 1)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 1000,
      thirdRate: 0,
      cloudMinutes: 10,
      paidAmount: 0,
      cloudPeriods: [
        {
          'start': now.add(const Duration(minutes: 10)).toIso8601String(),
          'end': now.add(const Duration(minutes: 20)).toIso8601String(),
        },
      ],
    );

    final outbox = await database.query(
      'SELECT table_name FROM sync_queue ORDER BY id',
    );
    expect(outbox.map((row) => row['table_name']).toList(), ['irrigations']);

    for (final relation in const [
      ('cloud_periods', 'irrigation_id'),
      ('journal_entries', 'reference_id'),
    ]) {
      final rows = await database.query(
        'SELECT id FROM ${relation.$1} WHERE ${relation.$2}=?',
        args: [irrigationId],
      );
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final identity = await database.query(
          'SELECT global_id FROM sync_global_identities WHERE table_name=? AND local_id=?',
          args: [relation.$1, row['id']],
        );
        expect(identity, hasLength(1));
      }
    }
    final journalLines = await database.query(
      'SELECT jl.id FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.reference_type=? AND je.reference_id=?',
      args: ['irrigation', irrigationId],
    );
    expect(journalLines, isNotEmpty);
    for (final line in journalLines) {
      expect(
        await database.query(
          'SELECT global_id FROM sync_global_identities WHERE table_name=? AND local_id=?',
          args: ['journal_lines', line['id']],
        ),
        hasLength(1),
      );
    }
    await database.update('pumps', {'system_type': 'diesel'}, 'id=?', [1]);
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


  test('manual beneficiary debt emits only its business event, not generated journal rows', () async {
    final now=DateTime.now().toIso8601String();
    final beneficiaryId=await database.insert('beneficiaries',{
      'name':'SYNC-TEST-manual-debt-party',
      'status':'active',
      'created_at':now,
      'updated_at':now,
    });
    // Exclude the beneficiary setup event; this assertion targets the debt transaction.
    await database.delete('sync_queue','1=1',const []);
    final service=AccountingService(database);
    final debtId=await service.addBeneficiaryDebt(
      beneficiaryId:beneficiaryId,
      amount:2400,
      date:DateTime(2026,11,7,9),
      notes:'مديونية سابقة للاختبار',
    );
    var events=await database.query(
      'sync_queue',
      where:'status=?',
      whereArgs:['pending'],
      orderBy:'id',
    );
    expect(events.map((e)=>e['table_name']).toList(),['beneficiary_manual_debts']);
    expect(events.single['operation'],'create');
    final payload=jsonDecode(events.single['payload'] as String) as Map<String,dynamic>;
    expect(payload['amount'],2400);
    expect(payload['_global_id'],isA<String>());
    expect((payload['_global_refs'] as Map)['beneficiary_id']['table'],'beneficiaries');

    await service.cancelBeneficiaryDebt(debtId,null,'إلغاء سند اختبار');
    events=await database.query(
      'sync_queue',
      where:'table_name=?',
      whereArgs:['beneficiary_manual_debts'],
      orderBy:'id',
    );
    expect(events.map((e)=>e['operation']).toList(),['create','update']);
    final cancelPayload=jsonDecode(events.last['payload'] as String) as Map<String,dynamic>;
    expect(cancelPayload['status'],'cancelled');
    expect(cancelPayload['cancel_reason'],'إلغاء سند اختبار');
    expect(await database.query('sync_queue',where:'table_name IN (?,?)',whereArgs:['journal_entries','journal_lines']),isEmpty);
  });


  test('previous worker and partner debts emit only their own ledger outbox events', () async {
    final stationId = await AccountingService(database).currentStationId();
    final now = DateTime.now().toIso8601String();

    Future<int> createParty(String table, String partyName) async {
      final columns = await database.rawQuery('PRAGMA table_info($table)');
      final values = <String,Object?>{'name':partyName,'station_id':stationId,'active':1};
      final foreignKeys = await database.rawQuery('PRAGMA foreign_key_list($table)');
      for (final fk in foreignKeys) {
        final columnName = fk['from'] as String;
        if (values.containsKey(columnName)) continue;
        final target = fk['table'] as String;
        final targetRows = await database.query(target,columns:['id'],limit:1);
        if (targetRows.isNotEmpty) {
          values[columnName] = targetRows.first['id'];
        }
      }
      for (final column in columns) {
        final columnName = column['name'] as String;
        if (columnName == 'id' || values.containsKey(columnName) ||
            (column['notnull'] as num).toInt() == 0 ||
            column['dflt_value'] != null) {
          continue;
        }
        final type = (column['type'] ?? '').toString().toUpperCase();
        if (type.contains('INT')) {
          values[columnName] = 0;
        } else if (type.contains('REAL') || type.contains('FLOA') || type.contains('DOUB')) {
          values[columnName] = 0.0;
        } else if (columnName == 'created_at' || columnName == 'updated_at') {
          values[columnName] = now;
        } else if (columnName == 'pay_type' || columnName == 'salary_type') {
          values[columnName] = 'fixed';
        } else if (columnName == 'ownership_mode') {
          values[columnName] = 'shares';
        } else {
          values[columnName] = '';
        }
      }
      return database.insert(table,values);
    }

    final workerId = await createParty('workers','SYNC-TEST-PREVIOUS-DEBT-worker');
    final partnerId = await createParty('partners','SYNC-TEST-PREVIOUS-DEBT-partner');
    await database.delete('sync_queue','1=1',const []);
    final service = AccountingService(database);
    await service.addPreviousPartyDebt(
      partyType:'worker',partyId:workerId,amount:4200,
      date:DateTime(2026,11,7,9),notes:'SYNC-TEST-PREVIOUS-DEBT-worker debt',
    );
    await service.addPreviousPartyDebt(
      partyType:'partner',partyId:partnerId,amount:5200,
      date:DateTime(2026,11,7,10),notes:'SYNC-TEST-PREVIOUS-DEBT-partner debt',
    );

    final events = await database.query('sync_queue',where:'status=?',whereArgs:['pending'],orderBy:'id');
    expect(events.map((e)=>e['table_name']).toList(),['worker_transactions','partner_transactions']);
    expect(events.map((e)=>e['operation']).toList(),['create','create']);
    final workerPayload = jsonDecode(events[0]['payload'] as String) as Map<String,dynamic>;
    final partnerPayload = jsonDecode(events[1]['payload'] as String) as Map<String,dynamic>;
    expect(workerPayload['type'],'opening_balance');
    expect(workerPayload['reference_type'],'previous_debt');
    expect(workerPayload['_global_id'],isA<String>());
    expect((workerPayload['_global_refs'] as Map)['worker_id']['table'],'workers');
    expect(partnerPayload['type'],'opening_balance');
    expect(partnerPayload['reference_type'],'previous_debt');
    expect(partnerPayload['_global_id'],isA<String>());
    expect((partnerPayload['_global_refs'] as Map)['partner_id']['table'],'partners');
    expect(await database.query('sync_queue',where:'table_name IN (?,?)',whereArgs:['journal_entries','journal_lines']),isEmpty);
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
