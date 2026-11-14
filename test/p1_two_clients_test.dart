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
    ('solar', 'beneficiary'),
    ('diesel', 'beneficiary'),
    ('equivalent_hybrid', 'beneficiary'),
    ('solar', 'worker'),
    ('solar', 'partner'),
  ]) {
    final (system, partyType) = scenario;
    test(
      'P1 $system $partyType edits, reversals, replay and rollback across two clients',
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
        final originalCash =
            (await db.query(
                  'cashboxes',
                  where: 'id=1',
                )).single['current_balance']
                as num;
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
        final party = await db.insert('beneficiaries', {
          'name': 'P1 party',
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });
        await first.push();
        final sessionId = await db.insert('irrigation_sessions', {
          'beneficiary_id': party,
          'pump_id': 1,
          'actual_start': now.toIso8601String(),
          'status': 'running',
        });
        await first.push();
        final svc = AccountingService(db);
        final irrigation = await svc.recordIrrigation(
          stationId: 1,
          sessionId: partyType == 'beneficiary' ? sessionId : null,
          pumpId: 1,
          beneficiaryId: partyType == 'beneficiary' ? party : null,
          partyType: partyType,
          workerId: partyType == 'worker'
              ? (await db.query(
                      "SELECT id FROM workers WHERE name='P1 hourly worker'",
                    )).single['id']
                    as int
              : null,
          partnerId: partyType == 'partner'
              ? (await db.query(
                      "SELECT id FROM partners WHERE name='P1 share A'",
                    )).single['id']
                    as int
              : null,
          start: now,
          end: now.add(const Duration(hours: 1)),
          systemType: system,
          waterRate: 6000,
          litersPerHour: 2,
          dieselPrice: 500,
          solarRate: 6000,
          thirdRate: 6000,
          cloudMinutes: system == 'solar' ? 20 : 0,
          cloudPeriods: system == 'solar'
              ? [
                  {
                    'start': now
                        .add(const Duration(minutes: 10))
                        .toIso8601String(),
                    'end': now
                        .add(const Duration(minutes: 20))
                        .toIso8601String(),
                  },
                  {
                    'start': now
                        .add(const Duration(minutes: 40))
                        .toIso8601String(),
                    'end': now
                        .add(const Duration(minutes: 50))
                        .toIso8601String(),
                  },
                ]
              : [],
          paidAmount: partyType == 'beneficiary' ? 200 : 0,
          paymentMethodId: 1,
          cashboxId: 1,
          userId: 1,
        );
        Future<void> settle(SyncService service) async {
          await service.push();
          expect(
            await db.query(
              "SELECT table_name,status,last_error FROM sync_queue WHERE status NOT IN ('acknowledged','resolved')",
            ),
            isEmpty,
          );
          await service.pull();
          for (var i = 0; i < 5; i++) {
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

        Future<Map<String, Object?>> financialState() async => {
          'worker_effects': await db.query(
            'SELECT type,reference_type,amount FROM worker_transactions ORDER BY id',
          ),
          'partner_effects': await db.query(
            'SELECT type,reference_type,amount FROM partner_transactions ORDER BY id',
          ),
          'cloud': await db.query(
            'SELECT start_datetime,end_datetime,minutes FROM cloud_periods ORDER BY id',
          ),
          'journals': await db.query(
            'SELECT reference_type,COUNT(*) n FROM journal_entries GROUP BY reference_type ORDER BY reference_type',
          ),
          'totals': await db.query(
            'SELECT SUM(debit) d,SUM(credit) c FROM journal_lines',
          ),
          'cash': await db.query(
            'SELECT current_balance FROM cashboxes WHERE id=1',
          ),
          'diesel': await db.query(
            'SELECT kind,COUNT(*) n,ROUND(SUM(liters),6) liters,SUM(amount) amount FROM diesel_movements GROUP BY kind ORDER BY kind',
          ),
          'irrigation': await db.query(
            'SELECT start_datetime,end_datetime,total_amount,paid_amount,status FROM irrigations',
          ),
        };
        Map<String, dynamic> event(Map<String, Object?> row) => {
          'event_id': row['event_id'],
          'entity_type': row['table_name'],
          'entity_key':
              '${row['table_name']}:${(jsonDecode(row['payload'] as String) as Map)['_global_id']}',
          'operation': row['operation'],
          'base_version': row['base_version'],
          'payload': jsonDecode(row['payload'] as String),
        };
        await settle(first);
        final initialState = await financialState();
        await db.close();
        await databaseFactory.setDatabasesPath(peer.path);
        await db.db;
        await db.transaction((tx) async {
          await tx.insert('beneficiaries', {
            'name': 'initial unrelated peer',
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          });
        }, captureSync: false);
        await settle(sync(newClient()));
        expect(await financialState(), initialState);
        await db.close();
        await databaseFactory.setDatabasesPath(origin.path);
        await db.db;

        await db.transaction((tx) async {
          await tx.update(
            'settings',
            {'value': '99999'},
            where:
                "key IN ('solar_hourly_rate','diesel_hourly_water_rate','third_type_hourly_rate','diesel_price_per_liter')",
          );
          await tx.update(
            'station_settings',
            {'value': '99999'},
            where:
                "station_id=1 AND key IN ('solar_hourly_rate','diesel_hourly_water_rate','third_type_hourly_rate','diesel_price_per_liter')",
          );
        }, captureSync: false);
        await svc.updateIrrigationBasic(
          id: irrigation,
          start: now,
          end: now.add(const Duration(minutes: 97)),
          userId: 1,
        );
        final pending = (await db.query(
          "SELECT * FROM sync_queue WHERE status='pending'",
        )).single;
        expect(pending['table_name'], 'irrigations');
        final savedEvent = event(pending);
        final device = (await db.query(
          "SELECT value FROM sync_metadata WHERE key='device_id'",
        )).single['value'];
        // Prices changed after recording must not replace the stored price snapshot.
        // Server-only closure proves validation is repeated on the authority.
        final authority = await databaseFactory.openDatabase(serverFile.path);
        final closure = await authority.insert('period_closures', {
          'station_id': 1,
          'period_start': now.toIso8601String(),
          'period_end': now.add(const Duration(days: 1)).toIso8601String(),
          'period_end_exclusive': now
              .add(const Duration(days: 1))
              .toIso8601String(),
          'closed_at': now.toIso8601String(),
          'closed_by': 1,
        });
        final locked =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [savedEvent],
                })
                as Map;
        expect((locked['results'] as List).single['status'], 'rejected');
        await authority.update(
          'period_closures',
          {'status': 'reopened'},
          where: 'id=?',
          whereArgs: [closure],
        );
        await authority.close();
        final alteredPrice =
            jsonDecode(jsonEncode(savedEvent)) as Map<String, dynamic>;
        alteredPrice['payload'][system == 'diesel'
                ? 'water_hourly_rate_snapshot'
                : system == 'solar'
                ? 'solar_hourly_rate_snapshot'
                : 'third_type_hourly_rate_snapshot'] =
            99999;
        final invalidPrice =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [alteredPrice],
                })
                as Map;
        expect((invalidPrice['results'] as List).single['status'], 'rejected');
        final damaged =
            jsonDecode(jsonEncode(savedEvent)) as Map<String, dynamic>;
        (damaged['payload']['_p1_effect_ids']['journal_lines'] as List)
            .removeLast();
        final rejected =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [damaged],
                })
                as Map;
        expect((rejected['results'] as List).single['status'], 'rejected');
        await settle(
          first,
        ); // Same event ID now succeeds only if failed effects rolled back.
        final duplicate =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [savedEvent],
                })
                as Map;
        expect((duplicate['results'] as List).single['status'], 'duplicate');
        final stale = {
          ...savedEvent,
          'event_id': '77777777-7777-4777-8777-777777777777',
        };
        final conflict =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [stale],
                })
                as Map;
        expect((conflict['results'] as List).single['status'], 'conflict');
        final expected = await financialState();
        await db.close();
        await databaseFactory.setDatabasesPath(peer.path);
        await db.db;
        await db.transaction((tx) async {
          await tx.insert('beneficiaries', {
            'name': 'unrelated peer',
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          });
        }, captureSync: false);
        final second = sync(newClient());
        await settle(second);
        expect(await financialState(), expected);
        expect(await db.query('sync_queue'), isEmpty);
        final peerId = (await db.query('irrigations')).single['id'] as int;
        if (partyType == 'beneficiary') {
          expect((await db.query('payments')).single['irrigation_id'], peerId);
        }
        await AccountingService(db).updateIrrigationBasic(
          id: peerId,
          start: now,
          end: now.add(const Duration(minutes: 31)),
          userId: 1,
        );
        // Queue the second edit and cancellation offline, then send together.
        await AccountingService(
          db,
        ).cancelIrrigation(peerId, 1, 'P1 audited cancellation');
        expect(
          (await db.query(
            "SELECT * FROM sync_queue WHERE status='pending'",
          )).map((row) => row['table_name']).toList(),
          ['irrigations', 'irrigations'],
        );
        final cancellation = event(
          (await db.query(
            "SELECT * FROM sync_queue WHERE status='pending' ORDER BY id DESC LIMIT 1",
          )).single,
        );
        final peerDevice = (await db.query(
          "SELECT value FROM sync_metadata WHERE key='device_id'",
        )).single['value'];
        await settle(second);
        final replayCancel =
            await api.post('/sync/events', {
                  'device_id': peerDevice,
                  'events': [cancellation],
                })
                as Map;
        expect((replayCancel['results'] as List).single['status'], 'duplicate');
        final cancelledRoot = {
          ...cancellation,
          'event_id': '88888888-8888-4888-8888-888888888888',
          'base_version': (cancellation['base_version'] as int) + 1,
        };
        final again =
            await api.post('/sync/events', {
                  'device_id': peerDevice,
                  'events': [cancelledRoot],
                })
                as Map;
        expect((again['results'] as List).single['status'], 'rejected');
        await expectLater(
          AccountingService(db).cancelIrrigation(peerId, 1, 'repeat'),
          throwsStateError,
        );
        final endState = await financialState();
        expect(
          (await db.query('irrigation_sessions')).single['status'],
          partyType == 'beneficiary' ? 'completed' : 'running',
        );
        expect(
          (await db.query(
            'cashboxes',
            where: 'id=1',
          )).single['current_balance'],
          originalCash,
        );
        if (partyType == 'beneficiary') {
          expect((await db.query('payments')).single['status'], 'cancelled');
        }
        final net = (await db.query(
          'SELECT SUM(debit-credit) net FROM journal_lines',
        )).single['net'];
        expect(net, 0);
        for (final row in await db.query(
          'SELECT account_id,SUM(debit-credit) net FROM journal_lines GROUP BY account_id',
        )) {
          expect(row['net'], 0);
        }
        expect(
          (await db.query(
            "SELECT COALESCE(SUM(liters),0) n FROM diesel_movements WHERE kind='consumption'",
          )).single['n'],
          0,
        );
        if (system == 'diesel') {
          expect(await db.query('diesel_movements'), isNotEmpty);
          expect(
            await db.query(
              'SELECT d.id FROM diesel_movements d WHERE d.reversal_of IS NULL AND NOT EXISTS(SELECT 1 FROM diesel_movements r WHERE r.reversal_of=d.id)',
            ),
            isEmpty,
          );
        }
        await db.close();
        await databaseFactory.setDatabasesPath(origin.path);
        await db.db;
        await settle(first);
        expect(await financialState(), endState);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
