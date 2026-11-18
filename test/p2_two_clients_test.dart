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
    ('solar', 'worker'),
    ('solar', 'partner'),
  ]) {
    final (system, partyType) = scenario;
    test(
      'P2 $partyType receipt, metadata, atomic replacement and cancellation across two clients',
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
        final beneficiary = await db.insert('beneficiaries', {
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
        final payment = partyType == 'beneficiary'
            ? await service.receivePayment(
                beneficiaryId: beneficiary,
                amount: 200,
                paymentMethodId: 1,
                cashboxId: 1,
                userId: 1,
              )
            : partyType == 'worker'
            ? await service.payWorker(
                workerId: worker,
                amount: 200,
                paymentMethodId: 1,
                cashboxId: 1,
                userId: 1,
              )
            : await service.payPartner(
                partnerId: partner,
                amount: 200,
                paymentMethodId: 1,
                cashboxId: 1,
                userId: 1,
              );
        expect(
          (await db.query(
            "SELECT table_name FROM sync_queue WHERE status='pending'",
          )).map((r) => r['table_name']),
          everyElement(isIn(['beneficiaries', 'payments'])),
        );
        await settle(first);
        final journalsBefore = (await db.query(
          'SELECT COUNT(*) n FROM journal_entries',
        )).single['n'];
        await service.updatePaymentDetails(
          id: payment,
          userId: 1,
          referenceNumber: 'P2 reference',
          notes: 'P2 notes',
        );
        final metadata = event(
          (await db.query(
            "SELECT * FROM sync_queue WHERE status='pending'",
          )).single,
        );
        final device = (await db.query(
          "SELECT value FROM sync_metadata WHERE key='device_id'",
        )).single['value'];
        final changedAmount =
            jsonDecode(jsonEncode(metadata)) as Map<String, dynamic>;
        changedAmount['payload']['amount'] = 201;
        final rejected =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [changedAmount],
                })
                as Map;
        expect((rejected['results'] as List).single['status'], 'rejected');
        final wrongCurrency =
            jsonDecode(jsonEncode(metadata)) as Map<String, dynamic>;
        wrongCurrency['payload']['currency'] = 'USD';
        final wrong =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [wrongCurrency],
                })
                as Map;
        expect((wrong['results'] as List).single['status'], 'rejected');
        final hardDelete = {...metadata, 'operation': 'delete'};
        final deleted =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [hardDelete],
                })
                as Map;
        expect((deleted['results'] as List).single['status'], 'rejected');
        final authorityChecks = await databaseFactory.openDatabase(
          serverFile.path,
        );
        final date = DateTime.parse('${(metadata['payload'] as Map)['date']}');
        final closure = await authorityChecks.insert('period_closures', {
          'station_id': 1,
          'period_start': date
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'period_end': date.add(const Duration(days: 1)).toIso8601String(),
          'period_end_exclusive': date
              .add(const Duration(days: 1))
              .toIso8601String(),
          'closed_at': date.toIso8601String(),
          'closed_by': 1,
        });
        final locked =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [metadata],
                })
                as Map;
        expect((locked['results'] as List).single['status'], 'rejected');
        await authorityChecks.update(
          'period_closures',
          {'status': 'reopened'},
          where: 'id=?',
          whereArgs: [closure],
        );
        await authorityChecks.execute(
          "INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'cashboxes','99999999-9999-4999-8999-999999999999',999,'now')",
        );
        final foreign =
            jsonDecode(jsonEncode(metadata)) as Map<String, dynamic>;
        foreign['payload']['_global_refs']['cashbox_id']['global_id'] =
            '99999999-9999-4999-8999-999999999999';
        final foreignResult =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [foreign],
                })
                as Map;
        expect((foreignResult['results'] as List).single['status'], 'rejected');
        await authorityChecks.update('app_users', {
          'role': 'operator',
        }, where: 'id=1');
        await expectLater(
          api.post('/sync/events', {
            'device_id': device,
            'events': [metadata],
          }),
          throwsA(isA<Exception>()),
        );
        await authorityChecks.update('app_users', {
          'role': 'manager',
        }, where: 'id=1');
        await authorityChecks.close();
        await settle(first);
        expect(
          (await db.query(
            'SELECT COUNT(*) n FROM journal_entries',
          )).single['n'],
          journalsBefore,
        );
        final initial = await state();
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
        expect(await state(), initial);
        expect(await db.query('sync_queue'), isEmpty);
        final peerPayment = (await db.query('payments')).single;
        final peerId = peerPayment['id'] as int;
        final newId = await AccountingService(db).replacePayment(
          id: peerId,
          userId: 1,
          reason: 'correct amount',
          beneficiaryId: peerPayment['beneficiary_id'] as int?,
          workerId: null,
          partnerId: partyType == 'worker'
              ? partner
              : peerPayment['partner_id'] as int?,
          amount: 350,
          paymentMethodId: 1,
          cashboxId: 1,
          referenceNumber: 'replacement',
          notes: 'corrected',
        );
        final pending = (await db.query(
          "SELECT * FROM sync_queue WHERE status='pending'",
        )).single;
        expect(pending['table_name'], 'payments');
        expect(pending['record_id'], peerId);
        final replacement = event(pending);
        final peerDevice = (await db.query(
          "SELECT value FROM sync_metadata WHERE key='device_id'",
        )).single['value'];
        final damaged =
            jsonDecode(jsonEncode(replacement)) as Map<String, dynamic>;
        (damaged['payload']['_p2_effect_ids']['journal_lines'] as List)
            .removeLast();
        final failure =
            await api.post('/sync/events', {
                  'device_id': peerDevice,
                  'events': [damaged],
                })
                as Map;
        expect((failure['results'] as List).single['status'], 'rejected');
        final authority = await databaseFactory.openDatabase(serverFile.path);
        expect((await authority.query('payments')).single['status'], 'posted');
        expect((await authority.query('payments')).single['amount'], 200);
        await authority.close();
        await settle(second);
        final repeated =
            await api.post('/sync/events', {
                  'device_id': peerDevice,
                  'events': [replacement],
                })
                as Map;
        expect((repeated['results'] as List).single['status'], 'duplicate');
        final stale = {
          ...replacement,
          'event_id': '77777777-7777-4777-8777-777777777777',
        };
        final conflict =
            await api.post('/sync/events', {
                  'device_id': peerDevice,
                  'events': [stale],
                })
                as Map;
        expect((conflict['results'] as List).single['status'], 'conflict');
        expect(
          (await db.query(
            'payments',
            where: 'id=?',
            whereArgs: [newId],
          )).single['replaces_payment_id'],
          peerId,
        );
        final replacementState = await state();
        await db.close();
        await databaseFactory.setDatabasesPath(origin.path);
        await db.db;
        await settle(first);
        expect(await state(), replacementState);
        final localNew = (await db.query(
          "SELECT * FROM payments WHERE status='posted'",
        )).single;
        await AccountingService(
          db,
        ).cancelPayment(localNew['id'] as int, 1, 'P2 cancel');
        final cancel = event(
          (await db.query(
            "SELECT * FROM sync_queue WHERE status='pending'",
          )).single,
        );
        await settle(first);
        final cancelReplay =
            await api.post('/sync/events', {
                  'device_id': device,
                  'events': [cancel],
                })
                as Map;
        expect((cancelReplay['results'] as List).single['status'], 'duplicate');
        await expectLater(
          AccountingService(
            db,
          ).cancelPayment(localNew['id'] as int, 1, 'repeat'),
          throwsStateError,
        );
        final cancelled = await state();
        expect(
          (await db.query(
            'cashboxes',
            where: 'id=1',
          )).single['current_balance'],
          originalCash,
        );
        for (final row in await db.query(
          'SELECT account_id,SUM(debit-credit) net FROM journal_lines GROUP BY account_id',
        )) {
          expect(row['net'], 0);
        }
        expect((await db.query('payments')).length, 2);
        expect(
          (await db.query('payments')).map((r) => r['status']),
          everyElement('cancelled'),
        );
        await db.close();
        await databaseFactory.setDatabasesPath(peer.path);
        await db.db;
        await settle(second);
        expect(await state(), cancelled);
        if (partyType == 'beneficiary') {
          final peerBeneficiary =
              (await db.query(
                    "SELECT id FROM beneficiaries WHERE name='P2 beneficiary'",
                  )).single['id']
                  as int;
          final irrigation = await AccountingService(db).recordIrrigation(
            stationId: 1,
            pumpId: 1,
            beneficiaryId: peerBeneficiary,
            start: now,
            end: now.add(const Duration(hours: 1)),
            systemType: 'solar',
            waterRate: 6000,
            litersPerHour: 2,
            dieselPrice: 500,
            solarRate: 6000,
            thirdRate: 6000,
            cloudMinutes: 0,
            paidAmount: 100,
            paymentMethodId: 1,
            cashboxId: 1,
            userId: 1,
          );
          await settle(second);
          final receipt =
              (await db.query(
                    'payments',
                    where: 'irrigation_id=?',
                    whereArgs: [irrigation],
                  )).single['id']
                  as int;
          await AccountingService(
            db,
          ).cancelPayment(receipt, 1, 'linked receipt cancellation');
          await settle(second);
          expect((await db.query('irrigations')).single['paid_amount'], 0);
          expect((await db.query('irrigations')).single['status'], 'posted');
          await db.close();
          await databaseFactory.setDatabasesPath(origin.path);
          await db.db;
          await settle(first);
          expect((await db.query('irrigations')).single['paid_amount'], 0);
          final localIrr = (await db.query('irrigations')).single['id'] as int;
          // P1 remains usable after the P2 receipt advances the irrigation version.
          await AccountingService(
            db,
          ).cancelIrrigation(localIrr, 1, 'finish linked case');
          await settle(first);
          expect(
            (await db.query(
              'cashboxes',
              where: 'id=1',
            )).single['current_balance'],
            originalCash,
          );
          for (final row in await db.query(
            'SELECT account_id,SUM(debit-credit) net FROM journal_lines GROUP BY account_id',
          )) {
            expect(row['net'], 0);
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
