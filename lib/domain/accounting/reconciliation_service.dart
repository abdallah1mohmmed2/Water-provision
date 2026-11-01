import '../../core/app_clock.dart';
import '../../data/local/database.dart';

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

    final profit = await scalar('''
      SELECT COALESCE(SUM(CASE
        WHEN pt.type='share_accrual' THEN pt.amount
        WHEN pt.type='share_adjustment' THEN -pt.amount
        WHEN pt.type='share_adjustment_reversal' THEN pt.amount
        WHEN pt.type='irrigation_reversal' AND COALESCE(pt.notes,'') LIKE 'عكس نصيب الشريك%' THEN -pt.amount
        ELSE 0 END),0) value
      FROM partner_transactions pt
      JOIN partners p ON p.id=pt.partner_id
      WHERE p.station_id=? AND pt.date>=? AND pt.date<?
    ''', [stationId, startText, endText]);

    final recordedPaid = await scalar(
      "SELECT COALESCE(SUM(amount),0) value FROM payments WHERE status='posted' AND partner_id IN (SELECT id FROM partners WHERE station_id=?) AND date>=? AND date<?",
      [stationId, startText, endText],
    );
    final legacyPaid = await scalar(
      "SELECT COALESCE(SUM(pt.amount),0) value FROM partner_transactions pt JOIN partners p ON p.id=pt.partner_id LEFT JOIN payments pay ON pay.id=pt.reference_id WHERE p.station_id=? AND pt.type='payment' AND pt.date>=? AND pt.date<? AND pay.id IS NULL",
      [stationId, startText, endText],
    );
    return {'profit': profit, 'paid': recordedPaid + legacyPaid};
  }

  Future<Map<String, Map<String, int>>> _partnerMonthlyTotals(
    int stationId,
    DateTime start,
    DateTime end,
  ) async {
    final from = start.toIso8601String();
    final to = end.toIso8601String();
    final totals = <String, Map<String, int>>{};
    void addRows(List<Map<String, Object?>> rows, String field) {
      for (final row in rows) {
        final key = '${row['month'] ?? ''}';
        if (key.isEmpty) continue;
        final item = totals.putIfAbsent(key, () => {'profit': 0, 'paid': 0});
        item[field] = (item[field] ?? 0) + ((row['amount'] as num?)?.round() ?? 0);
      }
    }

    final profitRows = await database.rawQuery('''
      SELECT substr(pt.date,1,7) month,
        COALESCE(SUM(CASE
          WHEN pt.type='share_accrual' THEN pt.amount
          WHEN pt.type='share_adjustment' THEN -pt.amount
          WHEN pt.type='share_adjustment_reversal' THEN pt.amount
          WHEN pt.type='irrigation_reversal' AND COALESCE(pt.notes,'') LIKE 'عكس نصيب الشريك%' THEN -pt.amount
          ELSE 0 END),0) amount
      FROM partner_transactions pt JOIN partners p ON p.id=pt.partner_id
      WHERE p.station_id=? AND pt.date>=? AND pt.date<?
      GROUP BY substr(pt.date,1,7)
    ''', [stationId, from, to]);
    addRows(profitRows, 'profit');

    final paymentRows = await database.rawQuery('''
      SELECT substr(date,1,7) month,COALESCE(SUM(amount),0) amount
      FROM payments
      WHERE status='posted' AND partner_id IN (SELECT id FROM partners WHERE station_id=?)
        AND date>=? AND date<?
      GROUP BY substr(date,1,7)
    ''', [stationId, from, to]);
    addRows(paymentRows, 'paid');

    final legacyPaymentRows = await database.rawQuery('''
      SELECT substr(pt.date,1,7) month,COALESCE(SUM(pt.amount),0) amount
      FROM partner_transactions pt
      JOIN partners p ON p.id=pt.partner_id
      LEFT JOIN payments pay ON pay.id=pt.reference_id
      WHERE p.station_id=? AND pt.type='payment' AND pt.date>=? AND pt.date<?
        AND pay.id IS NULL
      GROUP BY substr(pt.date,1,7)
    ''', [stationId, from, to]);
    addRows(legacyPaymentRows, 'paid');
    return totals;
  }

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

    // أرصدة الأطراف تُحسب حتى نهاية الشهر المختار، لا حتى تاريخ اليوم،
    // حتى تبقى تقارير الأشهر التاريخية صحيحة عند الرجوع إليها.
    final beneficiaryRows = await database.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN balance>0 THEN balance ELSE 0 END),0) due,
        COALESCE(SUM(CASE WHEN balance<0 THEN -balance ELSE 0 END),0) credit
      FROM (
        SELECT b.id,
          COALESCE((
            SELECT SUM(jl.debit-jl.credit)
            FROM journal_lines jl
            JOIN journal_entries je ON je.id=jl.journal_entry_id
            JOIN accounts a ON a.id=jl.account_id
            WHERE je.status='posted' AND je.date<? AND a.code='1200'
              AND jl.beneficiary_id=b.id
          ),0) balance
        FROM beneficiaries b WHERE b.station_id=?
      )
    ''', [endText, stationId]);
    final workerRows = await database.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN balance>0 THEN balance ELSE 0 END),0) due,
        COALESCE(SUM(CASE WHEN balance<0 THEN -balance ELSE 0 END),0) credit
      FROM (
        SELECT w.id,
          COALESCE((
            SELECT SUM(jl.credit-jl.debit)
            FROM journal_lines jl
            JOIN journal_entries je ON je.id=jl.journal_entry_id
            JOIN accounts a ON a.id=jl.account_id
            WHERE je.status='posted' AND je.date<? AND (
              a.code=('2100.W'||w.id) OR (a.code='2100' AND jl.worker_id=w.id)
            )
          ),0) balance
        FROM workers w WHERE w.station_id=?
      )
    ''', [endText, stationId]);

    final key = monthKey(start);
    final savedRows = await database.query(
      'accountant_reconciliation_months',
      where: 'station_id=? AND month_key<=?',
      whereArgs: [stationId, key],
      orderBy: 'month_key ASC',
    );
    final savedByMonth = <String, Map<String, Object?>>{
      for (final row in savedRows) '${row['month_key']}': row,
    };
    var opening = 0;
    var manualPaid = 0;
    var openingDetails = '';
    var currentSaved = false;
    var hasPrevious = false;
    final history = <Map<String, Object?>>[];

    if (savedRows.isNotEmpty) {
      final firstParts = '${savedRows.first['month_key']}'.split('-');
      final firstMonth = DateTime(int.parse(firstParts[0]), int.parse(firstParts[1]), 1);
      final monthlyTotals = await _partnerMonthlyTotals(stationId, firstMonth, start);
      var carry = (savedRows.first['opening_balance'] as num?)?.round() ?? 0;
      // عند اختيار نفس أول شهر محفوظ، يكون افتتاحه اليدوي هو افتتاح الشهر الحالي.
      // لا توجد أشهر سابقة لإعادة المرور عليها في هذه الحالة.
      opening = carry;
      var cursor = firstMonth;
      while (cursor.isBefore(start)) {
        final cursorKey = monthKey(cursor);
        final nextMonth = DateTime(cursor.year, cursor.month + 1, 1);
        final totals = monthlyTotals[cursorKey] ?? const <String, int>{};
        final savedRow = savedByMonth[cursorKey];
        final monthManualPaid = (savedRow?['manual_paid'] as num?)?.round() ?? 0;
        final monthOpening = carry;
        final monthClosing = monthOpening +
            (totals['profit'] ?? 0) -
            (totals['paid'] ?? 0) -
            monthManualPaid;
        history.add({
          'month_key': cursorKey,
          'opening_balance': monthOpening,
          'partner_profit': totals['profit'] ?? 0,
          'partner_app_paid': totals['paid'] ?? 0,
          'manual_paid': monthManualPaid,
          'closing_balance': monthClosing,
          'opening_details': savedRow?['opening_details'] ?? '',
        });
        carry = monthClosing;
        cursor = nextMonth;
      }
      opening = carry;
      hasPrevious = firstMonth.isBefore(start);
      final currentRow = savedByMonth[key];
      if (currentRow != null) {
        currentSaved = true;
        manualPaid = (currentRow['manual_paid'] as num?)?.round() ?? 0;
        openingDetails = '${currentRow['opening_details'] ?? ''}';
      }
    }
    final closing = opening +
        (partnerTotals['profit'] ?? 0) -
        (partnerTotals['paid'] ?? 0) -
        manualPaid;
    return {
      'station_id': stationId,
      'month_key': key,
      'partner_profit': partnerTotals['profit'] ?? 0,
      'partner_app_paid': partnerTotals['paid'] ?? 0,
      'opening_balance': opening,
      'manual_paid': manualPaid,
      'opening_details': openingDetails,
      'closing_balance': closing,
      'beneficiary_due': (beneficiaryRows.first['due'] as num?)?.round() ?? 0,
      'beneficiary_credit': (beneficiaryRows.first['credit'] as num?)?.round() ?? 0,
      'beneficiary_paid': beneficiaryPaid,
      'worker_due': (workerRows.first['due'] as num?)?.round() ?? 0,
      'worker_credit': (workerRows.first['credit'] as num?)?.round() ?? 0,
      'worker_paid': workerPaid,
      'expenses': expenses,
      'has_previous': hasPrevious,
      'has_saved': currentSaved,
      'history': history.reversed.toList(),
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
    final effectiveOpening = summary['has_previous'] == true
        ? (summary['opening_balance'] as num?)?.round() ?? openingBalance
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
