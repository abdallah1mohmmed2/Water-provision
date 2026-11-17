import 'package:flutter/material.dart';
import 'package:saqia_station/features/diesel_oil_page.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/domain/maintenance/diesel_oil_service.dart';
import 'package:saqia_station/core/app_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;
  late Directory directory;
  late DieselOilService service;
  late DateTime clock;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('diesel_oil_test_');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  setUp(() async {
    await db.close();
    await databaseFactory.deleteDatabase(
      '${directory.path}/saqia_station_v2.db',
    );
    await db.db;
    clock = DateTime(2026, 1, 1, 8);
    service = DieselOilService(db, clock: () => clock);
    await db.transaction((tx) async {
      await tx.update(
        'settings',
        {'value': 'diesel'},
        where: 'key=?',
        whereArgs: ['system_type'],
      );
    }, captureSync: false);
  });
  tearDownAll(() async {
    await db.close();
    await directory.delete(recursive: true);
  });
  Future<void> configure({
    int initial = 0,
    int interval = 600,
    int warning = 120,
  }) => service.configure(
    station: 1,
    user: 1,
    interval: interval,
    warning: warning,
    initial: initial,
  );
  Future<int> irrigation(
    DateTime start,
    DateTime end, {
    String type = 'diesel',
    String status = 'posted',
  }) async => db.transaction(
    (tx) => tx.insert('irrigations', {
      'station_id': 1,
      'pump_id': 1,
      'date': start.toIso8601String(),
      'start_datetime': start.toIso8601String(),
      'end_datetime': end.toIso8601String(),
      'minutes': end.difference(start).inMinutes,
      'chargeable_minutes': 999,
      'system_type': type,
      'status': status,
      'created_at': start.toIso8601String(),
      'updated_at': end.toIso8601String(),
    }),
    captureSync: false,
  );
  Future<int> change(String cycle, String request) => service.change(
    station: 1,
    user: 1,
    amount: 2500,
    paymentMethod: 1,
    cashbox: 1,
    expectedCycle: cycle,
    requestId: request,
  );
  Future<num> scalar(String sql) async =>
      (await db.query(sql)).first.values.first as num;

  test(
    'legacy cycles retain clipped historical hours and exclude unrecorded future hours',
    () async {
      await configure(initial: 60);
      final savedConfig = (await db.query(
        "SELECT value FROM settings WHERE key='diesel_oil_maintenance_v1.1'",
      )).single['value'] as String;
      final legacy = jsonDecode(savedConfig) as Map<String, dynamic>;
      legacy.remove('irrigation_baseline_id');
      await db.update('settings', {'value': jsonEncode(legacy)}, 'key=?',
        ['diesel_oil_maintenance_v1.1']);
      await irrigation(DateTime(2026, 1, 1, 7), DateTime(2026, 1, 1, 9));
      await irrigation(
        DateTime(2026, 1, 1, 9),
        DateTime(2026, 1, 1, 10),
        type: 'solar',
      );
      await irrigation(
        DateTime(2026, 1, 1, 9),
        DateTime(2026, 1, 1, 10),
        status: 'cancelled',
      );
      await irrigation(DateTime(2026, 1, 1, 11), DateTime(2026, 1, 1, 12));
      clock = DateTime(2026, 1, 1, 10);
      expect((await service.load(1)).usedMinutes, 120);
      await configure(interval: 120, warning: 30);
      expect((await service.load(1)).state, 'due');
      expect((await service.load(1)).usedMinutes, 120);
    },
  );
  test('120 hours deduct all three owners, persist, and reset only on oil change', () async {
    final repo = StationRepository(db);
    final beneficiary = await repo.createBeneficiary(name: 'مستفيد الزيت');
    final worker = await repo.createWorker(name: 'عامل الزيت', payType: 'fixed');
    final partner = await repo.createPartner(name: 'شريك الزيت', mode: 'shares', shares: 1);
    await repo.setSetting('min_wait_days', '0');
    await repo.setSetting('diesel_hourly_water_rate', '6000');
    await repo.setSetting('diesel_liters_per_hour', '2');
    // Already recorded rows belong to the previous cycle, even with later times.
    await irrigation(clock, clock.add(const Duration(hours: 1)));
    await configure(interval: 120 * 60, warning: 10 * 60);
    final ids = <int>[];
    for (var i = 0; i < 3; i++) {
      final at = DateTime(2025, 12, 20 + i, 8);
      ids.add(await repo.accounting.recordIrrigation(
        stationId: 1, pumpId: 1,
        partyType: ['beneficiary', 'worker', 'partner'][i],
        beneficiaryId: i == 0 ? beneficiary : null,
        workerId: i == 1 ? worker : null,
        partnerId: i == 2 ? partner : null,
        start: at, end: at.add(const Duration(hours: 3)),
        systemType: 'diesel', waterRate: 6000, litersPerHour: 2,
        dieselPrice: 0, solarRate: 0, thirdRate: 0,
        cloudMinutes: 0, paidAmount: 0, userId: 1,
      ));
      expect((await service.load(1)).remaining, (120 - (i + 1) * 3) * 60);
    }
    await db.close();
    expect((await service.load(1)).remaining, 111 * 60);
    await configure(interval: 120 * 60, warning: 20 * 60);
    expect((await service.load(1)).remaining, 111 * 60);
    await repo.accounting.cancelIrrigation(ids.last, 1, 'تصحيح');
    expect((await service.load(1)).remaining, 114 * 60);
    clock = clock.add(const Duration(hours: 1));
    final expense = await change((await service.load(1)).cycle, 'manual-reset');
    expect((await service.load(1)).remaining, 120 * 60);
    await service.cancel(station: 1, user: 1, expense: expense, reason: 'تراجع');
    expect((await service.load(1)).remaining, 114 * 60);
  });
  test('new cycles count posted duration immediately, not scheduled or cancelled rows', () async {
    await configure(interval: 180, warning: 30);
    await irrigation(clock.subtract(const Duration(days: 1)),
      clock.subtract(const Duration(days: 1)).add(const Duration(hours: 3)));
    expect((await service.load(1)).remaining, 0);
    await irrigation(clock, clock.add(const Duration(hours: 1)));
    expect((await service.load(1)).remaining, -60);
    await irrigation(clock, clock.add(const Duration(hours: 1)), status: 'scheduled');
    await irrigation(clock, clock.add(const Duration(hours: 1)), status: 'cancelled');
    await irrigation(clock, clock.add(const Duration(hours: 1)), type: 'solar');
    expect((await service.load(1)).remaining, -60);
    // Advancing the clock never resets or deducts the same row a second time.
    clock = clock.add(const Duration(days: 10));
    expect((await service.load(1)).remaining, -60);
  });
  test('irrigation change signal follows commit and stays silent on rollback and reads', () async {
    var changes = 0;
    final subscription = db.irrigationChanges.listen((_) => changes++);
    try {
      final id = await irrigation(clock, clock.add(const Duration(hours: 1)));
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      await service.load(1);
      await expectLater(db.transaction((tx) async {
        await tx.update('irrigations', {'status': 'cancelled'}, where: 'id=?', whereArgs: [id]);
        throw StateError('rollback');
      }), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      expect((await db.query('irrigations', where: 'id=?', whereArgs: [id])).single['status'], 'posted');
    } finally {
      await subscription.cancel();
    }
  });
  test('threshold alerts remain active without a dashboard card', () async {
    await configure(interval: 600, warning: 120);
    final alerts = <AppAlert>[];
    final subscription = AppAlerts.stream.listen(alerts.add);
    final watcher = watchDieselOilAlerts(StationRepository(db));
    try {
      await irrigation(clock, clock.add(const Duration(hours: 9)));
      for (var i = 0; i < 100 && alerts.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(alerts.where((a) => a.title == 'تنبيه تغيير الزيت'), hasLength(1));
      expect(alerts.single.body, 'متبقي 1.00 ساعة سقاية لتغيير الزيت');
      await irrigation(clock, clock.add(const Duration(hours: 2)));
      for (var i = 0; i < 100 && alerts.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(alerts.where((a) => a.title == 'تنبيه تغيير الزيت'), hasLength(2));
      expect(alerts.last.body, 'تأخر تغيير الزيت بمقدار 1.00 ساعة سقاية');
    } finally {
      await watcher.cancel();
      await subscription.cancel();
    }
  });
  testWidgets('oil card updates immediately and alerts after every threshold irrigation without timer spam', (tester) async {
    await tester.runAsync(() => configure(interval: 600, warning: 120));
    final alerts = <AppAlert>[];
    final subscription = AppAlerts.stream.listen(alerts.add);
    Future<void> waitFor(String message) async {
      for (var i = 0; i < 200 && find.text(message).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(find.text(message), findsOneWidget);
    }
    try {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        DieselOilCard(StationRepository(db), userId: 1, role: 'manager'))));
      await waitFor('متبقي 10.00 ساعة سقاية لتغيير الزيت');
      await tester.runAsync(() => irrigation(clock, clock.add(const Duration(hours: 8))));
      await waitFor('متبقي 2.00 ساعة سقاية لتغيير الزيت');
      expect(alerts.where((a) => a.title == 'تنبيه تغيير الزيت'), hasLength(1));
      await tester.runAsync(() => irrigation(clock, clock.add(const Duration(minutes: 30))));
      await waitFor('متبقي 1.50 ساعة سقاية لتغيير الزيت');
      expect(alerts.where((a) => a.title == 'تنبيه تغيير الزيت'), hasLength(2));
      await tester.pump(const Duration(seconds: 30));
      // The periodic read starts in Flutter's fake-async zone. Alternate real
      // SQLite progress with frames before awaiting the next write; otherwise
      // that write can wait on a read whose continuation needs another frame.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(alerts.where((a) => a.title == 'تنبيه تغيير الزيت'), hasLength(2));
      await tester.runAsync(() => irrigation(clock, clock.add(const Duration(hours: 2))));
      await waitFor('تأخر تغيير الزيت بمقدار 0.50 ساعة سقاية');
      expect(alerts.where((a) => a.title == 'تنبيه تغيير الزيت'), hasLength(3));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await subscription.cancel();
    }
  });
  test(
    'irrigation edits and cancellation recalculate warning and overdue',
    () async {
      await configure(interval: 120, warning: 30);
      final id = await irrigation(
        clock,
        clock.add(const Duration(minutes: 100)),
      );
      clock = clock.add(const Duration(hours: 3));
      expect((await service.load(1)).state, 'warning');
      await db.transaction(
        (tx) => tx.update(
          'irrigations',
          {'end_datetime': DateTime(2026, 1, 1, 10, 30).toIso8601String()},
          where: 'id=?',
          whereArgs: [id],
        ),
        captureSync: false,
      );
      expect((await service.load(1)).remaining, -30);
      await db.transaction(
        (tx) => tx.update(
          'irrigations',
          {'status': 'cancelled'},
          where: 'id=?',
          whereArgs: [id],
        ),
        captureSync: false,
      );
      expect((await service.load(1)).usedMinutes, 0);
    },
  );
  test(
    'one expense reduces cash and profit once; cancellation restores cycle',
    () async {
      await configure(initial: 480);
      final before = await service.load(1);
      clock = clock.add(const Duration(hours: 1));
      final id = await change(before.cycle, 'first');
      expect(
        await scalar('SELECT current_balance FROM cashboxes WHERE id=1'),
        -2500,
      );
      expect(
        await scalar(
          "SELECT SUM(l.debit-l.credit) FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE a.code='5020'",
        ),
        2500,
      );
      expect(await scalar('SELECT SUM(debit-credit) FROM journal_lines'), 0);
      expect((await service.load(1)).usedMinutes, 0);
      expect(
        await scalar(
          "SELECT COUNT(*) FROM sync_queue WHERE table_name='expenses'",
        ),
        1,
      );
      await expectLater(change(before.cycle, 'repeat'), throwsStateError);
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 1);
      await irrigation(clock, clock.add(const Duration(hours: 2)));
      clock = clock.add(const Duration(hours: 3));
      expect((await service.load(1)).usedMinutes, 120);
      // A cancellation from the ordinary Expenses screen also restores the counter.
      await AccountingService(db).cancelExpense(id, 1, 'تسجيل غير صحيح');
      expect((await service.load(1)).usedMinutes, 600);
      expect(
        await scalar('SELECT current_balance FROM cashboxes WHERE id=1'),
        0,
      );
      expect(
        await scalar(
          "SELECT SUM(l.debit-l.credit) FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE a.code='5020'",
        ),
        0,
      );
      await expectLater(
        change((await service.load(1)).cycle, 'first'),
        throwsStateError,
      );
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 1);
    },
  );
  test(
    'concurrent submissions commit only one reset and one expense',
    () async {
      await configure();
      final cycle = (await service.load(1)).cycle;
      final results = await Future.wait([
        for (final id in ['a', 'b'])
          change(cycle, id).then((_) => true, onError: (Object _) => false),
      ]);
      expect(results.where((e) => e).length, 1);
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 1);
      expect(
        await scalar('SELECT current_balance FROM cashboxes WHERE id=1'),
        -2500,
      );
    },
  );
  test(
    'solar and invalid settings cannot post or reset financial state',
    () async {
      await expectLater(configure(interval: 0), throwsArgumentError);
      await expectLater(configure(warning: 600), throwsArgumentError);
      await configure();
      final cycle = (await service.load(1)).cycle;
      await db.transaction(
        (tx) => tx.update(
          'settings',
          {'value': 'solar'},
          where: 'key=?',
          whereArgs: ['system_type'],
        ),
        captureSync: false,
      );
      await expectLater(change(cycle, 'solar'), throwsStateError);
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 0);
      expect(await scalar('SELECT COUNT(*) FROM journal_entries'), 0);
      expect(
        await scalar('SELECT current_balance FROM cashboxes WHERE id=1'),
        0,
      );
    },
  );
  test(
    'only active manager configures and authorized station user posts',
    () async {
      await configure();
      final cycle = (await service.load(1)).cycle;
      await db.transaction(
        (tx) => tx.update('app_users', {'role': 'operations'}, where: 'id=1'),
        captureSync: false,
      );
      await expectLater(configure(), throwsStateError);
      await expectLater(change(cycle, 'denied'), throwsStateError);
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 0);
      await db.transaction(
        (tx) => tx.update('app_users', {'role': 'accountant'}, where: 'id=1'),
        captureSync: false,
      );
      await expectLater(configure(), throwsStateError);
      await change(cycle, 'accountant');
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 1);
    },
  );
  test(
    'cancel older change keeps newest cycle; restart preserves history',
    () async {
      await configure(initial: 300);
      final first = await change((await service.load(1)).cycle, 'one');
      clock = clock.add(const Duration(hours: 1));
      final second = await change((await service.load(1)).cycle, 'two');
      await service.cancel(
        station: 1,
        user: 1,
        expense: first,
        reason: 'تسجيل قديم خاطئ',
      );
      expect((await service.load(1)).usedMinutes, 0);
      await db.close();
      final restarted = DieselOilService(db, clock: () => clock);
      expect((await restarted.load(1)).history.length, 2);
      await restarted.cancel(
        station: 1,
        user: 1,
        expense: second,
        reason: 'تصحيح',
      );
      expect((await restarted.load(1)).usedMinutes, 300);
      expect(
        await scalar('SELECT current_balance FROM cashboxes WHERE id=1'),
        0,
      );
      await expectLater(
        restarted.cancel(station: 1, user: 1, expense: second, reason: 'تكرار'),
        throwsStateError,
      );
    },
  );
  test(
    'configuration change invalidates stale submission without posting',
    () async {
      await configure();
      final cycle = (await service.load(1)).cycle;
      await configure(interval: 1200);
      await expectLater(change(cycle, 'stale'), throwsStateError);
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 0);
      expect(await scalar('SELECT COUNT(*) FROM sync_queue'), 0);
      clock = clock.subtract(const Duration(days: 1));
      await expectLater(
        change((await service.load(1)).cycle, 'bad-clock'),
        throwsStateError,
      );
      expect(await scalar('SELECT COUNT(*) FROM expenses'), 0);
    },
  );
  test('cross-station and disabled user cannot post', () async {
    await configure();
    final cycle = (await service.load(1)).cycle;
    await expectLater(
      service.change(
        station: 2,
        user: 1,
        amount: 2500,
        paymentMethod: 1,
        cashbox: 1,
        expectedCycle: cycle,
        requestId: 'foreign',
      ),
      throwsStateError,
    );
    await db.transaction(
      (tx) => tx.update('app_users', {'active': 0}, where: 'id=1'),
      captureSync: false,
    );
    await expectLater(change(cycle, 'disabled'), throwsStateError);
    expect(await scalar('SELECT COUNT(*) FROM expenses'), 0);
  });
  testWidgets(
    'oil confirmation can be cancelled and retried, posts one expense',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => configure());
      await tester.pumpWidget(
        MaterialApp(
          home: DieselOilPage(
            StationRepository(db),
            userId: 1,
            role: 'manager',
          ),
        ),
      );
      for (
        var i = 0;
        i < 100 && find.text('تسجيل تغيير الزيت').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('تسجيل تغيير الزيت'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'تكلفة تغيير الزيت'),
        '2500',
      );
      await tester.tap(find.byType(DropdownButtonFormField<int>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('نقدي').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('تم تغيير الزيت'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('رجوع'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تم تغيير الزيت'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('تم تغيير الزيت').last);
      await tester.pump();
      for (
        var i = 0;
        i < 100 && find.text('تم الحفظ').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('تم الحفظ'), findsOneWidget);
      final count = await tester.runAsync(
        () => scalar('SELECT COUNT(*) FROM expenses'),
      );
      expect(count, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
