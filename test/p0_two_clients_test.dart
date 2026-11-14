import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/api/api_client.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/services/sync_service.dart';
import 'package:saqia_station/services/sync_inbox_applier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'P0 real Shelf and two clients preserve compound commands, reversals and identities',
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
        await tx.update('pumps', {'system_type': 'solar'}, where: 'id=1');
        for (final setting in {
          'system_type': 'solar',
          'solar_hourly_rate': '1000',
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
      final originalCash =
          (await db.query('cashboxes', where: 'id=1')).single['current_balance']
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

      final originApi = newClient();
      final originSync = SyncService.withInboxHandler(
        originApi,
        database: db,
        applyIncoming: SyncInboxApplier.apply,
      );
      final now = DateTime(2099, 9, 1, 8);
      final beneficiaryId = await db.insert('beneficiaries', {
        'name': 'P0 actual origin party',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      await originSync.push();
      expect(
        await db.query("SELECT * FROM sync_queue WHERE status<>'acknowledged'"),
        isEmpty,
      );
      final irrigationId = await AccountingService(db).recordIrrigation(
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
        cloudMinutes: 0,
        paidAmount: 200,
        paymentMethodId: 1,
        cashboxId: 1,
        userId: 1,
      );
      final commands = [
        ...await db.query(
          "SELECT * FROM sync_queue WHERE status='pending' ORDER BY id",
        ),
      ];
      expect(commands.map((r) => r['table_name']).toList(), [
        'irrigations',
        'payments',
      ]);
      await originSync.push();
      expect(
        await db.query("SELECT * FROM sync_queue WHERE status<>'acknowledged'"),
        isEmpty,
      );
      final accounting = AccountingService(db);
      final workerId = await db.insert('workers', {
        'name': 'P0 worker',
        'pay_type': 'fixed',
      });
      final partnerId = await db.insert('partners', {
        'name': 'P0 partner',
        'ownership_mode': 'shares',
        'shares_count': 1,
      });
      final secondBox = await accounting.createCashbox(
        name: 'P0 second box',
        userId: 1,
      );
      await originSync.push();
      expect(
        await db.query(
          "SELECT table_name,last_error FROM sync_queue WHERE status<>'acknowledged'",
        ),
        isEmpty,
      );
      await accounting.transferCash(
        from: 1,
        to: secondBox,
        amount: 10,
        date: now,
        userId: 1,
      );
      await accounting.transferCash(
        from: 1,
        to: secondBox,
        amount: 15,
        date: now,
        userId: 1,
        opening: true,
      );
      await accounting.addPreviousPartyDebt(
        partyType: 'worker',
        partyId: workerId,
        amount: 50,
        date: now,
        notes: 'P0 worker debt',
        userId: 1,
      );
      await accounting.addPreviousPartyDebt(
        partyType: 'partner',
        partyId: partnerId,
        amount: 60,
        date: now,
        notes: 'P0 partner debt',
        userId: 1,
      );
      final expenseId = await accounting.addExpense(
        category: 'other',
        title: 'P0 expense',
        amount: 30,
        date: now,
        paymentMethodId: 1,
        cashboxId: 1,
        userId: 1,
      );
      await accounting.addDieselMovement(
        kind: 'opening_balance',
        liters: 10,
        unitPrice: 2,
        date: now,
        userId: 1,
      );
      await accounting.addDieselMovement(
        kind: 'receipt',
        liters: 5,
        unitPrice: 2,
        date: now,
        cashboxId: 1,
        userId: 1,
      );
      await accounting.addDieselMovement(
        kind: 'consumption',
        liters: 2,
        unitPrice: 2,
        date: now,
        userId: 1,
      );
      for (final kind in ['correction', 'delivery', 'advance']) {
        await accounting.addDieselMovement(
          kind: kind,
          liters: 1,
          unitPrice: 2,
          date: now,
          userId: 1,
          beneficiaryId: kind == 'correction' ? null : beneficiaryId,
        );
      }
      final debtId = await accounting.addBeneficiaryDebt(
        beneficiaryId: beneficiaryId,
        amount: 40,
        date: now,
        notes: 'P0 debt',
        userId: 1,
      );
      final extraCommands = await db.query(
        "SELECT * FROM sync_queue WHERE status='pending' ORDER BY id",
      );
      expect(extraCommands.map((r) => r['table_name']), [
        'cashbox_transfers',
        'cashbox_transfers',
        'worker_transactions',
        'partner_transactions',
        'expenses',
        'diesel_movements',
        'diesel_movements',
        'diesel_movements',
        'diesel_movements',
        'diesel_movements',
        'diesel_movements',
        'beneficiary_manual_debts',
      ]);
      commands.addAll(extraCommands);
      await originSync.push();
      expect(
        await db.query(
          "SELECT table_name,last_error FROM sync_queue WHERE status<>'acknowledged'",
        ),
        isEmpty,
      );
      // Posted debt corrections are one root update each: the original
      // journals are reversed and replacement journals stay auditable.
      final workerDebt = (await db.query('worker_transactions',
        where: "reference_type='previous_debt' AND worker_id=?",
        whereArgs: [workerId])).single;
      final partnerDebt = (await db.query('partner_transactions',
        where: "reference_type='previous_debt' AND partner_id=?",
        whereArgs: [partnerId])).single;
      await accounting.revisePreviousPartyDebt(
        partyType: 'worker',
        transactionId: (workerDebt['id'] as num).toInt(),
        amount: 75,
        notes: 'corrected worker debt',
        userId: 1,
      );
      await accounting.revisePreviousPartyDebt(
        partyType: 'partner',
        transactionId: (partnerDebt['id'] as num).toInt(),
        cancellationReason: 'partner debt entered in error',
        userId: 1,
      );
      await accounting.reviseBeneficiaryDebt(
        debtId: debtId, amount: 45, notes: 'corrected beneficiary debt', userId: 1,
      );
      expect((await accounting.workerBalance(workerId))['balance'], -75);
      expect((await accounting.partnerBalance(partnerId))['balance'], 0);
      final statementRepository = StationRepository(db);
      // A correction is still a previous debt (not an opening balance).
      expect((await statementRepository.workerTransactions(workerId)).any(
        (row) => row['type'] == 'previous_receivable' &&
          row['previous_debt_transaction_id'] == workerDebt['id'],
      ), isTrue);
      expect((await statementRepository.workers()).singleWhere(
        (row) => row['id'] == workerId,
      )['previous_debt_total'], 75);
      expect((await statementRepository.partners()).singleWhere(
        (row) => row['id'] == partnerId,
      )['previous_debt_total'], 0);
      await expectLater(
        accounting.revisePreviousPartyDebt(
          partyType: 'partner',
          transactionId: (partnerDebt['id'] as num).toInt(),
          cancellationReason: 'duplicate cancellation',
          userId: 1,
        ),
        throwsA(isA<StateError>()),
      );
      final correctionEvents = await db.query(
        "SELECT * FROM sync_queue WHERE status='pending' ORDER BY id",
      );
      expect(correctionEvents.map((x) => x['table_name']).toList(), [
        'worker_transactions', 'partner_transactions', 'beneficiary_manual_debts',
      ]);
      commands.addAll(correctionEvents);
      await originSync.push();
      expect(await db.query("SELECT * FROM sync_queue WHERE status<>'acknowledged'"), isEmpty);
      await accounting.cancelExpense(expenseId, 1, 'P0 reversal');
      await accounting.cancelBeneficiaryDebt(debtId, 1, 'P0 reversal');
      commands.addAll(
        await db.query(
          "SELECT * FROM sync_queue WHERE status='pending' ORDER BY id",
        ),
      );
      await originSync.push();
      expect(
        await db.query(
          "SELECT table_name,last_error FROM sync_queue WHERE status<>'acknowledged'",
        ),
        isEmpty,
      );
      final originDevice = (await db.query(
        "SELECT value FROM sync_metadata WHERE key='device_id'",
      )).single['value'];
      // Replay exactly the saved HTTP events: no duplicate journal or balance.
      final replay =
          await originApi.post('/sync/events', {
                'device_id': originDevice,
                'events': [
                  for (final command in commands)
                    {
                      'event_id': command['event_id'],
                      'entity_type': command['table_name'],
                      'entity_key':
                          '${command['table_name']}:${(jsonDecode(command['payload'] as String) as Map)['_global_id']}',
                      'operation': command['operation'],
                      'base_version': command['base_version'],
                      'payload': jsonDecode(command['payload'] as String),
                    },
                ],
              })
              as Map;
      expect(
        (replay['results'] as List).map((r) => r['status']),
        everyElement('duplicate'),
      );
      await originSync.pull();
      while (await originSync.applyInbox() > 0) {}
      expect(
        await db.query("SELECT * FROM sync_inbox WHERE status<>'applied'"),
        isEmpty,
      );
      expect(
        (await db.query('cashboxes', where: 'id=1')).single['current_balance'],
        originalCash + 180,
      );
      final expectedAllJournals = await db.query(
        "SELECT reference_type,COUNT(*) n FROM journal_entries WHERE description<>'P0 unrelated local journal' GROUP BY reference_type ORDER BY reference_type",
      );
      final expectedTotals = await db.query(
        'SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines',
      );
      final expectedJournals = await db.query(
        "SELECT reference_type,COUNT(*) n FROM journal_entries WHERE reference_type IN ('payment','irrigation') GROUP BY reference_type ORDER BY reference_type",
      );
      await db.close();

      // A different local beneficiary ID proves references are resolved by UUID.
      await databaseFactory.setDatabasesPath(peer.path);
      await db.db;
      await db.transaction(
        (tx) => tx.insert('beneficiaries', {
          'name': 'peer local unrelated party',
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        }),
        captureSync: false,
      );
      await db.transaction((tx) async {
        await tx.insert('journal_entries', {
          'station_id': 1,
          'date': now.toIso8601String(),
          'description': 'P0 unrelated local journal',
          'status': 'draft',
          'created_at': now.toIso8601String(),
        });
        await tx.insert('workers', {
          'name': 'unrelated local worker',
          'pay_type': 'fixed',
        });
        await tx.insert('partners', {
          'name': 'unrelated local partner',
          'ownership_mode': 'shares',
          'shares_count': 1,
        });
      }, captureSync: false);
      final peerSync = SyncService.withInboxHandler(
        newClient(),
        database: db,
        applyIncoming: SyncInboxApplier.apply,
      );
      await peerSync.pull();
      // Stored Inbox survives close/reopen before application.
      await db.close();
      await db.db;
      while (await peerSync.applyInbox() > 0) {}
      await peerSync.retryDeferredInbox();
      while (await peerSync.applyInbox() > 0) {}
      final failures = await db.query(
        "SELECT entity_type,status,last_error FROM sync_inbox WHERE status<>'applied'",
      );
      expect(failures, isEmpty);
      final peerParty = (await db.query(
        'beneficiaries',
        where: 'name=?',
        whereArgs: ['P0 actual origin party'],
      )).single;
      expect(peerParty['id'], isNot(beneficiaryId));
      final peerIrrigation = (await db.query(
        'irrigations',
        where: 'beneficiary_id=?',
        whereArgs: [peerParty['id']],
      )).single;
      final peerPayment = (await db.query(
        'payments',
        where: 'beneficiary_id=?',
        whereArgs: [peerParty['id']],
      )).single;
      expect(peerIrrigation['total_amount'], 1000);
      expect(peerPayment['amount'], 200);
      expect(
        (await db.query('cashboxes', where: 'id=1')).single['current_balance'],
        originalCash + 180,
      );
      expect(
        await db.query(
          "SELECT reference_type,COUNT(*) n FROM journal_entries WHERE reference_type IN ('payment','irrigation') GROUP BY reference_type ORDER BY reference_type",
        ),
        expectedJournals,
      );
      for (final entry in await db.query(
        "SELECT * FROM journal_entries WHERE reference_type IN ('payment','irrigation')",
      )) {
        expect(
          entry['reference_id'],
          entry['reference_type'] == 'payment'
              ? peerPayment['id']
              : peerIrrigation['id'],
        );
        final sums = (await db.query(
          'SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines WHERE journal_entry_id=?',
          args: [entry['id']],
        )).single;
        expect(sums['debit'], sums['credit']);
        expect(sums['debit'], greaterThan(0));
      }
      expect(
        await db.query(
          "SELECT reference_type,COUNT(*) n FROM journal_entries WHERE description<>'P0 unrelated local journal' GROUP BY reference_type ORDER BY reference_type",
        ),
        expectedAllJournals,
      );
      expect(
        await db.query(
          'SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines',
        ),
        expectedTotals,
      );
      expect((await db.query('expenses')).single['status'], 'cancelled');
      final peerDebt = (await db.query('beneficiary_manual_debts')).single;
      expect(peerDebt['status'], 'cancelled');
      expect(peerDebt['amount'], 45);
      expect(peerDebt['notes'], 'corrected beneficiary debt');
      expect(peerDebt['journal_entry_id'], isNotNull);
      expect(
        (await db.query(
          'journal_entries',
          where: 'id=?',
          whereArgs: [peerDebt['journal_entry_id']],
        )).single['reference_id'],
        peerDebt['id'],
      );
      expect(
        (await db.query(
          'cashboxes',
          where: 'name=?',
          whereArgs: ['P0 second box'],
        )).single['current_balance'],
        25,
      );
      for (final type in ['worker', 'partner']) {
        final party = (await db.query(
          '${type}s',
          where: 'name=?',
          whereArgs: ['P0 $type'],
        )).single;
        expect(party['id'], isNot(type == 'worker' ? workerId : partnerId));
        final transaction = (await db.query(
          '${type}_transactions',
          where: 'reference_type=?',
          whereArgs: ['previous_debt'],
        )).single;
        expect(transaction['${type}_id'], party['id']);
        expect(transaction['type'],
            type == 'worker' ? 'previous_receivable' : 'previous_receivable_cancelled');
        expect(transaction['amount'], type == 'worker' ? 75 : 60);
        final peerBalance = type == 'worker'
            ? await AccountingService(db).workerBalance(party['id'] as int)
            : await AccountingService(db).partnerBalance(party['id'] as int);
        expect(peerBalance['balance'], type == 'worker' ? -75 : 0);
        final journal = (await db.query(
          'journal_entries',
          where: 'id=?',
          whereArgs: [transaction['reference_id']],
        )).single;
        expect(journal['reference_id'], party['id']);
        final lines = await db.query(
          'SELECT a.code FROM journal_lines jl JOIN accounts a ON a.id=jl.account_id WHERE jl.journal_entry_id=? AND jl.debit>0',
          args: [journal['id']],
        );
        expect(
          lines.single['code'],
          '${type == 'worker' ? '2100.W' : '2200.P'}${party['id']}',
        );
      }
      final reversals = await db.query(
        "SELECT original.reference_type FROM journal_entries r JOIN journal_entries original ON original.id=r.reference_id WHERE r.reference_type='reversal' ORDER BY original.reference_type",
      );
      expect(reversals.map((r) => r['reference_type']), [
        'beneficiary_manual_debt',
        'beneficiary_manual_debt',
        'expense',
        'partner_opening',
        'worker_opening',
      ]);
      expect(irrigationId, greaterThan(0));
      expect(await db.query('sync_queue'), isEmpty);
      await peerSync.pull();
      expect(await peerSync.applyInbox(), 0);
      expect(await db.query('sync_queue'), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
