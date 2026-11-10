import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/api/api_client.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/local/global_identity.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/services/sync_inbox_applier.dart';
import 'package:saqia_station/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('P3c fixed salary batch crosses Shelf HTTP and two SQLite clients as one atomic command', () async {
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = await Directory.systemTemp.createTemp('saqia-p3c-batch-e2e-');
    final origin = await Directory('${root.path}/origin').create();
    final peer = await Directory('${root.path}/peer').create();
    final db = AppDatabase.instance;
    Process? process;
    final clients = <ApiClient>[];
    addTearDown(() async {
      for (final client in clients) {
        client.client.close();
      }
      final running = process;
      if (running != null) {
        await running.stdin.close();
        await running.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            running.kill();
            return -1;
          },
        );
      }
      await db.close();
      await root.delete(recursive: true);
    });

    await databaseFactory.setDatabasesPath(origin.path);
    await db.db;
    await db.transaction((tx) async {
      for (final name in ['P3c fixed A', 'P3c fixed B']) {
        await tx.insert('workers', {
          'name': name,
          'pay_type': 'fixed',
          'fixed_salary': name.endsWith('A') ? 1100 : 2200,
          'active': 1,
        });
      }
    }, captureSync: false);
    await GlobalIdentity.ensure(await db.db);
    final workers = await db.query(
      "SELECT id FROM workers WHERE name LIKE 'P3c fixed %' ORDER BY id",
    );
    expect(workers,hasLength(2));
    final initialCash = (await db.query('cashboxes', where: 'id=1'))
        .single['current_balance'];
    await db.close();

    final originFile = File('${origin.path}/saqia_station_v2.db');
    final serverFile = await originFile.copy('${root.path}/p0-server-fixture.db');
    await originFile.copy('${peer.path}/saqia_station_v2.db');

    process = await Process.start(
      'dart', ['run', 'tool/p0_fixture_server.dart', serverFile.path],
      workingDirectory: '${Directory.current.path}/server',
    );
    final ready = Completer<Map<String, dynamic>>();
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('{') && !ready.isCompleted) {
        ready.complete(jsonDecode(line) as Map<String, dynamic>);
      }
    });
    process.exitCode.then((exit) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('fixture exited $exit: $errors'));
      }
    });
    final connection = await ready.future.timeout(const Duration(seconds: 60));
    ApiClient newClient() {
      final client = ApiClient(
        'http://127.0.0.1:${connection['port']}',
        token: connection['token'] as String,
      );
      clients.add(client);
      return client;
    }

    // p0_fixture_server registers verified UUID mappings from the copied
    // sync_global_identities table. Do not create a duplicate worker link.

    SyncService sync(ApiClient client) => SyncService.withInboxHandler(
      client, database: db, applyIncoming: SyncInboxApplier.apply,
    );
    final api = newClient();
    await databaseFactory.setDatabasesPath(origin.path);
    await db.db;
    final sender = sync(api);
    await AccountingService(db).createWorkerAccrualBatch(
      amounts:{
        (workers[0]['id'] as num).toInt():1100,
        (workers[1]['id'] as num).toInt():2200,
      },
      from:DateTime(2090,4,1),
      to:DateTime(2090,4,30),
      date:DateTime(2090,4,20),
      periodKey:'P3C-2090-04',
      periodLabel:'April 2090',
      userId:1,
    );
    final pending = (await db.query(
      "SELECT * FROM sync_queue WHERE status='pending'",
    )).single;
    expect(pending['table_name'], 'worker_transactions');
    final payload = jsonDecode(pending['payload'] as String) as Map<String, dynamic>;
    expect(payload['reference_type'], 'fixed_salary_batch');
    expect((payload['_p3c_batch']['members'] as List),hasLength(2));
    expect((payload['_derived_global_ids']['journal_entries'] as List), hasLength(2));
    expect((payload['_derived_global_ids']['journal_lines'] as List), hasLength(4));
    expect(await db.query(
      'sync_queue', where: 'table_name IN (?,?)',
      whereArgs: ['journal_entries', 'journal_lines'],
    ), isEmpty);

    final command = <String, Object?>{
      'event_id': pending['event_id'],
      'entity_type': 'worker_transactions',
      'entity_key': 'worker_transactions:${payload['_global_id']}',
      'operation': 'create',
      'base_version': pending['base_version'],
      'payload': payload,
    };
    final tampered = jsonDecode(jsonEncode(command)) as Map<String, dynamic>;
    (tampered['payload']['_derived_global_ids']['journal_lines'] as List).removeLast();
    const probeDevice = 'p3c-invalid-probe';
    final damagedResult = await api.post('/sync/events', {
      'device_id': probeDevice,
      'events': [tampered],
    }) as Map;
    expect((damagedResult['results'] as List).single['status'], 'rejected');

    await sender.push();
    expect(await db.query(
      'sync_queue', where: "status NOT IN ('acknowledged','resolved')",
    ), isEmpty);
    await sender.pull();
    for (var i = 0; i < 8; i++) {
      await sender.retryDeferredInbox();
      if (await sender.applyInbox() == 0) break;
    }
    final localRows = await db.query(
      "SELECT type,amount,reference_type FROM worker_transactions WHERE reference_type='fixed_salary_batch'",
    );
    expect(localRows, hasLength(2));
    expect(localRows.fold<int>(0,(n,row)=>n+(row['amount'] as num).toInt()),3300);
    expect((await db.query('cashboxes', where: 'id=1')).single['current_balance'], initialCash);
    final rootCount = (await db.query(
      "SELECT COUNT(*) n FROM journal_entries WHERE description='استحقاق راتب ثابت للعامل'",
    )).single['n'];
    expect(rootCount, 2);

    final actualDevice = (await db.query(
      'sync_metadata', where: 'key=?', whereArgs: ['device_id'],
    )).single['value'] as String;
    final replay = await api.post('/sync/events', {
      'device_id': actualDevice,
      'events': [command],
    }) as Map;
    expect((replay['results'] as List).single['status'], 'duplicate');

    await db.close();
    await databaseFactory.setDatabasesPath(peer.path);
    await db.db;
    // Independent device identity, even though the starter DB is a copy.
    await db.transaction((tx) async {
      await tx.rawInsert(
        'INSERT OR REPLACE INTO sync_metadata(key,value,updated_at) VALUES(?,?,?)',
        ['device_id', 'p3c-peer-unique-device', DateTime.now().toUtc().toIso8601String()],
      );
    }, captureSync: false);
    final receiver = sync(newClient());
    await receiver.pull();
    for (var i = 0; i < 8; i++) {
      await receiver.retryDeferredInbox();
      if (await receiver.applyInbox() == 0) break;
    }
    final peerRows = await db.query(
      "SELECT type,amount,reference_type FROM worker_transactions WHERE reference_type='fixed_salary_batch'",
    );
    expect(peerRows, localRows);
    expect((await db.query('cashboxes', where: 'id=1')).single['current_balance'], initialCash);
    expect((await db.query(
      "SELECT COUNT(*) n FROM journal_entries WHERE description='استحقاق راتب ثابت للعامل'",
    )).single['n'], 2);
    final gl = (await db.query(
      "SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.description='استحقاق راتب ثابت للعامل'",
    )).single;
    expect(gl['debit'], 3300);
    expect(gl['credit'], 3300);
    expect(await db.query(
      "SELECT entity_type,status,last_error FROM sync_inbox WHERE status<>'applied'",
    ), isEmpty);
    expect(await db.query('sync_queue'), isEmpty);
  });
}
