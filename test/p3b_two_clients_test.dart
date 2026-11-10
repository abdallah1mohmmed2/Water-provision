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

  test('P3b standalone partner share crosses real Shelf HTTP and two independent SQLite files without duplicate GL', () async {
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = await Directory.systemTemp.createTemp('saqia-p3b-e2e-');
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
      await tx.insert('partners', {
        'name': 'P3b isolated partner',
        'ownership_mode': 'percentage',
        'ownership_percentage': 40,
        'active': 1,
      });
    }, captureSync: false);
    await GlobalIdentity.ensure(await db.db);
    final partner = (await db.query(
      "SELECT id FROM partners WHERE name='P3b isolated partner'",
    )).single['id'] as int;
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
    // sync_global_identities table. Do not create a duplicate partner link.

    SyncService sync(ApiClient client) => SyncService.withInboxHandler(
      client, database: db, applyIncoming: SyncInboxApplier.apply,
    );
    final api = newClient();
    await databaseFactory.setDatabasesPath(origin.path);
    await db.db;
    final sender = sync(api);
    await AccountingService(db).createPartnerShare(
      partnerId: partner,
      amount: 1200,
      date: DateTime(2026, 11, 10, 10),
      percentage: 40,
      userId: 1,
    );
    final pending = (await db.query(
      "SELECT * FROM sync_queue WHERE status='pending'",
    )).single;
    expect(pending['table_name'], 'partner_transactions');
    final payload = jsonDecode(pending['payload'] as String) as Map<String, dynamic>;
    expect(payload['reference_type'], 'standalone_share');
    expect((payload['_derived_global_ids']['journal_entries'] as List), hasLength(1));
    expect((payload['_derived_global_ids']['journal_lines'] as List), hasLength(2));
    expect(await db.query(
      'sync_queue', where: 'table_name IN (?,?)',
      whereArgs: ['journal_entries', 'journal_lines'],
    ), isEmpty);

    final command = <String, Object?>{
      'event_id': pending['event_id'],
      'entity_type': 'partner_transactions',
      'entity_key': 'worker_transactions:${payload['_global_id']}',
      'operation': 'create',
      'base_version': pending['base_version'],
      'payload': payload,
    };
    final tampered = jsonDecode(jsonEncode(command)) as Map<String, dynamic>;
    (tampered['payload']['_derived_global_ids']['journal_lines'] as List).removeLast();
    const probeDevice = 'p3b-invalid-probe';
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
      "SELECT type,amount,reference_type FROM worker_transactions WHERE reference_type='standalone_share'",
    );
    expect(localRows, hasLength(1));
    expect(localRows.single['amount'], 1200);
    expect((await db.query('cashboxes', where: 'id=1')).single['current_balance'], initialCash);
    final rootCount = (await db.query(
      "SELECT COUNT(*) n FROM journal_entries WHERE description='حصة شريك من النشاط'",
    )).single['n'];
    expect(rootCount, 1);

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
        ['device_id', 'p3b-peer-unique-device', DateTime.now().toUtc().toIso8601String()],
      );
    }, captureSync: false);
    final receiver = sync(newClient());
    await receiver.pull();
    for (var i = 0; i < 8; i++) {
      await receiver.retryDeferredInbox();
      if (await receiver.applyInbox() == 0) break;
    }
    final peerRows = await db.query(
      "SELECT type,amount,reference_type FROM worker_transactions WHERE reference_type='standalone_share'",
    );
    expect(peerRows, localRows);
    expect((await db.query('cashboxes', where: 'id=1')).single['current_balance'], initialCash);
    expect((await db.query(
      "SELECT COUNT(*) n FROM journal_entries WHERE description='حصة شريك من النشاط'",
    )).single['n'], 1);
    final gl = (await db.query(
      "SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.description='حصة شريك من النشاط'",
    )).single;
    expect(gl['debit'], 1200);
    expect(gl['credit'], 1200);
    expect(await db.query(
      "SELECT entity_type,status,last_error FROM sync_inbox WHERE status<>'applied'",
    ), isEmpty);
    expect(await db.query('sync_queue'), isEmpty);
  });
}
