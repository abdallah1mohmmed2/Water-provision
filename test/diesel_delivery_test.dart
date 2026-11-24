import 'package:saqia_station/services/irrigation_message_fuel_service.dart';
import 'package:saqia_station/features/party_diesel_balance.dart';
import 'package:saqia_station/core/diesel_quantity.dart';
import 'package:saqia_station/features/app.dart' show BeneficiariesPage, WorkersPage, PartnersPage, DieselPage;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/maintenance/diesel_delivery_service.dart';
import 'package:saqia_station/features/diesel_delivery_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final app = AppDatabase.instance;
  late Directory folder;
  late StationRepository repo;
  late DieselDeliveryService service;
  late Map<String, int> ids;
  var sequence = 0;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    folder = await Directory.systemTemp.createTemp('diesel-delivery-');
    await databaseFactory.setDatabasesPath(folder.path);
  });
  setUp(() async {
    await app.close();
    await databaseFactory.deleteDatabase('${folder.path}/saqia_station_v2.db');
    await app.db;
    repo = StationRepository(app);
    service = DieselDeliveryService(app);
    sequence = 0;
    await repo.setSetting('system_type', 'diesel');
    await repo.setSetting('diesel_hourly_water_rate', '6000');
    await repo.setSetting('diesel_liters_per_hour', '10');
    await repo.setSetting('partial_hour', 'true');
    await repo.setSetting('min_wait_days', '0');
    final beneficiary = await app.insert('beneficiaries', {
      'station_id': 1,
      'name': 'شخص الاختبار',
      'created_at': '2026-01-01',
      'updated_at': '2026-01-01',
    });
    final worker = await repo.createWorker(
      name: 'عامل الاختبار',
      payType: 'fixed',
    );
    final partner = await repo.createPartner(
      name: 'شريك الاختبار',
      mode: 'shares',
      shares: 1,
    );
    ids = {'beneficiary': beneficiary, 'worker': worker, 'partner': partner};
  });
  tearDownAll(() async {
    await app.close();
    await folder.delete(recursive: true);
  });
  Future<int> receive(String type, double liters, {String? request}) =>
      service.receive(
        station: 1,
        user: 1,
        type: type,
        person: ids[type]!,
        liters: liters,
        date: DateTime(2026, 2, 10),
        requestId: request ?? 'request-${sequence++}',
      );
  Future<int> irrigate(String type, int hours) =>
      repo.accounting.recordIrrigation(
        stationId: 1,
        pumpId: 1,
        beneficiaryId: type == 'beneficiary' ? ids[type] : null,
        workerId: type == 'worker' ? ids[type] : null,
        partnerId: type == 'partner' ? ids[type] : null,
        partyType: type,
        start: DateTime(2026, 2, 1, 8),
        end: DateTime(2026, 2, 1, 8 + hours),
        systemType: 'diesel',
        waterRate: 6000,
        litersPerHour: 10,
        dieselPrice: 500,
        solarRate: 0,
        thirdRate: 0,
        cloudMinutes: 0,
        paidAmount: 0,
        userId: 1,
      );
  Future<num> scalar(String sql) async =>
      (await app.query(sql)).single.values.first as num;
  for (final type in ['beneficiary', 'worker', 'partner']) {
    test(
      '$type: receipt settles debt, excess becomes credit, cancellation restores debt',
      () async {
        await irrigate(type, 2);
        expect(await service.balance(1, type, ids[type]!), -20);
        expect(await repo.dieselStock(), -20);
        final journals = await scalar('SELECT COUNT(*) FROM journal_entries');
        final cash = await scalar(
          'SELECT current_balance FROM cashboxes WHERE id=1',
        );
        final first = await receive(type, 15);
        expect(await service.balance(1, type, ids[type]!), -5);
        await receive(type, 10);
        expect(await service.balance(1, type, ids[type]!), 5);
        expect(await scalar('SELECT COUNT(*) FROM journal_entries'), journals);
        expect(
          await scalar('SELECT current_balance FROM cashboxes WHERE id=1'),
          cash,
        );
        await repo.accounting.cancelDieselMovement(first, 1, 'إلغاء اختبار');
        expect(await service.balance(1, type, ids[type]!), -10);
        expect(
          await scalar(
            "SELECT COUNT(*) FROM diesel_movements WHERE party_receipt=1",
          ),
          3,
        );
        await expectLater(
          repo.accounting.cancelDieselMovement(first, 1, 'مكرر'),
          throwsStateError,
        );
        final rows = await repo.diesel(
          search: type == 'beneficiary'
              ? 'شخص'
              : type == 'worker'
              ? 'عامل'
              : 'شريك',
        );
        expect(rows.where((e) => e['party_receipt'] == 1).length, 3);
        final queue = await app.query(
          "SELECT payload FROM sync_queue WHERE table_name='diesel_movements'",
        );
        final payloads = queue
            .map((r) => jsonDecode(r['payload'] as String) as Map)
            .toList();
        expect(
          payloads.any(
            (p) =>
                (p['_global_refs'] as Map?)?.containsKey('${type}_id') ?? false,
          ),
          isTrue,
        );
      },
    );
  }
  for (final type in ['beneficiary', 'worker', 'partner']) {
    test('$type: station issue increases party debt and cancellation restores balance', () async {
      final beforeStock = await repo.dieselStock();
      await receive(type, 12);
      expect(await service.balance(1, type, ids[type]!), 12);
      expect(await repo.dieselStock(), beforeStock + 12);
      final issueId = await service.issueToParty(
        station: 1,
        user: 1,
        type: type,
        person: ids[type]!,
        liters: 5.5,
        date: DateTime(2026, 2, 11),
        requestId: 'issue-$type-${sequence++}',
        notes: 'تسليم سابق من المنظومة للطرف',
      );
      expect(await service.balance(1, type, ids[type]!), 6.5);
      expect(await repo.dieselStock(), beforeStock + 6.5);
      final issue = (await app.query('diesel_movements', where: 'id=?', whereArgs: [issueId])).single;
      expect(issue['kind'], 'consumption');
      expect(issue['party_receipt'], 1);
      expect(issue['date'], startsWith('2026-02-11'));
      await repo.accounting.cancelDieselMovement(issueId, 1, 'إلغاء تسليم سابق');
      expect(await service.balance(1, type, ids[type]!), 12);
      expect(await repo.dieselStock(), beforeStock + 12);
      final reversal = (await app.query(
        'diesel_movements',
        where: 'reversal_of=?',
        whereArgs: [issueId],
      )).single;
      expect(reversal['kind'], 'consumption');
      expect(reversal['liters'], -5.5);
    });
  }

  test(
    'future irrigation consumes only excess after settling previous advance',
    () async {
      await irrigate('beneficiary', 2);
      await receive('beneficiary', 15);
      final next = await repo.accounting.recordIrrigation(
        stationId: 1,
        pumpId: 1,
        beneficiaryId: ids['beneficiary'],
        start: DateTime(2026, 2, 12, 8),
        end: DateTime(2026, 2, 12, 9),
        systemType: 'diesel',
        waterRate: 6000,
        litersPerHour: 10,
        dieselPrice: 500,
        solarRate: 0,
        thirdRate: 0,
        cloudMinutes: 0,
        paidAmount: 0,
        userId: 1,
      );
      expect(await service.balance(1, 'beneficiary', ids['beneficiary']!), -15);
      final advances = await app.query(
        "SELECT liters FROM diesel_movements WHERE irrigation_id=? AND kind='advance'",
        args: [next],
      );
      expect(advances.single['liters'], 10);
      await repo.accounting.cancelIrrigation(next, 1, 'إلغاء السقاية');
      expect(await service.balance(1, 'beneficiary', ids['beneficiary']!), -5);
    },
  );
  test(
    'duplicate request, invalid quantity, solar and wrong station rollback',
    () async {
      await receive('worker', 5, request: 'same');
      await expectLater(
        receive('worker', 5, request: 'same'),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(receive('worker', double.nan), throwsArgumentError);
      await expectLater(
        service.receive(
          station: 2,
          user: 1,
          type: 'worker',
          person: ids['worker']!,
          liters: 5,
          date: DateTime(2026),
          requestId: 'foreign',
        ),
        throwsStateError,
      );
      await repo.setSetting('system_type', 'solar');
      await expectLater(receive('worker', 5), throwsStateError);
      await repo.setSetting('system_type', 'equivalent_hybrid');
      await receive('worker', 5);
      expect(await service.balance(1, 'worker', ids['worker']!), 10);
      expect(
        await scalar(
          "SELECT COUNT(*) FROM diesel_movements WHERE party_receipt=1",
        ),
        2,
      );
    },
  );
  testWidgets(
    'delivery screen saves liters for selected beneficiary with balance preview',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: DieselDeliveryPage(repo, userId: 1)),
      );
      for (var i = 0; i < 100 && find.text('الاسم').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('شخص الاختبار').last);
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 && find.text('الرصيد الحالي: الرصيد متعادل').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.enterText(
        find.widgetWithText(TextField, 'الكمية المستلمة باللترات'),
        '15',
      );
      await tester.pump();
      expect(find.text('بعد الحركة: له 15 لتر'), findsOneWidget);
      await tester.tap(find.text('حفظ تسليم الديزل'));
      await tester.pump();
      for (
        var i = 0;
        i < 100 &&
            find.text('تم تسجيل التسليم وتسوية رصيد الديزل').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('تم تسجيل التسليم وتسوية رصيد الديزل'), findsOneWidget);
      expect(
        await tester.runAsync(
          () => service.balance(1, 'beneficiary', ids['beneficiary']!),
        ),
        15,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'hybrid system exposes the existing diesel page and delivery action',
    (tester) async {
      await tester.runAsync(() => repo.setSetting('system_type', 'equivalent_hybrid'));
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: DieselPage(repo, userId: 1)));
      for (var i = 0; i < 100 && find.text('إضافة تسليم ديزل').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('إضافة تسليم ديزل'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'v33 diesel rows survive migration and gain nullable party fields',
    () async {
      final db = await app.db;
      final id = await db.insert('diesel_movements', {
        'station_id': 1,
        'kind': 'receipt',
        'liters': 17.5,
        'unit_price': 100,
        'amount': 1750,
        'date': '2026-01-01',
      });
      await db.execute('DROP INDEX idx_diesel_request');
      for (final column in [
        'worker_id',
        'partner_id',
        'request_id',
        'party_receipt',
      ]) {
        await db.execute('ALTER TABLE diesel_movements DROP COLUMN $column');
      }
      await db.execute('PRAGMA user_version=33');
      await app.close();
      final upgraded = await app.db;
      final old = (await upgraded.query(
        'diesel_movements',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      expect(old['liters'], 17.5);
      expect(old['amount'], 1750);
      expect(old['kind'], 'receipt');
      expect(old['party_receipt'], 0);
      expect(old['worker_id'], isNull);
      await receive('worker', 2);
      expect(await service.balance(1, 'worker', ids['worker']!), 2);
    },
  );
  test('card balances and report consumption use recorded liters for all owners', () async {
    final cash = await scalar('SELECT current_balance FROM cashboxes WHERE id=1');
    for (final type in ['beneficiary', 'worker', 'partner']) {
      final irrigation = await irrigate(type, 1);
      final receipt = await receive(type, 5.75);
      final cards = await PartyDieselBalance.loadRows(repo, type, [
        {'id': ids[type]},
      ]);
      expect(cards.single['party_diesel_balance'], -4.25);
      expect(DieselQuantity.balanceLabel(cards.single['party_diesel_balance'] as num), 'ديزل عليه 4.25 لتر');
      final report = await repo.report('irrigations', systemType: 'all');
      expect(report.singleWhere((row) => row['irrigation_id'] == irrigation)['diesel_consumption_liters'], 10);
      await repo.accounting.cancelDieselMovement(receipt, 1, 'عكس التسليم');
      expect(await service.balance(1, type, ids[type]!), -10);
      await repo.accounting.cancelIrrigation(irrigation, 1, 'عكس التسقية');
      expect(await service.balance(1, type, ids[type]!), 0);
    }
    expect(await scalar('SELECT current_balance FROM cashboxes WHERE id=1'), cash);
    await repo.setSetting('system_type', 'solar');
    final rows = await PartyDieselBalance.loadRows(repo, 'beneficiary', [{'id': ids['beneficiary']}]);
    expect(rows.single.containsKey('party_diesel_balance'), isFalse);
  });

  test('old consumption survives engine rate changes in PDF sources', () async {
    final irrigation = await irrigate('beneficiary', 1);
    await repo.setSetting('diesel_liters_per_hour', '99');
    for (final key in ['irrigations', 'invoices', 'beneficiary_detailed']) {
      final rows = await repo.report(key, beneficiaryId: ids['beneficiary'], systemType: 'diesel');
      final row = rows.singleWhere((row) => row['irrigation_id'] == irrigation || row['invoice_id'] == irrigation || row['type'] == 's');
      expect(row['diesel_consumption_liters'], 10);
    }
  });

  test('personal diesel rates apply per owner and clearing restores station default', () async {
    for (final type in ['beneficiary', 'worker', 'partner']) {
      final id = ids[type]!;
      Future<void> update(double? rate) async {
        final values = <String,Object?>{'diesel_liters_per_hour': rate};
        if (type == 'beneficiary') {
          await repo.updateBeneficiary(id, values, 1);
        } else if (type == 'worker') {
          await repo.updateWorker(id, values, 1);
        } else {
          await repo.updatePartner(id, values, 1);
        }
      }
      await update(type == 'beneficiary' ? 5 : 4.65);
      final irrigation = await irrigate(type, 2);
      final saved = (await app.query('irrigations', where: 'id=?', whereArgs: [irrigation])).single;
      final expected = type == 'beneficiary' ? 10.0 : 9.3;
      expect(await service.balance(1, type, id), closeTo(-expected, 0.00001));
      expect(saved['diesel_liters_per_hour_snapshot'], type == 'beneficiary' ? 5 : 4.65);
      await update(9);
      expect(await service.balance(1, type, id), closeTo(-expected, 0.00001));
      final stillSaved = (await app.query('irrigations', where: 'id=?', whereArgs: [irrigation])).single;
      expect(stillSaved['diesel_liters_per_hour_snapshot'], saved['diesel_liters_per_hour_snapshot']);
      await repo.accounting.cancelIrrigation(irrigation, 1, 'عكس بعد تعديل المعدل');
      expect(await service.balance(1, type, id), closeTo(0, 0.00001));
      await update(null);
      final fallback = await irrigate(type, 1);
      expect((await app.query('irrigations', where: 'id=?', whereArgs: [fallback])).single['diesel_liters_per_hour_snapshot'], 10);
      await expectLater(update(-1), throwsArgumentError);
      await expectLater(update(4.655), throwsArgumentError);
      await repo.accounting.cancelIrrigation(fallback, 1, 'إنهاء حالة الاختبار قبل الطرف التالي');
    }
  });

  test('creation stores personal rates and version 34 upgrade preserves records through version 36', () async {
    final b = await repo.createBeneficiary(name: 'معدل مستفيد', dieselLitersPerHour: 5);
    final w = await repo.createWorker(name: 'معدل عامل', payType: 'fixed', dieselLitersPerHour: 4.65);
    final p = await repo.createPartner(name: 'معدل شريك', mode: 'shares', shares: 1, dieselLitersPerHour: 4.5);
    for (final entry in {'beneficiaries': b, 'workers': w, 'partners': p}.entries) {
      expect((await app.query(entry.key, where: 'id=?', whereArgs: [entry.value])).single['diesel_liters_per_hour'], isNotNull);
    }
    final db = await app.db;
    for (final table in ['beneficiaries', 'workers', 'partners']) {
      await db.execute('ALTER TABLE $table DROP COLUMN diesel_liters_per_hour');
    }
    await db.execute('PRAGMA user_version=34');
    await app.close();
    final upgraded = await app.db;
    expect(await upgraded.getVersion(), 36);
    for (final entry in {'beneficiaries': b, 'workers': w, 'partners': p}.entries) {
      final row = (await app.query(entry.key, where: 'id=?', whereArgs: [entry.value])).single;
      expect(row['diesel_liters_per_hour'], isNull);
      expect(row['name'], startsWith('معدل'));
    }
  });

  for (final type in ['beneficiary', 'worker', 'partner']) {
    test('message fuel uses saved consumption and signed $type balance without writes', () async {
      final table = DieselDeliveryService.tables[type]!;
      await (await app.db).update(table, {'diesel_liters_per_hour': 4.65}, where:'id=?', whereArgs:[ids[type]]);
      await receive(type, 5.75);
      final irrigation = await irrigate(type, 2);
      await (await app.db).update(table, {'diesel_liters_per_hour': 99}, where:'id=?', whereArgs:[ids[type]]);
      final queue = await scalar('SELECT COUNT(*) FROM sync_queue');
      final journals = await scalar('SELECT COUNT(*) FROM journal_entries');
      final fuel = IrrigationMessageFuelService(repo);
      final values = await fuel.forIrrigation(irrigation);
      expect(values['الديزل المستهلك'], '9.3 لتر');
      expect(values['رصيد الديزل المتبقي'], 'عليه 3.55 لتر');
      expect(values['ديزل له'], '0 لتر');
      expect(values['ديزل عليه'], '3.55 لتر');
      expect(await scalar('SELECT COUNT(*) FROM sync_queue'), queue);
      expect(await scalar('SELECT COUNT(*) FROM journal_entries'), journals);
      await receive(type, 10);
      final positive = await fuel.forIrrigation(irrigation);
      expect(positive['الديزل المستهلك'], '9.3 لتر');
      expect(positive['رصيد الديزل المتبقي'], 'له 6.45 لتر');
      expect(positive['ديزل عليه'], '0 لتر');
      await repo.accounting.cancelIrrigation(irrigation, 1, 'عكس اختبار الرسالة');
      expect(await fuel.forIrrigation(irrigation), isEmpty);
    });
  }

  Future<void> waitForUi(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 150 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  void largeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'beneficiary card opens exact person and saves diesel against their debt',
    (tester) async {
      largeView(tester);
      final target = await tester.runAsync(
        () => app.insert('beneficiaries', {
          'station_id': 1,
          'name': 'مستفيد آخر',
          'opening_diesel_liters': -20,
          'created_at': '2026-01-01',
          'updated_at': '2026-01-01',
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BeneficiariesPage(repo, userId: 1, manager: true),
          ),
        ),
      );
      final button = find.byKey(ValueKey('party-diesel-delivery-beneficiary-$target'));
      await waitForUi(tester, () => button.evaluate().isNotEmpty);
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await waitForUi(
        tester,
        () => find.text('الرصيد الحالي: عليه 20 لتر').evaluate().isNotEmpty,
      );
      expect(find.text('الرصيد الحالي: عليه 20 لتر'), findsOneWidget);
      final selector = tester.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>),
      );
      expect(selector.initialValue, target);
      await tester.enterText(
        find.widgetWithText(TextField, 'الكمية المستلمة باللترات'),
        '15',
      );
      await tester.pump();
      expect(find.text('بعد التسليم: عليه 5 لتر'), findsOneWidget);
      await tester.tap(find.text('حفظ تسليم الديزل'));
      await tester.pump();
      await waitForUi(
        tester,
        () => find
            .text('تم تسجيل التسليم وتسوية رصيد الديزل')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        await tester.runAsync(() => service.balance(1, 'beneficiary', target!)),
        -5,
      );
      expect(
        await tester.runAsync(
          () => service.balance(1, 'beneficiary', ids['beneficiary']!),
        ),
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final type in ['worker', 'partner']) {
    testWidgets(
      '$type card opens diesel delivery for the selected person',
      (tester) async {
        largeView(tester);
        final target = ids[type]!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: type == 'worker'
                  ? WorkersPage(repo, userId: 1, manager: true)
                  : PartnersPage(repo, userId: 1, manager: true),
            ),
          ),
        );
        final button = find.byKey(
          ValueKey('party-diesel-delivery-$type-$target'),
        );
        await waitForUi(tester, () => button.evaluate().isNotEmpty);
        expect(button, findsOneWidget);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await waitForUi(
          tester,
          () => find.text('الاسم').evaluate().isNotEmpty,
        );
        final typeSelector = tester.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>).first,
        );
        expect(typeSelector.initialValue, type);
        final personSelector = tester.widget<DropdownButtonFormField<int>>(
          find.byType(DropdownButtonFormField<int>),
        );
        expect(personSelector.initialValue, target);
        expect(find.text('إضافة تسليم ديزل'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final system in ['solar', 'equivalent_hybrid']) {
    testWidgets('beneficiary card hides diesel delivery for $system', (
      tester,
    ) async {
      largeView(tester);
      await tester.runAsync(() => repo.setSetting('system_type', system));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BeneficiariesPage(repo, userId: 1, manager: true),
          ),
        ),
      );
      await waitForUi(
        tester,
        () => find.text('شخص الاختبار').evaluate().isNotEmpty,
      );
      expect(find.text('شخص الاختبار'), findsOneWidget);
      expect(find.text('إضافة تسليم ديزل'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'missing initial beneficiary fails closed without choosing somebody else',
    (tester) async {
      largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: DieselDeliveryPage(
            repo,
            userId: 1,
            initialPartyType: 'beneficiary',
            initialPartyId: 999999,
          ),
        ),
      );
      await waitForUi(
        tester,
        () => find
            .textContaining('الطرف المحدد غير موجود')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('الطرف المحدد غير موجود'), findsOneWidget);
      expect(find.text('حفظ تسليم الديزل'), findsNothing);
      expect(
        await tester.runAsync(
          () => scalar(
            'SELECT COUNT(*) FROM diesel_movements WHERE party_receipt=1',
          ),
        ),
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
