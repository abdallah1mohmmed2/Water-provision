import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/domain/maintenance/diesel_oil_service.dart';

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
    'actual irrigation only, clipped baseline, cancelled/solar/future excluded',
    () async {
      await configure(initial: 60);
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
}
