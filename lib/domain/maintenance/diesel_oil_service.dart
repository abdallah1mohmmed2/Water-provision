import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/app_clock.dart';
import '../../data/local/database.dart';
import '../accounting/accounting_service.dart';

/// Maintenance is a local projection. Only the linked expense is a sync root.
class OilStatus {
  final Map<String, dynamic> config;
  final List<Map<String, Object?>> history;
  final int usedMinutes;
  final String cycle;
  const OilStatus(this.config, this.history, this.usedMinutes, this.cycle);
  bool get configured => config.isNotEmpty;
  int get interval => (config['interval'] as num?)?.toInt() ?? 0;
  int get warning => (config['warning'] as num?)?.toInt() ?? 0;
  int get remaining => interval - usedMinutes;
  String get state => !configured
      ? 'unset'
      : remaining <= 0
      ? 'due'
      : remaining <= warning
      ? 'warning'
      : 'ok';
  String get message => !configured
      ? 'اضبط موعد تغيير الزيت من الإعدادات'
      : remaining < 0
      ? 'تأخر تغيير الزيت بمقدار ${hours(-remaining)} ساعة سقاية'
      : remaining == 0
      ? 'حان موعد تغيير الزيت'
      : 'متبقي ${hours(remaining)} ساعة سقاية لتغيير الزيت';
  static String hours(int minutes) => (minutes / 60).toStringAsFixed(2);
}

class DieselOilService {
  final AppDatabase db;
  final DateTime Function() now;
  DieselOilService(this.db, {DateTime Function()? clock})
    : now = clock ?? AppClock.now;
  String _key(int station) => 'diesel_oil_maintenance_v1.$station';

  Future<void> _authorize(
    DatabaseExecutor tx,
    int station,
    int user, {
    bool manager = false,
  }) async {
    final selected = await tx.rawQuery(
      "SELECT p.station_id FROM settings s JOIN pumps p ON p.id=CAST(s.value AS INTEGER) WHERE s.key='selected_pump_id' AND p.active=1 LIMIT 1",
    );
    final fallback = selected.isEmpty
        ? await tx.rawQuery(
            'SELECT id station_id FROM stations WHERE active=1 ORDER BY id LIMIT 1',
          )
        : selected;
    if (fallback.isEmpty || fallback.first['station_id'] != station) {
      throw StateError('تغيرت المحطة الحالية؛ افتح شاشة الزيت من جديد');
    }
    final users = await tx.rawQuery(
      'SELECT role FROM app_users WHERE id=? AND station_id=? AND active=1',
      [user, station],
    );
    final role = users.isEmpty ? '' : users.first['role'];
    if (role != 'manager' && (manager || role != 'accountant')) {
      throw StateError('ليست لديك صلاحية تعديل متابعة الزيت لهذه المحطة');
    }
    final type = await tx.rawQuery(
      "SELECT value FROM settings WHERE key='system_type'",
    );
    if (type.isEmpty || type.first['value'] != 'diesel') {
      throw StateError('متابعة الزيت خاصة بمنظومة الديزل');
    }
  }

  Future<Map<String, dynamic>> _config(DatabaseExecutor tx, int station) async {
    final rows = await tx.rawQuery('SELECT value FROM settings WHERE key=?', [
      _key(station),
    ]);
    if (rows.isEmpty) {
      return {};
    }
    return Map<String, dynamic>.from(
      jsonDecode(rows.first['value'] as String) as Map,
    );
  }

  Future<void> _write(
    DatabaseExecutor tx,
    int station,
    Map<String, dynamic> config,
  ) => tx
      .insert('settings', {
        'key': _key(station),
        'value': jsonEncode(config),
        'updated_at': now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  /// Actual engine time only: never chargeable/rounded minutes or cloud discounts.
  static int operatingMinutes(
    Iterable<Map<String, Object?>> rows,
    DateTime since,
    DateTime until,
  ) {
    var minutes = 0;
    for (final row in rows) {
      if (row['system_type'] != 'diesel' || row['status'] == 'cancelled') {
        continue;
      }
      final start = DateTime.tryParse('${row['start_datetime']}');
      final end = DateTime.tryParse('${row['end_datetime']}');
      if (start == null ||
          end == null ||
          !end.isAfter(start) ||
          end.isAfter(until)) {
        continue;
      }
      final clipped = start.isBefore(since) ? since : start;
      if (end.isAfter(clipped)) {
        minutes += end.difference(clipped).inMinutes;
      }
    }
    return minutes;
  }

  Future<OilStatus> _load(DatabaseExecutor tx, int station) async {
    final config = await _config(tx, station);
    if (config.isEmpty) {
      return const OilStatus({}, [], 0, 'unset');
    }
    final history = <Map<String, Object?>>[];
    for (final record in (config['changes'] as List? ?? [])) {
      final change = Map<String, Object?>.from(record as Map);
      final expenses = await tx.rawQuery(
        'SELECT id,status,amount,date FROM expenses WHERE id=? AND station_id=? AND category=\'oil\'',
        [change['expense_id'], station],
      );
      if (expenses.isNotEmpty) {
        history.add({...change, ...expenses.first});
      }
    }
    history.sort(
      (a, b) => (b['expense_id'] as int).compareTo(a['expense_id'] as int),
    );
    final active = history.where((e) => e['status'] == 'posted');
    final last = active.isEmpty ? null : active.first;
    final baseline = DateTime.parse(
      '${last?['at'] ?? config['configured_at']}',
    );
    final rows = await tx.rawQuery(
      "SELECT start_datetime,end_datetime,system_type,status FROM irrigations WHERE station_id=? AND system_type='diesel' AND status!='cancelled'",
      [station],
    );
    final used =
        operatingMinutes(rows, baseline, now()) +
        (last == null ? (config['initial'] as int) : 0);
    return OilStatus(
      config,
      history,
      used,
      '${config['revision']}/${last?['expense_id'] ?? 0}',
    );
  }

  Future<OilStatus> load(int station) =>
      db.transaction((tx) => _load(tx, station), captureSync: false);

  Future<void> configure({
    required int station,
    required int user,
    required int interval,
    required int warning,
    required int initial,
  }) async {
    if (interval <= 0 || warning < 0 || warning >= interval || initial < 0) {
      throw ArgumentError(
        'حدد ساعات تغيير موجبة، وتنبيهًا أقل منها، وساعات مستهلكة غير سالبة',
      );
    }
    await db.transaction((tx) async {
      await _authorize(tx, station, user, manager: true);
      final old = await _config(tx, station);
      final config = <String, dynamic>{
        ...old,
        'interval': interval,
        'warning': warning,
        'revision': ((old['revision'] as int?) ?? 0) + 1,
      };
      if (old.isEmpty) {
        config.addAll({
          'configured_at': now().toIso8601String(),
          'initial': initial,
          'changes': <dynamic>[],
        });
      }
      // Subsequent configuration edits never reset hours or rewrite an oil cycle.
      await _write(tx, station, config);
      await db.auditTx(
        tx,
        userId: user,
        operation: 'configure_diesel_oil',
        table: 'settings',
        oldValues: old,
        newValues: config,
      );
    }, captureSync: false);
  }

  Future<int> change({
    required int station,
    required int user,
    required int amount,
    required int paymentMethod,
    required int cashbox,
    required String expectedCycle,
    required String requestId,
  }) async {
    final at = now();
    return AccountingService(db).addExpense(
      category: 'oil',
      title: 'تغيير زيت منظومة الديزل',
      amount: amount,
      date: at,
      paymentMethodId: paymentMethod,
      cashboxId: cashbox,
      userId: user,
      afterPosting: (tx, expense) async {
        await _authorize(tx, station, user);
        final source = await tx.rawQuery(
          'SELECT station_id FROM cashboxes WHERE id=?',
          [cashbox],
        );
        final method = await tx.rawQuery(
          'SELECT station_id FROM payment_methods WHERE id=?',
          [paymentMethod],
        );
        if (source.isEmpty ||
            source.first['station_id'] != station ||
            method.isEmpty ||
            method.first['station_id'] != station) {
          throw StateError('طريقة الدفع والصندوق يجب أن يتبعا المحطة');
        }
        await tx.update(
          'expenses',
          {'station_id': station},
          where: 'id=?',
          whereArgs: [expense],
        );
        final status = await _load(tx, station);
        if (!status.configured || status.cycle != expectedCycle) {
          throw StateError('تغيرت دورة الزيت؛ حدّث الشاشة قبل التسجيل');
        }
        final changes = List<dynamic>.from(status.config['changes'] as List);
        if (requestId.trim().isEmpty ||
            changes.any((e) => (e as Map)['request_id'] == requestId)) {
          throw StateError('عملية تغيير الزيت مسجلة بالفعل');
        }
        final last = status.history.where((e) => e['status'] == 'posted');
        final baseline = DateTime.parse(
          '${last.isEmpty ? status.config['configured_at'] : last.first['at']}',
        );
        if (at.isBefore(baseline)) {
          throw StateError('تاريخ الجهاز يسبق بداية دورة الزيت');
        }
        changes.add({
          'expense_id': expense,
          'at': at.toIso8601String(),
          'request_id': requestId,
        });
        await _write(tx, station, {...status.config, 'changes': changes});
      },
    );
  }

  Future<void> cancel({
    required int station,
    required int user,
    required int expense,
    required String reason,
  }) async {
    await AccountingService(db).cancelExpense(
      expense,
      user,
      reason,
      beforeCancellation: (tx) async {
        await _authorize(tx, station, user);
        final status = await _load(tx, station);
        if (!status.history.any(
          (e) => e['expense_id'] == expense && e['status'] == 'posted',
        )) {
          throw StateError('سجل تغيير الزيت غير موجود أو ملغى');
        }
      },
    );
    // Audited expense reversal restores cash/GL; the projection falls back
    // to the previous still-posted oil change without deleting its history.
  }
}
