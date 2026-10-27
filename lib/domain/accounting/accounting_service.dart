import '../../core/app_clock.dart';
import '../../core/app_prefs.dart';
import '../../core/period_ranges.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'calculations.dart';
import '../../data/local/database.dart';
import '../../data/local/queue_rotation.dart';
import 'balance_sql.dart';

/// رصيد ديزل المستفيد (لترات) = افتتاحي + مرحّل + تسليم + سلف − استهلاك.
/// السلف داخلة في الرصيد حتى لا يبقى الرصيد سالبًا فتتضاعف السلفة التالية.
/// مخزون المحطة (لترات).
const String _stationDieselStockSql =
    "SELECT COALESCE(SUM(CASE WHEN kind='receipt' OR (kind IN ('opening_balance','correction') AND beneficiary_id IS NULL) THEN liters WHEN kind IN ('delivery','consumption') THEN -liters WHEN kind='advance' AND irrigation_id IS NULL THEN -liters ELSE 0 END),0) stock FROM diesel_movements";

const String _beneficiaryDieselStockSql =
    "SELECT COALESCE((SELECT opening_diesel_liters FROM beneficiaries WHERE id=?),0)"
    "+COALESCE((SELECT carried_diesel_liters FROM beneficiaries WHERE id=?),0)"
    "+COALESCE((SELECT SUM(CASE WHEN kind IN ('delivery','advance') THEN liters WHEN kind='consumption' THEN -liters ELSE 0 END) FROM diesel_movements WHERE beneficiary_id=?),0) stock";

class AccountingService {
  final AppDatabase database;
  AccountingService([AppDatabase? db]) : database = db ?? AppDatabase.instance;

  // تنبيهات تُجمَّع داخل المعاملة وتُطلق بعد نجاحها فقط (صوت/نافذة منبثقة حسب الإعدادات).
  final List<AppAlert> _pendingAlerts = [];

  Future<T> _withAlerts<T>(Future<T> Function() body) async {
    _pendingAlerts.clear();
    try {
      final r = await body();
      for (final a in List<AppAlert>.of(_pendingAlerts)) {
        AppAlerts.emit(a.title, a.body);
      }
      return r;
    } finally {
      _pendingAlerts.clear();
    }
  }

  Future<int> _accountIdTx(Transaction tx, String code) async {
    final r = await tx.query(
      'accounts',
      columns: ['id'],
      where: 'code=?',
      whereArgs: [code],
      limit: 1,
    );
    if (r.isNotEmpty) return r.first['id'] as int;
    // حسابات أُضيفت بعد إصدارات سابقة: تُنشأ عند غيابها (مثل استعادة نسخة احتياطية قديمة).
    final auto = _autoAccounts[code];
    if (auto == null) throw StateError('الحساب غير موجود: $code');
    return tx.insert('accounts', {'code': code, 'name': auto.$1, 'type': auto.$2});
  }

  /// الحساب الشخصي للعامل. الحساب 2100 هو الحساب التجميعي فقط، بينما كل
  /// حركة تفصيلية تُرحّل إلى حساب فرعي مستقل يمكن تتبعه باسم العامل.
  Future<int> _workerAccountIdTx(Transaction tx, int workerId) async {
    final worker = await tx.query(
      'workers',
      columns: ['name'],
      where: 'id=?',
      whereArgs: [workerId],
      limit: 1,
    );
    if (worker.isEmpty) throw StateError('العامل غير موجود: $workerId');
    final code = '2100.W$workerId';
    final existing = await tx.query(
      'accounts',
      columns: ['id'],
      where: 'code=?',
      whereArgs: [code],
      limit: 1,
    );
    if (existing.isNotEmpty) return (existing.first['id'] as num).toInt();
    final parent = await _accountIdTx(tx, '2100');
    return tx.insert('accounts', {
      'parent_id': parent,
      'code': code,
      'name': 'حساب العامل الشخصي: ${worker.first['name']}',
      'type': 'liability',
    });
  }

  /// الحساب الشخصي للشريك. الحساب 2200 يبقى حساباً تجميعياً، وكل حركة
  /// تفصيلية للشريك تُرحّل إلى حسابه الفرعي المستقل.
  Future<int> _partnerAccountIdTx(Transaction tx, int partnerId) async {
    final partner = await tx.query(
      'partners',
      columns: ['name'],
      where: 'id=?',
      whereArgs: [partnerId],
      limit: 1,
    );
    if (partner.isEmpty) throw StateError('الشريك غير موجود: $partnerId');
    final code = '2200.P$partnerId';
    final existing = await tx.query(
      'accounts',
      columns: ['id'],
      where: 'code=?',
      whereArgs: [code],
      limit: 1,
    );
    if (existing.isNotEmpty) return (existing.first['id'] as num).toInt();
    final parent = await _accountIdTx(tx, '2200');
    return tx.insert('accounts', {
      'parent_id': parent,
      'code': code,
      'name': 'حساب الشريك الشخصي: ${partner.first['name']}',
      'type': 'liability',
    });
  }

  static const Map<String, (String, String)> _autoAccounts = {
    '3200': ('حصص الشركاء من الأرباح', 'equity'),
    '3300': ('الأرباح المبقاة', 'equity'),
  };

  Future<int> _selectedStationIdTx(Transaction tx) async {
    final selected = await tx.rawQuery(
      "SELECT p.station_id FROM settings s JOIN pumps p ON p.id=CAST(s.value AS INTEGER) WHERE s.key='selected_pump_id' AND p.active=1 LIMIT 1",
    );
    if (selected.isNotEmpty) return (selected.first['station_id'] as num).toInt();
    final station = await tx.rawQuery('SELECT id FROM stations WHERE active=1 ORDER BY id LIMIT 1');
    return station.isEmpty ? 1 : (station.first['id'] as num).toInt();
  }

  Future<int> _entry(
    Transaction tx, {
    required String description,
    required String referenceType,
    int? referenceId,
    required List<Map<String, Object?>> lines,
    int? userId,
    DateTime? date,
    int? stationId,
  }) async {
    final debit = lines.fold<int>(
      0,
      (s, x) => s + ((x['debit'] as num?)?.round() ?? 0),
    );
    final credit = lines.fold<int>(
      0,
      (s, x) => s + ((x['credit'] as num?)?.round() ?? 0),
    );
    if (debit != credit) {
      throw StateError('القيد غير متوازن: المدين $debit / الدائن $credit');
    }
    if (debit <= 0 || credit <= 0 || lines.isEmpty) {
      throw StateError('القيد المحاسبي يجب أن يحتوي مبلغًا موجبًا ومتوازنًا');
    }
    for (final line in lines) {
      final lineDebit = (line['debit'] as num?)?.toDouble() ?? 0;
      final lineCredit = (line['credit'] as num?)?.toDouble() ?? 0;
      if (lineDebit < 0 ||
          lineCredit < 0 ||
          (lineDebit > 0 && lineCredit > 0) ||
          lineDebit != lineDebit.roundToDouble() ||
          lineCredit != lineCredit.roundToDouble()) {
        throw StateError('سطر القيد المحاسبي يحتوي مبلغًا غير صالح');
      }
    }
    final now = AppClock.now().toIso8601String();
    final entryStationId = stationId ?? await _selectedStationIdTx(tx);
    // تاريخ القيد = تاريخ العملية الفعلي (وليس لحظة الحفظ) حتى لا تُرحَّل
    // الحركات القديمة إلى اليوم ولا يُتجاوز إغلاق الفترة.
    final id = await tx.insert('journal_entries', {
      'station_id': entryStationId,
      'date': (date ?? AppClock.now()).toIso8601String(),
      'reference_type': referenceType,
      'reference_id': referenceId,
      'description': description,
      'status': 'posted',
      'created_by': userId,
      'created_at': now,
    });
    for (final line in lines) {
      await tx.insert('journal_lines', {...line, 'journal_entry_id': id});
    }
    return id;
  }

  Future<Map<String, String>> settings() async {
    final r = await database.query('SELECT key,value FROM settings');
    return {for (final x in r) x['key'] as String: x['value'] as String};
  }

  Future<bool> _settingBool(String key, {bool fallback = false}) async =>
      (await settings())[key]?.toLowerCase() == 'true' ? true : fallback;


  /// يعكس كل القيود المرحّلة المرتبطة بمرجع معيّن بقيد عكسي (مدين↔دائن).
  /// لا يعدّل القيد الأصلي؛ يبقى مرحّلاً ويُلغى أثره بقيد عكسي مرحّل.
  /// آمن للاستدعاء مرتين: القيد الذي له عكس سابق يُتجاوز.
  Future<int> _reverseEntriesTx(
    Transaction tx, {
    required String referenceType,
    required int referenceId,
    required String reason,
    int? userId,
    String? descriptionEquals,
  }) async {
    final entries = await tx.rawQuery(
      "SELECT je.id,je.description FROM journal_entries je WHERE je.reference_type=? AND je.reference_id=? AND je.status='posted' "
      "${descriptionEquals == null ? '' : 'AND je.description=? '}"
      "AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reference_type='reversal' AND r.reference_id=je.id)",
      [referenceType, referenceId, if (descriptionEquals != null) descriptionEquals],
    );
    var n = 0;
    for (final e in entries) {
      final eid = e['id'] as int;
      final lines = await tx.query(
        'journal_lines',
        where: 'journal_entry_id=?',
        whereArgs: [eid],
      );
      await _entry(
        tx,
        description: 'عكس قيد رقم $eid: ${e['description']} — $reason',
        referenceType: 'reversal',
        referenceId: eid,
        lines: [
          for (final l in lines)
            {
              'account_id': l['account_id'],
              'beneficiary_id': l['beneficiary_id'],
              'worker_id': l['worker_id'],
              'partner_id': l['partner_id'],
              'debit': l['credit'],
              'credit': l['debit'],
              'memo': 'عكس: ${l['memo'] ?? ''}',
            },
        ],
        userId: userId,
      );
      n++;
    }
    return n;
  }

  Future<void> _assertPeriodOpen(Transaction tx, DateTime date, {int? stationId}) async {
    final station = stationId ?? await _selectedStationIdTx(tx);
    final value = date.toIso8601String();
    final rows = await tx.rawQuery(
      "SELECT id FROM period_closures WHERE station_id=? AND status!='reopened' AND period_start<=? AND ((period_end_exclusive IS NOT NULL AND period_end_exclusive>?) OR (period_end_exclusive IS NULL AND period_end>=?)) LIMIT 1",
      [station, value, value, value],
    );
    if (rows.isNotEmpty) {
      throw StateError('الفترة المحاسبية مغلقة ولا يمكن إضافة حركة إليها');
    }
  }

  Future<void> _assertPeriodRangeOpen(
    Transaction tx, DateTime start, DateTime endExclusive, {int? stationId}
  ) async {
    final station = stationId ?? await _selectedStationIdTx(tx);
    final rows = await tx.rawQuery(
      "SELECT id FROM period_closures WHERE station_id=? AND status!='reopened' AND period_start<? AND ((period_end_exclusive IS NOT NULL AND period_end_exclusive>?) OR (period_end_exclusive IS NULL AND period_end>=?)) LIMIT 1",
      [station, endExclusive.toIso8601String(), start.toIso8601String(), start.toIso8601String()],
    );
    if (rows.isNotEmpty) throw StateError('الفترة المحاسبية المطلوبة مغلقة');
  }

  Future<int> _checkWaiting(
    Transaction tx,
    int beneficiaryId,
    DateTime start, {
    required int minDays,
    required bool override,
    String? reason,
    int? userId,
  }) async {
    // نفحص أقرب سقاية سابقة وأقرب سقاية لاحقة للتاريخ المُدخل، فالإدخال بتاريخ
    // قديم لا يُرفض خطأً بسبب سقاية أحدث، وفي المقابل لا يُسمح بسقاية قريبة جدًا
    // قبل سقاية لاحقة مسجلة.
    final startIso = start.toIso8601String();
    final prev = await tx.rawQuery(
      "SELECT MAX(start_datetime) d FROM irrigations WHERE beneficiary_id=? AND status!='cancelled' AND start_datetime<=?",
      [beneficiaryId, startIso],
    );
    final next = await tx.rawQuery(
      "SELECT MIN(start_datetime) d FROM irrigations WHERE beneficiary_id=? AND status!='cancelled' AND start_datetime>?",
      [beneficiaryId, startIso],
    );
    final prevV = prev.first['d'], nextV = next.first['d'];
    if (prevV == null && nextV == null) return 0;
    var elapsed = 1 << 30;
    if (prevV != null) {
      elapsed = start.difference(DateTime.parse(prevV as String)).inDays;
    }
    if (nextV != null) {
      final gap = DateTime.parse(nextV as String).difference(start).inDays;
      if (gap < elapsed) elapsed = gap;
    }
    if (elapsed < minDays && override) {
      if (reason == null || reason.trim().isEmpty) {
        throw StateError('يجب إدخال سبب تجاوز مدة الانتظار');
      }
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'waiting_period_override',
        table: 'irrigations',
        recordId: null,
        reason: reason,
      );
      return 1;
    }
    return 0;
  }

  /// يحدد طريقة الدفع والصندوق معًا. الصندوق «تابع» للطريقة: إن كان للطريقة صندوق مرتبط
  /// فهو الصندوق الوحيد المسموح، وأي صندوق مختلف يُرفض (حتى لا يتباعد رصيد الصندوق عن قيد
  /// الأستاذ). الطريقة بلا صندوق مرتبط تقبل صندوقًا يُمرَّر صراحةً، وإلا أول صندوق مفعّل.
  /// عند عدم اختيار طريقة تُستخدم أول طريقة نقدية مفعّلة.
  Future<Map<String, int>> resolvePaymentSource(
    DatabaseExecutor ex, {
    int? paymentMethodId,
    int? cashboxId,
  }) async {
    final m = paymentMethodId != null
        ? await ex.rawQuery(
            'SELECT id,cashbox_id FROM payment_methods WHERE id=? AND active=1',
            [paymentMethodId],
          )
        : await ex.rawQuery(
            "SELECT id,cashbox_id FROM payment_methods WHERE active=1 ORDER BY CASE WHEN type='cash' THEN 0 ELSE 1 END, id LIMIT 1",
          );
    if (m.isEmpty) {
      throw ArgumentError(paymentMethodId != null
          ? 'طريقة الدفع غير موجودة أو غير مفعّلة'
          : 'لا توجد طريقة دفع مفعّلة');
    }
    final methodBox = (m.first['cashbox_id'] as num?)?.toInt();
    if (methodBox != null && cashboxId != null && cashboxId != methodBox) {
      throw ArgumentError('الصندوق المختار لا يطابق الصندوق المرتبط بطريقة الدفع');
    }
    var cb = methodBox ?? cashboxId;
    if (cb == null) {
      final c = await ex.rawQuery(
        'SELECT id FROM cashboxes WHERE active=1 ORDER BY id LIMIT 1',
      );
      if (c.isEmpty) throw ArgumentError('لا يوجد صندوق مفعّل');
      cb = (c.first['id'] as num).toInt();
    } else {
      final c = await ex.rawQuery(
        'SELECT id FROM cashboxes WHERE id=? AND active=1',
        [cb],
      );
      if (c.isEmpty) throw ArgumentError('الصندوق غير موجود أو غير مفعّل');
    }
    return {'method': (m.first['id'] as num).toInt(), 'cashbox': cb};
  }

  Future<Map<String, int>> paymentSource({
    int? paymentMethodId,
    int? cashboxId,
  }) async => resolvePaymentSource(
    await database.db,
    paymentMethodId: paymentMethodId,
    cashboxId: cashboxId,
  );

  /// يتحقق من وجود الصندوق فقط. يسمح النظام عمدًا بالرصيد السالب لأن الصندوق
  /// حساب عهدة للصراف له وعليه، ولا يُشترط وجود نقد سابق لإثبات عملية صرف.
  Future<void> _assertCashboxCanSpend(DatabaseExecutor ex, int cashboxId, int amount) async {
    final rows = await ex.rawQuery(
      'SELECT id FROM cashboxes WHERE id=? AND active=1',
      [cashboxId],
    );
    if (rows.isEmpty) {
      throw StateError('الصندوق غير موجود أو غير مفعّل');
    }
  }

  /// محطة العمل الحالية: محطة المضخة المحددة في الإعدادات، وإلا أول محطة فعالة، وإلا 1.
  /// تُقرأ خارج أي معاملة مفتوحة (تفاديًا لتعليق sqflite).
  Future<int> currentStationId() async {
    final set = await settings();
    final pumpId = int.tryParse(set['selected_pump_id'] ?? '');
    if (pumpId != null) {
      final r = await database.query(
        'SELECT station_id FROM pumps WHERE id=? LIMIT 1',
        args: [pumpId],
      );
      final v = r.isEmpty ? null : (r.first['station_id'] as num?)?.toInt();
      if (v != null) return v;
    }
    final r = await database.query(
      'SELECT id FROM stations WHERE active=1 ORDER BY id LIMIT 1',
    );
    return r.isEmpty ? 1 : (r.first['id'] as num).toInt();
  }

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<String?> _fiscalRangeError(DatabaseExecutor tx, DateTime start, DateTime endExclusive) async {
    if (!endExclusive.isAfter(start)) return 'نهاية السنة المالية غير صحيحة';
    if (_day(start) != start || _day(endExclusive) != endExclusive) return 'يجب أن تكون حدود السنة المالية عند منتصف الليل';
    final setting = await tx.rawQuery("SELECT value FROM settings WHERE key='financial_year_start' LIMIT 1");
    final mmdd = setting.isEmpty ? '01-01' : '${setting.first['value']}';
    final expectedStart = PeriodRanges.financialYearStart(start, mmdd);
    final expectedEnd = PeriodRanges.financialYearStart(DateTime(start.year + 1, 12, 31), mmdd);
    if (_day(expectedStart) != _day(start) || _day(expectedEnd) != _day(endExclusive)) {
      return 'النطاق لا يطابق سنة مالية كاملة حسب إعداد بداية السنة ($mmdd)';
    }
    if (endExclusive.isAfter(AppClock.now())) return 'لا يمكن إقفال سنة مالية لم تنتهِ بعد';
    return null;
  }

  Future<List<Map<String, Object?>>> _subledgerReconciliationTx(
    Transaction tx, {required int stationId, required DateTime endExclusive}
  ) async {
    final end = endExclusive.toIso8601String();
    final financialDeliverySetting = await tx.rawQuery(
      "SELECT value FROM settings WHERE key='diesel_delivery_financial_credit' LIMIT 1",
    );
    final financialDeliveryValue = financialDeliverySetting.isEmpty
        ? ''
        : '${financialDeliverySetting.first['value']}';
    final financialDeliveries = financialDeliveryValue.toLowerCase() == 'true';

    final beneficiaries = await tx.rawQuery('''
      SELECT b.id,b.name,
        COALESCE(b.opening_balance,0)+COALESCE(b.carried_balance,0)
        -COALESCE(adj.balance,0)+COALESCE(ir.total,0)+COALESCE(dm.advances,0)
        -COALESCE(pay.total,0)
        -CASE WHEN ?=1 THEN COALESCE(dm.deliveries,0) ELSE 0 END AS subledger_balance,
        COALESCE(gl.balance,0) AS general_ledger_balance
      FROM beneficiaries b
      LEFT JOIN (
        SELECT jl.beneficiary_id, SUM(jl.debit-jl.credit) balance
        FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.status='posted' AND je.date>=? AND a.code='1200'
          AND je.reference_type IN ('beneficiary_opening','beneficiary_carried')
          AND jl.beneficiary_id IN (SELECT id FROM beneficiaries WHERE station_id=?)
        GROUP BY jl.beneficiary_id
      ) adj ON adj.beneficiary_id=b.id
      LEFT JOIN (
        SELECT i.beneficiary_id,i.station_id,SUM(i.total_amount) total
        FROM irrigations i
        WHERE i.station_id=? AND i.status!='cancelled' AND i.start_datetime<?
        GROUP BY i.beneficiary_id,i.station_id
      ) ir ON ir.beneficiary_id=b.id AND ir.station_id=b.station_id
      LEFT JOIN (
        SELECT d.beneficiary_id,
          SUM(CASE WHEN d.kind='advance' AND d.irrigation_id IS NULL THEN d.amount ELSE 0 END) advances,
          SUM(CASE WHEN d.kind='delivery' THEN d.amount ELSE 0 END) deliveries
        FROM diesel_movements d
        WHERE d.date<? AND d.beneficiary_id IN (SELECT id FROM beneficiaries WHERE station_id=?)
        GROUP BY d.beneficiary_id
      ) dm ON dm.beneficiary_id=b.id
      LEFT JOIN (
        SELECT p.beneficiary_id,SUM(p.amount) total
        FROM payments p
        WHERE p.status='posted' AND p.date<?
          AND p.beneficiary_id IN (SELECT id FROM beneficiaries WHERE station_id=?)
        GROUP BY p.beneficiary_id
      ) pay ON pay.beneficiary_id=b.id
      LEFT JOIN (
        SELECT jl.beneficiary_id, SUM(jl.debit-jl.credit) balance
        FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.station_id=? AND je.status='posted' AND je.date<? AND a.code='1200'
        GROUP BY jl.beneficiary_id
      ) gl ON gl.beneficiary_id=b.id
      WHERE b.station_id=?
    ''', [financialDeliveries ? 1 : 0, end, stationId, stationId, end, end, stationId, end, stationId, stationId, end, stationId]);
    final beneficiaryReconciliation = <Map<String, Object?>>[];
    for (final beneficiary in beneficiaries) {
      final subledgerBalance = (beneficiary['subledger_balance'] as num?)?.round() ?? 0;
      final ledgerBalance = (beneficiary['general_ledger_balance'] as num?)?.round() ?? 0;
      if (subledgerBalance != ledgerBalance) {
        beneficiaryReconciliation.add({
          'id': beneficiary['id'], 'name': beneficiary['name'],
          'subledger_balance': subledgerBalance,
          'general_ledger_balance': ledgerBalance,
          'difference': subledgerBalance - ledgerBalance,
        });
      }
    }

    Future<Map<String, Object?>> reconcileControlAccount({
      required String kind,
      required String accountCode,
      required String table,
    }) async {
      final control = await tx.rawQuery('''
        SELECT COALESCE(SUM(jl.credit-jl.debit),0) balance
        FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id
        WHERE je.station_id=? AND je.status='posted' AND je.date<?
          AND jl.account_id IN (
            SELECT a.id FROM accounts a
            WHERE a.code=? OR a.parent_id=(SELECT id FROM accounts WHERE code=?)
          )
      ''', [stationId, end, accountCode, accountCode]);
      final entityColumn = table == 'workers' ? 'worker_id' : 'partner_id';
      final codePrefix = table == 'workers' ? '2100.W' : '2200.P';
      final subsidiary = await tx.rawQuery('''
        SELECT COALESCE(SUM(jl.credit-jl.debit),0) balance
        FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id
        WHERE je.station_id=? AND je.status='posted' AND je.date<? AND (
          jl.account_id IN (
            SELECT a.id FROM accounts a JOIN $table x ON a.code=('$codePrefix'||x.id)
            WHERE x.station_id=?
          ) OR (
            jl.account_id=(SELECT id FROM accounts WHERE code=?)
            AND jl.$entityColumn IN (SELECT id FROM $table WHERE station_id=?)
          )
        )
      ''', [stationId, end, stationId, accountCode, stationId]);
      final controlBalance = (control.first['balance'] as num?)?.round() ?? 0;
      final subsidiaryBalance = (subsidiary.first['balance'] as num?)?.round() ?? 0;
      return {
        'kind': kind,
        'control_account': accountCode,
        'subledger_balance': subsidiaryBalance,
        'general_ledger_balance': controlBalance,
        'difference': subsidiaryBalance - controlBalance,
      };
    }

    final workers = await reconcileControlAccount(
      kind: 'workers', accountCode: '2100', table: 'workers',
    );
    final partners = await reconcileControlAccount(
      kind: 'partners', accountCode: '2200', table: 'partners',
    );
    final beneficiaryTotal = beneficiaries.fold<int>(
      0, (sum, row) => sum + ((row['subledger_balance'] as num?)?.round() ?? 0),
    );
    final beneficiaryLedgerTotal = await tx.rawQuery('''
      SELECT COALESCE(SUM(jl.debit-jl.credit),0) balance
      FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
      JOIN accounts a ON a.id=jl.account_id
      WHERE je.station_id=? AND je.status='posted' AND je.date<? AND a.code='1200'
    ''', [stationId, end]);
    final totalLedgerBalance = (beneficiaryLedgerTotal.first['balance'] as num?)?.round() ?? 0;
    return [
      {
        'kind': 'beneficiaries',
        'control_account': '1200',
        'party_count': beneficiaries.length,
        'subledger_balance': beneficiaryTotal,
        'general_ledger_balance': totalLedgerBalance,
        'difference': beneficiaryTotal - totalLedgerBalance,
        'mismatches': beneficiaryReconciliation,
      },
      workers,
      partners,
    ];
  }

  Future<List<Map<String, Object?>>> _cashReconciliationTargetsTx(
    Transaction tx, {required int stationId, required DateTime endExclusive}
  ) async {
    final boxes = await tx.rawQuery('''
      SELECT c.id,c.name,c.currency,
        COALESCE(NULLIF(c.ledger_account_code,''),
          NULLIF((SELECT pm.ledger_account_code FROM payment_methods pm
            WHERE pm.cashbox_id=c.id AND pm.active=1 ORDER BY pm.id LIMIT 1),''),
          CASE (SELECT pm.type FROM payment_methods pm
            WHERE pm.cashbox_id=c.id AND pm.active=1 ORDER BY pm.id LIMIT 1)
            WHEN 'bank_transfer' THEN '1100' WHEN 'wallet' THEN '1120' ELSE '1000' END
        ) code,
        (SELECT GROUP_CONCAT(DISTINCT pm.type) FROM payment_methods pm
          WHERE pm.cashbox_id=c.id AND pm.active=1) method_types
      FROM cashboxes c
      WHERE c.station_id=? AND (c.active=1 OR c.current_balance<>0)
      ORDER BY c.id
    ''', [stationId]);
    final grouped = <String, Map<String, Object?>>{};
    for (final box in boxes) {
      final code = '${box['code'] ?? '1000'}';
      final group = grouped.putIfAbsent(code, () => {
        'currencies': <String>{},
        'box_names': <String>{},
        'box_ids': <int>{},
        'method_types': <String>{},
      });
      (group['currencies'] as Set<String>).add('${box['currency'] ?? 'YER'}');
      (group['box_names'] as Set<String>).add('${box['name']}');
      (group['box_ids'] as Set<int>).add((box['id'] as num).toInt());
      final methodTypes = '${box['method_types'] ?? ''}'.split(',').where((x) => x.isNotEmpty);
      (group['method_types'] as Set<String>).addAll(methodTypes);
    }
    final codes = <String>{'1000', '1100', '1120', ...grouped.keys}.toList()..sort();
    final placeholders = List.filled(codes.length, '?').join(',');
    final accountRows = await tx.rawQuery(
      'SELECT id,code,name FROM accounts WHERE code IN ($placeholders)', codes,
    );
    final accounts = {for (final row in accountRows) '${row['code']}': row};
    final ledgerRows = await tx.rawQuery('''
      SELECT a.code,COALESCE(SUM(jl.debit-jl.credit),0) balance
      FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
      JOIN accounts a ON a.id=jl.account_id
      WHERE je.station_id=? AND je.status='posted' AND je.date<?
        AND a.code IN ($placeholders)
      GROUP BY a.code
    ''', [stationId, endExclusive.toIso8601String(), ...codes]);
    final ledgerBalances = {
      for (final row in ledgerRows)
        '${row['code']}': (row['balance'] as num?)?.round() ?? 0,
    };
    final result = <Map<String, Object?>>[];
    for (final code in codes) {
      final group = grouped[code];
      final bookBalance = ledgerBalances[code] ?? 0;
      if (group == null && bookBalance == 0) continue;
      final currencies = (group?['currencies'] as Set<String>?) ?? <String>{};
      final methodTypes = (group?['method_types'] as Set<String>?) ?? <String>{};
      final isMixedSource = methodTypes.contains('cash') &&
          (methodTypes.contains('bank_transfer') || methodTypes.contains('wallet'));
      final sourceType = isMixedSource
          ? 'other'
          : methodTypes.contains('bank_transfer') || code == '1100'
              ? 'bank_statement'
              : methodTypes.contains('wallet') || code == '1120'
                  ? 'wallet_statement'
                  : methodTypes.contains('cash') || code == '1000' || methodTypes.isEmpty
                      ? 'cash_count'
                      : 'other';
      final account = accounts[code];
      result.add({
        'account_code': code,
        'account_name': '${account?['name'] ?? 'حساب $code'}',
        'cashbox_names': ((group?['box_names'] as Set<String>?) ?? <String>{}).toList()..sort(),
        'cashbox_ids': ((group?['box_ids'] as Set<int>?) ?? <int>{}).toList()..sort(),
        'currency': currencies.length == 1 ? currencies.single : currencies.isEmpty ? 'YER' : 'MIXED',
        'currency_conflict': currencies.length > 1,
        'source_type': sourceType,
        'book_balance': bookBalance,
        'account_exists': account != null,
      });
    }
    return result;
  }

  Future<Map<String, Object?>> _cashReconciliationCheckTx(
    Transaction tx, {
      required int stationId,
      required DateTime start,
      required DateTime endExclusive,
    }
  ) async {
    final targets = await _cashReconciliationTargetsTx(
      tx, stationId: stationId, endExclusive: endExclusive,
    );
    final rows = <Map<String, Object?>>[];
    final missing = <Map<String, Object?>>[];
    final mismatches = <Map<String, Object?>>[];
    for (final target in targets) {
      final code = '${target['account_code']}';
      if (target['account_exists'] != true || target['currency_conflict'] == true) {
        final invalid = {
          ...target,
          'reason': target['account_exists'] != true ? 'missing_ledger_account' : 'mixed_currency',
          'evidence_status': target['account_exists'] != true ? 'invalid_account' : 'mixed_currency',
        };
        rows.add(invalid);
        mismatches.add(invalid);
        continue;
      }
      final records = await tx.query(
        'cash_reconciliations',
        where: 'station_id=? AND period_start=? AND period_end_exclusive=? AND account_code=?',
        whereArgs: [stationId, start.toIso8601String(), endExclusive.toIso8601String(), code],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (records.isEmpty) {
        missing.add(target);
        rows.add({...target, 'evidence_status': 'missing'});
        continue;
      }
      final saved = records.first;
      final storedBook = (saved['book_balance'] as num).round();
      final currentBook = (target['book_balance'] as num).round();
      final actual = (saved['actual_balance'] as num).round();
      final difference = actual - currentBook;
      final stale = storedBook != currentBook;
      final accepted = saved['status'] == 'matched' &&
          (saved['difference'] as num).round() == 0 && difference == 0 &&
          saved['approved_by'] != null && !stale;
      final checked = {
        ...target,
        'actual_balance': actual,
        'difference': difference,
        'stored_book_balance': storedBook,
        'reference': saved['reference'],
        'reconciled_at': saved['created_at'],
        'evidence_status': accepted ? 'matched' : stale ? 'stale' : 'variance',
      };
      rows.add(checked);
      if (!accepted) mismatches.add(checked);
    }
    return {
      'valid': missing.isEmpty && mismatches.isEmpty,
      'rows': rows,
      'missing': missing,
      'mismatches': mismatches,
    };
  }

  Future<List<Map<String, Object?>>> cashReconciliationTargets({
    required int stationId,
    required DateTime endExclusive,
  }) => database.transaction((tx) => _cashReconciliationTargetsTx(
    tx, stationId: stationId, endExclusive: endExclusive,
  ));

  /// يسجل لقطة العد النقدي/كشف الحساب لكل حساب مطلوب؛ لا ينشئ قيد تسوية تلقائيًا.
  Future<List<Map<String, Object?>>> recordCashReconciliations({
    required int stationId,
    required DateTime start,
    required DateTime endExclusive,
    required int userId,
    required List<Map<String, Object?>> entries,
  }) => database.transaction((tx) async {
    final user = await tx.query(
      'app_users', columns: ['role', 'active', 'station_id'], where: 'id=?', whereArgs: [userId], limit: 1,
    );
    if (user.isEmpty || user.first['active'] != 1 || user.first['role'] != 'manager') {
      throw StateError('مطابقة النقد والبنك واعتمادها متاحان للمدير النشط فقط');
    }
    final assignedStationId = user.first['station_id'] as num?;
    if (assignedStationId != null && assignedStationId.toInt() != stationId) {
      throw StateError('لا يملك هذا المدير صلاحية مطابقة حسابات محطة أخرى');
    }
    final rangeError = await _fiscalRangeError(tx, start, endExclusive);
    if (rangeError != null) throw StateError(rangeError);
    final targets = await _cashReconciliationTargetsTx(
      tx, stationId: stationId, endExclusive: endExclusive,
    );
    if (targets.isEmpty) throw StateError('لا توجد حسابات نقدية أو بنكية مطلوبة للمطابقة');
    final targetByCode = {for (final target in targets) '${target['account_code']}': target};
    final submittedCodes = entries.map((row) => '${row['account_code'] ?? ''}').toList();
    if (submittedCodes.toSet().length != submittedCodes.length ||
        submittedCodes.length != targetByCode.length ||
        !submittedCodes.toSet().containsAll(targetByCode.keys)) {
      throw StateError('أدخل رصيدًا فعليًا لكل حساب نقدي أو بنكي ظاهر في قائمة المطابقة، دون تكرار');
    }
    for (final target in targets) {
      if (target['account_exists'] != true) {
        throw StateError('الحساب ${target['account_code']} غير موجود في دليل الأستاذ');
      }
      if (target['currency_conflict'] == true) {
        throw StateError('الصناديق التابعة للحساب ${target['account_code']} تستخدم عملات مختلفة؛ افصل الحسابات قبل المطابقة');
      }
    }
    final createdAt = AppClock.now().toIso8601String();
    final result = <Map<String, Object?>>[];
    for (final entry in entries) {
      final code = '${entry['account_code']}';
      final target = targetByCode[code]!;
      final rawAmount = entry['actual_balance'];
      if (rawAmount is! num || rawAmount != rawAmount.round()) {
        throw ArgumentError('الرصيد الفعلي للحساب $code يجب أن يكون عددًا صحيحًا بوحدة العملة');
      }
      final actualBalance = rawAmount.round();
      final sourceType = '${target['source_type']}';
      if (sourceType == 'cash_count' && actualBalance < 0) {
        throw ArgumentError('لا يمكن أن يكون النقد المعدود سالبًا للحساب $code');
      }
      final reference = '${entry['reference'] ?? ''}'.trim();
      if (sourceType != 'cash_count' && reference.isEmpty) {
        throw ArgumentError('مرجع كشف الحساب مطلوب للحساب $code');
      }
      final bookBalance = (target['book_balance'] as num).round();
      final difference = actualBalance - bookBalance;
      final matched = difference == 0;
      final id = await tx.insert('cash_reconciliations', {
        'station_id': stationId,
        'period_start': start.toIso8601String(),
        'period_end_exclusive': endExclusive.toIso8601String(),
        'account_code': code,
        'account_name': target['account_name'],
        'currency': target['currency'],
        'source_type': sourceType,
        'book_balance': bookBalance,
        'actual_balance': actualBalance,
        'difference': difference,
        'reference': reference.isEmpty ? null : reference,
        'notes': '${entry['notes'] ?? ''}'.trim(),
        'status': matched ? 'matched' : 'variance',
        'created_by': userId,
        'approved_by': matched ? userId : null,
        'approved_at': matched ? createdAt : null,
        'created_at': createdAt,
      });
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'cash_reconciliation',
        table: 'cash_reconciliations',
        recordId: id,
        newValues: {
          'station_id': stationId,
          'period_start': start.toIso8601String(),
          'period_end_exclusive': endExclusive.toIso8601String(),
          'account_code': code,
          'source_type': sourceType,
          'book_balance': bookBalance,
          'actual_balance': actualBalance,
          'difference': difference,
          'status': matched ? 'matched' : 'variance',
          'reference': reference,
        },
        reason: matched ? 'اعتماد مطابقة صفرية' : 'تسجيل فرق للمراجعة؛ لا ينشأ قيد تسوية تلقائيًا',
      );
      result.add({
        'id': id,
        'account_code': code,
        'book_balance': bookBalance,
        'actual_balance': actualBalance,
        'difference': difference,
        'status': matched ? 'matched' : 'variance',
      });
    }
    return result;
  });

  Future<Map<String, Object?>> _fiscalPreviewTx(
    Transaction tx, {required int stationId, required DateTime start, required DateTime endExclusive}
  ) async {
    final errors = <String>[];
    final rangeError = await _fiscalRangeError(tx, start, endExclusive);
    if (rangeError != null) errors.add(rangeError);
    final station = await tx.query('stations', where: 'id=? AND active=1', whereArgs: [stationId], limit: 1);
    if (station.isEmpty) errors.add('المحطة غير موجودة أو غير نشطة');
    final overlapping = await tx.rawQuery(
      "SELECT id FROM period_closures WHERE station_id=? AND status!='reopened' AND period_start<? AND ((period_end_exclusive IS NOT NULL AND period_end_exclusive>?) OR (period_end_exclusive IS NULL AND period_end>=?)) LIMIT 1",
      [stationId, endExclusive.toIso8601String(), start.toIso8601String(), start.toIso8601String()],
    );
    if (overlapping.isNotEmpty) errors.add('تتداخل هذه السنة مع فترة مغلقة سابقًا');
    final args = [stationId, start.toIso8601String(), endExclusive.toIso8601String()];
    final unassigned = await tx.rawQuery('SELECT COUNT(*) n FROM journal_entries WHERE station_id IS NULL AND date>=? AND date<?', [start.toIso8601String(), endExclusive.toIso8601String()]);
    final unassignedCount = (unassigned.first['n'] as num).toInt();
    if (unassignedCount > 0) errors.add('يوجد $unassignedCount قيدًا قديمًا غير منسوب إلى محطة؛ يلزم تصنيفه قبل الإقفال');
    final unposted = await tx.rawQuery("SELECT COUNT(*) n FROM journal_entries WHERE station_id=? AND date>=? AND date<? AND status!='posted'", args);
    final unpostedCount = (unposted.first['n'] as num).toInt();
    if (unpostedCount > 0) errors.add('توجد قيود غير مرحلة في الفترة');
    final unbalanced = await tx.rawQuery(
      "SELECT COUNT(*) n FROM (SELECT je.id FROM journal_entries je LEFT JOIN journal_lines jl ON jl.journal_entry_id=je.id WHERE je.station_id=? AND je.date>=? AND je.date<? AND je.status='posted' GROUP BY je.id HAVING COUNT(jl.id)=0 OR ROUND(SUM(jl.debit),2)<>ROUND(SUM(jl.credit),2))",
      args,
    );
    final unbalancedCount = (unbalanced.first['n'] as num).toInt();
    if (unbalancedCount > 0) errors.add('توجد قيود يومية غير متوازنة');
    final trialBalance = await tx.rawQuery(
      "SELECT a.type,COALESCE(SUM(jl.debit),0) debit,COALESCE(SUM(jl.credit),0) credit,COALESCE(SUM(jl.debit-jl.credit),0) debit_balance,COALESCE(SUM(jl.credit-jl.debit),0) credit_balance FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.date<? AND je.status='posted' GROUP BY a.type ORDER BY a.type",
      [stationId, endExclusive.toIso8601String()],
    );
    final tbDebit = trialBalance.fold<int>(0, (n, r) => n + (r['debit'] as num).round());
    final tbCredit = trialBalance.fold<int>(0, (n, r) => n + (r['credit'] as num).round());
    if (tbDebit != tbCredit) errors.add('ميزان المراجعة غير متوازن عند نهاية الفترة: مدين $tbDebit / دائن $tbCredit');

    // مطابقة الموجود الفعلي حاليًا مع دفاتر الأستاذ للصناديق التابعة لهذه المحطة.
    // لا نقارن النقد الحالي بتاريخ تاريخي؛ المقارنة تستخدم كامل حركة الأستاذ حتى الآن.
    final cashboxes = await tx.rawQuery(
      "SELECT COALESCE(NULLIF(c.ledger_account_code,''),(SELECT NULLIF(pm.ledger_account_code,'') FROM payment_methods pm WHERE pm.cashbox_id=c.id AND pm.active=1 ORDER BY pm.id LIMIT 1),'1000') code,COALESCE(SUM(c.current_balance),0) balance FROM cashboxes c WHERE c.station_id=? GROUP BY COALESCE(NULLIF(c.ledger_account_code,''),(SELECT NULLIF(pm.ledger_account_code,'') FROM payment_methods pm WHERE pm.cashbox_id=c.id AND pm.active=1 ORDER BY pm.id LIMIT 1),'1000')",
      [stationId],
    );
    final cashAccountCodes = <String>{'1000', '1100', '1120', ...cashboxes.map((r) => '${r['code']}')}.toList()..sort();
    final cashLedger = await tx.rawQuery(
      "SELECT a.code,COALESCE(SUM(jl.debit-jl.credit),0) balance FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND a.code IN (${List.filled(cashAccountCodes.length, '?').join(',')}) GROUP BY a.code",
      [stationId, ...cashAccountCodes],
    );
    final cashByCode = <String, int>{for (final r in cashboxes) '${r['code']}': (r['balance'] as num).round()};
    final ledgerByCode = <String, int>{for (final r in cashLedger) '${r['code']}': (r['balance'] as num).round()};
    final cashCodes = {...cashByCode.keys, ...ledgerByCode.keys};
    final cashReconciliation = [
      for (final code in cashCodes.toList()..sort())
        {
          'code': code,
          'cashbox_balance': cashByCode[code] ?? 0,
          'ledger_balance': ledgerByCode[code] ?? 0,
          'difference': (cashByCode[code] ?? 0) - (ledgerByCode[code] ?? 0),
        },
    ];
    final cashMismatch = cashReconciliation.where((r) => r['difference'] != 0).toList();
    if (cashMismatch.isNotEmpty) {
      final details = cashMismatch.map((r) => "${r['code']}: فرق ${r['difference']}").join('، ');
      errors.add('أرصدة الصناديق الحالية لا تطابق حسابات النقد في الأستاذ ($details)؛ سوِّ الفروق قبل الإقفال');
    }

    final actualCashCheck = await _cashReconciliationCheckTx(
      tx, stationId: stationId, start: start, endExclusive: endExclusive,
    );
    final actualCashMissing = actualCashCheck['missing'] as List<Map<String, Object?>>;
    final actualCashMismatches = actualCashCheck['mismatches'] as List<Map<String, Object?>>;
    if (actualCashMissing.isNotEmpty) {
      final codes = actualCashMissing.map((r) => '${r['account_code']}').join('، ');
      errors.add('لم تُسجل مطابقة العد النقدي/كشوف الحسابات عند نهاية السنة للحسابات: $codes');
    }
    if (actualCashMismatches.isNotEmpty) {
      final details = actualCashMismatches.map((r) {
        final reason = switch ('${r['reason'] ?? r['evidence_status']}') {
          'stale' => 'تغير رصيد الدفاتر بعد المطابقة',
          'mixed_currency' => 'عملات مختلطة في الحساب نفسه',
          'missing_ledger_account' => 'الحساب غير موجود في دليل الأستاذ',
          _ => 'فرق ${r['difference'] ?? 'غير معتمد'}',
        };
        return '${r['account_code']}: $reason';
      }).join('، ');
      errors.add('مطابقة النقد والبنك غير مكتملة أو بها فروق ($details)؛ أعد المطابقة بعد التحقق');
    }

    final subledgerReconciliation = await _subledgerReconciliationTx(
      tx, stationId: stationId, endExclusive: endExclusive,
    );
    final subledgerMismatches = subledgerReconciliation.where((row) {
      final partyMismatches = row['mismatches'] as List?;
      return row['difference'] != 0 || (partyMismatches?.isNotEmpty ?? false);
    }).toList();
    if (subledgerMismatches.isNotEmpty) {
      final details = subledgerMismatches.map((row) {
        final label = switch ('${row['kind']}') {
          'beneficiaries' => 'المستفيدون',
          'workers' => 'العمال',
          'partners' => 'الشركاء',
          _ => '${row['kind']}',
        };
        final parties = (row['mismatches'] as List?)?.length ?? 0;
        return '$label: فرق ${row['difference']}${parties > 0 ? ' ($parties حسابات)' : ''}';
      }).join('، ');
      errors.add('توجد فروق بين الدفاتر الفرعية والأستاذ العام ($details)؛ عالجها قبل الإقفال');
    }

    final carryAccounts = await tx.rawQuery(
      "SELECT a.code,a.name,a.type,COALESCE(SUM(jl.debit),0) debit,COALESCE(SUM(jl.credit),0) credit,COALESCE(SUM(jl.credit-jl.debit),0) credit_balance FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.date<? AND je.status='posted' AND a.type IN ('asset','liability','equity') GROUP BY a.id,a.code,a.name,a.type HAVING ABS(COALESCE(SUM(jl.credit-jl.debit),0))>0 ORDER BY a.code",
      [stationId, endExclusive.toIso8601String()],
    );
    final warnings = <String>[
      'توزيع أرباح الشركاء لا يتم تلقائيًا عند الإقفال؛ راجع سياسة التوزيع ونفّذها قبل إغلاق السنة إذا لزم.',
    ];
    final salaryWorkers = await tx.rawQuery(
      "SELECT COUNT(*) n FROM workers WHERE active=1 AND pay_type='fixed' AND fixed_salary>0",
    );
    final fixedSalaryWorkers = (salaryWorkers.first['n'] as num).toInt();
    if (fixedSalaryWorkers > 0) {
      warnings.add('يوجد $fixedSalaryWorkers عامل بأجر شهري ثابت. لا يحفظ النظام تاريخ التعيين أو تغيّر الأجر؛ راجع سجل استحقاقات الرواتب يدويًا قبل الاعتماد.');
    }
    final pnlRows = await tx.rawQuery(
      "SELECT a.id account_id,a.code,a.name,a.type,COALESCE(SUM(jl.debit),0) debit,COALESCE(SUM(jl.credit),0) credit,COALESCE(SUM(jl.credit-jl.debit),0) net FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.date>=? AND je.date<? AND je.status='posted' AND a.type IN ('revenue','expense') GROUP BY a.id,a.code,a.name,a.type HAVING ABS(COALESCE(SUM(jl.credit-jl.debit),0))>0 ORDER BY a.code",
      args,
    );
    var income = 0;
    var expenses = 0;
    for (final row in pnlRows) {
      final net = (row['net'] as num).round();
      if (row['type'] == 'revenue') income += net;
      if (row['type'] == 'expense') expenses -= net;
    }
    final entries = await tx.rawQuery("SELECT COUNT(*) n FROM journal_entries WHERE station_id=? AND date>=? AND date<? AND status='posted'", args);
    return {
      'valid': errors.isEmpty, 'errors': errors, 'station_id': stationId,
      'start': start.toIso8601String(), 'end_exclusive': endExclusive.toIso8601String(),
      'income': income, 'expenses': expenses, 'net_profit': income - expenses,
      'journal_entry_count': (entries.first['n'] as num).toInt(),
      'unassigned_count': unassignedCount, 'unposted_count': unpostedCount,
      'unbalanced_count': unbalancedCount, 'overlap': overlapping.isNotEmpty,
      'pnl_accounts': pnlRows,
      'trial_balance': trialBalance,
      'trial_balance_debit': tbDebit,
      'trial_balance_credit': tbCredit,
      'cashbox_reconciliation': cashReconciliation,
      'cashbox_reconciliation_as_of': AppClock.now().toIso8601String(),
      'cashbox_mismatches': cashMismatch,
      'actual_cash_reconciliation': actualCashCheck['rows'],
      'actual_cash_missing': actualCashMissing,
      'actual_cash_mismatches': actualCashMismatches,
      'actual_cash_reconciliation_valid': actualCashCheck['valid'],
      'subledger_reconciliation': subledgerReconciliation,
      'subledger_mismatches': subledgerMismatches,
      'carry_accounts': carryAccounts,
      'warnings': warnings,
      'fixed_salary_workers': fixedSalaryWorkers,
      'partner_distributions_automatic': false,
    };
  }

  Future<Map<String, Object?>> previewFiscalYear({required int stationId, required DateTime start, required DateTime endExclusive}) async =>
      database.transaction((tx) => _fiscalPreviewTx(tx, stationId: stationId, start: start, endExclusive: endExclusive));

  /// يقفل سنة كاملة؛ أرصدة الميزانية تبقى في دفتر الأستاذ المتصل ولا تُكرر بقيود افتتاحية.
  Future<int> closeFiscalYear({required int stationId, required DateTime start, required DateTime endExclusive, required int userId, String? notes}) async =>
      database.transaction((tx) async {
        final user = await tx.query('app_users', columns: ['role', 'active'], where: 'id=?', whereArgs: [userId], limit: 1);
        if (user.isEmpty || user.first['active'] != 1 || user.first['role'] != 'manager') throw StateError('إقفال السنة المالية متاح للمدير النشط فقط');
        final preview = await _fiscalPreviewTx(tx, stationId: stationId, start: start, endExclusive: endExclusive);
        if (preview['valid'] != true) throw StateError((preview['errors'] as List).join('؛ '));
        final closeDate = endExclusive.subtract(const Duration(microseconds: 1));
        final id = await tx.insert('period_closures', {
          'station_id': stationId, 'period_start': start.toIso8601String(),
          'period_end': closeDate.toIso8601String(), 'period_end_exclusive': endExclusive.toIso8601String(),
          'closed_at': AppClock.now().toIso8601String(), 'closed_by': userId,
          'opening_transfer': 0, 'net_profit': preview['net_profit'], 'status': 'closing', 'notes': notes,
          'reconciliation_json': jsonEncode({
            'journal_entry_count': preview['journal_entry_count'],
            'trial_balance': preview['trial_balance'],
            'trial_balance_debit': preview['trial_balance_debit'],
            'trial_balance_credit': preview['trial_balance_credit'],
            'cashbox_reconciliation': preview['cashbox_reconciliation'],
            'cashbox_reconciliation_as_of': preview['cashbox_reconciliation_as_of'],
            'actual_cash_reconciliation': preview['actual_cash_reconciliation'],
            'actual_cash_reconciliation_valid': preview['actual_cash_reconciliation_valid'],
            'subledger_reconciliation': preview['subledger_reconciliation'],
            'carry_accounts': preview['carry_accounts'],
            'income': preview['income'], 'expenses': preview['expenses'],
            'net_profit': preview['net_profit'],
            'warnings': preview['warnings'],
            'fixed_salary_workers': preview['fixed_salary_workers'],
            'partner_distributions_automatic': false,
          }),
        });
        final lines = <Map<String, Object?>>[];
        for (final account in preview['pnl_accounts'] as List<Map<String, Object?>>) {
          final net = (account['net'] as num).round();
          if (net != 0) lines.add({'account_id': account['account_id'], 'debit': net > 0 ? net : 0, 'credit': net < 0 ? -net : 0, 'memo': 'إقفال السنة المالية ${start.year}'});
        }
        final profit = (preview['net_profit'] as num).round();
        if (profit != 0) lines.add({'account_id': await _accountIdTx(tx, '3300'), 'debit': profit < 0 ? -profit : 0, 'credit': profit > 0 ? profit : 0, 'memo': 'صافي نتيجة السنة المالية ${start.year}'});
        int? closingEntryId;
        if (lines.isNotEmpty) {
          closingEntryId = await _entry(tx, description: 'إقفال السنة المالية ${start.year}', referenceType: 'year_close', referenceId: id, lines: lines, userId: userId, date: closeDate, stationId: stationId);
        }
        await tx.update('period_closures', {'status': 'closed', 'close_journal_entry_id': closingEntryId}, where: 'id=?', whereArgs: [id]);
        await database.auditTx(tx, userId: userId, operation: 'close_fiscal_year', table: 'period_closures', recordId: id,
          newValues: {'station_id': stationId, 'start': start.toIso8601String(), 'end_exclusive': endExclusive.toIso8601String(), 'income': preview['income'], 'expenses': preview['expenses'], 'net_profit': profit, 'closing_journal_entry_id': closingEntryId}, reason: notes);
        return id;
      });

  Future<void> reopenFiscalYear({required int closureId, required int userId, required String reason}) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب إعادة فتح السنة مطلوب');
    await database.transaction((tx) async {
      final user = await tx.query('app_users', columns: ['role', 'active'], where: 'id=?', whereArgs: [userId], limit: 1);
      if (user.isEmpty || user.first['active'] != 1 || user.first['role'] != 'manager') {
        throw StateError('إعادة فتح السنة المالية متاحة للمدير النشط فقط');
      }
      final rows = await tx.query('period_closures', where: 'id=?', whereArgs: [closureId], limit: 1);
      if (rows.isEmpty || rows.first['status'] != 'closed') throw StateError('الإقفال غير موجود أو سبق إعادة فتحه');
      final closure = rows.first;
      final stationId = (closure['station_id'] as num).toInt();
      final endExclusive = DateTime.parse('${closure['period_end_exclusive']}');
      final later = await tx.rawQuery(
        "SELECT id FROM period_closures WHERE station_id=? AND status='closed' AND period_start>=? LIMIT 1",
        [stationId, endExclusive.toIso8601String()],
      );
      if (later.isNotEmpty) throw StateError('لا يمكن إعادة فتح سنة تسبق سنة مالية مقفلة؛ أعد فتح الإقفالات الأحدث أولًا');

      int? reversalId;
      final closingEntryId = (closure['close_journal_entry_id'] as num?)?.toInt();
      if (closingEntryId != null) {
        final entry = await tx.query('journal_entries', where: 'id=?', whereArgs: [closingEntryId], limit: 1);
        if (entry.isEmpty || entry.first['status'] != 'posted') throw StateError('قيد الإقفال غير موجود أو غير مرحّل');
        final lines = await tx.query('journal_lines', where: 'journal_entry_id=?', whereArgs: [closingEntryId]);
        if (lines.isEmpty) throw StateError('قيد الإقفال لا يحتوي على أسطر قابلة للعكس');
        reversalId = await _entry(
          tx,
          description: 'عكس إقفال السنة ${DateTime.parse('${closure['period_start']}').year}: ${reason.trim()}',
          referenceType: 'year_close_reversal',
          referenceId: closureId,
          lines: [
            for (final line in lines)
              {
                'account_id': line['account_id'],
                'beneficiary_id': line['beneficiary_id'],
                'worker_id': line['worker_id'],
                'partner_id': line['partner_id'],
                'debit': line['credit'],
                'credit': line['debit'],
                'memo': 'عكس إقفال: ${line['memo'] ?? ''}',
              },
          ],
          userId: userId,
          date: DateTime.parse('${closure['period_end']}'),
          stationId: stationId,
        );
      }
      final now = AppClock.now().toIso8601String();
      await tx.update('period_closures', {
        'status': 'reopened',
        'reopened_at': now,
        'reopened_by': userId,
        'reopen_reason': reason.trim(),
        'reopen_journal_entry_id': reversalId,
      }, where: 'id=?', whereArgs: [closureId]);
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'reopen_fiscal_year',
        table: 'period_closures',
        recordId: closureId,
        oldValues: {'status': 'closed', 'close_journal_entry_id': closingEntryId},
        newValues: {'status': 'reopened', 'reopen_journal_entry_id': reversalId},
        reason: reason.trim(),
      );
    });
  }

  /// قيد الرصيد الافتتاحي لعامل/شريك (الموجب = له على المحطة، السالب = عليه).
  /// له: مدين الأرصدة الافتتاحية 3000 / دائن حساب الطرف. عليه: العكس.
  Future<void> postPartyOpeningTx(
    Transaction tx, {
    required String kind,
    required int id,
    required String name,
    required int amount,
    int? userId,
  }) async {
    if (amount == 0) return;
    await _assertPeriodOpen(tx, AppClock.now());
    final isWorker = kind == 'worker';
    final liability = isWorker
        ? await _workerAccountIdTx(tx, id)
        : await _partnerAccountIdTx(tx, id);
    final equity = await _accountIdTx(tx, '3000');
    final owed = amount > 0;
    final abs = amount.abs();
    await _entry(
      tx,
      description:
          '${isWorker ? 'رصيد افتتاحي للعامل' : 'رصيد افتتاحي للشريك'} $name',
      referenceType: isWorker ? 'worker_opening' : 'partner_opening',
      referenceId: id,
      lines: [
        {
          'account_id': liability,
          if (isWorker) 'worker_id': id else 'partner_id': id,
          'debit': owed ? 0 : abs,
          'credit': owed ? abs : 0,
        },
        {
          'account_id': equity,
          'debit': owed ? abs : 0,
          'credit': owed ? 0 : abs,
        },
      ],
      userId: userId,
    );
  }

  Future<int> recordIrrigation({
    required int stationId,
    required int pumpId,
    int? beneficiaryId,
    int? workerId,
    int? operatorWorkerId,
    int? partnerId,
    String partyType = 'beneficiary',
    required DateTime start,
    required DateTime end,
    required String systemType,
    required int waterRate,
    required double litersPerHour,
    required int dieselPrice,
    required int solarRate,
    required int thirdRate,
    required int cloudMinutes,
    List<Map<String, String>> cloudPeriods = const [],
    required int paidAmount,
    int? paymentMethodId,
    int? cashboxId,
    int? bookingId,
    int? queueId,
    int? sessionId,
    int? userId,
    bool overrideWaitingPeriod = false,
    String? overrideReason,
    String? notes,
  }) async {
    if ((partyType == 'beneficiary' && beneficiaryId == null) ||
        (partyType == 'worker' && workerId == null) ||
        (partyType == 'partner' && partnerId == null)) {
      throw ArgumentError('يجب تحديد صاحب حساب السقاية');
    }
    if (paidAmount < 0) throw ArgumentError('المبلغ المدفوع لا يمكن أن يكون سالبًا');
    // الدفعة المرافقة للسقاية تخص المستفيد فقط؛ العامل/الشريك يُسدَّد حسابهما من شاشة الدفع.
    if (paidAmount > 0 && partyType != 'beneficiary') {
      throw ArgumentError('الدفعة المرافقة للسقاية متاحة للمستفيد فقط');
    }
    // الدور والحجز والجلسة تخص المستفيد فقط؛ سقاية عامل/شريك لا يجوز أن تُغلق دور مستفيد.
    if (partyType != 'beneficiary' &&
        (queueId != null || bookingId != null || sessionId != null)) {
      throw ArgumentError('الربط بالدور أو الحجز أو الجلسة متاح لسقاية المستفيد فقط');
    }
    final set = await settings();
    final configuredPumpId = int.tryParse(set['selected_pump_id'] ?? '');
    if (configuredPumpId == null) throw StateError('لا توجد مضخة محددة في الإعدادات');
    final pumpRows = await database.query(
      'SELECT id,station_id,active FROM pumps WHERE id=? LIMIT 1',
      args: [configuredPumpId],
    );
    if (pumpRows.isEmpty || pumpRows.first['active'] != 1) {
      throw StateError('المضخة المحددة في الإعدادات غير موجودة أو غير فعالة');
    }
    if (pumpRows.first['station_id'] != stationId) {
      throw StateError('المضخة المحددة لا تتبع المحطة الحالية');
    }
    if (pumpId != configuredPumpId) {
      throw StateError('يجب استخدام المضخة المحددة في الإعدادات فقط');
    }

    // نوع المنظومة مركزي: لا نثق بقيمة الشاشة أو المضخة القادمة من الواجهة.
    final effectiveType = set['system_type'] ?? 'diesel';
    const allowedTypes = {'diesel', 'solar', 'equivalent_hybrid'};
    if (!allowedTypes.contains(effectiveType)) {
      throw StateError('نوع المنظومة في الإعدادات غير صالح');
    }

    // الأسعار أيضًا تؤخذ من الإعدادات لحظة التسجيل حتى يكون السعر Snapshot موحدًا.
    final effectiveWaterRate = int.tryParse(set['diesel_hourly_water_rate'] ?? '0') ?? 0;
    final effectiveLiters = double.tryParse(set['diesel_liters_per_hour'] ?? '0') ?? 0;
    final effectiveDieselPrice = int.tryParse(set['diesel_price_per_liter'] ?? '0') ?? 0;
    final effectiveSolarRate = int.tryParse(set['solar_hourly_rate'] ?? '0') ?? 0;
    final effectiveThirdRate = int.tryParse(set['third_type_hourly_rate'] ?? '0') ?? 0;
    final allowMidnight = set['allow_midnight_crossing'] == 'true';
    // عبور منتصف الليل: تُنقل النهاية لليوم التالي قبل أي فحص أو حفظ، حتى لا يُحفظ
    // end_datetime أصغر من البداية فيفسد فحص التعارض والتقارير.
    final endDt = (allowMidnight && !end.isAfter(start))
        ? end.add(const Duration(days: 1))
        : end;
    final normalizedCloudPeriods = <Map<String, Object?>>[];
    if (effectiveType == 'solar' && cloudPeriods.isNotEmpty) {
      final parsed = <Map<String, Object?>>[];
      for (final period in cloudPeriods) {
        final ps = DateTime.tryParse(period['start'] ?? '');
        final pe = DateTime.tryParse(period['end'] ?? '');
        if (ps == null || pe == null || !pe.isAfter(ps)) {
          throw ArgumentError('فترة الغيم يجب أن تحتوي وقت بداية ونهاية صحيحين');
        }
        if (ps.isBefore(start) || pe.isAfter(endDt)) {
          throw ArgumentError('فترة الغيم يجب أن تقع داخل وقت السقاية');
        }
        parsed.add({'start': ps, 'end': pe, 'minutes': pe.difference(ps).inMinutes});
      }
      parsed.sort((a,b) => (a['start'] as DateTime).compareTo(b['start'] as DateTime));
      for (var i=1; i<parsed.length; i++) {
        if ((parsed[i]['start'] as DateTime).isBefore(parsed[i-1]['end'] as DateTime)) {
          throw ArgumentError('فترات الغيم لا يجوز أن تتداخل');
        }
      }
      final totalCloud = parsed.fold<int>(0, (sum, x) => sum + (x['minutes'] as int));
      if (totalCloud > AccountingCalculations.minutesBetween(start, endDt, allowMidnightCrossing: allowMidnight)) {
        throw ArgumentError('إجمالي خصم الغيم لا يمكن أن يتجاوز مدة السقاية');
      }
      for (final x in parsed) {
        normalizedCloudPeriods.add({
          'start': (x['start'] as DateTime).toIso8601String(),
          'end': (x['end'] as DateTime).toIso8601String(),
          'minutes': x['minutes'],
        });
      }
    }
    final effectiveCloud = effectiveType == 'solar'
        ? (normalizedCloudPeriods.isNotEmpty
            ? normalizedCloudPeriods.fold<int>(0, (sum, x) => sum + (x['minutes'] as int))
            : cloudMinutes.clamp(0, AccountingCalculations.minutesBetween(start, endDt, allowMidnightCrossing: allowMidnight)))
        : 0;
    final rounding = set['rounding'] ?? 'nearest';
    final partialHour = set['partial_hour'] != 'false';
    final calc = effectiveType == 'diesel'
        ? AccountingCalculations.diesel(
            start: start,
            end: endDt,
            hourlyWaterRate: effectiveWaterRate,
            litersPerHour: effectiveLiters,
            dieselPrice: effectiveDieselPrice,
            cloudMinutes: 0,
            allowMidnightCrossing: allowMidnight,
            rounding: rounding,
            partialHour: partialHour,
          )
        : effectiveType == 'solar'
        ? AccountingCalculations.solar(
            start: start,
            end: endDt,
            hourlyRate: effectiveSolarRate,
            cloudMinutes: effectiveCloud,
            allowMidnightCrossing: allowMidnight,
            rounding: rounding,
            partialHour: partialHour,
          )
        : AccountingCalculations.equivalent(
            start: start,
            end: endDt,
            hourlyRate: effectiveThirdRate,
            allowMidnightCrossing: allowMidnight,
            rounding: rounding,
            partialHour: partialHour,
          );

    return _withAlerts(() => database.transaction((tx) async {
      await _assertPeriodOpen(tx, start, stationId: stationId);
      if (sessionId != null) {
        final sess = await tx.query(
          'irrigation_sessions',
          columns: ['status', 'beneficiary_id'],
          where: 'id=?',
          whereArgs: [sessionId],
          limit: 1,
        );
        if (sess.isEmpty || sess.first['status'] != 'running') {
          throw StateError('الجلسة غير موجودة أو ليست قيد التشغيل');
        }
        if (sess.first['beneficiary_id'] != beneficiaryId) {
          throw StateError('الجلسة المختارة تخص مستفيدًا آخر');
        }
      }
      if (queueId != null) {
        final q = await tx.query(
          'queue_entries',
          columns: ['status', 'beneficiary_id'],
          where: 'id=?',
          whereArgs: [queueId],
          limit: 1,
        );
        if (q.isEmpty) throw StateError('إدخال الدور غير موجود');
        if (q.first['beneficiary_id'] != beneficiaryId) {
          throw StateError('الدور المختار يخص مستفيدًا آخر');
        }
        if (!['waiting', 'postponed'].contains('${q.first['status']}')) {
          throw StateError('الدور المختار لم يعد قائمًا (تمت خدمته أو إلغاؤه)');
        }
      }
      if (bookingId != null) {
        final bk = await tx.query(
          'booking_requests',
          columns: ['status', 'beneficiary_id'],
          where: 'id=?',
          whereArgs: [bookingId],
          limit: 1,
        );
        if (bk.isEmpty) throw StateError('الحجز غير موجود');
        if (bk.first['beneficiary_id'] != beneficiaryId) {
          throw StateError('الحجز المختار يخص مستفيدًا آخر');
        }
        if (!['new', 'under_review', 'scheduled', 'accepted', 'notified']
            .contains('${bk.first['status']}')) {
          throw StateError('الحجز المختار لم يعد قائمًا (مكتمل أو ملغى)');
        }
      }
      final overlap = await tx.rawQuery(
        "SELECT id FROM irrigations WHERE pump_id=? AND status!='cancelled' AND start_datetime<? AND end_datetime>? LIMIT 1",
        [pumpId, endDt.toIso8601String(), start.toIso8601String()],
      );
      if (overlap.isNotEmpty) throw StateError('يوجد تعارض زمني على المضخة');
      final minDays = int.tryParse(set['min_wait_days'] ?? '3') ?? 3;
      final override = partyType == 'beneficiary'
          ? await _checkWaiting(
              tx,
              beneficiaryId!,
              start,
              minDays: minDays,
              override: overrideWaitingPeriod,
              reason: overrideReason,
              userId: userId,
            )
          : (overrideWaitingPeriod ? 1 : 0);
      // ---- ديزل المستفيد: حساب العجز مرة واحدة قبل إنشاء الفاتورة ----
      // سياسة منع الازدواج:
      //  * إن كان تسليم الديزل رصيدًا ماليًا (له) يُحمَّل كامل ثمن الوقود ويُخصم الرصيد عند التسليم.
      //  * وإلا يُحمَّل ثمن العجز فقط (الكمية التي لم يغطها ديزله العيني).
      var chargedDiesel = calc.dieselAmount;
      var shortageLiters = 0.0;
      if (partyType == 'beneficiary' &&
          effectiveType == 'diesel' &&
          calc.dieselLiters > 0) {
        final br = await tx.rawQuery(_beneficiaryDieselStockSql, [
          beneficiaryId,
          beneficiaryId,
          beneficiaryId,
        ]);
        final available = (br.first['stock'] as num?)?.toDouble() ?? 0;
        shortageLiters = calc.dieselLiters > available
            ? calc.dieselLiters - available
            : 0;
        final financialCredit =
            (set['diesel_delivery_financial_credit'] ?? '').toLowerCase() ==
            'true';
        if (!financialCredit) {
          chargedDiesel = AccountingCalculations.roundAmount(
            shortageLiters * effectiveDieselPrice,
            rounding,
          );
        }
      }
      final totalCharged = calc.waterAmount + chargedDiesel;
      final now = AppClock.now().toIso8601String();
      final id = await tx.insert('irrigations', {
        'station_id': stationId,
        'pump_id': pumpId,
        'beneficiary_id': beneficiaryId,
        'worker_id': workerId,
        'operator_worker_id': operatorWorkerId,
        'partner_id': partnerId,
        'party_type': partyType,
        'booking_id': bookingId,
        'queue_entry_id': queueId,
        'session_id': sessionId,
        'date': start.toIso8601String().substring(0, 10),
        'start_datetime': start.toIso8601String(),
        'end_datetime': endDt.toIso8601String(),
        'minutes': calc.minutes,
        'system_type': effectiveType,
        'water_hourly_rate_snapshot': effectiveWaterRate,
        'diesel_liters_per_hour_snapshot': effectiveLiters,
        'diesel_price_snapshot': effectiveDieselPrice,
        'solar_hourly_rate_snapshot': effectiveSolarRate,
        'third_type_hourly_rate_snapshot': effectiveThirdRate,
        'cloud_minutes': calc.cloudMinutes,
        'chargeable_minutes': calc.chargeableMinutes,
        'water_amount': calc.waterAmount,
        'diesel_amount': chargedDiesel,
        'total_amount': totalCharged,
        'paid_amount': paidAmount,
        'status': 'posted',
        'override_waiting_period': override,
        'override_reason': overrideReason,
        'created_by': userId,
        'created_at': now,
        'updated_at': now,
        'notes': notes,
      });
      for (final period in normalizedCloudPeriods) {
        await tx.insert('cloud_periods', {
          'irrigation_id': id,
          'start_datetime': period['start'],
          'end_datetime': period['end'],
          'minutes': period['minutes'],
          'created_at': now,
        });
      }
      // حساب الطرف في الأستاذ يطابق كشفه الفرعي:
      // مستفيد → ذمم المستفيدين 1200، عامل → مستحقات العمال 2100، شريك → مستحقات الشركاء 2200.
      // (كان العامل/الشريك يُقيَّد على 1200 بينما كشفهما يخصم السقاية من 2100/2200).
      final receivable = partyType == 'worker'
          ? await _workerAccountIdTx(tx, workerId!)
          : partyType == 'partner'
          ? await _partnerAccountIdTx(tx, partnerId!)
          : await _accountIdTx(tx, '1200');
      final waterRevenue = await _accountIdTx(tx, '4000');
      final fuelRevenue = await _accountIdTx(tx, '4010');
      final lines = <Map<String, Object?>>[
        {
          'account_id': receivable,
          'beneficiary_id': beneficiaryId,
          'worker_id': workerId,
          'partner_id': partnerId,
          'debit': totalCharged,
          'credit': 0,
          'memo': partyType == 'beneficiary' ? 'استحقاق سقاية' : 'خصم سقاية من مستحقات الطرف',
        },
      ];
      if (calc.waterAmount > 0) {
        lines.add({
          'account_id': waterRevenue,
          'debit': 0,
          'credit': calc.waterAmount,
          'memo': 'إيراد السقي',
        });
      }
      if (chargedDiesel > 0) {
        lines.add({
          'account_id': fuelRevenue,
          'debit': 0,
          'credit': chargedDiesel,
          'memo': 'قيمة ديزل السقي',
        });
      }
      await _entry(
        tx,
        description: 'سقاية رقم $id',
        referenceType: 'irrigation',
        referenceId: id,
        lines: lines,
        userId: userId,
        date: start,
        stationId: stationId,
      );
      // احتساب أجر كل عامل نشط أجره بالساعة أو بالنسبة تلقائيًا،
      // دون الاعتماد على اختيار عامل في شاشة السقاية أو على نوع صاحب السقاية.
      // كل استحقاق يُسجل مرة واحدة في كشف العامل والأستاذ.
      var totalWorkerEntitlement = 0;
      final wageWorkers = await tx.query(
        'workers',
        columns: ['id'],
        where: "station_id=? AND active=1 AND pay_type IN ('hourly', 'percentage')",
        whereArgs: [stationId],
        orderBy: 'id',
      );
      for (final wageWorker in wageWorkers) {
        final wageWorkerId = (wageWorker['id'] as num).toInt();
        totalWorkerEntitlement += await _accrueWorkerIrrigationTx(
          tx,
          workerId: wageWorkerId,
          irrigationId: id,
          amount: totalCharged,
          hours: calc.chargeableMinutes / 60.0,
          date: start,
          userId: userId,
        );
      }

      // الاستحقاقات المباشرة عند السقاية تكون بعد أجور العمال دائمًا،
      // بما فيها سقاية الشريك؛ ولا يجوز توزيع الإيراد الإجمالي قبل الأجور.
      final partnerPool =
          (totalCharged - totalWorkerEntitlement).clamp(0, totalCharged).toInt();
      if (partnerPool > 0) {
        await _accruePartnersFromIrrigationTx(
          tx,
          irrigationId: id,
          stationId: stationId,
          amount: partnerPool,
          date: start,
          userId: userId,
        );
      }
      if (partyType == 'worker') {
        await tx.insert('worker_transactions', {
          'worker_id': workerId,
          'date': start.toIso8601String(),
          'type': 'irrigation',
          'amount': totalCharged,
          'reference_type': 'irrigation',
          'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب العامل',
          'created_by': userId,
        });
      } else if (partyType == 'partner') {
        await tx.insert('partner_transactions', {
          'partner_id': partnerId,
          'date': start.toIso8601String(),
          'type': 'irrigation',
          'amount': totalCharged,
          'ownership_snapshot': null,
          'reference_type': 'irrigation',
          'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب الشريك',
          'created_by': userId,
        });
      }
      if (partyType == 'beneficiary' &&
          effectiveType == 'diesel' &&
          calc.dieselLiters > 0) {
        if (shortageLiters > 0) {
          // سلفة تلقائية: تُسجَّل كحركة كمية فقط. قيمتها محتسبة أصلًا ضمن إجمالي
          // السقاية، فلا قيد ولا إضافة للرصيد (منعًا للازدواج وللخصم الوهمي من الصندوق).
          await tx.insert('diesel_movements', {
            'beneficiary_id': beneficiaryId,
            'irrigation_id': id,
            'kind': 'advance',
            'liters': shortageLiters,
            'unit_price': effectiveDieselPrice,
            'amount': AccountingCalculations.roundAmount(
              shortageLiters * effectiveDieselPrice,
              rounding,
            ),
            'date': start.toIso8601String(),
            'created_by': userId,
            'notes': 'سلفة ديزل تلقائية (قيمتها ضمن إجمالي السقاية)',
          });
        }
        await tx.insert('diesel_movements', {
          'beneficiary_id': beneficiaryId,
          'irrigation_id': id,
          'kind': 'consumption',
          'liters': calc.dieselLiters,
          'unit_price': effectiveDieselPrice,
          'amount': calc.dieselAmount,
          'date': start.toIso8601String(),
          'created_by': userId,
          'notes': 'استهلاك جلسة السقي',
        });
      }
      if (paidAmount > 0) {
        final src = await resolvePaymentSource(
          tx,
          paymentMethodId: paymentMethodId,
          cashboxId: cashboxId,
        );
        await _paymentInTx(
          tx,
          beneficiaryId: beneficiaryId,
          amount: paidAmount,
          paymentMethodId: src['method']!,
          cashboxId: src['cashbox']!,
          userId: userId,
          referenceNumber: 'IRR-$id',
        );
      }
      if (sessionId != null) {
        // إنهاء الجلسة داخل نفس المعاملة: إن فشل أي جزء تبقى الجلسة «تعمل» ويمكن إعادة المحاولة.
        final st = await tx.rawQuery(_stationDieselStockSql);
        await tx.update(
          'irrigation_sessions',
          {
            'actual_end': endDt.toIso8601String(),
            'timer_stopped_at': endDt.toIso8601String(),
            'status': 'completed',
            'diesel_after': (st.first['stock'] as num?)?.toDouble() ?? 0,
          },
          where: 'id=?',
          whereArgs: [sessionId],
        );
      }
      if (queueId != null) {
        final qt = await tx.rawQuery(
          "SELECT value FROM settings WHERE key='queue_type' LIMIT 1",
        );
        final circular =
            (qt.isEmpty ? 'circular' : '${qt.first['value']}') == 'circular';
        await completeQueueEntryTx(tx, queueId, now, circular: circular);
      }
      if (bookingId != null) {
        await tx.update(
          'booking_requests',
          {'status': 'completed', 'reviewed_at': now},
          where: 'id=?',
          whereArgs: [bookingId],
        );
      }
      return id;
    }));
  }

  Future<int> _paymentInTx(
    Transaction tx, {
    int? beneficiaryId,
    int? partnerId,
    int? workerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? referenceNumber,
    String? notes,
    bool sendNotification = true,
    DateTime? paymentDate,
  }) async {
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    final now = AppClock.now().toIso8601String();
    final effectivePaymentDate = paymentDate ?? AppClock.now();
    await _assertPeriodOpen(tx, effectivePaymentDate);
    // الصندوق تابع للطريقة؛ أي تعارض بينهما يُرفض هنا قبل أي كتابة.
    final src = await resolvePaymentSource(
      tx,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
    );
    paymentMethodId = src['method']!;
    cashboxId = src['cashbox']!;
    final isOutgoing = beneficiaryId == null;
    if (isOutgoing) {
      await _assertCashboxCanSpend(tx, cashboxId, amount);
    }
    final id = await tx.insert('payments', {
      'beneficiary_id': beneficiaryId,
      'partner_id': partnerId,
      'worker_id': workerId,
      'amount': amount,
      'date': effectivePaymentDate.toIso8601String(),
      'payment_method_id': paymentMethodId,
      'cashbox_id': cashboxId,
      'reference_number': referenceNumber,
      'notes': notes,
      'status': 'posted',
      'created_by': userId,
    });
    // قبض من مستفيد = دخول نقد (+). دفع لعامل/شريك = خروج نقد (−).
    await tx.rawUpdate(
      'UPDATE cashboxes SET current_balance=current_balance${isOutgoing ? '-' : '+'}? WHERE id=?',
      [amount, cashboxId],
    );
    // حساب الأستاذ يُشتق من الصندوق نفسه (مصدر واحد لكل العمليات).
    final cash = await _accountIdTx(tx, await _cashboxLedgerCode(tx, cashboxId));
    final partyAccount = beneficiaryId != null
        ? await _accountIdTx(tx, '1200')
        : partnerId != null
        ? await _partnerAccountIdTx(tx, partnerId)
        : await _workerAccountIdTx(tx, workerId!);
    await _entry(
      tx,
      description: isOutgoing ? 'دفع لطرف رقم $id' : 'قبض من مستفيد رقم $id',
      // كل قيد دفعة مرتبط بالدفعة نفسها ليمكن عكسه منفردًا عند إلغاء الدفعة.
      referenceType: 'payment',
      referenceId: id,
      // قبض: مدين الصندوق / دائن حساب الطرف. دفع: مدين حساب الطرف / دائن الصندوق.
      lines: [
        {
          'account_id': cash,
          'debit': isOutgoing ? 0 : amount,
          'credit': isOutgoing ? amount : 0,
        },
        {
          'account_id': partyAccount,
          'beneficiary_id': beneficiaryId,
          'partner_id': partnerId,
          'worker_id': workerId,
          'debit': isOutgoing ? amount : 0,
          'credit': isOutgoing ? 0 : amount,
        },
      ],
      userId: userId,
    );
    if (beneficiaryId != null && sendNotification) {
      final templates = await tx.query(
        'settings',
        columns: ['key', 'value'],
        where:
            "key IN ('notification_payment_title','notification_payment_body')",
      );
      final map = {
        for (final x in templates) x['key'] as String: x['value'] as String,
      };
      final title = map['notification_payment_title'] ?? 'تسجيل دفعة';
      final body =
          (map['notification_payment_body'] ??
                  'تم تسجيل دفعة بمبلغ {amount} ريال')
              .replaceAll('{amount}', '$amount');
      await tx.insert('notifications', {
        'beneficiary_id': beneficiaryId,
        'type': 'payment',
        'title': title,
        'body': body,
        'created_at': now,
      });
      _pendingAlerts.add(AppAlert(title, body));
    }
    return id;
  }

  Future<int> receivePayment({
    required int beneficiaryId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? referenceNumber,
    String? notes,
  }) => _withAlerts(
    () => database.transaction(
      (tx) => _paymentInTx(
        tx,
        beneficiaryId: beneficiaryId,
        amount: amount,
        paymentMethodId: paymentMethodId,
        cashboxId: cashboxId,
        userId: userId,
        referenceNumber: referenceNumber,
        notes: notes,
      ),
    ),
  );
  Future<int> payWorker({
    required int workerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? referenceNumber,
    String? notes,
  }) => database.transaction((tx) async {
    final id = await _paymentInTx(
      tx,
      workerId: workerId,
      amount: amount,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      userId: userId,
      referenceNumber: referenceNumber,
      notes: notes,
    );
    await tx.insert('worker_transactions', {
      'worker_id': workerId,
      'date': AppClock.now().toIso8601String(),
      'type': 'payment',
      'amount': amount,
      'cashbox_id': cashboxId,
      'reference_type': 'payment',
      'reference_id': id,
      'notes': notes,
      'created_by': userId,
    });
    return id;
  });
  Future<int> payPartner({
    required int partnerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? referenceNumber,
    String? notes,
  }) => database.transaction((tx) async {
    final id = await _paymentInTx(
      tx,
      partnerId: partnerId,
      amount: amount,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      userId: userId,
      referenceNumber: referenceNumber,
      notes: notes,
    );
    await tx.insert('partner_transactions', {
      'partner_id': partnerId,
      'date': AppClock.now().toIso8601String(),
      'type': 'payment',
      'amount': amount,
      'reference_type': 'payment',
      'reference_id': id,
      'notes': notes,
      'created_by': userId,
    });
    return id;
  });

  Future<int> addExpense({
    required String category,
    required String title,
    required int amount,
    required DateTime date,
    required int paymentMethodId,
    required int cashboxId,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    int? userId,
    String? attachmentPath,
    String? notes,
  }) async => database.transaction((tx) async {
    await _assertPeriodOpen(tx, date);
    if (amount <= 0) {
      throw ArgumentError('قيمة المصروف يجب أن تكون أكبر من صفر');
    }
    // رواتب وأجور العاملين تُسجل من سجل العامل كاستحقاق ثم تُسوّى بالدفع.
    // منع تسجيلها كمصروف نقدي عام يحمي من احتساب الأجر مرتين.
    if (partnerId == null && category == 'workers') {
      throw ArgumentError('أجور العاملين تُسجل من شاشة العمال كاستحقاق، ثم تُدفع من حساب العامل؛ لا تسجلها كمصروف عام مرة أخرى.');
    }
    // الصندوق تابع للطريقة المختارة (يُرفض أي تعارض).
    final src = await resolvePaymentSource(
      tx,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
    );
    paymentMethodId = src['method']!;
    cashboxId = src['cashbox']!;
    await _assertCashboxCanSpend(tx, cashboxId, amount);
    final id = await tx.insert('expenses', {
      'category': category,
      'title': title,
      'amount': amount,
      'date': date.toIso8601String(),
      'payment_method_id': paymentMethodId,
      'cashbox_id': cashboxId,
      'beneficiary_id': beneficiaryId,
      'worker_id': workerId,
      'partner_id': partnerId,
      'attachment_path': attachmentPath,
      'notes': notes,
      'status': 'posted',
      'created_by': userId,
    });
    await tx.rawUpdate(
      'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
      [amount, cashboxId],
    );
    final cash = await _accountIdTx(tx, await _cashboxLedgerCode(tx, cashboxId));
    // المصروف الخاص بالشريك يُحمّل مباشرة على حسابه الشخصي، ولا يدخل ضمن
    // المصروفات العامة أو يُخصم مرة ثانية عند احتساب الربح القابل للتوزيع.
    final debitAccount = partnerId == null
        ? await _accountIdTx(tx, _expenseAccount(category))
        : await _partnerAccountIdTx(tx, partnerId);
    await _entry(
      tx,
      description: partnerId == null ? title : '$title (مصروف خاص بالشريك)',
      referenceType: 'expense',
      referenceId: id,
      lines: [
        {
          'account_id': debitAccount,
          if (partnerId != null) 'partner_id': partnerId,
          'debit': amount,
          'credit': 0,
        },
        {'account_id': cash, 'debit': 0, 'credit': amount},
      ],
      userId: userId,
      date: date,
    );
    return id;
  });

  String _expenseAccount(String category) => switch (category) {
    'workers' => '5000',
    // التصنيف العام «الشركاء» ليس استحقاقًا للعامل.
    'partners' => '5030',
    'fuel' || 'diesel' => '5010',
    'oil' || 'grease' => '5020',
    'maintenance' || 'parts' => '5030',
    _ => '5030',
  };

  Future<void> cancelExpense(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الإلغاء مطلوب');
    await database.transaction((tx) async {
      final r = await tx.query(
        'expenses',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (r.isEmpty || r.first['status'] != 'posted') {
        throw StateError('المصروف غير قابل للإلغاء');
      }
      await _assertPeriodOpen(tx, DateTime.parse('${r.first['date']}'));
      await tx.update(
        'expenses',
        {
          'status': 'cancelled',
          'notes': '${r.first['notes'] ?? ''}\nإلغاء: $reason',
        },
        where: 'id=?',
        whereArgs: [id],
      );
      // إعادة المبلغ إلى الصندوق + قيد عكسي (بدل ترك الأستاذ والصندوق على حالهما).
      final cb = r.first['cashbox_id'] as int?;
      if (cb != null) {
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
          [(r.first['amount'] as num).round(), cb],
        );
      }
      await _reverseEntriesTx(
        tx,
        referenceType: 'expense',
        referenceId: id,
        reason: reason,
        userId: userId,
      );
      // داخل المعاملة: يجب استعمال auditTx لا audit (الأخيرة تستعمل الاتصال الخارجي).
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'cancel',
        table: 'expenses',
        recordId: id,
        oldValues: r.first,
        reason: reason,
      );
    });
  }

  Future<void> addDieselMovement({
    int? beneficiaryId,
    int? irrigationId,
    required String kind,
    required double liters,
    required int unitPrice,
    required DateTime date,
    int? cashboxId,
    int? userId,
    String? notes,
  }) async {
    if (!liters.isFinite || liters <= 0) {
      throw ArgumentError('كمية الديزل يجب أن تكون رقمًا موجبًا وصالحًا');
    }
    if (unitPrice < 0) {
      throw ArgumentError('سعر لتر الديزل لا يمكن أن يكون سالبًا');
    }
    if (!{'receipt', 'delivery', 'advance', 'consumption', 'correction', 'opening_balance'}.contains(kind)) {
      throw ArgumentError('نوع حركة الديزل غير صالح');
    }
    if ((kind == 'correction' || kind == 'opening_balance') && beneficiaryId != null) {
      throw ArgumentError('تصحيح ورصيد مخزون الديزل الافتتاحي يخص مخزون المحطة ولا يُسجل على مستفيد');
    }
    // قراءة الإعدادات خارج المعاملة لتفادي تعليق sqflite (استعلام على الاتصال أثناء معاملة مفتوحة).
    final financialCredit = await _settingBool(
      'diesel_delivery_financial_credit',
    );
    await database.transaction((tx) async {
      await _assertPeriodOpen(tx, date);
      final amount = (liters * unitPrice).round();
      if ((kind == 'correction' || kind == 'opening_balance') && amount <= 0) {
        throw ArgumentError('تصحيح المخزون والرصيد الافتتاحي يتطلبان قيمة مالية موجبة');
      }
      final stock = await tx.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN kind='receipt' OR (kind IN ('opening_balance','correction') AND beneficiary_id IS NULL) THEN liters WHEN kind IN ('delivery','consumption') THEN -liters WHEN kind='advance' AND irrigation_id IS NULL THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
      );
      final current = (stock.first['stock'] as num?)?.toDouble() ?? 0;
      if ((kind == 'delivery' ||
              kind == 'consumption' ||
              (kind == 'advance' && irrigationId == null)) &&
          liters > current) {
        throw StateError('كمية الديزل المطلوبة أكبر من المخزون المتاح');
      }
      if (kind == 'receipt' && cashboxId != null) {
        if (unitPrice < 0) {
          throw ArgumentError('سعر لتر الديزل لا يمكن أن يكون سالبًا');
        }
        await _assertCashboxCanSpend(tx, cashboxId, amount);
      }
      final id = await tx.insert('diesel_movements', {
        'beneficiary_id': beneficiaryId,
        'irrigation_id': irrigationId,
        'cashbox_id': cashboxId,
        'kind': kind,
        'liters': liters,
        'unit_price': unitPrice,
        'amount': amount,
        'date': date.toIso8601String(),
        'notes': notes,
        'created_by': userId,
      });
      if (kind == 'receipt' && cashboxId != null) {
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
          [amount, cashboxId],
        );
        final inventory = await _accountIdTx(tx, '1300');
        final cash = await _accountIdTx(
          tx,
          await _cashboxLedgerCode(tx, cashboxId),
        );
        await _entry(
          tx,
          description: 'شراء/إضافة ديزل للمخزون',
          referenceType: 'diesel_receipt',
          referenceId: id,
          lines: [
            {'account_id': inventory, 'debit': amount, 'credit': 0},
            {'account_id': cash, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'consumption') {
        final fuelExpense = await _accountIdTx(tx, '5010');
        final inventory = await _accountIdTx(tx, '1300');
        await _entry(
          tx,
          description: 'استهلاك ديزل',
          referenceType: 'diesel_consumption',
          referenceId: id,
          lines: [
            {'account_id': fuelExpense, 'debit': amount, 'credit': 0},
            {'account_id': inventory, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'correction') {
        final inventory = await _accountIdTx(tx, '1300');
        final fuelExpense = await _accountIdTx(tx, '5010');
        await _entry(
          tx,
          description: 'تصحيح زيادة مخزون الديزل',
          referenceType: 'diesel_correction',
          referenceId: id,
          lines: [
            {'account_id': inventory, 'debit': amount, 'credit': 0},
            {'account_id': fuelExpense, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'opening_balance') {
        final inventory = await _accountIdTx(tx, '1300');
        final equity = await _accountIdTx(tx, '3000');
        await _entry(
          tx,
          description: 'رصيد افتتاحي لمخزون الديزل',
          referenceType: 'diesel_opening_balance',
          referenceId: id,
          lines: [
            {'account_id': inventory, 'debit': amount, 'credit': 0},
            {'account_id': equity, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'delivery' && beneficiaryId != null && financialCredit) {
        // تسليم الديزل رصيد مالي «له»: مدين مخزون الديزل / دائن ذمة المستفيد
        // (نفس اتجاه كشف الحساب الذي يطرحه من الرصيد).
        final rec = await _accountIdTx(tx, '1200'),
            inventory = await _accountIdTx(tx, '1300');
        await _entry(
          tx,
          description: 'تسليم ديزل من المستفيد (رصيد مالي)',
          referenceType: 'diesel',
          referenceId: id,
          lines: [
            {'account_id': inventory, 'debit': amount, 'credit': 0},
            {
              'account_id': rec,
              'beneficiary_id': beneficiaryId,
              'debit': 0,
              'credit': amount,
            },
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'advance' && beneficiaryId != null) {
        // سلفة ديزل عينية: لا خروج نقد، بل خروج من مخزون الديزل.
        final rec = await _accountIdTx(tx, '1200'),
            inventory = await _accountIdTx(tx, '1300');
        await _entry(
          tx,
          description: 'سلفة ديزل للمستفيد',
          referenceType: 'diesel_advance',
          referenceId: id,
          lines: [
            {
              'account_id': rec,
              'beneficiary_id': beneficiaryId,
              'debit': amount,
              'credit': 0,
            },
            {'account_id': inventory, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
    });
  }

  Future<double> dieselStock() async {
    final r = await database.query(
      "SELECT COALESCE(SUM(CASE WHEN kind='receipt' OR (kind IN ('opening_balance','correction') AND beneficiary_id IS NULL) THEN liters WHEN kind IN ('delivery','consumption') THEN -liters WHEN kind='advance' AND irrigation_id IS NULL THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
    );
    return (r.first['stock'] as num?)?.toDouble() ?? 0;
  }

  /// كود حساب الأستاذ الذي يمثل الصندوق. هو المصدر الوحيد لكل العمليات (دفعات، مصروفات،
  /// ديزل، تحويلات). للصناديق القديمة بلا قيمة محفوظة يُشتق من أول طريقة دفع مفعّلة مرتبطة بها.
  Future<String> _cashboxLedgerCode(DatabaseExecutor ex, int cashboxId) async {
    final c = await ex.query(
      'cashboxes',
      columns: ['ledger_account_code'],
      where: 'id=?',
      whereArgs: [cashboxId],
      limit: 1,
    );
    if (c.isEmpty) throw StateError('الصندوق غير موجود');
    final own = c.first['ledger_account_code'] as String?;
    if (own != null && own.isNotEmpty) return own;
    final m = await ex.query(
      'payment_methods',
      columns: ['ledger_account_code', 'type'],
      where: 'cashbox_id=? AND active=1',
      whereArgs: [cashboxId],
      orderBy: 'id',
      limit: 1,
    );
    if (m.isEmpty) return '1000';
    final code = m.first['ledger_account_code'] as String?;
    if (code != null && code.isNotEmpty) return code;
    return switch (m.first['type'] as String?) {
      'bank_transfer' => '1100',
      'wallet' => '1120',
      _ => '1000',
    };
  }

  static const Set<String> _cashLedgerCodes = {'1000', '1100', '1120'};

  /// إنشاء صندوق. الرصيد الافتتاحي يُقيَّد (مدين حساب الصندوق / دائن الأرصدة الافتتاحية 3000)
  /// في نفس المعاملة، فلا يبقى رصيد في الصندوق بلا أثر في الأستاذ.
  Future<int> createCashbox({
    required String name,
    int openingBalance = 0,
    String currency = 'YER',
    String ledgerAccountCode = '1000',
    int? userId,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم الصندوق مطلوب');
    if (openingBalance < 0) {
      throw ArgumentError('الرصيد الافتتاحي لا يمكن أن يكون سالبًا');
    }
    if (!_cashLedgerCodes.contains(ledgerAccountCode)) {
      throw ArgumentError('حساب الصندوق غير صالح');
    }
    final stationId = await currentStationId();
    return database.transaction((tx) async {
      final now = AppClock.now();
      if (openingBalance > 0) await _assertPeriodOpen(tx, now);
      final id = await tx.insert('cashboxes', {
        'station_id': stationId,
        'name': name.trim(),
        'opening_balance': openingBalance,
        'current_balance': openingBalance,
        'currency': currency,
        'ledger_account_code': ledgerAccountCode,
        'active': 1,
      });
      if (openingBalance > 0) {
        await _entry(
          tx,
          description: 'رصيد افتتاحي للصندوق ${name.trim()}',
          referenceType: 'cashbox_opening',
          referenceId: id,
          lines: [
            {
              'account_id': await _accountIdTx(tx, ledgerAccountCode),
              'debit': openingBalance,
              'credit': 0,
            },
            {
              'account_id': await _accountIdTx(tx, '3000'),
              'debit': 0,
              'credit': openingBalance,
            },
          ],
          userId: userId,
          date: now,
        );
      }
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'create',
        table: 'cashboxes',
        recordId: id,
        newValues: {
          'name': name,
          'opening_balance': openingBalance,
          'ledger_account_code': ledgerAccountCode,
        },
      );
      return id;
    });
  }

  Future<void> transferCash({
    required int from,
    required int to,
    required int amount,
    required DateTime date,
    int? userId,
    bool opening = false,
    String? reference,
  }) async => database.transaction((tx) async {
    await _assertPeriodOpen(tx, date);
    if (amount <= 0) {
      throw ArgumentError('قيمة التحويل يجب أن تكون أكبر من صفر');
    }
    if (from == to) throw ArgumentError('لا يمكن التحويل إلى نفس الصندوق');
    final target = await tx.query(
      'cashboxes',
      columns: ['id'],
      where: 'id=? AND active=1',
      whereArgs: [to],
      limit: 1,
    );
    if (target.isEmpty) throw StateError('صندوق الوجهة غير موجود أو غير مفعّل');
    if (!opening) {
      final r = await tx.query(
        'cashboxes',
        columns: ['id'],
        where: 'id=? AND active=1',
        whereArgs: [from],
        limit: 1,
      );
      if (r.isEmpty) throw StateError('صندوق المصدر غير موجود أو غير مفعّل');
    }
    final id = await tx.insert('cashbox_transfers', {
      'from_cashbox_id': from,
      'to_cashbox_id': to,
      'amount': amount,
      'date': date.toIso8601String(),
      'is_opening_transfer': opening ? 1 : 0,
      'reference': reference,
      'created_by': userId,
    });
    if (!opening) {
      await tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
        [amount, from],
      );
    }
    await tx.rawUpdate(
      'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
      [amount, to],
    );
    // حساب كل صندوق يُشتق من الصندوق نفسه، بنفس الدالة المستعملة في الدفعات والمصروفات.
    final toAccount = await _accountIdTx(tx, await _cashboxLedgerCode(tx, to));
    // التحويل الافتتاحي: يقابله حساب الأرصدة الافتتاحية (3000) لا صندوق آخر،
    // لأن رصيد المصدر لا ينقص فيه.
    final fromAccount = opening
        ? await _accountIdTx(tx, '3000')
        : await _accountIdTx(tx, await _cashboxLedgerCode(tx, from));
    await _entry(
      tx,
      description: opening ? 'تحويل افتتاحي' : 'تحويل بين الصناديق',
      referenceType: 'cashbox_transfer',
      referenceId: id,
      lines: [
        {'account_id': toAccount, 'debit': amount, 'credit': 0},
        {'account_id': fromAccount, 'debit': 0, 'credit': amount},
      ],
      userId: userId,
      date: date,
    );
  });

  Future<int> _accrueWorkerIrrigationTx(Transaction tx, {required int workerId, required int irrigationId,
    required int amount, required double hours, required DateTime date, int? userId}) async {
    final w = await tx.query('workers', columns: ['pay_type','hourly_rate','percentage_rate'], where: 'id=?', whereArgs: [workerId], limit: 1);
    if (w.isEmpty) throw StateError('العامل المنفّذ غير موجود');
    final payType = '${w.first['pay_type']}';
    final entitlement = AccountingCalculations.workerIrrigationEntitlement(payType: payType,
      irrigationAmount: amount, hours: hours, hourlyRate: (w.first['hourly_rate'] as num?)?.round() ?? 0,
      percentageRate: (w.first['percentage_rate'] as num?)?.toDouble() ?? 0);
    // لا يجوز أن يتجاوز أجر العامل قيمة السقاية أو يجعل حصة الشركاء سالبة.
    final payableEntitlement = entitlement.clamp(0, amount).toInt();
    if (payableEntitlement <= 0) return 0;
    final id = await tx.insert('worker_transactions', {'worker_id': workerId, 'date': date.toIso8601String(),
      'type': 'irrigation', 'hours': hours, 'rate_snapshot': w.first['hourly_rate'],
      'percentage_snapshot': w.first['percentage_rate'], 'amount': payableEntitlement, 'reference_type': 'irrigation',
      'reference_id': irrigationId, 'notes': payType == 'hourly' ? 'استحقاق بالساعة من السقاية' : 'استحقاق نسبة من السقاية', 'created_by': userId});
    final exp = await _accountIdTx(tx, '5000'), payable = await _workerAccountIdTx(tx, workerId);
    await _entry(tx, description: 'أجر العامل عن السقاية $irrigationId', referenceType: 'worker', referenceId: id,
      userId: userId, date: date, lines: [{'account_id': exp, 'worker_id': workerId, 'debit': payableEntitlement, 'credit': 0},
      {'account_id': payable, 'worker_id': workerId, 'debit': 0, 'credit': payableEntitlement}]);
    return payableEntitlement;
  }

  Future<void> _accruePartnersFromIrrigationTx(Transaction tx, {required int irrigationId, required int stationId,
    required int amount, required DateTime date, int? userId}) async {
    final partners = await tx.query(
      'partners',
      where: 'station_id=? AND active=1',
      whereArgs: [stationId],
      orderBy: 'id',
    );
    if (partners.isEmpty || amount <= 0) return;
    // Use the shared allocation routine so independent percentage rounding
    // cannot allocate more than the irrigation pool (for example 3 x 33.33%
    // of a very small amount). The same rules are used by final distribution.
    final allocations = AccountingCalculations.partnerDistributionAmounts(
      distributable: amount,
      partners: partners,
    );
    for (final p in partners) {
      final pid = (p['id'] as num).toInt();
      final mode = '${p['ownership_mode']}';
      final value = allocations[pid] ?? 0;
      if (value <= 0) continue;
      final id = await tx.insert('partner_transactions', {
        'partner_id': pid,
        'date': date.toIso8601String(),
        'type': 'share_accrual',
        'amount': value,
        'ownership_snapshot': mode == 'percentage' ? p['ownership_percentage'] : p['shares_count'],
        'reference_type': 'irrigation_profit',
        'reference_id': irrigationId,
        'created_by': userId,
      });
      final equity = await _accountIdTx(tx, '3200');
      final payable = await _partnerAccountIdTx(tx, pid);
      await _entry(tx, description: 'نصيب الشريك من صافي السقاية $irrigationId',
        referenceType: 'partner', referenceId: id, userId: userId, date: date, lines: [
          {'account_id': equity, 'partner_id': pid, 'debit': value, 'credit': 0},
          {'account_id': payable, 'partner_id': pid, 'debit': 0, 'credit': value},
        ]);
    }
  }

  Future<int> accrueMonthlySalaries({required DateTime month, int? userId}) async {
    final start = DateTime(month.year, month.month, 1), end = DateTime(month.year, month.month + 1, 1);
    // راتب الشهر الجاري يُثبت بتاريخ الترحيل ليظهر ضمن فترة الشهر حتى لو لم
    // ينتهِ الشهر بعد؛ أما الأشهر السابقة فتُثبت في آخر يوم من الشهر.
    final now = AppClock.now();
    final accrualDate = month.year == now.year && month.month == now.month
        ? now
        : end.subtract(const Duration(seconds: 1));
    return database.transaction((tx) async {
      final stationId = await _selectedStationIdTx(tx);
      await _assertPeriodOpen(tx, accrualDate, stationId: stationId);
      var count = 0;
      final workers = await tx.query(
        'workers',
        where: "station_id=? AND active=1 AND pay_type='fixed' AND fixed_salary>0",
        whereArgs: [stationId],
      );
      for (final w in workers) {
        final wid = w['id'] as int;
        final monthKey = month.year * 100 + month.month;
        // مرجع الشهر في سجل العامل هو مفتاح منع التكرار الأساسي؛ فحص الأستاذ
        // أدناه يبقى لتجاوز الرواتب القديمة التي سُجلت قبل حفظ المرجع.
        final recorded = await tx.rawQuery(
          "SELECT 1 FROM worker_transactions WHERE worker_id=? AND reference_type='monthly_salary' AND reference_id=? LIMIT 1",
          [wid, monthKey],
        );
        if (recorded.isNotEmpty) continue;
        final exists = await tx.rawQuery("SELECT 1 FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id WHERE je.station_id=? AND je.reference_type='worker' AND je.description='راتب العامل الشهري' AND jl.worker_id=? AND je.date>=? AND je.date<? LIMIT 1", [stationId, wid, start.toIso8601String(), end.toIso8601String()]);
        if (exists.isNotEmpty) continue;
        // حفظ نسخة الراتب وقت الاستحقاق؛ تعديل راتب العامل لاحقًا لا يغيّر التاريخ.
        final amount = (w['fixed_salary'] as num).round();
        final id = await tx.insert('worker_transactions', {
          'worker_id': wid,
          'date': accrualDate.toIso8601String(),
          'type': 'worker_entitlement',
          'amount': amount,
          'rate_snapshot': amount,
          'reference_type': 'monthly_salary',
          'reference_id': monthKey,
          'notes': 'راتب شهري مستحق لشهر ${month.year}/${month.month.toString().padLeft(2, '0')}؛ الراتب المحفوظ وقت الترحيل: $amount',
          'created_by': userId,
        });
        final exp = await _accountIdTx(tx, '5000'), payable = await _workerAccountIdTx(tx, wid);
        await _entry(tx, description: 'راتب العامل الشهري', referenceType: 'worker', referenceId: id, userId: userId, date: accrualDate, stationId: stationId, lines: [{'account_id': exp, 'worker_id': wid, 'debit': amount, 'credit': 0}, {'account_id': payable, 'worker_id': wid, 'debit': 0, 'credit': amount}]);
        count++;
      }
      return count;
    });
  }

  Future<int> distributePartnerProfits({required DateTime from, required DateTime to, int? userId}) async {
    final start = DateTime(from.year, from.month, from.day);
    final endExclusive = DateTime(to.year, to.month, to.day + 1);
    if (!endExclusive.isAfter(start)) throw ArgumentError('نهاية فترة التوزيع يجب أن تكون بعد بدايتها');
    return database.transaction((tx) async {
      final stationId = await _selectedStationIdTx(tx);
      await _assertPeriodRangeOpen(tx, start, endExclusive, stationId: stationId);
      final args = [stationId, start.toIso8601String(), endExclusive.toIso8601String()];
      final rev = await tx.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN a.type='revenue' THEN jl.credit-jl.debit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND COALESCE(je.reference_type,'') NOT IN ('year_close','year_close_reversal') AND je.date>=? AND je.date<?",
        args,
      );
      final general = await tx.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN a.type='expense' AND a.code!='5000' THEN jl.debit-jl.credit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND COALESCE(je.reference_type,'') NOT IN ('year_close','year_close_reversal') AND je.date>=? AND je.date<?",
        args,
      );
      final worker = await tx.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN a.code='5000' THEN jl.debit-jl.credit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND COALESCE(je.reference_type,'') NOT IN ('year_close','year_close_reversal') AND je.date>=? AND je.date<?",
        args,
      );
      final profit = AccountingCalculations.distributableProfit(
        totalRevenue: (rev.first['n'] as num).round(),
        generalExpenses: (general.first['n'] as num).round(),
        workerEntitlements: (worker.first['n'] as num).round(),
      );
      final distributionRef = start.millisecondsSinceEpoch;
      final already = await tx.rawQuery(
        "SELECT pt.id FROM partner_transactions pt JOIN partners p ON p.id=pt.partner_id WHERE p.station_id=? AND pt.reference_type='profit_distribution' AND pt.reference_id=? LIMIT 1",
        [stationId, distributionRef],
      );
      if (already.isNotEmpty) throw StateError('تم ترحيل توزيع الأرباح لهذه الفترة مسبقاً');

      // تسوية الاستحقاقات المباشرة القديمة عند السقاية قبل أي توزيع جديد.
      // تُستبعد السقايات الملغاة، ويُعكس الفائض بقيد جديد لا بتعديل قيد مرحّل.
      final directRows = await tx.rawQuery(
        "SELECT pt.id,pt.partner_id,pt.amount,COALESCE((SELECT SUM(adj.amount) FROM partner_transactions adj WHERE adj.reference_type='partner_profit_adjustment' AND adj.reference_id=pt.id AND adj.type='share_adjustment'),0) adjusted FROM partner_transactions pt JOIN partners p ON p.id=pt.partner_id JOIN irrigations i ON i.id=pt.reference_id WHERE p.station_id=? AND pt.reference_type='irrigation_profit' AND COALESCE(i.status,'')!='cancelled' AND pt.date>=? AND pt.date<? ORDER BY pt.id DESC",
        args,
      );
      var directTotal = 0;
      for (final row in directRows) {
        final original = (row['amount'] as num).round();
        final adjusted = (row['adjusted'] as num).round();
        directTotal += (original - adjusted).clamp(0, original).toInt();
      }
      if (directTotal > profit) {
        var excess = directTotal - profit;
        final equity = await _accountIdTx(tx, '3200');
        for (final row in directRows) {
          if (excess <= 0) break;
          final original = (row['amount'] as num).round();
          final adjusted = (row['adjusted'] as num).round();
          final available = (original - adjusted).clamp(0, original).toInt();
          if (available <= 0) continue;
          final correction = available < excess ? available : excess;
          final partnerId = (row['partner_id'] as num).toInt();
          final adjustmentId = await tx.insert('partner_transactions', {
            'partner_id': partnerId,
            'date': endExclusive.subtract(const Duration(microseconds: 1)).toIso8601String(),
            'type': 'share_adjustment',
            'amount': correction,
            'reference_type': 'partner_profit_adjustment',
            'reference_id': (row['id'] as num).toInt(),
            'notes': 'تسوية فائض استحقاق مباشر حتى لا يتجاوز صافي ربح الفترة',
            'created_by': userId,
          });
          final payable = await _partnerAccountIdTx(tx, partnerId);
          await _entry(
            tx,
            description: 'تسوية فائض حصة أرباح مباشرة',
            referenceType: 'partner_profit_adjustment',
            referenceId: adjustmentId,
            userId: userId,
            date: endExclusive.subtract(const Duration(microseconds: 1)),
            stationId: stationId,
            lines: [
              {'account_id': payable, 'partner_id': partnerId, 'debit': correction, 'credit': 0},
              {'account_id': equity, 'partner_id': partnerId, 'debit': 0, 'credit': correction},
            ],
          );
          excess -= correction;
        }
        directTotal = profit;
      }
      final remainingProfit = (profit - directTotal).clamp(0, profit).toInt();
      final ps = await tx.query('partners', where: 'station_id=? AND active=1', whereArgs: [stationId]);
      final allocations = AccountingCalculations.partnerDistributionAmounts(
        distributable: remainingProfit,
        partners: ps,
      );
      final distributionDate = endExclusive.subtract(const Duration(microseconds: 1));
      var count = 0;
      for (final p in ps) {
        final partnerId = (p['id'] as num).toInt();
        final amount = allocations[partnerId] ?? 0;
        if (amount <= 0) continue;
        final id = await tx.insert('partner_transactions', {
          'partner_id': partnerId,
          'date': distributionDate.toIso8601String(),
          'type': 'share_accrual',
          'amount': amount,
          'ownership_snapshot': p['ownership_mode'] == 'percentage'
              ? p['ownership_percentage']
              : p['shares_count'],
          'reference_type': 'profit_distribution',
          'reference_id': distributionRef,
          'created_by': userId,
        });
        final eq = await _accountIdTx(tx, '3200');
        final payable = await _partnerAccountIdTx(tx, partnerId);
        await _entry(
          tx,
          description: 'توزيع صافي الربح للشريك',
          referenceType: 'partner',
          referenceId: id,
          userId: userId,
          date: distributionDate,
          stationId: stationId,
          lines: [
            {'account_id': eq, 'partner_id': partnerId, 'debit': amount, 'credit': 0},
            {'account_id': payable, 'partner_id': partnerId, 'debit': 0, 'credit': amount},
          ],
        );
        count++;
      }
      return count;
    });
  }

  Future<void> createWorkerAccrual({
    required int workerId,
    required int amount,
    required DateTime date,
    double hours = 0,
    int rateSnapshot = 0,
    double percentageSnapshot = 0,
    int? userId,
    String? memo,
  }) async => database.transaction((tx) async {
    if (amount <= 0) {
      throw ArgumentError('قيمة استحقاق العامل يجب أن تكون أكبر من صفر');
    }
    await _assertPeriodOpen(tx, date);
    final worker = await tx.query(
      'workers',
      columns: ['id'],
      where: 'id=?',
      whereArgs: [workerId],
      limit: 1,
    );
    if (worker.isEmpty) throw StateError('العامل غير موجود');
    final id = await tx.insert('worker_transactions', {
      'worker_id': workerId,
      'date': date.toIso8601String(),
      'type': 'accrual',
      'hours': hours,
      'rate_snapshot': rateSnapshot,
      'percentage_snapshot': percentageSnapshot,
      'amount': amount,
      'notes': memo,
      'created_by': userId,
    });
    final exp = await _accountIdTx(tx, '5000'),
        payable = await _workerAccountIdTx(tx, workerId);
    await _entry(
      tx,
      description: 'استحقاق عامل',
      referenceType: 'worker',
      referenceId: id,
      lines: [
        {
          'account_id': exp,
          'worker_id': workerId,
          'debit': amount,
          'credit': 0,
        },
        {
          'account_id': payable,
          'worker_id': workerId,
          'debit': 0,
          'credit': amount,
        },
      ],
      userId: userId,
      date: date,
    );
  });

  Future<void> createPartnerShare({
    required int partnerId,
    required int amount,
    required DateTime date,
    double? percentage,
    int? userId,
  }) async => database.transaction((tx) async {
    if (amount <= 0) {
      throw ArgumentError('قيمة حصة الشريك يجب أن تكون أكبر من صفر');
    }
    await _assertPeriodOpen(tx, date);
    final partner = await tx.query(
      'partners',
      columns: ['id'],
      where: 'id=?',
      whereArgs: [partnerId],
      limit: 1,
    );
    if (partner.isEmpty) throw StateError('الشريك غير موجود');
    final id = await tx.insert('partner_transactions', {
      'partner_id': partnerId,
      'date': date.toIso8601String(),
      'type': 'share_accrual',
      'amount': amount,
      'ownership_snapshot': percentage,
      'created_by': userId,
    });
    // حصة الشريك من الأرباح توزيع على الملكية (حقوق ملكية 3200) وليست مصروف عمال 5000.
    final expense = await _accountIdTx(tx, '3200'),
        payable = await _partnerAccountIdTx(tx, partnerId);
    await _entry(
      tx,
      description: 'حصة شريك من النشاط',
      referenceType: 'partner',
      referenceId: id,
      lines: [
        {
          'account_id': expense,
          'partner_id': partnerId,
          'debit': amount,
          'credit': 0,
        },
        {
          'account_id': payable,
          'partner_id': partnerId,
          'debit': 0,
          'credit': amount,
        },
      ],
      userId: userId,
      date: date,
    );
  });

  Future<Map<String, int>> beneficiaryBalance(int id) async {
    final r = await database.query(
      'SELECT ${BalanceSql.beneficiary('b')} balance FROM beneficiaries b WHERE b.id=?',
      args: [id],
    );
    final balance = r.isEmpty ? 0 : (r.first['balance'] as num?)?.round() ?? 0;
    return {
      'balance': balance,
      'due': balance > 0 ? balance : 0,
      'credit': balance < 0 ? -balance : 0,
    };
  }

  Future<Map<String, int>> workerBalance(int id) async {
    final r = await database.query(
      "SELECT COUNT(jl.id) entry_count,COALESCE(SUM(CASE WHEN jl.credit>0 THEN jl.credit ELSE -jl.debit END),0) balance "
      "FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id "
      "JOIN accounts a ON a.id=jl.account_id "
      "WHERE je.status='posted' AND (a.code=? OR (a.code='2100' AND jl.worker_id=?))",
      args: ['2100.W$id', id],
    );
    var v = (r.first['balance'] as num?)?.round() ?? 0;
    if (((r.first['entry_count'] as num?)?.toInt() ?? 0) == 0) {
      // Legacy worker transactions may predate general-ledger posting. Use them
      // only when there are no personal-account journal lines, never alongside GL.
      final rows = await database.query(
        "SELECT wt.*,i.party_type irrigation_party_type FROM worker_transactions wt "
        "LEFT JOIN irrigations i ON wt.reference_type='irrigation' AND i.id=wt.reference_id "
        "WHERE wt.worker_id=? ORDER BY wt.date,wt.id",
        args: [id],
      );
      v = 0;
      for (final row in rows) {
        final type = '${row['type'] ?? ''}';
        final amount = (row['amount'] as num?)?.round() ?? 0;
        final notes = '${row['notes'] ?? ''}';
        final signed = switch (type) {
          'accrual' || 'salary' || 'worker_entitlement' || 'opening_balance' => amount,
          'payment' => -amount,
          'payment_reversal' => amount,
          'irrigation' => notes.startsWith('خصم قيمة سقاية')
              ? -amount
              : notes.startsWith('استحقاق') || row['irrigation_party_type'] != 'worker'
                  ? amount
                  : -amount,
          'irrigation_reversal' => notes.startsWith('عكس استحقاق العامل')
              ? -amount
              : amount,
          _ => 0,
        };
        v += signed;
      }
    }
    return {'balance': v, 'due': v > 0 ? v : 0, 'credit': v < 0 ? -v : 0};
  }

  Future<Map<String, int>> partnerBalance(int id) async {
    final r = await database.query(
      "SELECT COUNT(jl.id) entry_count,COALESCE(SUM(CASE WHEN jl.credit>0 THEN jl.credit ELSE -jl.debit END),0) balance "
      "FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id "
      "JOIN accounts a ON a.id=jl.account_id "
      "WHERE je.status='posted' AND (a.code=? OR (a.code='2200' AND jl.partner_id=?))",
      args: ['2200.P$id', id],
    );
    var v = (r.first['balance'] as num?)?.round() ?? 0;
    if (((r.first['entry_count'] as num?)?.toInt() ?? 0) == 0) {
      // Same legacy-only fallback as the partner statement. The note distinguishes
      // a reversed personal irrigation debit from a reversed profit accrual.
      final rows = await database.query(
        'SELECT type,amount,notes FROM partner_transactions WHERE partner_id=? ORDER BY date,id',
        args: [id],
      );
      v = 0;
      for (final row in rows) {
        final type = '${row['type'] ?? ''}';
        final amount = (row['amount'] as num?)?.round() ?? 0;
        final notes = '${row['notes'] ?? ''}';
        final signed = switch (type) {
          'share_accrual' || 'opening_balance' || 'contribution' => amount,
          'payment' || 'irrigation' || 'share_adjustment' => -amount,
          'payment_reversal' || 'share_adjustment_reversal' => amount,
          'irrigation_reversal' => notes.startsWith('عكس سقاية الشريك')
              ? amount
              : -amount,
          _ => 0,
        };
        v += signed;
      }
    }
    return {'balance': v, 'due': v > 0 ? v : 0, 'credit': v < 0 ? -v : 0};
  }



  /// يعدّل السقاية ويعيد احتساب القيود والحركات التابعة داخل معاملة واحدة.
  /// الفترات المقفلة والتعارضات الزمنية تُرفض صراحةً لحماية الإقفال وسجل تشغيل المضخة.
  Future<int> updateIrrigationBasic({
    required int id,
    required DateTime start,
    required DateTime end,
    int? userId,
  }) async {
    if (!end.isAfter(start)) throw ArgumentError('وقت النهاية يجب أن يكون بعد البداية');
    return database.transaction((tx) async {
      final rows = await tx.query('irrigations', where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty || rows.first['status'] != 'posted') {
        throw StateError('السقاية غير موجودة أو ملغاة/غير مرحّلة');
      }
      final old = rows.first;
      final type = '${old['system_type']}';
      final oldStart = DateTime.parse('${old['start_datetime']}');
      final oldEnd = DateTime.parse('${old['end_datetime']}');
      try {
        await _assertPeriodRangeOpen(tx, oldStart, oldEnd,
          stationId: (old['station_id'] as num).toInt());
        await _assertPeriodRangeOpen(tx, start, end,
          stationId: (old['station_id'] as num).toInt());
      } on StateError {
        throw StateError('لا يمكن تعديل السقاية داخل فترة محاسبية مقفلة. أعد فتح الفترة من شاشة الإقفال مع تسجيل السبب، ثم أعد التعديل؛ لم تُغيّر أي بيانات.');
      }
      final overlap = await tx.rawQuery(
        "SELECT id,start_datetime,end_datetime FROM irrigations WHERE id<>? AND pump_id=? AND status!='cancelled' AND start_datetime<? AND end_datetime>? LIMIT 1",
        [id, old['pump_id'], end.toIso8601String(), start.toIso8601String()],
      );
      if (overlap.isNotEmpty) {
        final conflict = overlap.first;
        throw StateError('يتعارض الوقت المحدد مع السقاية رقم ${conflict['id']} من ${conflict['start_datetime']} إلى ${conflict['end_datetime']}. اختر وقتًا لا يتداخل معها.');
      }
      final cfgRows = await tx.query('settings', columns: ['key','value']);
      final cfg = {for (final row in cfgRows) row['key'] as String: row['value'] as String};
      final rounding = cfg['rounding'] ?? 'nearest';
      final partialHour = cfg['partial_hour'] != 'false';
      final oldCloudPeriods = await tx.query('cloud_periods',
        where: 'irrigation_id=?', whereArgs: [id], orderBy: 'start_datetime,id');
      var cloud = ((old['cloud_minutes'] as num?)?.toInt() ?? 0);
      final shiftedCloudPeriods = <Map<String, Object?>>[];
      if (oldCloudPeriods.isNotEmpty) {
        final shift = start.difference(oldStart);
        var cloudSum = 0;
        for (final period in oldCloudPeriods) {
          final originalStart = DateTime.parse('${period['start_datetime']}');
          final originalEnd = DateTime.parse('${period['end_datetime']}');
          var shiftedStart = originalStart.add(shift);
          var shiftedEnd = originalEnd.add(shift);
          if (shiftedStart.isBefore(start)) shiftedStart = start;
          if (shiftedEnd.isAfter(end)) shiftedEnd = end;
          if (!shiftedEnd.isAfter(shiftedStart)) {
            shiftedCloudPeriods.add({'id': period['id'], 'delete': true, 'old': period});
            continue;
          }
          final mins = shiftedEnd.difference(shiftedStart).inMinutes;
          cloudSum += mins;
          shiftedCloudPeriods.add({'id': period['id'], 'start_datetime': shiftedStart.toIso8601String(),
            'end_datetime': shiftedEnd.toIso8601String(), 'minutes': mins, 'old': period});
        }
        cloud = cloudSum.clamp(0, end.difference(start).inMinutes).toInt();
      }
      final allowMidnight = cfg['allow_midnight_crossing'] == 'true';
      var result = type == 'diesel'
          ? AccountingCalculations.diesel(
              start: start, end: end,
              hourlyWaterRate: (old['water_hourly_rate_snapshot'] as num?)?.toInt() ?? 0,
              litersPerHour: (old['diesel_liters_per_hour_snapshot'] as num?)?.toDouble() ?? 0,
              dieselPrice: (old['diesel_price_snapshot'] as num?)?.toInt() ?? 0,
              cloudMinutes: cloud,
              allowMidnightCrossing: allowMidnight,
              rounding: rounding, partialHour: partialHour,
            )
          : type == 'solar'
              ? AccountingCalculations.solar(
                  start: start, end: end,
                  hourlyRate: (old['solar_hourly_rate_snapshot'] as num?)?.toInt() ?? 0,
                  cloudMinutes: cloud,
                  allowMidnightCrossing: allowMidnight,
                  rounding: rounding, partialHour: partialHour,
                )
              : AccountingCalculations.equivalent(
                  start: start, end: end,
                  hourlyRate: (old['third_type_hourly_rate_snapshot'] as num?)?.toInt() ?? 0,
                  allowMidnightCrossing: allowMidnight,
                  rounding: rounding, partialHour: partialHour,
                );
      var chargedDiesel = result.dieselAmount;
      var shortageLiters = 0.0;
      final partyTypeForDiesel = '${old['party_type'] ?? 'beneficiary'}';
      final dieselBeneficiaryId = (old['beneficiary_id'] as num?)?.toInt();
      if (type == 'diesel' && partyTypeForDiesel == 'beneficiary' && result.dieselLiters > 0) {
        final stockRows = await tx.rawQuery(_beneficiaryDieselStockSql, [
          dieselBeneficiaryId, dieselBeneficiaryId, dieselBeneficiaryId,
        ]);
        var stockWithoutThisIrrigation = (stockRows.first['stock'] as num?)?.toDouble() ?? 0;
        final oldMoves = await tx.query('diesel_movements',
          where: 'irrigation_id=?', whereArgs: [id]);
        for (final move in oldMoves) {
          final liters = (move['liters'] as num?)?.toDouble() ?? 0;
          if ('${move['kind']}' == 'advance') stockWithoutThisIrrigation -= liters;
          if ('${move['kind']}' == 'consumption') stockWithoutThisIrrigation += liters;
        }
        shortageLiters = (result.dieselLiters - stockWithoutThisIrrigation).clamp(0, result.dieselLiters).toDouble();
        final financialCredit = (cfg['diesel_delivery_financial_credit'] ?? '').toLowerCase() == 'true';
        if (!financialCredit) {
          chargedDiesel = AccountingCalculations.roundAmount(shortageLiters *
            ((old['diesel_price_snapshot'] as num?)?.toDouble() ?? 0), rounding);
        }
        result = IrrigationResult(
          minutes: result.minutes, cloudMinutes: result.cloudMinutes,
          chargeableMinutes: result.chargeableMinutes, waterAmount: result.waterAmount,
          dieselAmount: chargedDiesel, totalAmount: result.waterAmount + chargedDiesel,
          dieselLiters: result.dieselLiters,
        );
      }
      final partyType = '${old['party_type'] ?? 'beneficiary'}';
      final beneficiaryId = (old['beneficiary_id'] as num?)?.toInt();
      final workerId = (old['worker_id'] as num?)?.toInt();
      final partnerId = (old['partner_id'] as num?)?.toInt();
      if (partyType == 'beneficiary' && beneficiaryId == null ||
          partyType == 'worker' && workerId == null ||
          partyType == 'partner' && partnerId == null) {
        throw StateError('بيانات صاحب حساب السقاية غير مكتملة؛ لم تُغيّر أي بيانات');
      }
      if (!{'beneficiary', 'worker', 'partner'}.contains(partyType)) {
        throw StateError('نوع صاحب حساب السقاية غير مدعوم؛ لم تُغيّر أي بيانات');
      }

      // Reverse linked wage and partner accrual rows without deleting history.
      final workerRows = await tx.query(
        'worker_transactions',
        where: "reference_type='irrigation' AND reference_id=? AND type='irrigation' AND NOT EXISTS (SELECT 1 FROM worker_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=worker_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in workerRows) {
        final transactionId = (item['id'] as num).toInt();
        await _reverseEntriesTx(tx, referenceType: 'worker', referenceId: transactionId,
          reason: 'إعادة احتساب السقاية رقم $id', userId: userId);
        final reversesPersonalIrrigation = '${item['notes'] ?? ''}'.startsWith('خصم قيمة سقاية');
        await tx.insert('worker_transactions', {
          'worker_id': item['worker_id'], 'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal', 'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_edit', 'reference_id': transactionId,
          'notes': '${reversesPersonalIrrigation ? 'عكس سقاية العامل' : 'عكس استحقاق العامل'} لإعادة احتساب السقاية رقم $id',
          'created_by': userId,
        });
      }
      final directPartnerRows = await tx.query(
        'partner_transactions',
        where: "reference_type='irrigation' AND reference_id=? AND type='irrigation' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=partner_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in directPartnerRows) {
        await tx.insert('partner_transactions', {
          'partner_id': item['partner_id'], 'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal', 'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_edit', 'reference_id': (item['id'] as num).toInt(),
          'notes': 'عكس سقاية الشريك: خصم سابق من السقاية رقم $id لإعادة احتسابها',
          'created_by': userId,
        });
      }
      final partnerRows = await tx.query(
        'partner_transactions',
        where: "reference_type='irrigation_profit' AND reference_id=? AND type='share_accrual' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=partner_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in partnerRows) {
        final transactionId = (item['id'] as num).toInt();
        final priorAdjustments = await tx.query(
          'partner_transactions',
          where: "reference_type='partner_profit_adjustment' AND reference_id=? AND type='share_adjustment' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='partner_profit_adjustment_cancel' AND rev.reference_id=partner_transactions.id AND rev.type='share_adjustment_reversal')",
          whereArgs: [transactionId],
        );
        for (final adjustment in priorAdjustments) {
          final adjustmentId = (adjustment['id'] as num).toInt();
          await _reverseEntriesTx(tx, referenceType: 'partner_profit_adjustment', referenceId: adjustmentId,
            reason: 'إعادة احتساب السقاية رقم $id', userId: userId);
          await tx.insert('partner_transactions', {
            'partner_id': adjustment['partner_id'], 'date': AppClock.now().toIso8601String(),
            'type': 'share_adjustment_reversal', 'amount': (adjustment['amount'] as num).round(),
            'reference_type': 'partner_profit_adjustment_cancel', 'reference_id': adjustmentId,
            'notes': 'عكس تسوية حصة الشريك بسبب تعديل السقاية رقم $id', 'created_by': userId,
          });
        }
        await _reverseEntriesTx(tx, referenceType: 'partner', referenceId: transactionId,
          reason: 'إعادة احتساب السقاية رقم $id', userId: userId);
        await tx.insert('partner_transactions', {
          'partner_id': item['partner_id'], 'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal', 'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_edit', 'reference_id': transactionId,
          'notes': 'عكس حصة الشريك السابقة من السقاية رقم $id لإعادة احتسابها',
          'created_by': userId,
        });
      }
      await _reverseEntriesTx(
        tx, referenceType: 'irrigation', referenceId: id,
        reason: 'تصحيح بيانات السقاية رقم $id', userId: userId,
      );
      final waterRevenue = await _accountIdTx(tx, '4000');
      final fuelRevenue = await _accountIdTx(tx, '4010');
      final receivable = partyType == 'worker'
          ? await _workerAccountIdTx(tx, workerId!)
          : partyType == 'partner'
              ? await _partnerAccountIdTx(tx, partnerId!)
              : await _accountIdTx(tx, '1200');
      final lines = <Map<String, Object?>>[
        {'account_id': receivable, 'beneficiary_id': beneficiaryId,
         'worker_id': workerId, 'partner_id': partnerId,
         'debit': result.totalAmount, 'credit': 0,
         'memo': partyType == 'beneficiary' ? 'استحقاق سقاية بعد التعديل' : 'خصم سقاية من مستحقات الطرف بعد التعديل'},
      ];
      if (result.waterAmount > 0) {
        lines.add({'account_id': waterRevenue, 'debit': 0,
          'credit': result.waterAmount, 'memo': 'إيراد السقي بعد التعديل'});
      }
      if (result.dieselAmount > 0) {
        lines.add({'account_id': fuelRevenue, 'debit': 0,
          'credit': result.dieselAmount, 'memo': 'قيمة ديزل السقي بعد التعديل'});
      }
      if (result.totalAmount > 0) {
        await _entry(tx,
          description: 'تعديل سقاية رقم $id',
          referenceType: 'irrigation', referenceId: id,
          lines: lines, userId: userId, date: start,
          stationId: (old['station_id'] as num).toInt());
      }
      final now = AppClock.now().toIso8601String();
      final values = <String, Object?>{
        'date': start.toIso8601String().substring(0, 10),
        'start_datetime': start.toIso8601String(),
        'end_datetime': end.toIso8601String(),
        'minutes': result.minutes,
        'cloud_minutes': result.cloudMinutes,
        'chargeable_minutes': result.chargeableMinutes,
        'water_amount': result.waterAmount,
        'diesel_amount': result.dieselAmount,
        'total_amount': result.totalAmount,
        'updated_at': now,
      };
      await tx.update('irrigations', values, where: 'id=?', whereArgs: [id]);

      // Keep detailed cloud intervals aligned with the edited irrigation window.
      for (final period in shiftedCloudPeriods) {
        final periodId = (period['id'] as num).toInt();
        if (period['delete'] == true) {
          await tx.delete('cloud_periods', where: 'id=?', whereArgs: [periodId]);
        } else {
          await tx.update('cloud_periods', {
            'start_datetime': period['start_datetime'],
            'end_datetime': period['end_datetime'],
            'minutes': period['minutes'],
          }, where: 'id=?', whereArgs: [periodId]);
        }
      }

      // Reconcile diesel movements with the newly calculated litres and shortage.
      final oldDieselMoves = await tx.query('diesel_movements',
        where: 'irrigation_id=?', whereArgs: [id], orderBy: 'id');
      if (type == 'diesel' && partyType == 'beneficiary' && result.dieselLiters > 0) {
        final price = (old['diesel_price_snapshot'] as num?)?.toInt() ?? 0;
        final advances = oldDieselMoves.where((m) => '${m['kind']}' == 'advance').toList();
        final consumptions = oldDieselMoves.where((m) => '${m['kind']}' == 'consumption').toList();
        if (shortageLiters > 0) {
          final advanceValues = <String, Object?>{
            'beneficiary_id': beneficiaryId, 'irrigation_id': id, 'kind': 'advance',
            'liters': shortageLiters, 'unit_price': price,
            'amount': AccountingCalculations.roundAmount(shortageLiters * price, rounding),
            'date': start.toIso8601String(), 'created_by': userId,
            'notes': 'سلفة ديزل تلقائية (بعد تعديل السقاية)',
          };
          if (advances.isEmpty) {
            await tx.insert('diesel_movements', advanceValues);
          } else {
            await tx.update('diesel_movements', advanceValues,
              where: 'id=?', whereArgs: [advances.first['id']]);
            for (final extra in advances.skip(1)) {
              await tx.delete('diesel_movements', where: 'id=?', whereArgs: [extra['id']]);
            }
          }
        } else {
          for (final advance in advances) {
            await tx.delete('diesel_movements', where: 'id=?', whereArgs: [advance['id']]);
          }
        }
        final consumptionValues = <String, Object?>{
          'beneficiary_id': beneficiaryId, 'irrigation_id': id, 'kind': 'consumption',
          'liters': result.dieselLiters, 'unit_price': price, 'amount': result.dieselAmount,
          'date': start.toIso8601String(), 'created_by': userId,
          'notes': 'استهلاك السقاية (بعد التعديل)',
        };
        if (consumptions.isEmpty) {
          await tx.insert('diesel_movements', consumptionValues);
        } else {
          await tx.update('diesel_movements', consumptionValues,
            where: 'id=?', whereArgs: [consumptions.first['id']]);
          for (final extra in consumptions.skip(1)) {
            await tx.delete('diesel_movements', where: 'id=?', whereArgs: [extra['id']]);
          }
        }
      } else {
        for (final move in oldDieselMoves) {
          await tx.delete('diesel_movements', where: 'id=?', whereArgs: [move['id']]);
        }
      }
      // Capture the persisted post-recalculation state, not the planning list:
      // this makes deleted/updated/inserted records reviewable from the audit log.
      final newCloudPeriods = await tx.query('cloud_periods',
        where: 'irrigation_id=?', whereArgs: [id], orderBy: 'start_datetime,id');
      final newDieselMoves = await tx.query('diesel_movements',
        where: 'irrigation_id=?', whereArgs: [id], orderBy: 'id');
      Map<int, Map<String, Object?>> indexById(List<Map<String, Object?>> rows) => {
        for (final row in rows)
          if (row['id'] is num) (row['id'] as num).toInt(): row,
      };
      final oldCloudById = indexById(oldCloudPeriods);
      final newCloudById = indexById(newCloudPeriods);
      final oldDieselById = indexById(oldDieselMoves);
      final newDieselById = indexById(newDieselMoves);
      final cloudChanges = <Map<String, Object?>>[
        for (final before in oldCloudPeriods)
          {
            'action': newCloudById.containsKey((before['id'] as num).toInt())
                ? (newCloudById[(before['id'] as num).toInt()].toString() == before.toString()
                    ? 'retained' : 'updated')
                : 'deleted',
            'id': before['id'],
            'old': before,
            if (newCloudById.containsKey((before['id'] as num).toInt()))
              'new': newCloudById[(before['id'] as num).toInt()],
          },
        for (final after in newCloudPeriods)
          if (!oldCloudById.containsKey((after['id'] as num).toInt()))
            {'action': 'inserted', 'id': after['id'], 'new': after},
      ];
      final dieselChanges = <Map<String, Object?>>[
        for (final before in oldDieselMoves)
          {
            'action': newDieselById.containsKey((before['id'] as num).toInt())
                ? (newDieselById[(before['id'] as num).toInt()].toString() == before.toString()
                    ? 'retained' : 'updated')
                : 'deleted',
            'id': before['id'],
            'old': before,
            if (newDieselById.containsKey((before['id'] as num).toInt()))
              'new': newDieselById[(before['id'] as num).toInt()],
          },
        for (final after in newDieselMoves)
          if (!oldDieselById.containsKey((after['id'] as num).toInt()))
            {'action': 'inserted', 'id': after['id'], 'new': after},
      ];
      if (oldCloudPeriods.isNotEmpty || oldDieselMoves.isNotEmpty ||
          newCloudPeriods.isNotEmpty || newDieselMoves.isNotEmpty) {
        await database.auditTx(tx, userId: userId, operation: 'update',
          table: 'irrigation_related_movements', recordId: id,
          oldValues: {
            'cloud_periods': oldCloudPeriods,
            'diesel_movements': oldDieselMoves,
          },
          newValues: {
            'cloud_periods': newCloudPeriods,
            'diesel_movements': newDieselMoves,
            'cloud_period_changes': cloudChanges,
            'diesel_movement_changes': dieselChanges,
            'diesel_liters': result.dieselLiters,
            'diesel_shortage_liters': shortageLiters,
            'diesel_amount': result.dieselAmount,
          },
          reason: 'إعادة احتساب الحركات التابعة للسقاية؛ يتضمن السجل حالة كل حركة (محتفظ بها/معدلة/محذوفة/مضافة) والقيم قبل وبعد');
      }

      // Recreate wage accruals and partner allocations from the edited amount.
      var totalWorkerEntitlement = 0;
      final wageWorkers = await tx.query('workers',
        columns: ['id'],
        where: "station_id=? AND active=1 AND pay_type IN ('hourly', 'percentage')",
        whereArgs: [(old['station_id'] as num).toInt()], orderBy: 'id');
      for (final wageWorker in wageWorkers) {
        totalWorkerEntitlement += await _accrueWorkerIrrigationTx(
          tx, workerId: (wageWorker['id'] as num).toInt(), irrigationId: id,
          amount: result.totalAmount, hours: result.chargeableMinutes / 60.0,
          date: start, userId: userId);
      }
      if (partyType == 'worker') {
        await tx.insert('worker_transactions', {
          'worker_id': workerId, 'date': start.toIso8601String(), 'type': 'irrigation',
          'amount': result.totalAmount, 'reference_type': 'irrigation', 'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب العامل', 'created_by': userId,
        });
      } else if (partyType == 'partner') {
        await tx.insert('partner_transactions', {
          'partner_id': partnerId, 'date': start.toIso8601String(), 'type': 'irrigation',
          'amount': result.totalAmount, 'ownership_snapshot': null,
          'reference_type': 'irrigation', 'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب الشريك', 'created_by': userId,
        });
      }
      final partnerPool = (result.totalAmount - totalWorkerEntitlement).clamp(0, result.totalAmount).toInt();
      if (partnerPool > 0) {
        await _accruePartnersFromIrrigationTx(tx,
          irrigationId: id, stationId: (old['station_id'] as num).toInt(),
          amount: partnerPool, date: start, userId: userId);
      }
      await database.auditTx(tx, userId: userId, operation: 'update',
        table: 'irrigations', recordId: id, oldValues: old,
        newValues: values, reason: 'تعديل وقت السقاية وإعادة ترحيل قيدها');
      return result.totalAmount;
    });
  }

  Future<void> cancelIrrigation(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب إلغاء السقاية مطلوب');
    await database.transaction((tx) async {
      final rows = await tx.query(
        'irrigations',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['status'] == 'cancelled') {
        throw StateError('السقاية غير موجودة أو ملغاة مسبقًا');
      }
      final old = rows.first;
      await _assertPeriodOpen(tx, DateTime.parse('${old['start_datetime']}'));
      await tx.update(
        'irrigations',
        {
          'status': 'cancelled',
          'notes': '${old['notes'] ?? ''}\nإلغاء: $reason',
          'updated_at': AppClock.now().toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      // 1) عكس الدفعات المرتبطة (إن وُجدت). يُسمح برصيد صندوق سالب
      final pays = await tx.query(
        'payments',
        where: "reference_number=? AND status='posted'",
        whereArgs: ['IRR-$id'],
      );
      for (final pay in pays) {
        await _cancelPaymentRowTx(tx, pay, reason: reason, userId: userId);
      }
      // 2) قيود عكسية لباقي قيود السقاية (الاستحقاق، وقيود الدفعات القديمة المربوطة بالسقاية)
      await _reverseEntriesTx(
        tx,
        referenceType: 'irrigation',
        referenceId: id,
        reason: reason,
        userId: userId,
      );
      // 3) حركات الديزل المرتبطة: تُحذف وتُحفظ قيمها في سجل التدقيق
      final moves = await tx.query(
        'diesel_movements',
        where: 'irrigation_id=?',
        whereArgs: [id],
      );
      if (moves.isNotEmpty) {
        await tx.delete(
          'diesel_movements',
          where: 'irrigation_id=?',
          whereArgs: [id],
        );
        await database.auditTx(
          tx,
          userId: userId,
          operation: 'delete',
          table: 'diesel_movements',
          recordId: id,
          oldValues: moves,
          reason: 'إلغاء السقاية: $reason',
        );
      }
      // 4) عكس كل استحقاقات الأطراف المرتبطة بالسقاية (العامل والشركاء).
      // لا نحذف الحركة الأصلية حتى يبقى كشف الحساب قابلاً للتدقيق.
      final workerAccruals = await tx.query(
        'worker_transactions',
        where: "reference_type='irrigation' AND reference_id=? AND type='irrigation'",
        whereArgs: [id],
      );
      for (final item in workerAccruals) {
        await _reverseEntriesTx(
          tx,
          referenceType: 'worker',
          referenceId: (item['id'] as num).toInt(),
          reason: reason,
          userId: userId,
        );
        final originalNotes = '${item['notes'] ?? ''}';
        final reversesPersonalIrrigation = originalNotes.startsWith('خصم قيمة سقاية');
        await tx.insert('worker_transactions', {
          'worker_id': item['worker_id'],
          'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': reversesPersonalIrrigation
              ? 'عكس سقاية العامل من السقاية رقم $id: $reason'
              : 'عكس استحقاق العامل من السقاية رقم $id: $reason',
          'created_by': userId,
        });
      }
      final directPartnerIrrigations = await tx.query(
        'partner_transactions',
        where: "reference_type='irrigation' AND reference_id=? AND type='irrigation'",
        whereArgs: [id],
      );
      for (final item in directPartnerIrrigations) {
        await tx.insert('partner_transactions', {
          'partner_id': item['partner_id'],
          'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': 'عكس سقاية الشريك رقم $id: $reason',
          'created_by': userId,
        });
      }
      final partnerAccruals = await tx.query(
        'partner_transactions',
        where: "reference_type='irrigation_profit' AND reference_id=? AND type='share_accrual'",
        whereArgs: [id],
      );
      for (final item in partnerAccruals) {
        final accrualId = (item['id'] as num).toInt();
        await _reverseEntriesTx(
          tx,
          referenceType: 'partner',
          referenceId: accrualId,
          reason: reason,
          userId: userId,
        );
        // إذا سُوّي فائض هذه الحصة عند توزيع أرباح الفترة، نعكس التسوية أيضًا
        // حتى لا يبقى خصم من حساب الشريك بعد إلغاء السقاية الأصلية.
        final adjustments = await tx.query(
          'partner_transactions',
          where: "reference_type='partner_profit_adjustment' AND reference_id=? AND type='share_adjustment'",
          whereArgs: [accrualId],
        );
        for (final adjustment in adjustments) {
          final adjustmentId = (adjustment['id'] as num).toInt();
          await _reverseEntriesTx(
            tx,
            referenceType: 'partner_profit_adjustment',
            referenceId: adjustmentId,
            reason: 'إلغاء السقاية الأصلية: $reason',
            userId: userId,
          );
          await tx.insert('partner_transactions', {
            'partner_id': item['partner_id'],
            'date': AppClock.now().toIso8601String(),
            'type': 'share_adjustment_reversal',
            'amount': (adjustment['amount'] as num).round(),
            'reference_type': 'partner_profit_adjustment_cancel',
            'reference_id': adjustmentId,
            'notes': 'عكس تسوية حصة الشريك بسبب إلغاء السقاية رقم $id',
            'created_by': userId,
          });
        }
        await tx.insert('partner_transactions', {
          'partner_id': item['partner_id'],
          'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': 'عكس نصيب الشريك من السقاية رقم $id: $reason',
          'created_by': userId,
        });
      }
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'cancel',
        table: 'irrigations',
        recordId: id,
        oldValues: old,
        reason: reason,
      );
    });
  }

  /// يلغي دفعة واحدة داخل معاملة قائمة: يغيّر حالتها، يعدّل رصيد الصندوق (ويُسمح بالسالب)،
  /// يعكس قيدها المحاسبي، ويضيف حركة عكسية لحساب العامل/الشريك.
  Future<void> _cancelPaymentRowTx(
    Transaction tx,
    Map<String, Object?> pay, {
    required String reason,
    int? userId,
  }) async {
    final payId = (pay['id'] as num).toInt();
    // حارس إضافي داخل المعاملة: لا نسمح بعكس الدفعة إذا لم تعد مرحّلة.
    // يمنع تكرار تعديل الصندوق أو إنشاء حركة عكسية للطرف عند استدعاء المساعد
    // من مسار آخر أو تمرير سجل قديم.
    final currentPayment = await tx.query(
      'payments',
      columns: ['status'],
      where: 'id=?',
      whereArgs: [payId],
      limit: 1,
    );
    if (currentPayment.isEmpty || currentPayment.first['status'] != 'posted') {
      throw StateError('الدفعة غير موجودة أو عُكست مسبقًا');
    }
    final amount = (pay['amount'] as num).round();
    final cashboxId = (pay['cashbox_id'] as num).toInt();
    final incoming = pay['beneficiary_id'] != null;
    await tx.update(
      'payments',
      {
        'status': 'cancelled',
        'notes': '${pay['notes'] ?? ''}\nإلغاء: $reason',
      },
      where: 'id=?',
      whereArgs: [payId],
    );
    if (incoming) {
      // عكس القبض يُخرج المبلغ من الصندوق؛ يُسمح بالرصيد السالب حسب سياسة الصراف.
      await tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
        [amount, cashboxId],
      );
    } else {
      await tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
        [amount, cashboxId],
      );
    }
    // القيد: الحديث مرتبط بالدفعة نفسها؛ القديم كان مرتبطًا بالسقاية بنفس وصف القيد.
    var n = await _reverseEntriesTx(
      tx,
      referenceType: 'payment',
      referenceId: payId,
      reason: reason,
      userId: userId,
    );
    final refNo = '${pay['reference_number'] ?? ''}';
    if (n == 0 && refNo.startsWith('IRR-')) {
      final irrId = int.tryParse(refNo.substring(4));
      if (irrId != null) {
        n = await _reverseEntriesTx(
          tx,
          referenceType: 'irrigation',
          referenceId: irrId,
          reason: reason,
          userId: userId,
          descriptionEquals: 'قبض من مستفيد رقم $payId',
        );
      }
    }
    if (refNo.startsWith('IRR-')) {
      final irrId = int.tryParse(refNo.substring(4));
      if (irrId != null) {
        await tx.rawUpdate(
          'UPDATE irrigations SET paid_amount=MAX(paid_amount-?,0) WHERE id=?',
          [amount, irrId],
        );
      }
    }
    final now = AppClock.now().toIso8601String();
    if (pay['worker_id'] != null) {
      await tx.insert('worker_transactions', {
        'worker_id': pay['worker_id'],
        'date': now,
        'type': 'payment_reversal',
        'amount': amount,
        'cashbox_id': cashboxId,
        'reference_type': 'payment_cancel',
        'reference_id': payId,
        'notes': 'إلغاء دفعة رقم $payId: $reason',
        'created_by': userId,
      });
    }
    if (pay['partner_id'] != null) {
      await tx.insert('partner_transactions', {
        'partner_id': pay['partner_id'],
        'date': now,
        'type': 'payment_reversal',
        'amount': amount,
        'reference_type': 'payment_cancel',
        'reference_id': payId,
        'notes': 'إلغاء دفعة رقم $payId: $reason',
        'created_by': userId,
      });
    }
    await database.auditTx(
      tx,
      userId: userId,
      operation: 'cancel',
      table: 'payments',
      recordId: payId,
      oldValues: pay,
      reason: reason,
    );
  }

  /// تعديل سند قبض/صرف بطريقة قابلة للتتبع: يُعكس السند السابق ويُنشأ البديل
  /// داخل المعاملة نفسها؛ عند أي فشل تُلغى العمليتان معًا.
  /// السندات المرتبطة بالسقايات تُعدّل من شاشة السقايات حتى لا ينفصل paid_amount.
  Future<int> replacePayment({
    required int id,
    required int userId,
    required String reason,
    int? beneficiaryId,
    int? partnerId,
    int? workerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    String? referenceNumber,
    String? notes,
  }) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب تعديل السند مطلوب');
    final partyCount = [beneficiaryId, partnerId, workerId]
        .where((value) => value != null).length;
    if (partyCount != 1) throw ArgumentError('يجب تحديد طرف واحد فقط للسند');
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    return database.transaction((tx) async {
      final rows = await tx.query('payments', where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty || rows.first['status'] != 'posted') {
        throw StateError('السند غير موجود أو ملغى مسبقًا');
      }
      final old = rows.first;
      final oldReference = '${old['reference_number'] ?? ''}';
      if (oldReference.startsWith('IRR-')) {
        throw StateError('هذا السند مرتبط بسقاية؛ عدّل السقاية من شاشة فواتير السقايات حتى يبقى رصيدها صحيحًا.');
      }
      await _assertPeriodOpen(tx, DateTime.parse('${old['date']}'));
      await _cancelPaymentRowTx(tx, old,
        reason: 'تعديل السند: ${reason.trim()}', userId: userId);
      final replacementId = await _paymentInTx(
        tx, beneficiaryId: beneficiaryId, partnerId: partnerId, workerId: workerId,
        amount: amount, paymentMethodId: paymentMethodId, cashboxId: cashboxId,
        userId: userId, referenceNumber: referenceNumber, notes: notes,
        sendNotification: false,
        paymentDate: DateTime.parse('${old['date']}'),
      );
      // Keep the party-specific subledgers in sync just as payWorker/payPartner do.
      if (workerId != null) {
        await tx.insert('worker_transactions', {
          'worker_id': workerId,
          'date': DateTime.parse('${old['date']}').toIso8601String(),
          'type': 'payment',
          'amount': amount,
          'cashbox_id': cashboxId,
          'reference_type': 'payment',
          'reference_id': replacementId,
          'notes': notes,
          'created_by': userId,
        });
      }
      if (partnerId != null) {
        await tx.insert('partner_transactions', {
          'partner_id': partnerId,
          'date': DateTime.parse('${old['date']}').toIso8601String(),
          'type': 'payment',
          'amount': amount,
          'reference_type': 'payment',
          'reference_id': replacementId,
          'notes': notes,
          'created_by': userId,
        });
      }
      final replacementRows = await tx.query('payments',
        where: 'id=?', whereArgs: [replacementId], limit: 1);
      await database.auditTx(tx, userId: userId, operation: 'replace',
        table: 'payments', recordId: replacementId,
        oldValues: {'replaced_payment_id': id, 'payment': old},
        newValues: {
          'replacement_payment_id': replacementId,
          'payment': replacementRows.isEmpty ? null : replacementRows.first,
        },
        reason: reason.trim());
      return replacementId;
    });
  }

  /// إلغاء دفعة (قبض من مستفيد أو دفع لعامل/شريك) مع عكس أثرها كاملًا.
  Future<void> cancelPayment(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب إلغاء الدفعة مطلوب');
    await database.transaction((tx) async {
      final r = await tx.query(
        'payments',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (r.isEmpty || r.first['status'] != 'posted') {
        throw StateError('الدفعة غير موجودة أو ملغاة مسبقًا');
      }
      await _assertPeriodOpen(tx, DateTime.parse('${r.first['date']}'));
      await _cancelPaymentRowTx(tx, r.first, reason: reason, userId: userId);
    });
  }

  /// إلغاء حركة ديزل يدوية (شراء/تسليم/سلفة/استهلاك/تصحيح): تُعكس قيودها ويُردّ أثرها على
  /// الصندوق، ثم تُحذف الحركة وتُحفظ قيمها في سجل التدقيق. حركات السقاية لا تُلغى من هنا
  /// بل بإلغاء السقاية نفسها. يُمنع الإلغاء إن كان سيجعل مخزون المحطة سالبًا.
  Future<void> cancelDieselMovement(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الإلغاء مطلوب');
    await database.transaction((tx) async {
      final r = await tx.query(
        'diesel_movements',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (r.isEmpty) throw StateError('حركة الديزل غير موجودة');
      final m = r.first;
      if (m['irrigation_id'] != null) {
        throw StateError('هذه الحركة مرتبطة بسقاية؛ تُلغى بإلغاء السقاية');
      }
      await _assertPeriodOpen(tx, DateTime.parse('${m['date']}'));
      final kind = '${m['kind']}';
      final liters = (m['liters'] as num).toDouble();
      // أثر الحركة على مخزون المحطة، وبعد إلغائها يجب ألا يصبح سالبًا.
      final delta = switch (kind) {
        'receipt' => liters,
        'opening_balance' || 'correction' =>
          m['beneficiary_id'] == null ? liters : 0.0,
        'delivery' || 'consumption' => -liters,
        'advance' => m['irrigation_id'] == null ? -liters : 0.0,
        _ => 0.0,
      };
      final st = await tx.rawQuery(_stationDieselStockSql);
      final stock = (st.first['stock'] as num?)?.toDouble() ?? 0;
      if (delta > 0 && stock - delta < -0.0005) {
        throw StateError('لا يمكن الإلغاء: سيصبح مخزون الديزل سالبًا');
      }
      final refType = switch (kind) {
        'receipt' => 'diesel_receipt',
        'consumption' => 'diesel_consumption',
        'delivery' => 'diesel',
        'advance' => 'diesel_advance',
        'correction' => 'diesel_correction',
        'opening_balance' => 'diesel_opening_balance',
        _ => null,
      };
      if (refType != null) {
        await _reverseEntriesTx(
          tx,
          referenceType: refType,
          referenceId: id,
          reason: reason,
          userId: userId,
        );
      }
      final cb = (m['cashbox_id'] as num?)?.toInt();
      if (kind == 'receipt' && cb != null) {
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
          [(m['amount'] as num).round(), cb],
        );
      }
      await tx.delete('diesel_movements', where: 'id=?', whereArgs: [id]);
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'cancel',
        table: 'diesel_movements',
        recordId: id,
        oldValues: m,
        reason: reason,
      );
    });
  }

  /// تعديل ملاحظات حركة ديزل فقط؛ الكمية والسعر والنوع تُصحَّح بإلغاء الحركة وإعادة إدخالها
  /// حتى لا يتباعد المخزون والقيود عن بعضهما.
  Future<void> updateDieselNotes(int id, String notes, int? userId) async {
    final r = await database.query(
      'SELECT notes FROM diesel_movements WHERE id=?',
      args: [id],
    );
    if (r.isEmpty) throw StateError('حركة الديزل غير موجودة');
    await database.update('diesel_movements', {'notes': notes}, 'id=?', [id]);
    await database.audit(
      userId: userId,
      operation: 'update',
      table: 'diesel_movements',
      recordId: id,
      oldValues: {'notes': r.first['notes']},
      newValues: {'notes': notes},
    );
  }

  /// يقيّد الفرق بين الأرصدة الافتتاحية/المرحَّلة القديمة والجديدة للمستفيد في الأستاذ:
  /// موجب (عليه) = مدين ذمم المستفيدين / دائن 3000 (أو 3100 للمرحَّل)، والسالب بالعكس.
  /// يُستدعى عند الإنشاء (القديم = 0) وعند التعديل، فلا يتغير رصيد المستفيد دون قيد.
  Future<void> postBeneficiaryBalanceDeltaTx(
    Transaction tx,
    int beneficiaryId,
    String name, {
    int oldOpening = 0,
    required int newOpening,
    int oldCarried = 0,
    required int newCarried,
    int? userId,
  }) async {
    final specs = [
      ('beneficiary_opening', newOpening - oldOpening, '3000', 'تعديل رصيد افتتاحي للمستفيد'),
      ('beneficiary_carried', newCarried - oldCarried, '3100', 'تعديل رصيد مرحَّل للمستفيد'),
    ];
    for (final spec in specs) {
      final delta = spec.$2;
      if (delta == 0) continue;
      await _assertPeriodOpen(tx, AppClock.now());
      final ar = await _accountIdTx(tx, '1200');
      final eq = await _accountIdTx(tx, spec.$3);
      final owes = delta > 0;
      final abs = delta.abs();
      await _entry(
        tx,
        description: '${spec.$4} $name',
        referenceType: spec.$1,
        referenceId: beneficiaryId,
        lines: [
          {
            'account_id': ar,
            'beneficiary_id': beneficiaryId,
            'debit': owes ? abs : 0,
            'credit': owes ? 0 : abs,
          },
          {
            'account_id': eq,
            'debit': owes ? 0 : abs,
            'credit': owes ? abs : 0,
          },
        ],
        userId: userId,
      );
    }
  }

  /// جداول النسخة المحمولة (JSON) مرتّبة بحيث تسبق الجداولُ الأمُّ جداولَها التابعة
  /// (تُدرج بهذا الترتيب وتُحذف بعكسه، فلا تنتهك المفاتيح الأجنبية).
  static const List<String> portableTables = [
    'stations',
    'pumps',
    'beneficiaries',
    'partners',
    'workers',
    'queue_entries',
    'booking_requests',
    'irrigation_sessions',
    'irrigations',
    'cloud_periods',
    'diesel_movements',
    'payment_methods',
    'cashboxes',
    'cashbox_transfers',
    'payments',
    'expenses',
    'worker_transactions',
    'partner_transactions',
    'accounts',
    'journal_entries',
    'journal_lines',
    'audit_logs',
    'settings',
    'notifications',
    'backup_records',
    'sync_queue',
    'app_users',
    'cash_reconciliations',
    'period_closures',
    'beneficiary_auth_codes',
    'beneficiary_sessions',
    'notification_templates',
  ];

  /// جداول أُضيفت للنسخة لاحقًا؛ قد لا توجد في ملفات JSON القديمة.
  static const List<String> optionalPortableTables = [
    'cloud_periods',
    'cash_reconciliations',
    'period_closures',
    'beneficiary_auth_codes',
    'beneficiary_sessions',
    'notification_templates',
  ];

  Future<String> exportStateJson() async {
    final d = await database.db;
    final out = <String, dynamic>{
      '_meta': {
        'format_version': 2,
        'exported_at': AppClock.now().toIso8601String(),
      },
    };
    for (final t in portableTables) {
      out[t] = await d.query(t);
    }
    return jsonEncode(out);
  }
}
