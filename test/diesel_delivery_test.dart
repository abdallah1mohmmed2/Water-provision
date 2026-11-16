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
      expect(
        await scalar(
          "SELECT COUNT(*) FROM diesel_movements WHERE party_receipt=1",
        ),
        1,
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
      expect(find.text('بعد التسليم: له 15.000 لتر'), findsOneWidget);
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
}
