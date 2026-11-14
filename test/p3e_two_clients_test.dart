import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/api/api_client.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/local/global_identity.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/services/sync_service.dart';
import 'package:saqia_station/services/sync_inbox_applier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    ('solar', 'worker'),
    ('solar', 'partner'),
  ]) {
    final (system, partyType) = scenario;
    test(
      'P3e $partyType cash advance, reversal and idempotent peer projection',
      () async {
        HttpOverrides.global =
            null; // Real loopback HTTP, not the widget-test stub.
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        final root = await Directory.systemTemp.createTemp('saqia-p0-e2e-');
        final origin = await Directory('${root.path}/origin').create();
        final peer = await Directory('${root.path}/peer').create();
        final db = AppDatabase.instance;
        Process? process;
        final clients = <ApiClient>[];
        addTearDown(() async {
          for (final client in clients) {
            client.client.close();
          }
          if (process != null) {
            await process.stdin.close();
            await process!.exitCode.timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                process!.kill();
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
          await tx.update('workers', {'active': 0});
          await tx.update('partners', {'active': 0});
          await tx.update('pumps', {'system_type': system}, where: 'id=1');
          for (final setting in {
            'system_type': system,
            'solar_hourly_rate': '6000',
            'third_type_hourly_rate': '6000',
            'diesel_hourly_water_rate': '6000',
            'diesel_liters_per_hour': '2',
            'diesel_price_per_liter': '500',
            'diesel_delivery_financial_credit': 'false',
            'partial_hour': 'true',
          }.entries) {
            await tx.update(
              'settings',
              {'value': setting.value},
              where: 'key=?',
              whereArgs: [setting.key],
            );
            await tx.update(
              'station_settings',
              {'value': setting.value},
              where: 'station_id=1 AND key=?',
              whereArgs: [setting.key],
            );
          }
        }, captureSync: false);
        await db.transaction((tx) async {
          await tx.insert('workers', {
            'name': 'P1 hourly worker',
            'pay_type': 'hourly',
            'hourly_rate': 701,
            'active': 1,
          });
          await tx.insert('partners', {
            'name': 'P1 share A',
            'ownership_mode': 'shares',
            'shares_count': 1,
            'active': 1,
          });
          await tx.insert('partners', {
            'name': 'P1 share B',
            'ownership_mode': 'shares',
            'shares_count': 2,
            'active': 1,
          });
        }, captureSync: false);
        await GlobalIdentity.ensure(await db.db);
        await db.close();
        final originalFile = File('${origin.path}/saqia_station_v2.db');
        final serverFile = await originalFile.copy(
          '${root.path}/p0-server-fixture.db',
        );
        await originalFile.copy('${peer.path}/saqia_station_v2.db');
        process = await Process.start('dart', [
          'run',
          'tool/p0_fixture_server.dart',
          serverFile.path,
        ], workingDirectory: '${Directory.current.path}/server');
        final ready = Completer<Map<String, dynamic>>();
        final errors = StringBuffer();
        process.stderr.transform(utf8.decoder).listen(errors.write);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.startsWith('{') && !ready.isCompleted) {
                ready.complete(jsonDecode(line) as Map<String, dynamic>);
              }
            });
        process.exitCode.then((code) {
          if (!ready.isCompleted) {
            ready.completeError(StateError('fixture exited $code: $errors'));
          }
        });
        final connection = await ready.future.timeout(
          const Duration(seconds: 60),
        );
        ApiClient newClient() {
          final client = ApiClient(
            'http://127.0.0.1:${connection['port']}',
            token: connection['token'] as String,
          );
          clients.add(client);
          return client;
        }

        final api = newClient();
        SyncService sync(ApiClient client) => SyncService.withInboxHandler(
          client,
          database: db,
          applyIncoming: SyncInboxApplier.apply,
        );
        final first = sync(api);
        final now = DateTime(2090, 1, 1, 8);
        await db.insert('beneficiaries', {
          'name': 'P2 beneficiary',
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });
        final worker =
            (await db.query(
                  "SELECT id FROM workers WHERE name='P1 hourly worker'",
                )).single['id']
                as int;
        final partner =
            (await db.query(
                  "SELECT id FROM partners WHERE name='P1 share A'",
                )).single['id']
                as int;
        Future<void> settle(SyncService service) async {
          await service.push();
          expect(
            await db.query(
              "SELECT table_name,status,last_error FROM sync_queue WHERE status NOT IN ('acknowledged','resolved')",
            ),
            isEmpty,
          );
          await service.pull();
          for (var i = 0; i < 8; i++) {
            await service.retryDeferredInbox();
            if (await service.applyInbox() == 0) break;
          }
          expect(
            await db.query(
              "SELECT entity_type,status,last_error FROM sync_inbox WHERE status<>'applied'",
            ),
            isEmpty,
          );
        }

        Map<String, Object?> event(Map row) => {
          'event_id': row['event_id'],
          'entity_type': row['table_name'],
          'entity_key':
              '${row['table_name']}:${(jsonDecode(row['payload'] as String) as Map)['_global_id']}',
          'operation': row['operation'],
          'base_version': row['base_version'],
          'payload': jsonDecode(row['payload'] as String),
        };
        Future<Map<String, Object?>> state() async => {
          'payments': await db.query(
            'SELECT amount,date,status,currency,reference_number FROM payments ORDER BY id',
          ),
          'cash': await db.query(
            'SELECT current_balance FROM cashboxes ORDER BY id',
          ),
          'gl': await db.query(
            'SELECT SUM(debit) d,SUM(credit) c FROM journal_lines',
          ),
          'worker': await db.query(
            'SELECT type,amount,reference_type FROM worker_transactions ORDER BY id',
          ),
          'partner': await db.query(
            'SELECT type,amount,reference_type FROM partner_transactions ORDER BY id',
          ),
        };
        final service = AccountingService(db);
        final partyId = partyType == 'worker' ? worker : partner;
        final advanceId = await service.recordPartyCashAdvance(
          partyType: partyType, partyId: partyId, amount: 200,
          paymentMethodId: 1, cashboxId: 1, userId: 1,
          notes: 'P3e independent database test',
        );
        final advance = event((await db.query(
          "SELECT * FROM sync_queue WHERE status='pending' AND table_name='payments'",
        )).single);
        await settle(first);
        final originPosted = await state();
        await db.close();
        await databaseFactory.setDatabasesPath(peer.path);
        await db.db;
        final second = sync(newClient());
        await settle(second);
        expect(await state(), originPosted);
        final peerAdvance = (await db.query('payments',
          where: "status='posted'", limit: 1)).single;
        expect(peerAdvance['amount'], 200);
        await AccountingService(db).reversePartyCashMovement(
          paymentId: peerAdvance['id'] as int,
          userId: 1, reason: 'P3e test reversal',
        );
        final reverseEvent = event((await db.query(
          "SELECT * FROM sync_queue WHERE status='pending' AND table_name='payments'",
        )).single);
        await settle(second);
        final cancelledState = await state();
        final device = (await db.query(
          "SELECT value FROM sync_metadata WHERE key='device_id'",
        )).single['value'];
        final replay = await api.post('/sync/events', {
          'device_id': device, 'events': [reverseEvent],
        }) as Map;
        expect((replay['results'] as List).single['status'], 'duplicate');
        await expectLater(
          AccountingService(db).reversePartyCashMovement(
            paymentId: peerAdvance['id'] as int,
            userId: 1, reason: 'duplicate reversal',
          ), throwsStateError,
        );
        await db.close();
        await databaseFactory.setDatabasesPath(origin.path);
        await db.db;
        await settle(first);
        expect(await state(), cancelledState);
        expect((await db.query('payments',where:'id=?',whereArgs:[advanceId])).single['status'], 'cancelled');
        final paymentRows = await db.query('payments');
        expect(paymentRows.length, 1);
        for (final row in await db.query(
          'SELECT journal_entry_id,SUM(debit) d,SUM(credit) c FROM journal_lines GROUP BY journal_entry_id',
        )) {
          expect(row['d'], row['c']);
        }
        expect(advance['entity_type'], 'payments');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
