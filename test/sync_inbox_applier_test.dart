import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/local/global_identity.dart';
import 'package:saqia_station/services/sync_inbox_applier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory directory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('sync_inbox_applier_');
    await databaseFactory.setDatabasesPath(directory.path);
    await databaseFactory.deleteDatabase(
      '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db',
    );
    database = AppDatabase.instance;
    await database.db;
  });

  tearDownAll(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  setUp(() async {
    await database.delete('sync_queue', '1=1', const []);
    await database.delete('sync_inbox', '1=1', const []);
  });

  Map<String, dynamic> event({
    required String table,
    required String id,
    required String operation,
    required Map<String, dynamic> payload,
    required int version,
  }) => {
    'event_id': '11111111-1111-4111-8111-111111111111',
    'entity_type': table,
    'entity_key': '$table:$id',
    'operation': operation,
    'server_version': version,
    'payload': {'_global_id': id, ...payload},
  };

  test('applies a remote party and its dependent booking using global FK refs without outbox echo', () async {
    const beneficiaryGlobalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const bookingGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final now = DateTime.now().toUtc().toIso8601String();

    await database.transaction((tx) async {
      final party = event(
        table: 'beneficiaries',
        id: beneficiaryGlobalId,
        operation: 'create',
        version: 1,
        payload: {
          'id': 9001,
          'station_id': 77,
          'name': 'INBOX-REMOTE-BENEFICIARY',
          'status': 'active',
          'created_at': now,
          'updated_at': now,
        },
      );
      expect(await SyncInboxApplier.apply(tx, party), InboxApplyResult.applied);

      final booking = event(
        table: 'booking_requests',
        id: bookingGlobalId,
        operation: 'create',
        version: 1,
        payload: {
          'id': 8001,
          'beneficiary_id': 9001,
          'created_at': now,
          'status': 'pending',
          '_global_refs': {
            'beneficiary_id': {
              'table': 'beneficiaries',
              'global_id': beneficiaryGlobalId,
            },
          },
        },
      );
      expect(await SyncInboxApplier.apply(tx, booking), InboxApplyResult.applied);
    }, captureSync: false);

    final beneficiary = (await database.query(
      'beneficiaries',
      where: 'name=?',
      whereArgs: ['INBOX-REMOTE-BENEFICIARY'],
      limit: 1,
    )).single;
    final booking = (await database.query(
      'booking_requests',
      where: 'status=?',
      whereArgs: ['pending'],
      orderBy: 'id DESC',
      limit: 1,
    )).single;

    expect(booking['beneficiary_id'], beneficiary['id']);
    expect(beneficiary['station_id'], isNot(77));
    expect(await database.query('sync_queue'), isEmpty);
    expect(await database.query(
      'sync_global_identities',
      where: 'table_name=? AND global_id=?',
      whereArgs: ['booking_requests', bookingGlobalId],
    ), hasLength(1));
  });

  test('applies station-owned irrigation session lifecycle and rejects reopening a completed session', () async {
    final now = DateTime.now().toUtc().toIso8601String();
    final beneficiaryId = await database.transaction((tx) async {
      final id = await tx.insert('beneficiaries', {
        'name': 'INBOX-SESSION-BENEFICIARY',
        'status': 'active',
        'created_at': now,
        'updated_at': now,
      });
      await GlobalIdentity.ensureRecord(tx, 'beneficiaries', id);
      return id;
    }, captureSync: false);
    final pump = (await database.query('pumps', where: 'id=?', whereArgs: [1], limit: 1)).single;
    final beneficiaryIdentity = (await database.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: ['beneficiaries', beneficiaryId],
      limit: 1,
    )).single['global_id'] as String;
    final pumpIdentity = (await database.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: ['pumps', pump['id']],
      limit: 1,
    )).single['global_id'] as String;
    const sessionId = 'abababab-1111-4111-8111-111111111111';
    const started = '2026-11-08T08:00:00.000';
    const ended = '2026-11-08T09:00:00.000';

    final created = await database.transaction(
      (tx) => SyncInboxApplier.apply(
        tx,
        event(
          table: 'irrigation_sessions',
          id: sessionId,
          operation: 'create',
          version: 1,
          payload: {
            'beneficiary_id': beneficiaryId,
            'pump_id': pump['id'],
            'actual_start': started,
            'timer_started_at': started,
            'status': 'running',
            '_global_refs': {
              'beneficiary_id': {'table': 'beneficiaries', 'global_id': beneficiaryIdentity},
              'pump_id': {'table': 'pumps', 'global_id': pumpIdentity},
            },
          },
        ),
      ),
      captureSync: false,
    );
    expect(created, InboxApplyResult.applied);
    await database.insert('sync_entity_versions', {
      'entity_type': 'irrigation_sessions',
      'entity_key': 'irrigation_sessions:$sessionId',
      'server_version': 1,
      'updated_at': now,
    });

    final localSession = (await database.query(
      'irrigation_sessions',
      where: 'status=?',
      whereArgs: ['running'],
      orderBy: 'id DESC',
      limit: 1,
    )).single;
    final finished = await database.transaction(
      (tx) => SyncInboxApplier.apply(
        tx,
        event(
          table: 'irrigation_sessions',
          id: sessionId,
          operation: 'update',
          version: 2,
          payload: {
            'status': 'completed',
            'actual_end': ended,
            'timer_stopped_at': ended,
            'beneficiary_id': beneficiaryId,
            'pump_id': pump['id'],
            '_global_refs': {
              'beneficiary_id': {'table': 'beneficiaries', 'global_id': beneficiaryIdentity},
              'pump_id': {'table': 'pumps', 'global_id': pumpIdentity},
            },
          },
        ),
      ),
      captureSync: false,
    );
    expect(finished, InboxApplyResult.applied);
    await database.update('sync_entity_versions', {'server_version': 2}, 'entity_type=? AND entity_key=?', ['irrigation_sessions', 'irrigation_sessions:$sessionId']);
    expect((await database.query(
      'irrigation_sessions',
      where: 'id=?',
      whereArgs: [localSession['id']],
      limit: 1,
    )).single['status'], 'completed');

    await expectLater(
      database.transaction(
        (tx) => SyncInboxApplier.apply(
          tx,
          event(
            table: 'irrigation_sessions',
            id: sessionId,
            operation: 'update',
            version: 3,
            payload: {
              'status': 'running',
              'beneficiary_id': beneficiaryId,
              'pump_id': pump['id'],
              '_global_refs': {
                'beneficiary_id': {'table': 'beneficiaries', 'global_id': beneficiaryIdentity},
                'pump_id': {'table': 'pumps', 'global_id': pumpIdentity},
              },
            },
          ),
        ),
        captureSync: false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await database.query('sync_queue'), isEmpty);
  });

  test('does not overwrite a locally edited record with an unacknowledged outbox event', () async {
    final now = DateTime.now().toUtc().toIso8601String();
    final localId = await database.insert('beneficiaries', {
      'name': 'INBOX-LOCAL-PENDING',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
    final identity = (await database.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: ['beneficiaries', localId],
    )).single['global_id'] as String;

    final result = await database.transaction(
      (tx) => SyncInboxApplier.apply(
        tx,
        event(
          table: 'beneficiaries',
          id: identity,
          operation: 'update',
          version: 1,
          payload: {'name': 'REMOTE-OVERWRITE', 'status': 'active'},
        ),
      ),
      captureSync: false,
    );

    expect(result, InboxApplyResult.conflict);
    final row = (await database.query(
      'beneficiaries',
      where: 'id=?',
      whereArgs: [localId],
    )).single;
    expect(row['name'], 'INBOX-LOCAL-PENDING');
  });

  test('rejects invalid non-positive amounts in incoming financial records', () async {
    const paymentGlobalId = 'abababab-abab-4bab-8bab-abababababab';
    await expectLater(
      database.transaction(
        (tx) => SyncInboxApplier.apply(
          tx,
          event(
            table: 'payments',
            id: paymentGlobalId,
            operation: 'create',
            version: 1,
            payload: {'amount': -25},
          ),
        ),
        captureSync: false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      await database.query(
        'payments',
        where: 'amount=?',
        whereArgs: [-25],
      ),
      isEmpty,
    );
  });

  test('financial ledger records cannot be deleted by remote tombstones', () async {
    const paymentGlobalId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final result = await database.transaction(
      (tx) => SyncInboxApplier.apply(
        tx,
        event(
          table: 'payments',
          id: paymentGlobalId,
          operation: 'delete',
          version: 1,
          payload: const {},
        ),
      ),
      captureSync: false,
    );
    expect(result, InboxApplyResult.conflict);
  });

  test('balanced remote journal lines promote the entry to posted', () async {
    const journalGlobalId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    const debitLineGlobalId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    const creditLineGlobalId = '99999999-9999-4999-8999-999999999999';
    final now = DateTime.now().toUtc().toIso8601String();

    final accounts = await database.query(
      'accounts',
      columns: ['id'],
      orderBy: 'id',
      limit: 2,
    );
    expect(accounts, hasLength(2));
    final accountRefs = <Map<String, String>>[];
    for (final account in accounts) {
      final identity = (await database.query(
        'sync_global_identities',
        columns: ['global_id'],
        where: 'table_name=? AND local_id=?',
        whereArgs: ['accounts', account['id']],
        limit: 1,
      )).single;
      accountRefs.add({
        'table': 'accounts',
        'global_id': identity['global_id'] as String,
      });
    }

    await database.transaction((tx) async {
      await SyncInboxApplier.apply(
        tx,
        event(
          table: 'journal_entries',
          id: journalGlobalId,
          operation: 'create',
          version: 1,
          payload: {
            'date': now,
            'description': 'INBOX-BALANCED-JOURNAL',
            'status': 'posted',
            'created_at': now,
          },
        ),
      );
      await SyncInboxApplier.apply(
        tx,
        event(
          table: 'journal_lines',
          id: debitLineGlobalId,
          operation: 'create',
          version: 1,
          payload: {
            'journal_entry_id': 7001,
            'account_id': accounts[0]['id'],
            'debit': 250,
            'credit': 0,
            '_global_refs': {
              'journal_entry_id': {
                'table': 'journal_entries',
                'global_id': journalGlobalId,
              },
              'account_id': accountRefs[0],
            },
          },
        ),
      );
      await SyncInboxApplier.apply(
        tx,
        event(
          table: 'journal_lines',
          id: creditLineGlobalId,
          operation: 'create',
          version: 1,
          payload: {
            'journal_entry_id': 7001,
            'account_id': accounts[1]['id'],
            'debit': 0,
            'credit': 250,
            '_global_refs': {
              'journal_entry_id': {
                'table': 'journal_entries',
                'global_id': journalGlobalId,
              },
              'account_id': accountRefs[1],
            },
          },
        ),
      );
    }, captureSync: false);

    final journal = (await database.query(
      'journal_entries',
      where: 'description=?',
      whereArgs: ['INBOX-BALANCED-JOURNAL'],
      limit: 1,
    )).single;
    expect(journal['status'], 'posted');
    expect(await database.query('sync_queue'), isEmpty);
  });

  test('journal entries remain draft until their lines balance', () async {
    const journalGlobalId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final now = DateTime.now().toUtc().toIso8601String();
    await database.transaction((tx) async {
      final result = await SyncInboxApplier.apply(
        tx,
        event(
          table: 'journal_entries',
          id: journalGlobalId,
          operation: 'create',
          version: 1,
          payload: {
            'date': now,
            'description': 'INBOX-UNBALANCED-JOURNAL',
            'status': 'posted',
            'created_at': now,
          },
        ),
      );
      expect(result, InboxApplyResult.applied);
    }, captureSync: false);

    final row = (await database.query(
      'journal_entries',
      where: 'description=?',
      whereArgs: ['INBOX-UNBALANCED-JOURNAL'],
      limit: 1,
    )).single;
    expect(row['status'], 'draft');
    expect(await database.query('sync_queue'), isEmpty);
  });
}
