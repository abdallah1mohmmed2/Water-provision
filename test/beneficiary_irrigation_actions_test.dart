import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/core/app_clock.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/beneficiary_irrigation_actions.dart';
import 'package:saqia_station/features/app.dart' show RecordDetailsPage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;
  late Directory dir;
  late StationRepository repo;
  late int beneficiary, other;
  late DateTime start;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp(
      'beneficiary-irrigation-actions-',
    );
    await databaseFactory.setDatabasesPath(dir.path);
    await initializeDateFormatting('ar');
  });
  setUp(() async {
    await db.close();
    await databaseFactory.deleteDatabase('${dir.path}/saqia_station_v2.db');
    await db.db;
    repo = StationRepository(db);
    final now = AppClock.now();
    start = DateTime(now.year, now.month, now.day, 8);
    beneficiary = await repo.createBeneficiary(name: 'صاحب السقاية');
    other = await repo.createBeneficiary(name: 'مستفيد آخر');
    for (final setting in {
      'diesel_hourly_water_rate': '6000',
      'solar_hourly_rate': '6000',
      'third_type_hourly_rate': '6000',
      'diesel_liters_per_hour': '2',
      'partial_hour': 'true',
      'min_wait_days': '0',
    }.entries) {
      await repo.setSetting(setting.key, setting.value);
    }
  });
  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  Future<int> record(
    String type, {
    int? owner,
    int atHour = 8,
    int paid = 300,
  }) async {
    await repo.setSetting('system_type', type);
    return repo.accounting.recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: owner ?? beneficiary,
      start: DateTime(start.year, start.month, start.day, atHour),
      end: DateTime(start.year, start.month, start.day, atHour + 1),
      systemType: type,
      waterRate: 6000,
      litersPerHour: 2,
      dieselPrice: 0,
      solarRate: 6000,
      thirdRate: 6000,
      cloudMinutes: 0,
      paidAmount: paid,
      paymentMethodId: paid > 0 ? 1 : null,
      cashboxId: paid > 0 ? 1 : null,
      userId: 1,
    );
  }

  BeneficiaryIrrigationActions actions(int id, {int? owner, int user = 1}) =>
      BeneficiaryIrrigationActions(
        db,
        userId: user,
        beneficiaryId: owner ?? beneficiary,
        irrigationId: id,
      );
  Future<Map<String, Object?>> row(int id) async => (await db.query(
    'SELECT * FROM irrigations WHERE id=?',
    args: [id],
  )).single;
  Future<void> drain(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Widget page({int? user = 1}) => MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: RecordDetailsPage(
      repo,
      kind: 'beneficiary',
      id: beneficiary,
      title: 'تفاصيل المستفيد',
      userId: user,
    ),
  );
  for (final type in ['diesel', 'solar', 'equivalent_hybrid']) {
    testWidgets(
      '$type details long press edits table irrigation then cancels through timeline',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 4000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final id = await tester.runAsync(() => record(type));
        final otherId = await tester.runAsync(
          () => record(type, owner: other, atHour: 12, paid: 0),
        );
        await tester.pumpWidget(page());
        final target = find.byKey(ValueKey('beneficiary-irrigation-table-$id'));
        await drain(tester, () => target.evaluate().isNotEmpty);
        expect(target, findsOneWidget);
        await tester.ensureVisible(target);
        await tester.pump();
        await tester.longPress(target);
        await tester.pumpAndSettle();
        await drain(
          tester,
          () => find.text('تعديل السقاية').evaluate().isNotEmpty,
        );
        expect(find.text('تعديل السقاية'), findsOneWidget);
        await tester.tap(find.text('تعديل السقاية'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'وقت النهاية'),
          '07:00',
        );
        await tester.tap(find.text('حفظ تعديل السقاية'));
        await tester.pump();
        expect(
          find.text('وقت النهاية يجب أن يكون بعد وقت البداية'),
          findsOneWidget,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'وقت النهاية'),
          '10:00',
        );
        await tester.tap(find.text('حفظ تعديل السقاية'));
        await tester.pump();
        await drain(
          tester,
          () => find
              .text('تم تعديل السقاية وتحديث حساب المستفيد')
              .evaluate()
              .isNotEmpty,
        );
        expect((await tester.runAsync(() => row(id!)))!['minutes'], 120);
        expect((await tester.runAsync(() => row(id!)))!['total_amount'], 12000);
        expect(
          (await tester.runAsync(() => row(otherId!)))!['total_amount'],
          6000,
        );
        await drain(tester, () => find.text('120 دقيقة').evaluate().isNotEmpty);
        expect(find.text('120 دقيقة'), findsOneWidget);
        final history = find.byKey(
          ValueKey('beneficiary-irrigation-history-s-$id'),
        );
        await drain(
          tester,
          () =>
              history.evaluate().isNotEmpty &&
              tester.widget<GestureDetector>(history).onLongPress != null,
        );
        await tester.ensureVisible(history);
        await tester.pump();
        await tester.longPress(history);
        await tester.pumpAndSettle();
        await drain(
          tester,
          () =>
              find.text('حذف السقاية (إلغاء وعكس الأثر)').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('حذف السقاية (إلغاء وعكس الأثر)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد إلغاء السقاية'));
        await tester.pump();
        expect(find.text('سبب الإلغاء مطلوب'), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextField, 'سبب الإلغاء'),
          'تصحيح سجل المستفيد',
        );
        await tester.tap(find.text('تأكيد إلغاء السقاية'));
        await tester.pump();
        await drain(
          tester,
          () => find.text('تأكيد إلغاء السقاية').evaluate().isEmpty,
        );
        final saved = await tester.runAsync(() => row(id!));
        expect(saved!['status'], 'cancelled');
        expect(saved['cancel_reason'], 'تصحيح سجل المستفيد');
        expect(
          (await tester.runAsync(() => row(otherId!)))!['status'],
          'posted',
        );
        final cash = await tester.runAsync(
          () => db.query('SELECT current_balance FROM cashboxes WHERE id=1'),
        );
        expect(cash!.single['current_balance'], 0);
        final balance = await tester.runAsync(
          () => repo.accounting.beneficiaryBalance(beneficiary),
        );
        expect(balance!['balance'], 0);
        if (type == 'diesel') {
          final fuel = await tester.runAsync(
            () => db.query(
              'SELECT COALESCE(SUM(liters),0) n FROM diesel_movements WHERE irrigation_id=? AND kind=\'consumption\'',
              args: [id],
            ),
          );
          expect(fuel!.single['n'], 0);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test('scope and role rechecked atomically, cancellation retained and not repeated', () async {
    final id = await record('diesel');
    await expectLater(
      actions(
        id,
        owner: other,
      ).edit(start, start.add(const Duration(hours: 2))),
      throwsStateError,
    );
    await db.update('app_users', {'role': 'operations'}, 'id=?', [1]);
    await expectLater(actions(id).cancel('ممنوع'), throwsStateError);
    expect((await row(id))['status'], 'posted');
    await db.update('app_users', {'role': 'accountant'}, 'id=?', [1]);
    await actions(id).edit(start, start.add(const Duration(hours: 2)));
    await actions(id).cancel('إلغاء مدقق');
    await expectLater(actions(id).cancel('ثانية'), throwsStateError);
    expect((await row(id))['status'], 'cancelled');
  });
  testWidgets('details without actor stay read only', (tester) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final id = await tester.runAsync(() => record('solar'));
    await tester.pumpWidget(page(user: null));
    final history = find.byKey(
      ValueKey('beneficiary-irrigation-history-s-$id'),
    );
    await drain(tester, () => history.evaluate().isNotEmpty);
    expect(history, findsOneWidget);
    expect(tester.widget<GestureDetector>(history).onLongPress, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
