import '../../core/app_clock.dart';
import '../../data/local/database.dart';
import 'balance_sql.dart';

/// دفتر تسويات مستقل؛ لا يكتب في القيود أو الصناديق أو سجلات الأطراف الأصلية.
class ReconciliationService {
  final AppDatabase database;
  ReconciliationService([AppDatabase? db]) : database = db ?? AppDatabase.instance;

  String monthKey(DateTime month) =>
      '${month.year}-${month.month.toString().padLeft(2, '0')}';

  Future<Map<String, int>> _partnerTotals(
    int stationId,
    DateTime start,
    DateTime end,
  ) async {
    final startText = start.toIso8601String();
    final endText = end.toIso8601String();
    Future<int> scalar(String sql, List<Object?> args) async {
      final rows = await database.rawQuery(sql, args);
      return (rows.first['value'] as num?)?.round() ?? 0;
    }
    final partnerTotals = await _partnerTotals(stationId, start, end);
    final beneficiaryPaid = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM payments WHERE status='posted' AND beneficiary_id IN (SELECT id FROM beneficiaries WHERE station_id=?) AND date>=? AND date<?",
      [stationId, startText, endText],
    );
    final workerPaidFromPayments = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM payments WHERE status='posted' AND worker_id IN (SELECT id FROM workers WHERE station_id=?) AND date>=? AND date<?",
      [stationId, startText, endText],
    );
    final legacyWorkerPaid = await scalar(
      "SELECT COALESCE(SUM(wt.amount),0) value FROM worker_transactions wt JOIN workers w ON w.id=wt.worker_id LEFT JOIN payments pay ON pay.id=wt.reference_id WHERE w.station_id=? AND wt.type='payment' AND wt.date>=? AND wt.date<? AND pay.id IS NULL",
      [stationId, startText, endText],
    );
    final workerPaid = workerPaidFromPayments + legacyWorkerPaid;
    final recordedExpenses = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM expenses WHERE status='posted' AND category!='workers' AND date>=? AND date<? AND (worker_id IN (SELECT id FROM workers WHERE station_id=?) OR partner_id IN (SELECT id FROM partners WHERE station_id=?) OR (worker_id IS NULL AND partner_id IS NULL))",
      [startText, endText, stationId, stationId],
    );
    // أجور العمال تُرحّل في الأستاذ على 5000 ولا تُسجّل في جدول expenses
    // حتى لا تُحسب مرتين؛ نضمّها هنا إلى إجمالي المصروفات الإحصائي.
    final workerEntitlements = await scalar(
      "SELECT COALESCE(SUM(jl.debit-jl.credit),0) value FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND a.code='5000' AND je.date>=? AND je.date<?",
      [stationId, startText, endText],
    );
    final expenses = recordedExpenses + workerEntitlements;
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
    var opening = (saved['opening_balance'] as num?)?.round() ?? 0;
    if (previous != null) {
      final previousParts = '${previous['month_key']}'.split('-');
      var carry = (previous['closing_balance'] as num?)?.round() ?? 0;
      if (previousParts.length == 2) {
        final previousEnd = DateTime(
          int.parse(previousParts[0]),
          int.parse(previousParts[1]) + 1,
          1,
        );
        if (previousEnd.isBefore(start)) {
          final gapTotals = await _partnerTotals(stationId, previousEnd, start);
          carry += (gapTotals['profit'] ?? 0) - (gapTotals['paid'] ?? 0);
        }
      }
      opening = carry;
    }
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
      'partner_profit': partnerTotals['profit'],
      'partner_app_paid': partnerTotals['paid'],
      'opening_balance': opening,
      'manual_paid': manualPaid,
      'opening_details': saved['opening_details'] ?? '',
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
    required String openingDetails,
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
    final effectiveOpening = (summary['opening_balance'] as num?)?.round() ?? openingBalance;
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

    // احسب تسويات الأشهر اللاحقة أولاً، مع إدخال أرباح ومدفوعات الأشهر
    // التي لم تُحفظ لها تسوية مستقلة بين شهرين محفوظين.
    final futureRows = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key>?',
      whereArgs: [stationId, key],
      orderBy: 'month_key ASC',
    );
    final futureUpdates = <Map<String, Object?>>[];
    var carry = closing;
    var cursor = DateTime(month.year, month.month + 1, 1);
    for (final row in futureRows) {
      final parts = '${row['month_key']}'.split('-');
      if (parts.length != 2) continue;
      final futureMonth = DateTime(int.parse(parts[0]), int.parse(parts[1]), 1);
      final gapTotals = await _partnerTotals(stationId, cursor, futureMonth);
      final futureOpening = carry +
          (gapTotals['profit'] ?? 0) - (gapTotals['paid'] ?? 0);
      final futureEnd = DateTime(futureMonth.year, futureMonth.month + 1, 1);
      final futureTotals = await _partnerTotals(stationId, futureMonth, futureEnd);
      final futureManualPaid = (row['manual_paid'] as num?)?.round() ?? 0;
      final futureClosing = futureOpening +
          (futureTotals['profit'] ?? 0) -
          (futureTotals['paid'] ?? 0) -
          futureManualPaid;
      futureUpdates.add({
        'id': row['id'],
        'opening_balance': futureOpening,
        'closing_balance': futureClosing,
      });
      carry = futureClosing;
      cursor = futureEnd;
    }

    await database.transaction((tx) async {
      final values = <String, Object?>{
        'station_id': stationId,
        'month_key': key,
        'opening_balance': effectiveOpening,
        'opening_details': openingDetails.trim(),
        'manual_paid': manualPaid,
        'closing_balance': closing,
        'updated_by': userId,
        'updated_at': now,
      };
      if (existing.isEmpty) {
        values['created_by'] = userId;
        values['created_at'] = now;
        await tx.insert('accountant_reconciliation_months', values);
      } else {
        await tx.update(
          'accountant_reconciliation_months',
          values,
          where: 'id=?',
          whereArgs: [existing.first['id']],
        );
      }
      for (final update in futureUpdates) {
        await tx.update(
          'accountant_reconciliation_months',
          {
            'opening_balance': update['opening_balance'],
            'closing_balance': update['closing_balance'],
            'updated_by': userId,
            'updated_at': now,
          },
          where: 'id=?',
          whereArgs: [update['id']],
        );
      }
    });
  }
}
