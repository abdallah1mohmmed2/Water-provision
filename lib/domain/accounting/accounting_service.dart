import '../../core/app_clock.dart';
import '../../core/app_prefs.dart';
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
    "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements";

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
  };

  Future<int> _entry(
    Transaction tx, {
    required String description,
    required String referenceType,
    int? referenceId,
    required List<Map<String, Object?>> lines,
    int? userId,
    DateTime? date,
  }) async {
    final debit = lines.fold<int>(
      0,
      (s, x) => s + ((x['debit'] as num?)?.round() ?? 0),
    );
    final credit = lines.fold<int>(
      0,
      (s, x) => s + ((x['credit'] as num?)?.round() ?? 0),
    );
    if (debit != credit)
      throw StateError('القيد غير متوازن: المدين $debit / الدائن $credit');
    if (debit < 0 || credit < 0 || lines.isEmpty)
      throw StateError('القيد المحاسبي غير صالح');
    final now = AppClock.now().toIso8601String();
    // تاريخ القيد = تاريخ العملية الفعلي (وليس لحظة الحفظ) حتى لا تُرحَّل
    // الحركات القديمة إلى اليوم ولا يُتجاوز إغلاق الفترة.
    final id = await tx.insert('journal_entries', {
      'date': (date ?? AppClock.now()).toIso8601String(),
      'reference_type': referenceType,
      'reference_id': referenceId,
      'description': description,
      'status': 'posted',
      'created_by': userId,
      'created_at': now,
    });
    for (final line in lines)
      await tx.insert('journal_lines', {...line, 'journal_entry_id': id});
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

  Future<void> _assertPeriodOpen(Transaction tx, DateTime date) async {
    final rows = await tx.rawQuery(
      "SELECT id FROM period_closures WHERE period_start<=? AND period_end>=? LIMIT 1",
      [date.toIso8601String(), date.toIso8601String()],
    );
    if (rows.isNotEmpty)
      throw StateError('الفترة المحاسبية مغلقة ولا يمكن إضافة حركة إليها');
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
      if (reason == null || reason.trim().isEmpty)
        throw StateError('يجب إدخال سبب تجاوز مدة الانتظار');
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
    if (paidAmount > 0 && partyType != 'beneficiary')
      throw ArgumentError('الدفعة المرافقة للسقاية متاحة للمستفيد فقط');
    // الدور والحجز والجلسة تخص المستفيد فقط؛ سقاية عامل/شريك لا يجوز أن تُغلق دور مستفيد.
    if (partyType != 'beneficiary' &&
        (queueId != null || bookingId != null || sessionId != null))
      throw ArgumentError('الربط بالدور أو الحجز أو الجلسة متاح لسقاية المستفيد فقط');
    final set = await settings();
    final configuredPumpId = int.tryParse(set['selected_pump_id'] ?? '');
    if (configuredPumpId == null) throw StateError('لا توجد مضخة محددة في الإعدادات');
    final pumpRows = await database.query(
      'SELECT id,station_id,active FROM pumps WHERE id=? LIMIT 1',
      args: [configuredPumpId],
    );
    if (pumpRows.isEmpty || pumpRows.first['active'] != 1)
      throw StateError('المضخة المحددة في الإعدادات غير موجودة أو غير فعالة');
    if (pumpRows.first['station_id'] != stationId)
      throw StateError('المضخة المحددة لا تتبع المحطة الحالية');
    if (pumpId != configuredPumpId)
      throw StateError('يجب استخدام المضخة المحددة في الإعدادات فقط');

    // نوع المنظومة مركزي: لا نثق بقيمة الشاشة أو المضخة القادمة من الواجهة.
    final effectiveType = set['system_type'] ?? 'diesel';
    const allowedTypes = {'diesel', 'solar', 'equivalent_hybrid'};
    if (!allowedTypes.contains(effectiveType))
      throw StateError('نوع المنظومة في الإعدادات غير صالح');

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
      await _assertPeriodOpen(tx, start);
      if (sessionId != null) {
        final sess = await tx.query(
          'irrigation_sessions',
          columns: ['status', 'beneficiary_id'],
          where: 'id=?',
          whereArgs: [sessionId],
          limit: 1,
        );
        if (sess.isEmpty || sess.first['status'] != 'running')
          throw StateError('الجلسة غير موجودة أو ليست قيد التشغيل');
        if (sess.first['beneficiary_id'] != beneficiaryId)
          throw StateError('الجلسة المختارة تخص مستفيدًا آخر');
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
        if (q.first['beneficiary_id'] != beneficiaryId)
          throw StateError('الدور المختار يخص مستفيدًا آخر');
        if (!['waiting', 'postponed'].contains('${q.first['status']}'))
          throw StateError('الدور المختار لم يعد قائمًا (تمت خدمته أو إلغاؤه)');
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
        if (bk.first['beneficiary_id'] != beneficiaryId)
          throw StateError('الحجز المختار يخص مستفيدًا آخر');
        if (!['new', 'under_review', 'scheduled', 'accepted', 'notified']
            .contains('${bk.first['status']}'))
          throw StateError('الحجز المختار لم يعد قائمًا (مكتمل أو ملغى)');
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
      if (calc.waterAmount > 0)
        lines.add({
          'account_id': waterRevenue,
          'debit': 0,
          'credit': calc.waterAmount,
          'memo': 'إيراد السقي',
        });
      if (chargedDiesel > 0)
        lines.add({
          'account_id': fuelRevenue,
          'debit': 0,
          'credit': chargedDiesel,
          'memo': 'قيمة ديزل السقي',
        });
      await _entry(
        tx,
        description: 'سقاية رقم $id',
        referenceType: 'irrigation',
        referenceId: id,
        lines: lines,
        userId: userId,
        date: start,
      );
      // احتساب أجر كل عامل نشط أجره بالساعة أو بالنسبة تلقائيًا،
      // دون الاعتماد على اختيار عامل في شاشة السقاية أو على نوع صاحب السقاية.
      // كل استحقاق يُسجل مرة واحدة في كشف العامل والأستاذ.
      var totalWorkerEntitlement = 0;
      final wageWorkers = await tx.query(
        'workers',
        columns: ['id'],
        where: "active=1 AND pay_type IN ('hourly', 'percentage')",
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

      // في سقاية الشريك لا نخصم أجر العمال مباشرة من قيمة السقاية
      // عند حساب المبلغ القابل للتوزيع؛ أما في بقية الأنواع فيُخصم مجموع الأجور.
      final partnerPool = partyType == 'partner'
          ? totalCharged
          : (totalCharged - totalWorkerEntitlement).clamp(0, totalCharged);
      if (partnerPool > 0) {
        await _accruePartnersFromIrrigationTx(
          tx,
          irrigationId: id,
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
      if (bookingId != null)
        await tx.update(
          'booking_requests',
          {'status': 'completed', 'reviewed_at': now},
          where: 'id=?',
          whereArgs: [bookingId],
        );
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
  }) async {
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    final now = AppClock.now().toIso8601String();
    await _assertPeriodOpen(tx, AppClock.now());
    // الصندوق تابع للطريقة؛ أي تعارض بينهما يُرفض هنا قبل أي كتابة.
    final src = await resolvePaymentSource(
      tx,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
    );
    paymentMethodId = src['method']!;
    cashboxId = src['cashbox']!;
    final id = await tx.insert('payments', {
      'beneficiary_id': beneficiaryId,
      'partner_id': partnerId,
      'worker_id': workerId,
      'amount': amount,
      'date': now,
      'payment_method_id': paymentMethodId,
      'cashbox_id': cashboxId,
      'reference_number': referenceNumber,
      'notes': notes,
      'status': 'posted',
      'created_by': userId,
    });
    // قبض من مستفيد = دخول نقد (+). دفع لعامل/شريك = خروج نقد (−).
    final isOutgoing = beneficiaryId == null;
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
    if (beneficiaryId != null) {
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
    if (amount <= 0)
      throw ArgumentError('قيمة المصروف يجب أن تكون أكبر من صفر');
    // الصندوق تابع للطريقة المختارة (يُرفض أي تعارض).
    final src = await resolvePaymentSource(
      tx,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
    );
    paymentMethodId = src['method']!;
    cashboxId = src['cashbox']!;
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
    final exp = await _accountIdTx(tx, _expenseAccount(category));
    final cash = await _accountIdTx(tx, await _cashboxLedgerCode(tx, cashboxId));
    await _entry(
      tx,
      description: title,
      referenceType: 'expense',
      referenceId: id,
      lines: [
        {'account_id': exp, 'debit': amount, 'credit': 0},
        {'account_id': cash, 'debit': 0, 'credit': amount},
      ],
      userId: userId,
      date: date,
    );
    return id;
  });

  String _expenseAccount(String category) => switch (category) {
    'workers' => '5000',
    'partners' => '5000',
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
      if (r.isEmpty || r.first['status'] != 'posted')
        throw StateError('المصروف غير قابل للإلغاء');
      await _assertPeriodOpen(tx, AppClock.now());
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
      if (cb != null)
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
          [(r.first['amount'] as num).round(), cb],
        );
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
    if (liters <= 0) throw ArgumentError('كمية الديزل يجب أن تكون أكبر من صفر');
    // قراءة الإعدادات خارج المعاملة لتفادي تعليق sqflite (استعلام على الاتصال أثناء معاملة مفتوحة).
    final financialCredit = await _settingBool(
      'diesel_delivery_financial_credit',
    );
    await database.transaction((tx) async {
      await _assertPeriodOpen(tx, date);
      final amount = (liters * unitPrice).round();
      final stock = await tx.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
      );
      final current = (stock.first['stock'] as num?)?.toDouble() ?? 0;
      if ((kind == 'delivery' || kind == 'consumption') && liters > current)
        throw StateError('كمية الديزل المطلوبة أكبر من المخزون المتاح');
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
      "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
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
    if (amount <= 0)
      throw ArgumentError('قيمة التحويل يجب أن تكون أكبر من صفر');
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
        columns: ['current_balance'],
        where: 'id=?',
        whereArgs: [from],
        limit: 1,
      );
      if (r.isEmpty) throw StateError('صندوق المصدر غير موجود');
      final balance = (r.first['current_balance'] as num?)?.round() ?? 0;
      if (balance < amount) throw StateError('الرصيد غير كافٍ للتحويل');
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
    if (!opening)
      await tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
        [amount, from],
      );
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

  Future<void> _accruePartnersFromIrrigationTx(Transaction tx, {required int irrigationId,
    required int amount, required DateTime date, int? userId}) async {
    final partners = await tx.query('partners', where: 'active=1', orderBy: 'id');
    if (partners.isEmpty || amount <= 0) return;
    final sharePartners = partners.where((p) => '${p['ownership_mode']}' == 'shares').toList();
    final percentagePartners = partners.where((p) => '${p['ownership_mode']}' == 'percentage').toList();
    final totalShares = sharePartners.fold<int>(0, (sum, p) => sum + ((p['shares_count'] as num?)?.round() ?? 0));
    final percentageAmounts = <int, int>{};
    var percentageTotal = 0;
    for (final p in percentagePartners) {
      final value = AccountingCalculations.partnerShare(
        distributable: amount,
        percentage: (p['ownership_percentage'] as num?)?.toDouble() ?? 0,
      );
      percentageAmounts[(p['id'] as num).toInt()] = value;
      percentageTotal += value;
    }
    final sharePool = (amount - percentageTotal).clamp(0, amount);
    var remaining = sharePool;
    var remainingShares = totalShares;
    for (final p in partners) {
      final pid = (p['id'] as num).toInt();
      final mode = '${p['ownership_mode']}';
      final shares = (p['shares_count'] as num?)?.round() ?? 0;
      final int value;
      if (mode == 'percentage') {
        value = percentageAmounts[pid] ?? 0;
      } else if (totalShares <= 0 || shares <= 0) {
        value = 0;
      } else if (remainingShares == shares) {
        value = remaining;
      } else {
        value = (sharePool * shares / totalShares).round().clamp(0, remaining).toInt();
      }
      if (mode == 'shares' && value > 0) {
        remaining -= value;
        remainingShares -= shares;
      }
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
    return database.transaction((tx) async {
      var count = 0; final workers = await tx.query('workers', where: "active=1 AND pay_type='fixed' AND fixed_salary>0");
      for (final w in workers) {
        final wid = w['id'] as int;
        final exists = await tx.rawQuery("SELECT 1 FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id WHERE je.reference_type='worker' AND je.description='راتب العامل الشهري' AND jl.worker_id=? AND je.date>=? AND je.date<? LIMIT 1", [wid, start.toIso8601String(), end.toIso8601String()]);
        if (exists.isNotEmpty) continue;
        final amount = (w['fixed_salary'] as num).round();
        final id = await tx.insert('worker_transactions', {'worker_id': wid, 'date': end.subtract(const Duration(seconds: 1)).toIso8601String(), 'type': 'worker_entitlement', 'amount': amount, 'reference_type': 'monthly_salary', 'reference_id': month.year * 100 + month.month, 'created_by': userId});
        final exp = await _accountIdTx(tx, '5000'), payable = await _workerAccountIdTx(tx, wid);
        await _entry(tx, description: 'راتب العامل الشهري', referenceType: 'worker', referenceId: id, userId: userId, date: end.subtract(const Duration(seconds: 1)), lines: [{'account_id': exp, 'worker_id': wid, 'debit': amount, 'credit': 0}, {'account_id': payable, 'worker_id': wid, 'debit': 0, 'credit': amount}]);
        count++;
      }
      return count;
    });
  }

  Future<int> distributePartnerProfits({required DateTime from, required DateTime to, int? userId}) async {
    return database.transaction((tx) async {
      final rev = await tx.rawQuery("SELECT COALESCE(SUM(CASE WHEN a.type='revenue' THEN jl.credit-jl.debit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.status='posted' AND je.date>=? AND je.date<?", [from.toIso8601String(), to.toIso8601String()]);
      final general = await tx.rawQuery("SELECT COALESCE(SUM(CASE WHEN a.type='expense' AND a.code!='5000' THEN jl.debit-jl.credit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.status='posted' AND je.date>=? AND je.date<?", [from.toIso8601String(), to.toIso8601String()]);
      final worker = await tx.rawQuery("SELECT COALESCE(SUM(CASE WHEN a.code='5000' THEN jl.debit-jl.credit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.status='posted' AND je.date>=? AND je.date<?", [from.toIso8601String(), to.toIso8601String()]);
      final profit = AccountingCalculations.distributableProfit(totalRevenue: (rev.first['n'] as num).round(), generalExpenses: (general.first['n'] as num).round(), workerEntitlements: (worker.first['n'] as num).round());
      // الاستحقاقات المباشرة للشركاء أُنشئت عند تسجيل السقاية، فلا نعيد
      // ترحيلها مرة ثانية عند تشغيل توزيع نهاية الشهر.
      final direct = await tx.rawQuery(
        "SELECT COALESCE(SUM(amount),0) n FROM partner_transactions WHERE reference_type='irrigation_profit' AND date>=? AND date<?",
        [from.toIso8601String(), to.toIso8601String()],
      );
      final remainingProfit = (profit - (direct.first['n'] as num).round()).clamp(0, profit).toInt();
      final distributionRef = from.millisecondsSinceEpoch;
      final already = await tx.query('partner_transactions', where: 'reference_type=? AND reference_id=?', whereArgs: ['profit_distribution', distributionRef], limit: 1);
      if (already.isNotEmpty) throw StateError('تم ترحيل توزيع الأرباح لهذه الفترة مسبقاً');
      final ps = await tx.query('partners', where: 'active=1');
      // Keep share quantities fractional and use double consistently with partnerShareByMode.
      final totalShares = ps.fold<double>(
        0.0,
        (sum, partner) => sum + ((partner['shares_count'] as num?)?.toDouble() ?? 0.0),
      );
      var count = 0;
      for (final p in ps) {
        final amount = AccountingCalculations.partnerShareByMode(
          mode: '${p['ownership_mode']}',
          distributable: remainingProfit,
          partnerShares: (p['shares_count'] as num?)?.toDouble() ?? 0.0,
          totalShares: totalShares,
          percentage: (p['ownership_percentage'] as num?)?.toDouble() ?? 0.0,
        );
        if (amount <= 0) continue;
        final id = await tx.insert('partner_transactions', {'partner_id': p['id'], 'date': to.subtract(const Duration(seconds: 1)).toIso8601String(), 'type': 'share_accrual', 'amount': amount, 'ownership_snapshot': p['ownership_mode']=='percentage' ? p['ownership_percentage'] : p['shares_count'], 'reference_type': 'profit_distribution', 'reference_id': distributionRef, 'created_by': userId});
        final eq = await _accountIdTx(tx, '3200'), payable = await _partnerAccountIdTx(tx, p['id'] as int);
        await _entry(tx, description: 'توزيع صافي الربح للشريك', referenceType: 'partner', referenceId: id, userId: userId, date: to.subtract(const Duration(seconds: 1)), lines: [{'account_id': eq, 'partner_id': p['id'], 'debit': amount, 'credit': 0}, {'account_id': payable, 'partner_id': p['id'], 'debit': 0, 'credit': amount}]); count++;
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
    await _assertPeriodOpen(tx, date);
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
    await _assertPeriodOpen(tx, date);
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
      "SELECT COALESCE(SUM(CASE WHEN jl.credit>0 THEN jl.credit ELSE -jl.debit END),0) balance "
      "FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id "
      "JOIN accounts a ON a.id=jl.account_id "
      "WHERE je.status='posted' AND (a.code=? OR (a.code='2100' AND jl.worker_id=?))",
      args: ['2100.W$id', id],
    );
    final v = (r.first['balance'] as num?)?.round() ?? 0;
    return {'balance': v, 'due': v > 0 ? v : 0, 'credit': v < 0 ? -v : 0};
  }

  Future<Map<String, int>> partnerBalance(int id) async {
    final r = await database.query(
      "SELECT COALESCE(SUM(CASE WHEN jl.credit>0 THEN jl.credit ELSE -jl.debit END),0) balance "
      "FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id "
      "JOIN accounts a ON a.id=jl.account_id "
      "WHERE je.status='posted' AND (a.code=? OR (a.code='2200' AND jl.partner_id=?))",
      args: ['2200.P$id', id],
    );
    final v = (r.first['balance'] as num?)?.round() ?? 0;
    return {'balance': v, 'due': v > 0 ? v : 0, 'credit': v < 0 ? -v : 0};
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
      if (rows.isEmpty || rows.first['status'] == 'cancelled')
        throw StateError('السقاية غير موجودة أو ملغاة مسبقًا');
      final old = rows.first;
      await _assertPeriodOpen(tx, AppClock.now());
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
      // 1) عكس الدفعات المرتبطة (إن وُجدت) مع فحص ألا يصبح الصندوق سالبًا
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
        await tx.insert('worker_transactions', {
          'worker_id': item['worker_id'],
          'date': AppClock.now().toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': 'عكس استحقاق العامل من السقاية رقم $id: $reason',
          'created_by': userId,
        });
      }
      final partnerAccruals = await tx.query(
        'partner_transactions',
        where: "reference_type='irrigation_profit' AND reference_id=? AND type='share_accrual'",
        whereArgs: [id],
      );
      for (final item in partnerAccruals) {
        await _reverseEntriesTx(
          tx,
          referenceType: 'partner',
          referenceId: (item['id'] as num).toInt(),
          reason: reason,
          userId: userId,
        );
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

  /// يلغي دفعة واحدة داخل معاملة قائمة: يغيّر حالتها، يعدّل رصيد الصندوق (مع منع الرصيد السالب
  /// عند عكس قبض)، يعكس قيدها المحاسبي، ويضيف حركة عكسية لحساب العامل/الشريك.
  Future<void> _cancelPaymentRowTx(
    Transaction tx,
    Map<String, Object?> pay, {
    required String reason,
    int? userId,
  }) async {
    final payId = (pay['id'] as num).toInt();
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
      // إلغاء قبض يُخرج المبلغ من الصندوق: يجب ألا يصبح رصيده سالبًا.
      final box = await tx.query(
        'cashboxes',
        columns: ['name', 'current_balance'],
        where: 'id=?',
        whereArgs: [cashboxId],
        limit: 1,
      );
      final bal = box.isEmpty ? 0 : (box.first['current_balance'] as num).round();
      if (bal < amount) {
        throw StateError(
          'لا يمكن الإلغاء: رصيد الصندوق «${box.isEmpty ? cashboxId : box.first['name']}» ($bal) أقل من مبلغ الدفعة ($amount) وسيصبح سالبًا',
        );
      }
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
      await _assertPeriodOpen(tx, AppClock.now());
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
        'receipt' || 'opening_balance' || 'correction' => liters,
        'delivery' || 'consumption' => -liters,
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
    'period_closures',
    'beneficiary_auth_codes',
    'beneficiary_sessions',
    'notification_templates',
  ];

  /// جداول أُضيفت للنسخة لاحقًا؛ قد لا توجد في ملفات JSON القديمة.
  static const List<String> optionalPortableTables = [
    'cloud_periods',
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
