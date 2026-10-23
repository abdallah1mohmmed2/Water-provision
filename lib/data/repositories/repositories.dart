import '../../core/app_clock.dart';
import '../../core/app_prefs.dart';
import 'package:sqflite/sqflite.dart';
import '../local/database.dart';
import '../local/queue_rotation.dart';
import '../../domain/accounting/accounting_service.dart';
import '../../domain/accounting/balance_sql.dart';
import '../../domain/accounting/calculations.dart';

class StationRepository {
  final AppDatabase db;
  late final AccountingService accounting;
  StationRepository([AppDatabase? database])
    : db = database ?? AppDatabase.instance {
    accounting = AccountingService(db);
  }

  // تم التصحيح: استخدام rawQuery بدلاً من query للاستعلامات المباشرة، وحذف args:
  Future<List<Map<String, Object?>>> beneficiaries([String q = '']) => db.rawQuery(
    '''SELECT b.*,
    (${BalanceSql.beneficiary('b')}) balance
    FROM beneficiaries b WHERE b.status='active' AND (b.name LIKE ? OR COALESCE(b.phone,'') LIKE ? OR COALESCE(b.jerba_number,'') LIKE ? OR COALESCE(b.location,'') LIKE ?) ORDER BY b.name''',
    ['%$q%', '%$q%', '%$q%', '%$q%'],
  );

  Future<int> createBeneficiary({
    required String name,
    String? phone,
    String? address,
    String? location,
    String? jerba,
    String? area,
    bool needy = false,
    int opening = 0,
    int carried = 0,
    double openingDiesel = 0,
    String? notes,
    int? userId,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم المستفيد مطلوب');
    final now = AppClock.now().toIso8601String();
    final id = await db.transaction((tx) async {
      final newId = await tx.insert('beneficiaries', {
        'name': name.trim(),
        'phone': phone,
        'address': address,
        'location': location,
        'jerba_number': jerba,
        'area': area,
        'is_needy': needy ? 1 : 0,
        'opening_balance': opening,
        'carried_balance': carried,
        'opening_diesel_liters': openingDiesel,
        'notes': notes,
        'status': 'active',
        'created_at': now,
        'updated_at': now,
      });
      await accounting.postBeneficiaryBalanceDeltaTx(
        tx,
        newId,
        name.trim(),
        newOpening: opening,
        newCarried: carried,
        userId: userId,
      );
      return newId;
    });
    if (openingDiesel > 0) {
      await accounting.addDieselMovement(
        beneficiaryId: id,
        kind: 'opening_balance',
        liters: openingDiesel,
        unitPrice: 0,
        date: AppClock.now(),
        userId: userId,
        notes: 'رصيد ديزل افتتاحي',
      );
    }
    await db.audit(
      userId: userId,
      operation: 'create',
      table: 'beneficiaries',
      recordId: id,
      newValues: {'name': name},
    );
    return id;
  }

  static const Set<String> _beneficiaryEditable = {
    'name',
    'phone',
    'address',
    'location',
    'jerba_number',
    'area',
    'is_needy',
    'notes',
    'opening_balance',
    'carried_balance',
  };

  Future<void> updateBeneficiary(
    int id,
    Map<String, Object?> values,
    int? userId,
  ) async {
    final unknown = values.keys.where((k) => k != 'updated_at' && !_beneficiaryEditable.contains(k));
    if (unknown.isNotEmpty) {
      throw ArgumentError('حقول غير قابلة للتعديل: ${unknown.join('، ')}');
    }
    if (values.containsKey('name') && '${values['name']}'.trim().isEmpty) {
      throw ArgumentError('اسم المستفيد مطلوب');
    }
    final rows = await db.rawQuery('SELECT * FROM beneficiaries WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('المستفيد غير موجود');
    final old = rows.first;
    final newValues = {...values, 'updated_at': AppClock.now().toIso8601String()};
    int asInt(Object? v) => (v as num?)?.round() ?? 0;
    final oldOpening = asInt(old['opening_balance']);
    final oldCarried = asInt(old['carried_balance']);
    final newOpening = values.containsKey('opening_balance') ? asInt(values['opening_balance']) : oldOpening;
    final newCarried = values.containsKey('carried_balance') ? asInt(values['carried_balance']) : oldCarried;
    await db.transaction((tx) async {
      await tx.update('beneficiaries', newValues, where: 'id=?', whereArgs: [id]);
      await accounting.postBeneficiaryBalanceDeltaTx(
        tx,
        id,
        '${newValues['name'] ?? old['name']}',
        oldOpening: oldOpening,
        newOpening: newOpening,
        oldCarried: oldCarried,
        newCarried: newCarried,
        userId: userId,
      );
      await db.auditTx(
        tx,
        userId: userId,
        operation: 'update',
        table: 'beneficiaries',
        recordId: id,
        oldValues: old,
        newValues: newValues,
      );
    });
  }

  Future<void> deleteBeneficiary(int id, int? userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الحذف المنطقي مطلوب');
    final rows = await db.rawQuery('SELECT * FROM beneficiaries WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('المستفيد غير موجود');
    final old = rows.first;
    final bal = (await accounting.beneficiaryBalance(id))['balance'] ?? 0;
    if (bal != 0) {
      throw StateError(
        'لا يمكن حذف مستفيد رصيده ${AccountingCalculations.balanceLabel(bal)}؛ سوِّ الرصيد أولًا ثم احذفه',
      );
    }
    final running = await db.rawQuery(
      "SELECT 1 FROM irrigation_sessions WHERE beneficiary_id=? AND status='running' LIMIT 1",
      [id],
    );
    if (running.isNotEmpty) {
      throw StateError('لا يمكن حذف مستفيد لديه جلسة سقي قيد التشغيل');
    }
    final now = AppClock.now().toIso8601String();
    await db.transaction((tx) async {
      await tx.update(
        'beneficiaries',
        {'status': 'deleted', 'updated_at': now},
        where: 'id=?',
        whereArgs: [id],
      );
      await tx.update(
        'queue_entries',
        {'status': 'cancelled', 'updated_at': now, 'skip_reason': 'حذف المستفيد'},
        where: "beneficiary_id=? AND status IN ('waiting','postponed')",
        whereArgs: [id],
      );
      await tx.update(
        'booking_requests',
        {'status': 'cancelled', 'cancel_reason': 'حذف المستفيد', 'reviewed_at': now},
        where: "beneficiary_id=? AND status IN ('new','under_review','scheduled','accepted','notified')",
        whereArgs: [id],
      );
      await db.auditTx(
        tx,
        userId: userId,
        operation: 'logical_delete',
        table: 'beneficiaries',
        recordId: id,
        oldValues: old,
        reason: reason,
      );
    });
  }

  Future<Map<String, Object?>> beneficiaryDetails(int id) async {
    final b = (await db.rawQuery(
      'SELECT * FROM beneficiaries WHERE id=?',
      [id],
    )).first;
    return {...b, 'balance': await accounting.beneficiaryBalance(id)};
  }

  Future<List<Map<String, Object?>>> beneficiaryStatement(
    int id, {
    DateTime? from,
    DateTime? to,
  }) async {
    final baseRows = await db.rawQuery(
      'SELECT opening_balance,carried_balance FROM beneficiaries WHERE id=?',
      [id],
    );
    if (baseRows.isEmpty) return <Map<String, Object?>>[];
    final opening = (baseRows.first['opening_balance'] as num?)?.round() ?? 0;
    final carried = (baseRows.first['carried_balance'] as num?)?.round() ?? 0;
    var running = opening + carried;
    final creditDelivery =
        (await settings())['diesel_delivery_financial_credit'] == 'true';
    final events = await db.rawQuery(
      "SELECT i.id,i.date,i.start_datetime,i.end_datetime,i.system_type,i.minutes,i.cloud_minutes,i.chargeable_minutes,i.total_amount,i.paid_amount,'s' type,i.total_amount debit,0 credit,i.total_amount lah,0 alayh,'سقاية' description FROM irrigations i WHERE i.beneficiary_id=? AND i.status!='cancelled' "
      "UNION ALL SELECT p.id,p.date,p.date,p.date,'payment',0,0,0,0,-p.amount,'p',0,p.amount,0,p.amount,'دفعة' FROM payments p WHERE p.beneficiary_id=? AND p.status='posted' "
      "UNION ALL SELECT d.id,d.date,d.date,d.date,'diesel_advance',0,0,0,0,0,'a',d.amount,0,d.amount,0,'سلفة ديزل' FROM diesel_movements d WHERE d.beneficiary_id=? AND d.kind='advance' AND d.irrigation_id IS NULL "
      "${creditDelivery ? "UNION ALL SELECT d.id,d.date,d.date,d.date,'diesel_delivery',0,0,0,0,0,'d',0,d.amount,0,d.amount,'تسليم ديزل' FROM diesel_movements d WHERE d.beneficiary_id=? AND d.kind='delivery' " : ''}"
      "ORDER BY date,id",
      [id, id, id, if (creditDelivery) id],
    );
    final result = <Map<String, Object?>>[];
    for (final raw in events) {
      final debit = (raw['debit'] as num?)?.round() ?? 0;
      final credit = (raw['credit'] as num?)?.round() ?? 0;
      running += debit - credit;
      final row = {...raw, 'balance': running};
      final date = DateTime.tryParse('${raw['date'] ?? ''}');
      // Date pickers provide midnight values. Treat both bounds as whole
      // calendar days so movements later on the selected end date are included.
      final fromDay = from == null
          ? null
          : DateTime(from.year, from.month, from.day);
      final toExclusive = to == null
          ? null
          : DateTime(to.year, to.month, to.day).add(const Duration(days: 1));
      if (fromDay != null && (date == null || date.isBefore(fromDay))) continue;
      if (toExclusive != null && (date == null || !date.isBefore(toExclusive))) continue;
      result.add(row);
    }
    // Include explicit opening/carried balance rows in the same statement source
    // used by the detail screen and its PDF export, even when a date filter is set.
    final openingRow = <String, Object?>{
      'id': -1,
      'date': null,
      'type': 'opening_balance',
      'description': 'رصيد افتتاحي',
      'debit': opening > 0 ? opening : 0,
      'credit': opening < 0 ? -opening : 0,
      'lah': opening > 0 ? opening : 0,
      'alayh': opening < 0 ? -opening : 0,
      'balance': opening,
    };
    final carriedRow = <String, Object?>{
      'id': -2,
      'date': null,
      'type': 'carried_balance',
      'description': 'رصيد مرحّل',
      'debit': carried > 0 ? carried : 0,
      'credit': carried < 0 ? -carried : 0,
      'lah': carried > 0 ? carried : 0,
      'alayh': carried < 0 ? -carried : 0,
      'balance': opening + carried,
    };
    if (opening != 0) result.insert(0, openingRow);
    if (carried != 0) result.insert(opening != 0 ? 1 : 0, carriedRow);
    return result;
  }

  Future<List<Map<String, Object?>>> wateringTotals({
    DateTime? from,
    DateTime? to,
    int? beneficiaryId,
    String? systemType,
  }) async {
    final currentType = (await settings())['system_type'] ?? 'diesel';
    systemType = currentType;
    final args = <Object?>[];
    var w = "i.status!='cancelled'";
    if (from != null) {
      w += ' AND i.start_datetime>=?';
      args.add(from.toIso8601String());
    }
    if (to != null) {
      w += ' AND i.start_datetime<=?';
      args.add(to.toIso8601String());
    }
    if (beneficiaryId != null) {
      w += ' AND i.beneficiary_id=?';
      args.add(beneficiaryId);
    }
    if (systemType != 'all') {
      w += ' AND i.system_type=?';
      args.add(systemType);
    }
    return db.rawQuery(
      "SELECT substr(i.date,1,10) day,substr(i.date,1,7) month,substr(i.date,1,4) year,COALESCE(SUM(i.minutes),0) minutes,ROUND(COALESCE(SUM(i.minutes),0)/60.0,2) hours,COUNT(*) sessions,COALESCE(SUM(i.total_amount),0) total FROM irrigations i WHERE $w GROUP BY day,month,year ORDER BY day DESC",
      args,
    );
  }

  // تم التصحيح: استبدال args بـ whereArgs في دالة query النظامية
  Future<List<Map<String, Object?>>> cloudPeriods(int irrigationId) async =>
      db.query('cloud_periods', where: 'irrigation_id=?', whereArgs: [irrigationId], orderBy: 'start_datetime');

  Future<List<Map<String, Object?>>> irrigations({
    DateTime? from,
    DateTime? to,
    String? systemType,
    int? beneficiaryId,
  }) async {
    final currentType = (await settings())['system_type'] ?? 'diesel';
    systemType = currentType;
    final args = <Object?>[];
    var w = "i.status!='cancelled'";
    if (from != null) {
      w += ' AND i.start_datetime>=?';
      args.add(from.toIso8601String());
    }
    if (to != null) {
      w += ' AND i.start_datetime<=?';
      args.add(to.toIso8601String());
    }
    {
      w += ' AND i.system_type=?';
      args.add(systemType);
    }
    if (beneficiaryId != null) {
      w += ' AND i.beneficiary_id=?';
      args.add(beneficiaryId);
    }
    return db.rawQuery(
      'SELECT i.*,COALESCE(b.name,w.name,pt.name) beneficiary_name,p.name pump_name FROM irrigations i LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id LEFT JOIN workers w ON w.id=i.worker_id LEFT JOIN partners pt ON pt.id=i.partner_id JOIN pumps p ON p.id=i.pump_id WHERE $w ORDER BY i.start_datetime DESC',
      args,
    );
  }

  Future<List<Map<String, Object?>>> queue() => db.rawQuery(
    "SELECT q.*,b.name beneficiary_name,b.phone FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE q.status IN ('waiting','postponed') ORDER BY q.position,q.cycle_number,q.created_at",
  );

  Future<int> enqueue(int beneficiaryId, {int? position, int? userId}) async {
    final rows = await db.rawQuery(
      "SELECT COALESCE(MAX(position),0)+1 n FROM queue_entries WHERE status IN ('waiting','postponed')",
    );
    final pos = position ?? ((rows.first['n'] as num?)?.toInt() ?? 1);
    final now = AppClock.now().toIso8601String();
    final id = await db.insert('queue_entries', {
      'beneficiary_id': beneficiaryId,
      'position': pos,
      'cycle_number': 1,
      'status': 'waiting',
      'created_at': now,
      'updated_at': now,
    });
    await db.audit(
      userId: userId,
      operation: 'enqueue',
      table: 'queue_entries',
      recordId: id,
      newValues: {'beneficiary_id': beneficiaryId, 'position': pos},
    );
    return id;
  }

  Future<void> postponeQueue(int id, String reason, {int? userId}) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب التأجيل مطلوب');
    var policy = (await settings())['absence_policy'] ?? 'keep_order';
    if (policy == 'keep') policy = 'keep_order';
    if (!const {'postpone', 'keep_order', 'cancel'}.contains(policy)) policy = 'keep_order';
    await db.transaction((tx) async {
      final rows = await tx.query(
        'queue_entries',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الدور غير موجود');
      final q = rows.first;
      if (!const {'waiting', 'postponed'}.contains('${q['status']}')) {
        throw StateError('لا يمكن تأجيل دور حالته ليست «منتظر» أو «مؤجل»');
      }
      final now = AppClock.now().toIso8601String();
      final count = ((q['postponed_count'] as num?)?.toInt() ?? 0) + 1;
      if (policy == 'postpone') {
        final max =
            (await tx.rawQuery(
                  "SELECT COALESCE(MAX(position),0)+1 n FROM queue_entries WHERE status IN ('waiting','postponed') AND id<>?",
                  [id],
                )).first['n']
                as num;
        await tx.update(
          'queue_entries',
          {
            'status': 'postponed',
            'position': max.toInt(),
            'postponed_count': count,
            'skip_reason': reason,
            'updated_at': now,
          },
          where: 'id=?',
          whereArgs: [id],
        );
      } else if (policy == 'cancel') {
        await tx.update(
          'queue_entries',
          {
            'status': 'cancelled',
            'postponed_count': count,
            'skip_reason': reason,
            'updated_at': now,
          },
          where: 'id=?',
          whereArgs: [id],
        );
      } else {
        await tx.update(
          'queue_entries',
          {'postponed_count': count, 'skip_reason': reason, 'updated_at': now},
          where: 'id=?',
          whereArgs: [id],
        );
      }
      await db.auditTx(
        tx,
        userId: userId,
        operation: 'postpone:$policy',
        table: 'queue_entries',
        recordId: id,
        oldValues: q,
        reason: reason,
      );
    });
  }

  Future<void> serveSpecific(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب تجاوز الدور مطلوب');
    await db.update(
      'queue_entries',
      {
        'position': 0,
        'status': 'waiting',
        'skip_reason': reason,
        'updated_at': AppClock.now().toIso8601String(),
      },
      'id=?',
      [id],
    );
    await db.audit(
      userId: userId,
      operation: 'queue_override',
      table: 'queue_entries',
      recordId: id,
      reason: reason,
    );
  }

  Future<void> completeQueue(int id, {int? userId}) async {
    final old = (await db.rawQuery(
      'SELECT * FROM queue_entries WHERE id=?',
      [id],
    )).first;
    final circular = ((await settings())['queue_type'] ?? 'circular') == 'circular';
    if (circular) {
      await rotateCircularQueue(id);
    } else {
      await db.transaction(
        (tx) => completeQueueEntryTx(
          tx,
          id,
          AppClock.now().toIso8601String(),
          circular: false,
        ),
      );
    }
    await db.audit(
      userId: userId,
      operation: 'serve',
      table: 'queue_entries',
      recordId: id,
      oldValues: old,
    );
  }

  Future<void> rotateCircularQueue(int servedId) => db.transaction(
    (tx) => completeQueueEntryTx(
      tx,
      servedId,
      AppClock.now().toIso8601String(),
      circular: true,
    ),
  );

  Future<List<Map<String, Object?>>> bookings([String? status]) => db.rawQuery(
    "SELECT br.*,b.name beneficiary_name,b.phone FROM booking_requests br JOIN beneficiaries b ON b.id=br.beneficiary_id ${status == null ? '' : 'WHERE br.status=?'} ORDER BY br.created_at",
    status == null ? [] : [status],
  );

  Future<int> createBooking(
    int beneficiaryId,
    String notes, {
    int? userId,
  }) async {
    final now = AppClock.now().toIso8601String();
    final id = await db.insert('booking_requests', {
      'beneficiary_id': beneficiaryId,
      'created_at': now,
      'status': 'new',
      'notes': notes,
    });
    await db.audit(
      userId: userId,
      operation: 'booking_create',
      table: 'booking_requests',
      recordId: id,
      newValues: {'beneficiary_id': beneficiaryId, 'notes': notes},
    );
    return id;
  }

  Future<void> reviewBooking(
    int id, {
    required String status,
    DateTime? start,
    DateTime? end,
    int? reviewer,
    String? reason,
  }) async {
    final rows = await db.rawQuery(
      'SELECT * FROM booking_requests WHERE id=?',
      [id],
    );
    if (rows.isEmpty) throw StateError('الحجز غير موجود');
    final old = rows.first;
    if (const {'completed', 'cancelled'}.contains('${old['status']}')) {
      throw StateError('لا يمكن تعديل حجز ${old['status'] == 'completed' ? 'مكتمل' : 'ملغى'}');
    }
    if (status == 'cancelled' && (reason ?? '').trim().isEmpty) {
      throw ArgumentError('سبب إلغاء الحجز مطلوب');
    }
    await db.update(
      'booking_requests',
      {
        'status': status,
        'scheduled_date': start?.toIso8601String().substring(0, 10),
        'scheduled_start': start?.toIso8601String(),
        'scheduled_end': end?.toIso8601String(),
        'reviewed_by': reviewer,
        'reviewed_at': AppClock.now().toIso8601String(),
        'cancel_reason': reason,
      },
      'id=?',
      [id],
    );
    await db.audit(
      userId: reviewer,
      operation: 'booking_update',
      table: 'booking_requests',
      recordId: id,
      oldValues: old,
      newValues: {
        'status': status,
        'scheduled_start': start?.toIso8601String(),
        'scheduled_end': end?.toIso8601String(),
      },
      reason: reason,
    );
    if ((status == 'scheduled' || status == 'accepted') &&
        old['beneficiary_id'] != null) {
      final dateText = start == null
          ? 'سيتم تحديد الموعد لاحقًا'
          : '${start.year}/${start.month.toString().padLeft(2, '0')}/${start.day.toString().padLeft(2, '0')} ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
      await notify(
        beneficiaryId: old['beneficiary_id'] as int,
        type: 'appointment',
        title: 'موعد السقي',
        body: 'تم تحديد موعد السقي: $dateText',
      );
    }
  }

  Future<void> updateBookingNotes(int id, String notes, {int? userId}) async {
    final rows = await db.rawQuery('SELECT * FROM booking_requests WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('الحجز غير موجود');
    if (const {'completed', 'cancelled'}.contains('${rows.first['status']}')) {
      throw StateError('لا يمكن تعديل حجز مكتمل أو ملغى');
    }
    await db.update('booking_requests', {'notes': notes}, 'id=?', [id]);
    await db.audit(
      userId: userId,
      operation: 'booking_update',
      table: 'booking_requests',
      recordId: id,
      oldValues: {'notes': rows.first['notes']},
      newValues: {'notes': notes},
    );
  }

  Future<List<Map<String, Object?>>> sessions() => db.rawQuery(
    'SELECT s.*,b.name beneficiary_name,p.name pump_name FROM irrigation_sessions s JOIN beneficiaries b ON b.id=s.beneficiary_id JOIN pumps p ON p.id=s.pump_id ORDER BY COALESCE(s.actual_start,s.planned_start) DESC',
  );

  Future<int> startSession({
    required int beneficiaryId,
    required int pumpId,
    int? queueId,
    int? bookingId,
  }) async {
    final set = await settings();
    final configuredPumpId = int.tryParse(set['selected_pump_id'] ?? '');
    if (configuredPumpId == null || configuredPumpId != pumpId) {
      throw StateError('يجب استخدام المضخة المحددة في الإعدادات فقط');
    }
    final active = await db.rawQuery(
      "SELECT id FROM irrigation_sessions WHERE pump_id=? AND status='running' LIMIT 1",
      [pumpId],
    );
    if (active.isNotEmpty) throw StateError('المضخة لديها جلسة سقي فعالة');
    if ((set['queue_type'] ?? 'circular') == 'booking') {
      if (bookingId == null) {
        throw StateError('لا يمكن بدء جلسة عشوائية في وضع الحجز');
      }
      final booking = await db.rawQuery(
        "SELECT * FROM booking_requests WHERE id=? AND beneficiary_id=?",
        [bookingId, beneficiaryId],
      );
      if (booking.isEmpty ||
          ![
            'scheduled',
            'accepted',
            'notified',
          ].contains('${booking.first['status']}')) {
        throw StateError('الحجز غير مجدول أو لا يخص المستفيد المحدد');
      }
    }
    if (queueId != null) {
      final q = await db.rawQuery(
        "SELECT * FROM queue_entries WHERE id=? AND beneficiary_id=? AND status IN ('waiting', 'postponed')",
        [queueId, beneficiaryId],
      );
      if (q.isEmpty) throw StateError('دور الطابور غير صالح للمستفيد المحدد');
    }
    final now = AppClock.now().toIso8601String();
    final stock = set['system_type'] == 'diesel' ? await accounting.dieselStock() : 0.0;
    return db.insert('irrigation_sessions', {
      'beneficiary_id': beneficiaryId,
      'queue_entry_id': queueId,
      'booking_id': bookingId,
      'pump_id': pumpId,
      'planned_start': now,
      'actual_start': now,
      'timer_started_at': now,
      'status': 'running',
      'diesel_before': stock,
    });
  }

  Future<int> stopSession(
    int sessionId, {
    int cloudMinutes = 0,
    int? operatorWorkerId,
    int? userId,
  }) async {
    final s = (await db.rawQuery(
      'SELECT * FROM irrigation_sessions WHERE id=?',
      [sessionId],
    )).first;
    if (s['status'] != 'running') throw StateError('الجلسة ليست قيد التشغيل');
    final end = AppClock.now();
    final pumpId = s['pump_id'] as int;
    final p = (await db.rawQuery(
      'SELECT * FROM pumps WHERE id=?',
      [pumpId],
    )).first;
    final set = await settings();
    final beneficiaryId = s['beneficiary_id'] as int;
    final previousBalance = (await accounting.beneficiaryBalance(beneficiaryId))['balance'] ?? 0;
    final id = await accounting.recordIrrigation(
      stationId: p['station_id'] as int,
      pumpId: pumpId,
      beneficiaryId: s['beneficiary_id'] as int,
      operatorWorkerId: operatorWorkerId,
      start: DateTime.parse(s['actual_start'] as String),
      end: end,
      systemType: set['system_type'] ?? 'diesel',
      waterRate: int.tryParse(set['diesel_hourly_water_rate'] ?? '0') ?? 0,
      litersPerHour: double.tryParse(set['diesel_liters_per_hour'] ?? '0') ?? 0,
      dieselPrice: int.tryParse(set['diesel_price_per_liter'] ?? '0') ?? 0,
      solarRate: int.tryParse(set['solar_hourly_rate'] ?? '0') ?? 0,
      thirdRate: int.tryParse(set['third_type_hourly_rate'] ?? '0') ?? 0,
      cloudMinutes: cloudMinutes,
      paidAmount: 0,
      queueId: s['queue_entry_id'] as int?,
      bookingId: s['booking_id'] as int?,
      sessionId: sessionId,
      userId: userId,
    );

    // أرسل إشعارًا ماليًا كاملًا بعد نجاح حفظ السقاية وتحديث الأستاذ.
    try {
      final irrigationRows = await db.rawQuery(
        'SELECT i.*,b.name beneficiary_name,p.name pump_name FROM irrigations i '
        'LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id '
        'LEFT JOIN pumps p ON p.id=i.pump_id WHERE i.id=?',
        [id],
      );
      final row = irrigationRows.isEmpty ? <String, Object?>{} : irrigationRows.first;
      final currentBalance = (await accounting.beneficiaryBalance(beneficiaryId))['balance'] ?? 0;
      String balanceText(int value) => value > 0
          ? 'عليه $value ريال'
          : value < 0
              ? 'له ${value.abs()} ريال'
              : 'متوازن (0 ريال)';
      String timeText(Object? value) {
        final raw = '${value ?? ''}'.replaceFirst('T', ' ');
        return raw.length >= 16 ? raw.substring(0, 16) : raw;
      }
      final system = switch ('${row['system_type'] ?? set['system_type'] ?? ''}') {
        'diesel' => 'ديزل',
        'solar' => 'شمسي',
        'equivalent_hybrid' => 'النوع الثالث',
        _ => 'غير محدد',
      };
      final startText = timeText(row['start_datetime'] ?? s['actual_start']);
      final endText = timeText(row['end_datetime'] ?? end.toIso8601String());
      final minutes = (row['minutes'] as num?)?.round() ?? 0;
      final cloud = (row['cloud_minutes'] as num?)?.round() ?? 0;
      final water = (row['water_amount'] as num?)?.round() ?? 0;
      final diesel = (row['diesel_amount'] as num?)?.round() ?? 0;
      final total = (row['total_amount'] as num?)?.round() ?? 0;
      final paid = (row['paid_amount'] as num?)?.round() ?? 0;
      await notify(
        beneficiaryId: beneficiaryId,
        type: 'irrigation',
        title: 'تفاصيل السقاية والرصيد',
        body: [
          'المستفيد: ${row['beneficiary_name'] ?? 'غير محدد'}',
          'المضخة: ${row['pump_name'] ?? p['name'] ?? 'غير محددة'}',
          'نوع المنظومة: $system',
          'وقت السقاية: $startText إلى $endText',
          'مدة السقاية: $minutes دقيقة (خصم الغيم: $cloud دقيقة)',
          'قيمة المياه: $water ريال',
          if (system == 'ديزل') 'قيمة الديزل المحتسبة: $diesel ريال',
          'الرصيد السابق: ${balanceText(previousBalance)}',
          'قيمة السقاية الحالية: $total ريال',
          'المدفوع: $paid ريال',
          'الرصيد بعد السقاية: ${balanceText(currentBalance)}',
        ].join('\n'),
      );
    } catch (_) {
      // لا نُظهر فشل إيقاف السقاية بعد أن تكون العملية المالية قد حُفظت بالفعل.
    }
    return id;
  }

  Future<void> postponeSession(
    int sessionId,
    String reason, {
    int? userId,
  }) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب تأجيل الجلسة مطلوب');
    final cur = await db.rawQuery(
      'SELECT status FROM irrigation_sessions WHERE id=?',
      [sessionId],
    );
    if (cur.isEmpty) throw StateError('الجلسة غير موجودة');
    if (cur.first['status'] != 'running') {
      throw StateError('لا يمكن تأجيل جلسة حالتها ليست «قيد التشغيل»');
    }
    await db.update(
      'irrigation_sessions',
      {'status': 'postponed', 'postponement_reason': reason},
      'id=?',
      [sessionId],
    );
    await db.audit(
      userId: userId,
      operation: 'session_postpone',
      table: 'irrigation_sessions',
      recordId: sessionId,
      reason: reason,
    );
  }

  Future<Map<String, Object?>> dieselWarning() async {
    final set = await settings();
    final warning =
        double.tryParse(set['diesel_warning_percent'] ?? '20') ?? 20;
    final r = await db.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
    );
    final stock = (r.first['stock'] as num?)?.toDouble() ?? 0;
    final capacity =
        double.tryParse(set['diesel_tank_capacity_liters'] ?? '0') ?? 0;
    final percent = capacity > 0 ? stock / capacity * 100 : 100;
    return {
      'stock': stock,
      'capacity': capacity,
      'percent': percent,
      'warning': capacity > 0 && percent <= warning,
      'snoozed_until': set['diesel_warning_snoozed_until'],
    };
  }

  Future<double> dieselStock() => accounting.dieselStock();
  Future<List<Map<String, Object?>>> diesel() => db.rawQuery(
    'SELECT dm.*,b.name beneficiary_name FROM diesel_movements dm LEFT JOIN beneficiaries b ON b.id=dm.beneficiary_id ORDER BY dm.date DESC',
  );
  Future<List<Map<String, Object?>>> payments() => db.rawQuery(
    'SELECT p.*,COALESCE(b.name,COALESCE(w.name,pt.name)) party_name,pm.name method_name,c.name cashbox_name FROM payments p LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id LEFT JOIN workers w ON w.id=p.worker_id LEFT JOIN partners pt ON pt.id=p.partner_id JOIN payment_methods pm ON pm.id=p.payment_method_id JOIN cashboxes c ON c.id=p.cashbox_id ORDER BY p.date DESC',
  );
  Future<List<Map<String, Object?>>> expenses() =>
      db.rawQuery('SELECT * FROM expenses ORDER BY date DESC');
  
  Future<List<Map<String, Object?>>> expenseDetails({DateTime? from, DateTime? to, String? category, String? status}) async {
    final args=<Object?>[];var w='1=1';
    if(from!=null){w+=' AND e.date>=?';args.add(from.toIso8601String());}
    if(to!=null){w+=' AND e.date<?';args.add(to.add(const Duration(days:1)).toIso8601String());}
    if(category!=null){w+=' AND e.category=?';args.add(category);}
    if(status!=null){w+=' AND e.status=?';args.add(status);}
    return db.rawQuery('SELECT e.*,pm.name method_name,c.name cashbox_name FROM expenses e LEFT JOIN payment_methods pm ON pm.id=e.payment_method_id LEFT JOIN cashboxes c ON c.id=e.cashbox_id WHERE $w ORDER BY e.date DESC,e.id DESC',args);
  }
  
  Future<List<Map<String, Object?>>> workers() => db.rawQuery(
    "SELECT w.*, ${BalanceSql.workerPersonal('w')} balance FROM workers w WHERE w.active=1 ORDER BY w.name",
  );

  // تم التصحيح: إزالة args:
  Future<Map<String, Object?>> partyFinancialSummary(String kind, int id) async {
    if (kind == 'beneficiary') {
      final rows = await db.rawQuery('''
        SELECT
          COALESCE((SELECT SUM(i.minutes) FROM irrigations i
            WHERE i.beneficiary_id=? AND i.status!='cancelled'),0) irrigation_minutes,
          COALESCE((SELECT SUM(i.total_amount) FROM irrigations i
            WHERE i.beneficiary_id=? AND i.status!='cancelled'),0) irrigation_total,
          0 earnings,
          COALESCE((SELECT SUM(p.amount) FROM payments p
            WHERE p.beneficiary_id=? AND p.status='posted'),0) paid,
          (${BalanceSql.beneficiary('b')}) balance
        FROM beneficiaries b WHERE b.id=?
      ''', [id, id, id, id]);
      if (rows.isEmpty) {
        return {'irrigation_minutes': 0, 'irrigation_total': 0, 'earnings': 0, 'paid': 0, 'balance': 0};
      }
      return rows.first;
    }
    final isWorker = kind == 'worker';
    if (!isWorker && kind != 'partner') throw ArgumentError('نوع الطرف غير مدعوم: $kind');
    final table = isWorker ? 'workers' : 'partners';
    final idColumn = isWorker ? 'i.worker_id' : 'i.partner_id';
    final earningTypes = isWorker ? "('worker','worker_entitlement')" : "('partner','share_accrual')";
    final personalAccountWhere = isWorker
        ? "(a.code='2100.W'||x.id OR (a.code='2100' AND jl.worker_id=x.id))"
        : "(a.code='2200.P'||x.id OR (a.code='2200' AND jl.partner_id=x.id))";
    final rows = await db.rawQuery('''
      SELECT
        COALESCE((SELECT SUM(i.minutes) FROM irrigations i WHERE $idColumn=? AND i.status!='cancelled'),0) irrigation_minutes,
        COALESCE((SELECT SUM(i.total_amount) FROM irrigations i WHERE $idColumn=? AND i.status!='cancelled'),0) irrigation_total,
        COALESCE((SELECT SUM(CASE WHEN jl.credit>0 THEN jl.credit ELSE 0 END)
          FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id
          WHERE $personalAccountWhere AND je.status='posted' AND je.reference_type IN $earningTypes),0) earnings,
        COALESCE((SELECT SUM(CASE WHEN jl.debit>0 THEN jl.debit ELSE 0 END)
          FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id
          WHERE $personalAccountWhere AND je.status='posted' AND je.reference_type='payment'),0) paid,
        COALESCE((SELECT SUM(jl.credit-jl.debit)
          FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id
          WHERE $personalAccountWhere AND je.status='posted'),0) balance
      FROM $table x WHERE x.id=?
    ''', [id, id, id]);
    if (rows.isEmpty) return {'irrigation_minutes': 0, 'irrigation_total': 0, 'earnings': 0, 'paid': 0, 'balance': 0};
    return rows.first;
  }

  // تم التصحيح: استخدام rawQuery وحذف args:
  Future<List<Map<String, Object?>>> partyIrrigations(String kind, int id) async {
    final where = switch (kind) {
      'worker' => 'i.worker_id=?',
      'partner' => 'i.partner_id=?',
      _ => 'i.beneficiary_id=?',
    };
    return db.rawQuery('''
      SELECT i.id,i.date,i.start_datetime,i.end_datetime,i.minutes,i.cloud_minutes,
             i.chargeable_minutes,i.total_amount,i.paid_amount,i.system_type,
             COALESCE(b.name,w.name,p.name) party_name,
             COALESCE(i.notes,'') notes
      FROM irrigations i
      LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id
      LEFT JOIN workers w ON w.id=i.worker_id
      LEFT JOIN partners p ON p.id=i.partner_id
      WHERE $where AND i.status!='cancelled'
      ORDER BY i.start_datetime DESC''', [id]);
  }

  Future<List<Map<String, Object?>>> workerTransactions(int id) => _ledgerPartyTransactions(accountCode: '2100.W$id', partyColumn: null, id: id, legacyAccountCode: '2100');
  Future<List<Map<String, Object?>>> partnerTransactions(int id) => _ledgerPartyTransactions(accountCode: '2200.P$id', partyColumn: null, id: id, legacyAccountCode: '2200', legacyPartyColumn: 'partner_id');

  Future<List<Map<String, Object?>>> _ledgerPartyTransactions({required String accountCode, required String? partyColumn, required int id, String? legacyAccountCode, String? legacyPartyColumn}) async {
    final partyFilter = partyColumn == null
        ? "(a.code=? OR (a.code=? AND jl.${legacyPartyColumn ?? 'worker_id'}=?))"
        : "a.code=? AND jl.$partyColumn=?";
    final args = partyColumn == null ? [accountCode, legacyAccountCode, id] : [accountCode, id];
    final rows = await db.rawQuery('''
      SELECT je.id journal_entry_id,je.date,je.description,je.reference_type,je.reference_id,jl.debit,jl.credit,jl.memo
      FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id
      WHERE $partyFilter AND je.status='posted' ORDER BY je.date ASC,je.id ASC,jl.id ASC''', args);
    var running=0; final out=<Map<String,Object?>>[];
    for (final row in rows) {
      final debit=(row['debit'] as num?)?.round() ?? 0, credit=(row['credit'] as num?)?.round() ?? 0, signed=credit-debit;
      running += signed; final ref='${row['reference_type']}';
      final type=switch(ref){'payment'=>'payment','worker'=>'accrual','partner'=>'share_accrual','worker_opening'||'partner_opening'=>'opening_balance',_=>ref};
      out.add({...row,'type':type,'amount':signed.abs(),'signed_amount':signed,'description':row['memo'] ?? row['description'],'balance':running,'lah':signed>0?signed:0,'alayh':signed<0?-signed:0});
    }
    return out.reversed.toList();
  }

  Future<int> createWorker({
    required String name,
    required String payType,
    int fixedSalary = 0,
    int hourlyRate = 0,
    double percentageRate = 0,
    String? phone,
    String? title,
    int opening = 0,
    int? userId,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم العامل مطلوب');
    final stationId = await accounting.currentStationId();
    final id = await db.transaction((tx) async {
      final newId = await tx.insert('workers', {
        'station_id': stationId,
        'name': name.trim(),
        'phone': phone,
        'job_title': title,
        'pay_type': payType,
        'fixed_salary': fixedSalary,
        'hourly_rate': hourlyRate,
        'percentage_rate': percentageRate,
        'opening_balance': opening,
        'active': 1,
      });
      await accounting.postPartyOpeningTx(
        tx,
        kind: 'worker',
        id: newId,
        name: name.trim(),
        amount: opening,
        userId: userId,
      );
      return newId;
    });
    await db.audit(
      userId: userId,
      operation: 'create',
      table: 'workers',
      recordId: id,
      newValues: {'name': name, 'pay_type': payType},
    );
    return id;
  }

  static const Set<String> _workerEditable = {
    'name', 'phone', 'job_title', 'pay_type', 'fixed_salary', 'hourly_rate',
    'percentage_rate', 'notes',
  };
  static const Set<String> _partnerEditable = {
    'name', 'phone', 'ownership_mode', 'shares_count', 'ownership_percentage',
    'notes',
  };

  Future<void> updateWorker(int id, Map<String,Object?> values, int? userId) async {
    final unknown = values.keys.where((k) => !_workerEditable.contains(k));
    if (unknown.isNotEmpty) throw ArgumentError('حقول غير قابلة للتعديل: ${unknown.join('، ')}');
    if (values.containsKey('name') && '${values['name']}'.trim().isEmpty) {
      throw ArgumentError('اسم العامل مطلوب');
    }
    final found = await db.query('workers', where:'id=?', whereArgs:[id], limit:1);
    if (found.isEmpty) throw StateError('العامل غير موجود');
    final old = found.first;
    await db.update('workers', values, 'id=?', [id]);
    await db.audit(userId:userId, operation:'update', table:'workers', recordId:id, oldValues:old, newValues:values);
  }

  Future<void> deleteWorker(int id, int? userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الحذف مطلوب');
    final bal = (await accounting.workerBalance(id))['balance'] ?? 0;
    if (bal != 0) {
      throw StateError('لا يمكن حذف عامل رصيده ${AccountingCalculations.partyDueLabel(bal)}؛ سوِّ حسابه أولًا');
    }
    await db.update('workers', {'active':0}, 'id=?', [id]);
    await db.audit(userId:userId, operation:'logical_delete', table:'workers', recordId:id, reason:reason);
  }

  Future<int?> workerTransaction({
    required int workerId,
    required String type,
    required int amount,
    double hours = 0,
    int rateSnapshot = 0,
    double percentageSnapshot = 0,
    int? cashboxId,
    int? paymentMethodId,
    String? notes,
    int? userId,
  }) async {
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    if (type == 'accrual' || type == 'salary') {
      await accounting.createWorkerAccrual(
        workerId: workerId,
        amount: amount,
        date: AppClock.now(),
        hours: hours,
        rateSnapshot: rateSnapshot,
        percentageSnapshot: percentageSnapshot,
        userId: userId,
        memo: notes,
      );
      return null;
    } else if (type == 'payment') {
      final src = await accounting.paymentSource(
        paymentMethodId: paymentMethodId,
        cashboxId: cashboxId,
      );
      return accounting.payWorker(
        workerId: workerId,
        amount: amount,
        paymentMethodId: src['method']!,
        cashboxId: src['cashbox']!,
        userId: userId,
        notes: notes,
      );
    } else {
      throw ArgumentError('نوع حركة العامل غير مدعوم: $type');
    }
  }

  Future<List<Map<String, Object?>>> partners() async {
    final stationId = await accounting.currentStationId();
    return db.rawQuery(
      "SELECT p.*, ${BalanceSql.partnerPersonal('p')} balance FROM partners p WHERE p.station_id=? AND p.active=1 ORDER BY p.name",
      [stationId],
    );
  }

  Future<int> createPartner({
    required String name,
    required String mode,
    double shares = 0,
    double percentage = 0,
    String? phone,
    int opening = 0,
    int? userId,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم الشريك مطلوب');
    if (!{'shares','percentage'}.contains(mode)) throw ArgumentError('طريقة توزيع الشريك غير صالحة');
    if (mode == 'shares' && (shares <= 0 || percentage != 0)) throw ArgumentError('اختر الحصص فقط وأدخل حصصًا موجبة');
    if (mode == 'percentage' && (percentage < 0 || percentage > 100 || shares != 0)) throw ArgumentError('اختر النسبة فقط بين صفر و100');
    final stationId = await accounting.currentStationId();
    final id = await db.transaction((tx) async {
      final newId = await tx.insert('partners', {
        'station_id': stationId,
        'name': name.trim(),
        'phone': phone,
        'ownership_mode': mode,
        'shares_count': mode == 'shares' ? shares : 0,
        'ownership_percentage': mode == 'percentage' ? percentage : 0,
        'opening_balance': opening,
        'active': 1,
      });
      await accounting.postPartyOpeningTx(
        tx,
        kind: 'partner',
        id: newId,
        name: name.trim(),
        amount: opening,
        userId: userId,
      );
      return newId;
    });
    await db.audit(
      userId: userId,
      operation: 'create',
      table: 'partners',
      recordId: id,
      newValues: {'name': name, 'ownership_mode': mode},
    );
    return id;
  }

  Future<void> updatePartner(int id, Map<String,Object?> values, int? userId) async {
    final unknown = values.keys.where((k) => !_partnerEditable.contains(k));
    if (unknown.isNotEmpty) throw ArgumentError('حقول غير قابلة للتعديل: ${unknown.join('، ')}');
    final found = await db.query('partners', where:'id=?', whereArgs:[id], limit:1);
    if (found.isEmpty) throw StateError('الشريك غير موجود');
    if (values.containsKey('name') && '${values['name']}'.trim().isEmpty) {
      throw ArgumentError('اسم الشريك مطلوب');
    }
    final mode = '${values['ownership_mode'] ?? found.first['ownership_mode']}';
    final shares = (values['shares_count'] ?? found.first['shares_count'] ?? 0) as num;
    final percentage = (values['ownership_percentage'] ?? found.first['ownership_percentage'] ?? 0) as num;
    if (mode == 'shares' && (shares <= 0 || percentage != 0)) throw ArgumentError('طريقة الحصص لا تقبل نسبة ملكية');
    if (mode == 'percentage' && (percentage < 0 || percentage > 100 || shares != 0)) throw ArgumentError('طريقة النسبة لا تقبل حصصًا');
    final old = found.first;
    await db.update('partners', values, 'id=?', [id]);
    await db.audit(userId:userId, operation:'update', table:'partners', recordId:id, oldValues:old, newValues:values);
  }

  Future<void> deletePartner(int id, int? userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الحذف مطلوب');
    final bal = (await accounting.partnerBalance(id))['balance'] ?? 0;
    if (bal != 0) {
      throw StateError('لا يمكن حذف شريك رصيده ${AccountingCalculations.partyDueLabel(bal)}؛ سوِّ حسابه أولًا');
    }
    await db.update('partners', {'active':0}, 'id=?', [id]);
    await db.audit(userId:userId, operation:'logical_delete', table:'partners', recordId:id, reason:reason);
  }

  Future<List<Map<String, Object?>>> paymentMethods() => db.rawQuery(
    'SELECT pm.*,c.name cashbox_name FROM payment_methods pm LEFT JOIN cashboxes c ON c.id=pm.cashbox_id WHERE pm.active=1 ORDER BY pm.name',
  );

  Future<List<Map<String, Object?>>> cashboxes() =>
      db.rawQuery('SELECT * FROM cashboxes WHERE active=1 ORDER BY name');

  Future<int> createCashbox({
    required String name,
    int openingBalance = 0,
    String currency = 'YER',
    String ledgerAccountCode = '1000',
    int? userId,
  }) => accounting.createCashbox(
    name: name,
    openingBalance: openingBalance,
    currency: currency,
    ledgerAccountCode: ledgerAccountCode,
    userId: userId,
  );

  Future<void> updateCashbox(int id, {required String name, int? userId}) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم الصندوق مطلوب');
    final rows = await db.rawQuery('SELECT * FROM cashboxes WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('الصندوق غير موجود');
    await db.update('cashboxes', {'name': name.trim()}, 'id=?', [id]);
    await db.audit(
      userId: userId,
      operation: 'update',
      table: 'cashboxes',
      recordId: id,
      oldValues: {'name': rows.first['name']},
      newValues: {'name': name.trim()},
    );
  }

  Future<void> deleteCashbox(int id, int? userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الحذف مطلوب');
    final rows = await db.rawQuery('SELECT * FROM cashboxes WHERE id=? AND active=1', [id]);
    if (rows.isEmpty) throw StateError('الصندوق غير موجود');
    final bal = (rows.first['current_balance'] as num?)?.round() ?? 0;
    if (bal != 0) {
      throw StateError('لا يمكن حذف صندوق رصيده $bal؛ حوِّل رصيده إلى صندوق آخر أولًا');
    }
    final methods = await db.rawQuery(
      'SELECT name FROM payment_methods WHERE cashbox_id=? AND active=1',
      [id],
    );
    if (methods.isNotEmpty) {
      throw StateError('الصندوق مرتبط بطرق دفع مفعّلة (${methods.map((m) => m['name']).join('، ')})؛ احذفها أو انقلها أولًا');
    }
    final others = await db.rawQuery('SELECT COUNT(*) n FROM cashboxes WHERE active=1 AND id<>?', [id]);
    if (((others.first['n'] as num?)?.toInt() ?? 0) == 0) {
      throw StateError('لا يمكن حذف آخر صندوق مفعّل');
    }
    await db.update('cashboxes', {'active': 0}, 'id=?', [id]);
    await db.audit(
      userId: userId,
      operation: 'logical_delete',
      table: 'cashboxes',
      recordId: id,
      oldValues: rows.first,
      reason: reason,
    );
  }

  Future<int> createPaymentMethod({
    required String name,
    required String type,
    int? cashboxId,
    String? accountNumber,
    String? bankName,
    int? userId,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم طريقة الدفع مطلوب');
    final code = await _methodLedgerCode(type, cashboxId);
    final stationId = await accounting.currentStationId();
    final id = await db.insert('payment_methods', {
      'station_id': stationId,
      'name': name.trim(),
      'type': type,
      'cashbox_id': cashboxId,
      'account_number': accountNumber,
      'bank_name': bankName,
      'ledger_account_code': code,
      'active': 1,
    });
    await db.audit(
      userId: userId,
      operation: 'create',
      table: 'payment_methods',
      recordId: id,
      newValues: {'name': name, 'type': type, 'cashbox_id': cashboxId},
    );
    return id;
  }

  Future<String> _methodLedgerCode(String type, int? cashboxId) async {
    if (cashboxId != null) {
      final c = await db.rawQuery(
        'SELECT ledger_account_code FROM cashboxes WHERE id=? AND active=1',
        [cashboxId],
      );
      if (c.isEmpty) throw ArgumentError('الصندوق المرتبط غير موجود أو غير مفعّل');
      final code = c.first['ledger_account_code'] as String?;
      if (code != null && code.isNotEmpty) return code;
    }
    return switch (type) {
      'bank_transfer' => '1100',
      'wallet' => '1120',
      _ => '1000',
    };
  }

  Future<void> updatePaymentMethod(
    int id, {
    required String name,
    required String type,
    int? cashboxId,
    String? accountNumber,
    String? bankName,
    int? userId,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('اسم طريقة الدفع مطلوب');
    final rows = await db.rawQuery('SELECT * FROM payment_methods WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('طريقة الدفع غير موجودة');
    final code = await _methodLedgerCode(type, cashboxId);
    final values = {
      'name': name.trim(),
      'type': type,
      'cashbox_id': cashboxId,
      'account_number': accountNumber,
      'bank_name': bankName,
      'ledger_account_code': code,
    };
    await db.update('payment_methods', values, 'id=?', [id]);
    await db.audit(
      userId: userId,
      operation: 'update',
      table: 'payment_methods',
      recordId: id,
      oldValues: rows.first,
      newValues: values,
    );
  }

  Future<void> deletePaymentMethod(int id, int? userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الحذف مطلوب');
    final rows = await db.rawQuery('SELECT * FROM payment_methods WHERE id=? AND active=1', [id]);
    if (rows.isEmpty) throw StateError('طريقة الدفع غير موجودة');
    final others = await db.rawQuery('SELECT COUNT(*) n FROM payment_methods WHERE active=1 AND id<>?', [id]);
    if (((others.first['n'] as num?)?.toInt() ?? 0) == 0) {
      throw StateError('لا يمكن حذف آخر طريقة دفع مفعّلة');
    }
    await db.update('payment_methods', {'active': 0}, 'id=?', [id]);
    await db.audit(
      userId: userId,
      operation: 'logical_delete',
      table: 'payment_methods',
      recordId: id,
      oldValues: rows.first,
      reason: reason,
    );
  }

  Future<List<Map<String, Object?>>> transfers() => db.rawQuery(
    'SELECT t.*,f.name from_cashbox,tb.name to_cashbox FROM cashbox_transfers t LEFT JOIN cashboxes f ON f.id=t.from_cashbox_id LEFT JOIN cashboxes tb ON tb.id=t.to_cashbox_id ORDER BY t.date DESC',
  );

  Future<List<Map<String, Object?>>> journal({
    DateTime? from,
    DateTime? to,
    String? accountCode,
  }) async {
    final args = <Object?>[];
    var w = '1=1';
    if (from != null) {
      w += ' AND je.date>=?';
      args.add(from.toIso8601String());
    }
    if (to != null) {
      w += ' AND je.date<?';
      args.add(DateTime(to.year, to.month, to.day).add(const Duration(days: 1)).toIso8601String());
    }
    if (accountCode != null) {
      if (accountCode == '2100' || accountCode == '2200') {
        w += " AND (a.code=? OR a.parent_id=(SELECT id FROM accounts WHERE code=?))";
        args..add(accountCode)..add(accountCode);
      } else {
        w += ' AND a.code=?';
        args.add(accountCode);
      }
    }
    return db.rawQuery(
      'SELECT je.*,je.id journal_id,jl.id line_id,a.code account_code,a.name account_name,a.type account_type,'
      'jl.debit,jl.credit,jl.beneficiary_id,jl.worker_id,jl.partner_id,jl.memo,'
      'COALESCE(b.name,w.name,p.name) party_name '
      'FROM journal_entries je '
      'JOIN journal_lines jl ON jl.journal_entry_id=je.id '
      'JOIN accounts a ON a.id=jl.account_id '
      'LEFT JOIN beneficiaries b ON b.id=jl.beneficiary_id '
      'LEFT JOIN workers w ON w.id=jl.worker_id '
      'LEFT JOIN partners p ON p.id=jl.partner_id '
      'WHERE $w AND je.status=\'posted\' ORDER BY je.date,je.id,jl.id',
      args,
    );
  }

  Future<List<Map<String, Object?>>> ledger(
    String accountCode, {
    DateTime? from,
    DateTime? to,
  }) => journal(from: from, to: to, accountCode: accountCode);

  Future<List<Map<String, Object?>>> partyLedgerStatement({
    required String kind,
    int? id,
    DateTime? from,
    DateTime? to,
  }) async {
    final args = <Object?>[];
    final where = <String>["je.status='posted'"];
    if (from != null) {
      where.add('je.date>=?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('je.date<?');
      args.add(DateTime(to.year, to.month, to.day).add(const Duration(days: 1)).toIso8601String());
    }
    String? movementJoin;
    String? cashAccountCode;
    if (kind == 'cashbox' && id != null) {
      final box = await db.rawQuery('SELECT ledger_account_code FROM cashboxes WHERE id=? LIMIT 1', [id]);
      cashAccountCode = box.isEmpty ? null : box.first['ledger_account_code'] as String?;
      if (cashAccountCode == null || cashAccountCode.isEmpty) {
        final method = await db.rawQuery('SELECT ledger_account_code,type FROM payment_methods WHERE cashbox_id=? AND active=1 ORDER BY id LIMIT 1', [id]);
        cashAccountCode = method.isEmpty ? '1000' : (method.first['ledger_account_code'] as String?);
        if (cashAccountCode == null || cashAccountCode.isEmpty) cashAccountCode = '1000';
      }
    }
    switch (kind) {
      case 'beneficiary':
        if (id == null) return <Map<String, Object?>>[];
        where.add('jl.beneficiary_id=?');
        args.add(id);
        break;
      case 'worker':
        if (id == null) return <Map<String, Object?>>[];
        where.add("(a.code=? OR (a.code='2100' AND jl.worker_id=?))");
        args..add('2100.W$id')..add(id);
        break;
      case 'partner':
        if (id == null) return <Map<String, Object?>>[];
        where.add("(a.code=? OR (a.code='2200' AND jl.partner_id=?))");
        args..add('2200.P$id')..add(id);
        break;
      case 'expenses':
        where.add("je.reference_type IN ('expense','petty_expense')");
        break;
      case 'receipts':
        movementJoin = 'JOIN payments pay ON pay.id=je.reference_id';
        where.add("je.reference_type='payment' AND pay.beneficiary_id IS NOT NULL");
        break;
      case 'payments':
        movementJoin = 'JOIN payments pay ON pay.id=je.reference_id';
        where.add("je.reference_type='payment' AND (pay.worker_id IS NOT NULL OR pay.partner_id IS NOT NULL OR pay.beneficiary_id IS NULL)");
        break;
      case 'cashbox':
        if (id == null) return <Map<String, Object?>>[];
        where.add('a.code=?');
        args.add(cashAccountCode ?? '1000');
        movementJoin = 'LEFT JOIN payments pay ON pay.id=je.reference_id LEFT JOIN expenses exp ON exp.id=je.reference_id LEFT JOIN cashbox_transfers tr ON tr.id=je.reference_id';
        where.add("((je.reference_type='payment' AND pay.cashbox_id=?) OR (je.reference_type IN ('expense','petty_expense') AND exp.cashbox_id=?) OR (je.reference_type='cashbox_transfer' AND (tr.from_cashbox_id=? OR tr.to_cashbox_id=?)))");
        args..add(id)..add(id)..add(id)..add(id);
        break;
      default:
        throw ArgumentError('نوع كشف الأستاذ غير مدعوم: $kind');
    }
    final rows = await db.rawQuery('''
      SELECT je.id journal_id,je.date,je.description,je.reference_type,je.reference_id,
             a.code account_code,a.name account_name,a.type account_type,
             jl.debit,jl.credit,jl.memo,jl.beneficiary_id,jl.worker_id,jl.partner_id,
             COALESCE(b.name,w.name,p.name) party_name
      FROM journal_entries je
      JOIN journal_lines jl ON jl.journal_entry_id=je.id
      JOIN accounts a ON a.id=jl.account_id
      ${movementJoin ?? ''}
      LEFT JOIN beneficiaries b ON b.id=jl.beneficiary_id
      LEFT JOIN workers w ON w.id=jl.worker_id
      LEFT JOIN partners p ON p.id=jl.partner_id
      WHERE ${where.join(' AND ')}
      ORDER BY je.date ASC,je.id ASC,jl.id ASC
    ''', args);
    var running = 0;
    return rows.map((row) {
      final debit = (row['debit'] as num?)?.round() ?? 0;
      final credit = (row['credit'] as num?)?.round() ?? 0;
      final partyPerspective = kind == 'worker' || kind == 'partner';
      final lah = partyPerspective ? credit : debit;
      final alayh = partyPerspective ? debit : credit;
      running += lah - alayh;
      return <String, Object?>{
        ...row,
        'lah': lah,
        'alayh': alayh,
        'balance': running,
        'amount': lah + alayh,
        'statement_kind': kind,
      };
    }).toList().reversed.toList();
  }

  Future<List<Map<String, Object?>>> accounts() =>
      db.rawQuery('SELECT code,name,type FROM accounts ORDER BY code');

  Future<Map<String, Object?>> ledgerStatement(
    String accountCode, {
    DateTime? from,
    DateTime? to,
  }) async {
    final f = from == null ? null : DateTime(from.year, from.month, from.day);
    var opening = 0;
    if (f != null) {
      final r = await db.rawQuery(
        'SELECT COALESCE(SUM(jl.debit),0) d,COALESCE(SUM(jl.credit),0) c '
        'FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id '
        "JOIN accounts a ON a.id=jl.account_id WHERE ${(accountCode == '2100' || accountCode == '2200') ? '(a.code=? OR a.parent_id=(SELECT id FROM accounts WHERE code=?))' : 'a.code=?'} AND je.status='posted' AND je.date<?",
        (accountCode == '2100' || accountCode == '2200')
            ? [accountCode, accountCode, f.toIso8601String()]
            : [accountCode, f.toIso8601String()],
      );
      opening = ((r.first['d'] as num?)?.round() ?? 0) -
          ((r.first['c'] as num?)?.round() ?? 0);
    }
    final lines = await journal(from: f, to: to, accountCode: accountCode);
    var running = opening, totalDebit = 0, totalCredit = 0;
    final rows = <Map<String, Object?>>[];
    for (final x in lines) {
      final d = (x['debit'] as num?)?.round() ?? 0;
      final c = (x['credit'] as num?)?.round() ?? 0;
      totalDebit += d;
      totalCredit += c;
      running += d - c;
      rows.add({...x, 'balance': running});
    }
    return {
      'opening': opening,
      'total_debit': totalDebit,
      'total_credit': totalCredit,
      'closing': running,
      'rows': rows,
    };
  }

  Future<Map<String, String>> settings() => db
      .rawQuery('SELECT key,value FROM settings')
      .then(
        (r) => {for (final x in r) x['key'] as String: x['value'] as String},
      );

  Future<Map<String, Object?>> systemConfiguration() async {
    final set = await settings();
    final configuredPumpId = int.tryParse(set['selected_pump_id'] ?? '');
    final rows = configuredPumpId == null
        ? <Map<String, Object?>>[]
        : await db.rawQuery(
            'SELECT id,name,station_id,system_type,active FROM pumps WHERE id=? AND active=1 LIMIT 1',
            [configuredPumpId],
          );
    if (rows.isEmpty) {
      throw StateError('المضخة المحددة في الإعدادات غير موجودة أو غير فعالة');
    }
    final pump = rows.first;
    final type = set['system_type'] ?? 'diesel';
    const allowed = {'diesel', 'solar', 'equivalent_hybrid'};
    if (!allowed.contains(type)) throw StateError('نوع المنظومة في الإعدادات غير صالح');
    if (pump['system_type'] != type) {
      await db.update('pumps', {'system_type': type}, 'id=?', [pump['id']]);
      pump['system_type'] = type;
    }
    return {
      'system_type': type,
      'pump_id': pump['id'],
      'pump_name': pump['name'],
      'pump_system_type': pump['system_type'],
    };
  }

  Future<void> setSystemType(String type) async {
    const allowed = {'diesel', 'solar', 'equivalent_hybrid'};
    if (!allowed.contains(type)) throw ArgumentError('نوع المنظومة غير صالح');
    final set = await settings();
    final lockedType = set['system_type'];
    if (set['initial_setup_completed'] == 'true' && lockedType != null && lockedType != type) {
      throw StateError('نوع المنظومة ثابت منذ الإعداد الأولي ولا يمكن تغييره');
    }
    final pumpId = int.tryParse(set['selected_pump_id'] ?? '');
    await db.transaction((tx) async {
      await tx.insert('settings', {
        'key': 'system_type',
        'value': type,
        'updated_at': AppClock.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (pumpId != null) {
        await tx.update(
          'pumps',
          {'system_type': type},
          where: 'id=?',
          whereArgs: [pumpId],
        );
      }
    });
  }

  Future<void> selectPump(int pumpId) async {
    final set = await settings();
    final pump = await db.rawQuery(
      'SELECT id,name FROM pumps WHERE id=? AND active=1',
      [pumpId],
    );
    if (pump.isEmpty) throw ArgumentError('المضخة غير موجودة أو غير مفعّلة');
    final now = AppClock.now().toIso8601String();
    await db.transaction((tx) async {
      await tx.insert('settings', {
        'key': 'selected_pump_id',
        'value': '$pumpId',
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.insert('settings', {
        'key': 'pump_name',
        'value': '${pump.first['name']}',
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.update(
        'pumps',
        {'system_type': set['system_type'] ?? 'diesel'},
        where: 'id=?',
        whereArgs: [pumpId],
      );
    });
  }

  Future<void> setSetting(String key, String value) async {
    if (key == 'system_type') {
      final set = await settings();
      if (set['initial_setup_completed'] == 'true' && set['system_type'] != value) {
        throw StateError('نوع المنظومة ثابت منذ الإعداد الأولي ولا يمكن تغييره');
      }
    }
    await db.insert('settings', {
      'key': key,
      'value': value,
      'updated_at': AppClock.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>> dashboard() async {
    final r = await db.rawQuery(
      "SELECT (SELECT value FROM settings WHERE key='system_type' LIMIT 1) system_type,(SELECT COUNT(*) FROM beneficiaries WHERE status='active') beneficiaries,(SELECT COUNT(*) FROM queue_entries WHERE status IN ('waiting','postponed')) queue,(SELECT COUNT(*) FROM booking_requests WHERE status IN ('new','under_review')) bookings,(SELECT COUNT(*) FROM irrigation_sessions WHERE status='running') running_sessions,(SELECT COALESCE(SUM(amount),0) FROM expenses WHERE status='posted') expenses,(SELECT COALESCE(SUM(total_amount),0) FROM irrigations WHERE status!='cancelled') revenue,(SELECT COALESCE(SUM(amount),0) FROM payments WHERE status='posted' AND beneficiary_id IS NOT NULL) paid,(SELECT COALESCE(SUM(bal),0) FROM (SELECT ${await _balanceSql()} bal FROM beneficiaries b WHERE b.status='active')) remaining,(SELECT COALESCE(SUM(total_amount),0) FROM irrigations WHERE status!='cancelled') due,(SELECT COUNT(*) FROM notifications WHERE read_at IS NULL) unread_notifications,(SELECT COALESCE(SUM(jl.credit-jl.debit),0) FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE (a.code='2100' OR a.parent_id=(SELECT id FROM accounts WHERE code='2100')) AND je.status='posted') worker_due,(SELECT COALESCE(SUM(jl.credit-jl.debit),0) FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE (a.code='2200' OR a.parent_id=(SELECT id FROM accounts WHERE code='2200')) AND je.status='posted') partner_due",
    );
    return r.first;
  }

  Future<Map<String, Object?>> currentSession() async {
    final r = await db.rawQuery(
      "SELECT s.*,b.name beneficiary_name,p.name pump_name FROM irrigation_sessions s JOIN beneficiaries b ON b.id=s.beneficiary_id JOIN pumps p ON p.id=s.pump_id WHERE s.status='running' ORDER BY s.actual_start LIMIT 1",
    );
    return r.isEmpty ? {} : r.first;
  }

  Future<List<Map<String, Object?>>> notifications({
    int? beneficiaryId,
  }) => db.rawQuery(
    'SELECT * FROM notifications ${beneficiaryId == null ? '' : 'WHERE beneficiary_id=?'} ORDER BY created_at DESC',
    beneficiaryId == null ? [] : [beneficiaryId],
  );

  Future<void> notify({
    int? beneficiaryId,
    required String type,
    required String title,
    required String body,
  }) async {
    await db.insert('notifications', {
      'beneficiary_id': beneficiaryId,
      'type': type,
      'title': title,
      'body': body,
      'created_at': AppClock.now().toIso8601String(),
    });
    AppAlerts.emit(title, body);
  }

  Future<void> markNotificationRead(int id) => db.update(
    'notifications',
    {'read_at': AppClock.now().toIso8601String()},
    'id=?',
    [id],
  );

  Future<void> snoozeNotification(int id, {int minutes = 10}) => db.update(
    'notifications',
    {
      'snoozed_until': AppClock.now()
          .add(Duration(minutes: minutes))
          .toIso8601String(),
    },
    'id=?',
    [id],
  );

  Future<List<Map<String, Object?>>> needyBeneficiaries() => db.rawQuery(
    "SELECT * FROM beneficiaries WHERE is_needy=1 AND status='active' ORDER BY name",
  );

  Future<Map<String, Object?>> partnerProfitSummary({required DateTime from, required DateTime to}) async {
    final stationId = await accounting.currentStationId();
    final start = DateTime(from.year, from.month, from.day);
    final endExclusive = DateTime(to.year, to.month, to.day + 1);
    final args = [stationId, start.toIso8601String(), endExclusive.toIso8601String()];
    Future<int> value(String sql) async => ((await db.rawQuery(sql, args)).first['n'] as num?)?.round() ?? 0;
    Future<int> currentLiability(String code) async => ((await db.rawQuery(
      "SELECT COALESCE(SUM(jl.credit-jl.debit),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND (a.code=? OR a.parent_id=(SELECT id FROM accounts WHERE code=?))",
      [stationId, code, code],
    )).first['n'] as num?)?.round() ?? 0;
    final revenue = await value("SELECT COALESCE(SUM(CASE WHEN a.type='revenue' THEN jl.credit-jl.debit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND COALESCE(je.reference_type,'') NOT IN ('year_close','year_close_reversal') AND je.date>=? AND je.date<?");
    final expenses = await value("SELECT COALESCE(SUM(CASE WHEN a.type='expense' AND a.code!='5000' THEN jl.debit-jl.credit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND COALESCE(je.reference_type,'') NOT IN ('year_close','year_close_reversal') AND je.date>=? AND je.date<?");
    final workers = await value("SELECT COALESCE(SUM(CASE WHEN a.code='5000' THEN jl.debit-jl.credit ELSE 0 END),0) n FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND COALESCE(je.reference_type,'') NOT IN ('year_close','year_close_reversal') AND je.date>=? AND je.date<?");
    return {
      'revenue': revenue,
      'expenses': expenses,
      'workers': workers,
      'worker_due': await currentLiability('2100'),
      'partner_due': await currentLiability('2200'),
      'distributable': AccountingCalculations.distributableProfit(totalRevenue: revenue, generalExpenses: expenses, workerEntitlements: workers),
    };
  }

  Future<List<Map<String, Object?>>> report(
    String key, {
    DateTime? from,
    DateTime? to,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    String? systemType,
    int? cashboxId,
    int? paymentMethodId,
    String? category,
    String? status,
  }) async {
    final args = <Object?>[];
    final currentSettings = await settings();
    final currentSystemType = currentSettings['system_type'] ?? 'diesel';
    if (key == 'diesel_inventory' && currentSystemType != 'diesel') {
      throw StateError('تقرير الديزل غير متاح لأن المنظومة الحالية ليست ديزل');
    }
    final allSystems = systemType == 'all';
    systemType ??= currentSystemType;
    String iw = "i.status!='cancelled'";
    if (from != null) {
      iw += ' AND i.start_datetime>=?';
      args.add(from.toIso8601String());
    }
    if (to != null) {
      iw += ' AND i.start_datetime<?';
      args.add(to.add(const Duration(days: 1)).toIso8601String());
    }
    if (beneficiaryId != null) {
      iw += ' AND i.beneficiary_id=?';
      args.add(beneficiaryId);
    }
    if (!allSystems) {
      iw += ' AND i.system_type=?';
      args.add(systemType);
    }
    switch (key) {
      case 'irrigations':
        {
          final a = <Object?>[];
          var w = "i.status!='cancelled'";
          // استخدم تاريخ العملية إن كان SQLite يستطيع قراءته، وإلا فارجع
          // إلى start_datetime. طبّق حدّي الفترة على التاريخ الفعلي نفسه.
          if (from != null) {
            w += ' AND COALESCE(date(i.date), date(i.start_datetime))>=date(?)';
            a.add(from.toIso8601String());
          }
          if (to != null) {
            w += ' AND COALESCE(date(i.date), date(i.start_datetime))<=date(?)';
            a.add(to.toIso8601String());
          }
          if (beneficiaryId != null) { w += ' AND i.beneficiary_id=?'; a.add(beneficiaryId); }
          if (workerId != null) { w += ' AND i.worker_id=?'; a.add(workerId); }
          if (partnerId != null) { w += ' AND i.partner_id=?'; a.add(partnerId); }
          if (systemType != 'all') { w += ' AND i.system_type=?'; a.add(systemType); }
          return db.rawQuery(
            '''SELECT i.id irrigation_id,i.beneficiary_id,COALESCE(b.name,wk.name,pt.name,'غير محدد') party_name,
                      i.start_datetime,i.end_datetime,i.minutes,i.paid_amount,i.total_amount,
                      COALESCE(i.cloud_minutes,0) cloud_minutes,
                      CASE WHEN COALESCE(i.cloud_minutes,0)>0 THEN 'discounted' ELSE 'none' END cloud_status
               FROM irrigations i
               LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id
               LEFT JOIN workers wk ON wk.id=i.worker_id
               LEFT JOIN partners pt ON pt.id=i.partner_id
               WHERE $w ORDER BY i.start_datetime DESC''', a);
        }
      case 'cash_flow':
        {
          final a = <Object?>[];
          final paymentWhere = <String>['p.status=\'posted\''];
          final expenseWhere = <String>["e.status='posted'"];
          if (from != null) { paymentWhere.add('p.date>=?'); expenseWhere.add('e.date>=?'); a.add(from.toIso8601String()); }
          if (to != null) { paymentWhere.add('p.date<?'); expenseWhere.add('e.date<?'); a.add(to.add(const Duration(days: 1)).toIso8601String()); }
          if (cashboxId != null) { paymentWhere.add('p.cashbox_id=?'); expenseWhere.add('e.cashbox_id=?'); a.add(cashboxId); }
          if (paymentMethodId != null) { paymentWhere.add('p.payment_method_id=?'); expenseWhere.add('e.payment_method_id=?'); a.add(paymentMethodId); }
          return db.rawQuery("SELECT date,kind,amount,title FROM (SELECT p.date,'payment' kind,CASE WHEN p.beneficiary_id IS NULL THEN -p.amount ELSE p.amount END amount,CASE WHEN p.beneficiary_id IS NULL THEN 'دفع' ELSE 'قبض' END title FROM payments p WHERE ${paymentWhere.join(' AND ')} UNION ALL SELECT e.date,'expense',-e.amount,e.title FROM expenses e WHERE ${expenseWhere.join(' AND ')}) ORDER BY date DESC", [...a, ...a]);
        }
      case 'time_comparison':
        {
          final q = "SELECT substr(i.date,1,7) month,i.system_type,SUM(i.minutes) minutes,SUM(i.chargeable_minutes) chargeable_minutes,COUNT(*) operations,SUM(i.total_amount) total FROM irrigations i WHERE $iw GROUP BY month,i.system_type ORDER BY month,i.system_type";
          return db.rawQuery(q, args);
        }
      case 'monthly_financial':
        return db.rawQuery(
          "SELECT substr(date,1,7) month,COALESCE((SELECT SUM(total_amount) FROM irrigations x WHERE substr(x.date,1,7)=substr(i.date,1,7) AND x.status!='cancelled'),0) income,COALESCE((SELECT SUM(amount) FROM expenses e WHERE substr(e.date,1,7)=substr(i.date,1,7) AND e.status='posted'),0) expenses FROM irrigations i WHERE $iw GROUP BY substr(date,1,7) ORDER BY month",
          args,
        );
      case 'income':
        return _systemReportWithOverall(
          "SELECT i.system_type,COUNT(*) operations,SUM(i.water_amount) water_income,SUM(i.diesel_amount) diesel_income,SUM(i.total_amount) total FROM irrigations i WHERE $iw GROUP BY i.system_type",
          args,
        );
      case 'payment_methods':
        return db.rawQuery(
          "SELECT pm.name method_name,pm.type,pm.account_number,pm.bank_name,COALESCE(SUM(p.amount),0) total FROM payment_methods pm LEFT JOIN payments p ON p.payment_method_id=pm.id AND p.status='posted' GROUP BY pm.id",
        );
      case 'expenses':
        {
          final a = <Object?>[];
          var w = "status='posted'";
          if (from != null) {
            w += ' AND date>=?';
            a.add(from.toIso8601String());
          }
          if (to != null) {
            w += ' AND date<?';
            a.add(to.add(const Duration(days: 1)).toIso8601String());
          }
          if (cashboxId != null) {
            w += ' AND cashbox_id=?';
            a.add(cashboxId);
          }
          if (paymentMethodId != null) {
            w += ' AND payment_method_id=?';
            a.add(paymentMethodId);
          }
          if (category != null) {
            w += ' AND category=?';
            a.add(category);
          }
          if (status != null) {
            // تم التصحيح: استخدام replaceAll لتجنب خطأ لغة Dart
            w = w.replaceAll("status='posted'", "status=?");
          }
          return db.rawQuery(
            'SELECT category,COUNT(*) count,SUM(amount) total FROM expenses WHERE $w GROUP BY category ORDER BY total DESC',
            a,
          );
        }
      case 'cashboxes':
        return db.rawQuery(
          "SELECT c.name,SUM(CASE WHEN t.to_cashbox_id=c.id THEN t.amount ELSE 0 END) incoming,SUM(CASE WHEN t.from_cashbox_id=c.id THEN t.amount ELSE 0 END) outgoing,c.current_balance FROM cashboxes c LEFT JOIN cashbox_transfers t ON t.to_cashbox_id=c.id OR t.from_cashbox_id=c.id GROUP BY c.id",
        );
      case 'queue_bookings':
        return db.rawQuery(
          "SELECT 'queue' source,b.name,q.status,q.created_at date FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id UNION ALL SELECT 'booking',b.name,br.status,br.created_at FROM booking_requests br JOIN beneficiaries b ON b.id=br.beneficiary_id ORDER BY date DESC",
        );
      case 'payment_log':
        {
          final a = <Object?>[];
          var w = 'p.status=\'posted\'';
          if (from != null) {
            w += ' AND p.date>=?';
            a.add(from.toIso8601String());
          }
          if (to != null) {
            w += ' AND p.date<?';
            a.add(to.add(const Duration(days: 1)).toIso8601String());
          }
          if (cashboxId != null) {
            w += ' AND p.cashbox_id=?';
            a.add(cashboxId);
          }
          if (paymentMethodId != null) {
            w += ' AND p.payment_method_id=?';
            a.add(paymentMethodId);
          }
          return db.rawQuery(
            'SELECT p.*,COALESCE(b.name,COALESCE(w.name,pt.name)) party_name,pm.name method_name,c.name cashbox_name FROM payments p LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id LEFT JOIN workers w ON w.id=p.worker_id LEFT JOIN partners pt ON pt.id=p.partner_id JOIN payment_methods pm ON pm.id=p.payment_method_id JOIN cashboxes c ON c.id=p.cashbox_id WHERE $w ORDER BY p.date DESC',
            a,
          );
        }
      case 'beneficiary_statement':
        return beneficiaryId == null
            ? <Map<String, Object?>>[]
            : await beneficiaryStatement(beneficiaryId, from: from, to: to);
      case 'beneficiary_detailed':
        return beneficiaryId == null
            ? <Map<String, Object?>>[]
            : await beneficiaryStatement(beneficiaryId, from: from, to: to);
      case 'beneficiary_stats':
        return db.rawQuery(
          "SELECT b.id,b.name,COUNT(i.id) irrigations,COALESCE(SUM(i.minutes),0) minutes,COALESCE(SUM(i.total_amount),0) total FROM beneficiaries b LEFT JOIN irrigations i ON i.beneficiary_id=b.id AND i.status!='cancelled' GROUP BY b.id ORDER BY total DESC",
        );
      case 'needy':
        return db.rawQuery(
          "SELECT b.id,b.name,b.phone,${await _balanceSql()} balance FROM beneficiaries b WHERE b.is_needy=1 AND b.status='active' ORDER BY b.name",
        );
      case 'diesel_inventory':
        {
          var rows = await diesel();
          if (from != null) rows = rows.where((x) => DateTime.tryParse('${x['date']}')?.isAfter(from.subtract(const Duration(seconds: 1))) ?? true).toList();
          if (to != null) rows = rows.where((x) => DateTime.tryParse('${x['date']}')?.isBefore(to.add(const Duration(days: 1))) ?? true).toList();
          return rows;
        }
      case 'activity_overview':
        return _systemReportWithOverall(
          "SELECT i.system_type,COUNT(*) operations,SUM(i.minutes) minutes,SUM(i.total_amount) total FROM irrigations i WHERE $iw GROUP BY i.system_type",
          args,
        );
      case 'oil_status':
        return db.rawQuery(
          "SELECT category,SUM(amount) total FROM expenses WHERE status='posted' AND category IN ('oil','grease') GROUP BY category",
        );
      case 'debts':
        return db.rawQuery(
          "SELECT b.id,b.name,${await _balanceSql()} balance FROM beneficiaries b WHERE b.status='active' ORDER BY balance DESC",
        );
      case 'beneficiary_list':
        return beneficiaries();
      case 'revenue_comparison':
        return db.rawQuery(
          "SELECT substr(i.date,1,7) AS month,i.system_type,SUM(i.total_amount) AS total FROM irrigations i WHERE $iw GROUP BY substr(i.date,1,7),i.system_type ORDER BY month,i.system_type",
          args,
        );
      case 'system_comparison':
        return _systemReportWithOverall(
          "SELECT i.system_type,COUNT(*) operations,SUM(i.minutes) minutes,SUM(i.total_amount) total,SUM(i.diesel_amount) diesel_cost FROM irrigations i WHERE $iw GROUP BY i.system_type",
          args,
        );
      case 'journal':
        return journal(from: from, to: to);
      case 'ledger':
        return journal(from: from, to: to);
      case 'worker_transactions':
        {
          var rows=await workerTransactions(workerId ?? 0);
          if(from!=null) rows=rows.where((x)=>DateTime.tryParse('${x['date']}')?.isAfter(from.subtract(const Duration(seconds:1))) ?? true).toList();
          if(to!=null) rows=rows.where((x)=>DateTime.tryParse('${x['date']}')?.isBefore(to.add(const Duration(days:1))) ?? true).toList();
          return rows;
        }
      case 'partner_accounts':
        {
          var rows=await partnerTransactions(partnerId ?? 0);
          if(from!=null) rows=rows.where((x)=>DateTime.tryParse('${x['date']}')?.isAfter(from.subtract(const Duration(seconds:1))) ?? true).toList();
          if(to!=null) rows=rows.where((x)=>DateTime.tryParse('${x['date']}')?.isBefore(to.add(const Duration(days:1))) ?? true).toList();
          return rows;
        }
      case 'partner_profit_distribution':
        if (from == null || to == null) return <Map<String, Object?>>[];
        final summary = await partnerProfitSummary(from: from, to: to);
        final ps = await partners();
        final totalShares = ps.fold<double>(0.0, (sum, p) => sum + ((p['shares_count'] as num?)?.toDouble() ?? 0.0));
        final profit = (summary['distributable'] as num?)?.round() ?? 0;
        final stationId = await accounting.currentStationId();
        final start = DateTime(from.year, from.month, from.day).toIso8601String();
        final endExclusive = DateTime(to.year, to.month, to.day + 1).toIso8601String();
        final individualExpenses = await db.rawQuery(
          "SELECT partner_id,COALESCE(SUM(amount),0) total FROM expenses WHERE status='posted' AND partner_id IS NOT NULL AND date>=? AND date<? AND partner_id IN (SELECT id FROM partners WHERE station_id=? AND active=1) GROUP BY partner_id",
          [start, endExclusive, stationId],
        );
        final expensesByPartner = <int, int>{
          for (final row in individualExpenses)
            (row['partner_id'] as num).toInt(): (row['total'] as num).round(),
        };
        return ps.map((p) {
          final id = (p['id'] as num).toInt();
          final gross = AccountingCalculations.partnerShareByMode(
            mode: '${p['ownership_mode']}',
            distributable: profit,
            partnerShares: (p['shares_count'] as num?)?.toDouble() ?? 0.0,
            totalShares: totalShares,
            percentage: (p['ownership_percentage'] as num?)?.toDouble() ?? 0,
          );
          final personalExpenses = expensesByPartner[id] ?? 0;
          return <String, Object?>{
            'name': p['name'],
            'mode': p['ownership_mode'],
            'basis': p['ownership_mode'] == 'percentage' ? p['ownership_percentage'] : p['shares_count'],
            'gross_amount': gross,
            'partner_expenses': personalExpenses,
            // قد تصبح النتيجة سالبة إذا تجاوزت المصروفات الخاصة حصة الشريك.
            'amount': gross - personalExpenses,
          };
        }).toList();
      default:
        throw StateError('نوع التقرير غير مدعوم: $key');
    }
  }

  Future<List<Map<String, Object?>>> _systemReportWithOverall(
    String sql,
    List<Object?> args,
  ) async {
    final rows = await db.rawQuery(sql, args);
    if (rows.isEmpty) return rows;
    int sumInt(String key) =>
        rows.fold<int>(0, (s, r) => s + ((r[key] as num?)?.round() ?? 0));
    final overall = <String, Object?>{'system_type': 'الإجمالي العام'};
    for (final key in [
      'minutes',
      'chargeable_minutes',
      'operations',
      'water_income',
      'diesel_income',
      'total',
      'diesel_cost',
    ]) {
      if (rows.first.containsKey(key)) overall[key] = sumInt(key);
    }
    return [...rows, overall];
  }

  Future<String> _balanceSql() => Future.value(BalanceSql.beneficiary('b'));
}
