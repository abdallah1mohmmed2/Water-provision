import 'package:sqflite/sqflite.dart';
import '../../core/app_clock.dart';
import '../../data/local/database.dart';
import 'balance_sql.dart';

/// دفتر تسويات مستقل؛ لا يكتب في القيود أو الصناديق أو سجلات الأطراف الأصلية.
class ReconciliationService {
  final AppDatabase database;
  ReconciliationService([AppDatabase? db]) : database = db ?? AppDatabase.instance;

  String monthKey(DateTime month) =>
      '${month.year}-${month.month.toString().padLeft(2, '0')}';

  Future<Map<String, Object?>> loadMonth(DateTime month) async {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1);
    final startText = start.toIso8601String();
    final endText = end.toIso8601String();
    final stationRows = await database.rawQuery(
      "SELECT station_id FROM pumps WHERE id=(SELECT CAST(value AS INTEGER) FROM settings WHERE key='selected_pump_id' LIMIT 1) LIMIT 1",
    );
    final stationId = stationRows.isEmpty
        ? 1
        : (stationRows.first['station_id'] as num?)?.toInt() ?? 1;

    Future<int> scalar(String sql, [List<Object?> args = const []]) async {
      final rows = await database.rawQuery(sql, args);
      return (rows.first['value'] as num?)?.round() ?? 0;
    }

    final profit = await scalar('''
      SELECT COALESCE(SUM(CASE
        WHEN pt.type IN ('share_accrual','contribution') THEN pt.amount
        WHEN pt.type IN ('share_adjustment','irrigation') THEN -pt.amount
        WHEN pt.type='share_adjustment_reversal' THEN pt.amount
        WHEN pt.type='irrigation_reversal' AND COALESCE(pt.notes,'') LIKE 'عكس نصيب الشريك%' THEN -pt.amount
        WHEN pt.type='irrigation_reversal' AND COALESCE(pt.notes,'') LIKE 'عكس سقاية الشريك%' THEN pt.amount
        ELSE 0 END),0) value
      FROM partner_transactions pt JOIN partners p ON p.id=pt.partner_id
      WHERE p.station_id=? AND pt.date>=? AND pt.date<?
    ''', [stationId, startText, endText]);

    final partnerPaid = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM payments WHERE status='posted' AND partner_id IN (SELECT id FROM partners WHERE station_id=?) AND date>=? AND date<?",
      [stationId, startText, endText],
    );
    final beneficiaryPaid = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM payments WHERE status='posted' AND beneficiary_id IN (SELECT id FROM beneficiaries WHERE station_id=?) AND date>=? AND date<?",
      [stationId, startText, endText],
    );
    final workerPaid = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM payments WHERE status='posted' AND worker_id IN (SELECT id FROM workers WHERE station_id=?) AND date>=? AND date<?",
      [stationId, startText, endText],
    );
    final expenses = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM expenses WHERE status='posted' AND date>=? AND date<? AND (worker_id IN (SELECT id FROM workers WHERE station_id=?) OR partner_id IN (SELECT id FROM partners WHERE station_id=?) OR (worker_id IS NULL AND partner_id IS NULL))",
      [startText, endText, stationId, stationId],
    );
    final beneficiaryRows = await database.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN balance>0 THEN balance ELSE 0 END),0) due, COALESCE(SUM(CASE WHEN balance<0 THEN -balance ELSE 0 END),0) credit FROM (SELECT (${BalanceSql.beneficiary('b')}) balance FROM beneficiaries b WHERE b.station_id=?)",
      [stationId],
    );
    final workerRows = await database.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN balance>0 THEN balance ELSE 0 END),0) due FROM (SELECT (${BalanceSql.workerPersonal('w')}) balance FROM workers w WHERE w.station_id=?)",
      [stationId],
    );

    final key = monthKey(start);
    final savedRows = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key=?',
      whereArgs: [stationId, key],
      limit: 1,
    );
    final previousRows = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key<?',
      whereArgs: [stationId, key],
      orderBy: 'month_key DESC',
      limit: 1,
    );
    final saved = savedRows.isEmpty ? <String, Object?>{} : savedRows.first;
    final previous = previousRows.isEmpty ? null : previousRows.first;
    final opening = previous != null
        ? ((previous['closing_balance'] as num?)?.round() ?? 0)
        : ((saved['opening_balance'] as num?)?.round() ?? 0);
    final manualPaid = (saved['manual_paid'] as num?)?.round() ?? 0;
    final closing = opening + profit - partnerPaid - manualPaid;
    final history = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key<?',
      whereArgs: [stationId, key],
      orderBy: 'month_key DESC',
      limit: 24,
    );
    return {
      'station_id': stationId,
      'month_key': key,
      'partner_profit': profit,
      'partner_app_paid': partnerPaid,
      'opening_balance': opening,
      'manual_paid': manualPaid,
      'closing_balance': closing,
      'beneficiary_due': (beneficiaryRows.first['due'] as num?)?.round() ?? 0,
      'beneficiary_credit': (beneficiaryRows.first['credit'] as num?)?.round() ?? 0,
      'beneficiary_paid': beneficiaryPaid,
      'worker_due': (workerRows.first['due'] as num?)?.round() ?? 0,
      'worker_paid': workerPaid,
      'expenses': expenses,
      'has_previous': previous != null,
      'has_saved': savedRows.isNotEmpty,
      'history': history,
    };
  }

  Future<void> saveMonth({
    required DateTime month,
    required int openingBalance,
    required int manualPaid,
    required int userId,
  }) async {
    if (manualPaid < 0) throw ArgumentError('المبلغ المسلّم لا يمكن أن يكون سالباً');
    final summary = await loadMonth(month);
    final stationId = (summary['station_id'] as num).toInt();
    final key = monthKey(month);
    final previous = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key<?',
      whereArgs: [stationId, key],
      orderBy: 'month_key DESC',
      limit: 1,
    );
    final effectiveOpening = previous.isNotEmpty
        ? (previous.first['closing_balance'] as num).round()
        : openingBalance;
    final closing = effectiveOpening +
        ((summary['partner_profit'] as num?)?.round() ?? 0) -
        ((summary['partner_app_paid'] as num?)?.round() ?? 0) -
        manualPaid;
    final now = AppClock.now().toIso8601String();
    final existing = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key=?',
      whereArgs: [stationId, key],
      limit: 1,
    );
    final values = <String, Object?>{
      'station_id': stationId,
      'month_key': key,
      'opening_balance': effectiveOpening,
      'manual_paid': manualPaid,
      'closing_balance': closing,
      'updated_by': userId,
      'updated_at': now,
    };
    if (existing.isEmpty) {
      values['created_by'] = userId;
      values['created_at'] = now;
      await database.insert('accountant_reconciliation_months', values);
    } else {
      await database.update(
        'accountant_reconciliation_months',
        values,
        where: 'id=?',
        whereArgs: [existing.first['id']],
      );
    }
  }
}
