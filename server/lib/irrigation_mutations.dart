part of 'server.dart';

// P1 mirrors the existing local time-edit and cancellation rules. Creation
// remains in the P0 handler. The real two-client tests verify their parity.
class _P1Mutations {
  final SaqiaServer server;
  final int station;
  final DateTime clock;
  late final _P1Db database = _P1Db(_P1Tx(server.db, station), clock);
  _P1Mutations(this.server, this.station, this.clock);
  int _selectedStationIdTx(_P1Tx tx) => station;
  int _accountIdTx(_P1Tx tx, String code) => server._accountId(code);
  int _workerAccountIdTx(_P1Tx tx, int id) => server._syncWorkerAccountId(id);
  int _partnerAccountIdTx(_P1Tx tx, int id) => server._syncPartnerAccountId(id);
  static const _beneficiaryDieselStockSql =
      "SELECT COALESCE((SELECT opening_diesel_liters FROM beneficiaries WHERE id=?),0)"
      "+COALESCE((SELECT carried_diesel_liters FROM beneficiaries WHERE id=?),0)"
      "+COALESCE((SELECT SUM(CASE WHEN kind IN ('delivery','advance') THEN liters WHEN kind='consumption' THEN -liters ELSE 0 END) FROM diesel_movements WHERE beneficiary_id=?),0) stock";
  int _entry(
    _P1Tx tx, {
    required String description,
    required String referenceType,
    int? referenceId,
    required List<Map<String, Object?>> lines,
    int? userId,
    DateTime? date,
    int? stationId,
  }) {
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
    final now = clock.toIso8601String();
    final entryStationId = stationId ?? _selectedStationIdTx(tx);
    // تاريخ القيد = تاريخ العملية الفعلي (وليس لحظة الحفظ) حتى لا تُرحَّل
    // الحركات القديمة إلى اليوم ولا يُتجاوز إغلاق الفترة.
    final id = tx.insert('journal_entries', {
      'station_id': entryStationId,
      'date': (date ?? clock).toIso8601String(),
      'reference_type': referenceType,
      'reference_id': referenceId,
      'description': description,
      'status': 'posted',
      'created_by': userId,
      'created_at': now,
    });
    for (final line in lines) {
      tx.insert('journal_lines', {...line, 'journal_entry_id': id});
    }
    return id;
  }

  int _reverseEntriesTx(
    _P1Tx tx, {
    required String referenceType,
    required int referenceId,
    required String reason,
    int? userId,
    String? descriptionEquals,
    DateTime? date,
  }) {
    final entries = tx.rawQuery(
      "SELECT je.id,je.description FROM journal_entries je WHERE je.reference_type=? AND je.reference_id=? AND je.status='posted' "
      "${descriptionEquals == null ? '' : 'AND je.description=? '}"
      "AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reference_type='reversal' AND r.reference_id=je.id)",
      [
        referenceType,
        referenceId,
        if (descriptionEquals != null) descriptionEquals,
      ],
    );
    var n = 0;
    for (final e in entries) {
      final eid = e['id'] as int;
      final lines = tx.query(
        'journal_lines',
        where: 'journal_entry_id=?',
        whereArgs: [eid],
      );
      _entry(
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
        date: date,
      );
      n++;
    }
    return n;
  }

  void _assertPeriodOpen(_P1Tx tx, DateTime date, {int? stationId}) {
    final station = stationId ?? _selectedStationIdTx(tx);
    final value = date.toIso8601String();
    final rows = tx.rawQuery(
      "SELECT id FROM period_closures WHERE station_id=? AND status!='reopened' AND period_start<=? AND ((period_end_exclusive IS NOT NULL AND period_end_exclusive>?) OR (period_end_exclusive IS NULL AND period_end>=?)) LIMIT 1",
      [station, value, value, value],
    );
    if (rows.isNotEmpty) {
      throw StateError('الفترة المحاسبية مغلقة ولا يمكن إضافة حركة إليها');
    }
  }

  void _assertPeriodRangeOpen(
    _P1Tx tx,
    DateTime start,
    DateTime endExclusive, {
    int? stationId,
  }) {
    final station = stationId ?? _selectedStationIdTx(tx);
    final rows = tx.rawQuery(
      "SELECT id FROM period_closures WHERE station_id=? AND status!='reopened' AND period_start<? AND ((period_end_exclusive IS NOT NULL AND period_end_exclusive>?) OR (period_end_exclusive IS NULL AND period_end>=?)) LIMIT 1",
      [
        station,
        endExclusive.toIso8601String(),
        start.toIso8601String(),
        start.toIso8601String(),
      ],
    );
    if (rows.isNotEmpty) throw StateError('الفترة المحاسبية المطلوبة مغلقة');
  }

  int _accrueWorkerIrrigationTx(
    _P1Tx tx, {
    required int workerId,
    required int irrigationId,
    required int amount,
    required double hours,
    required DateTime date,
    int? userId,
  }) {
    final w = tx.query(
      'workers',
      columns: ['pay_type', 'hourly_rate', 'percentage_rate'],
      where: 'id=?',
      whereArgs: [workerId],
      limit: 1,
    );
    if (w.isEmpty) throw StateError('العامل المنفّذ غير موجود');
    final payType = '${w.first['pay_type']}';
    final entitlement = AccountingCalculations.workerIrrigationEntitlement(
      payType: payType,
      irrigationAmount: amount,
      hours: hours,
      hourlyRate: (w.first['hourly_rate'] as num?)?.round() ?? 0,
      percentageRate: (w.first['percentage_rate'] as num?)?.toDouble() ?? 0,
    );
    // لا يجوز أن يتجاوز أجر العامل قيمة السقاية أو يجعل حصة الشركاء سالبة.
    final payableEntitlement = entitlement.clamp(0, amount).toInt();
    if (payableEntitlement <= 0) return 0;
    final id = tx.insert('worker_transactions', {
      'worker_id': workerId,
      'date': date.toIso8601String(),
      'type': 'irrigation',
      'hours': hours,
      'rate_snapshot': w.first['hourly_rate'],
      'percentage_snapshot': w.first['percentage_rate'],
      'amount': payableEntitlement,
      'reference_type': 'irrigation',
      'reference_id': irrigationId,
      'notes': payType == 'hourly'
          ? 'استحقاق بالساعة من السقاية'
          : 'استحقاق نسبة من السقاية',
      'created_by': userId,
    });
    final exp = _accountIdTx(tx, '5000'),
        payable = _workerAccountIdTx(tx, workerId);
    _entry(
      tx,
      description: 'أجر العامل عن السقاية $irrigationId',
      referenceType: 'worker',
      referenceId: id,
      userId: userId,
      date: date,
      lines: [
        {
          'account_id': exp,
          'worker_id': workerId,
          'debit': payableEntitlement,
          'credit': 0,
        },
        {
          'account_id': payable,
          'worker_id': workerId,
          'debit': 0,
          'credit': payableEntitlement,
        },
      ],
    );
    return payableEntitlement;
  }

  void _accruePartnersFromIrrigationTx(
    _P1Tx tx, {
    required int irrigationId,
    required int stationId,
    required int amount,
    required DateTime date,
    int? userId,
  }) {
    final partners = tx.query(
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
      final id = tx.insert('partner_transactions', {
        'partner_id': pid,
        'date': date.toIso8601String(),
        'type': 'share_accrual',
        'amount': value,
        'ownership_snapshot': mode == 'percentage'
            ? p['ownership_percentage']
            : p['shares_count'],
        'reference_type': 'irrigation_profit',
        'reference_id': irrigationId,
        'created_by': userId,
      });
      final equity = _accountIdTx(tx, '3200');
      final payable = _partnerAccountIdTx(tx, pid);
      _entry(
        tx,
        description: 'نصيب الشريك من صافي السقاية $irrigationId',
        referenceType: 'partner',
        referenceId: id,
        userId: userId,
        date: date,
        lines: [
          {
            'account_id': equity,
            'partner_id': pid,
            'debit': value,
            'credit': 0,
          },
          {
            'account_id': payable,
            'partner_id': pid,
            'debit': 0,
            'credit': value,
          },
        ],
      );
    }
  }

  void _reverseIrrigationDieselTx(
    _P1Tx tx,
    int irrigationId,
    int? userId,
    String reason,
  ) {
    final moves = tx.rawQuery(
      "SELECT d.* FROM diesel_movements d WHERE d.irrigation_id=? AND d.reversal_of IS NULL AND NOT EXISTS (SELECT 1 FROM diesel_movements r WHERE r.reversal_of=d.id) ORDER BY d.id",
      [irrigationId],
    );
    for (final move in moves) {
      _reverseEntriesTx(
        tx,
        referenceType: 'diesel_advance',
        referenceId: (move['id'] as num).toInt(),
        reason: reason,
        userId: userId,
      );
      tx.insert('diesel_movements', {
        'station_id': move['station_id'],
        'beneficiary_id': move['beneficiary_id'],
        'irrigation_id': irrigationId,
        'kind': move['kind'],
        'liters': -(move['liters'] as num).toDouble(),
        'unit_price': move['unit_price'],
        'amount': -(move['amount'] as num).toInt(),
        'date': clock.toIso8601String(),
        'notes': 'عكس حركة ${move['id']}: $reason',
        'created_by': userId,
        'reversal_of': move['id'],
      });
    }
  }

  int updateIrrigationBasic({
    required int id,
    required DateTime start,
    required DateTime end,
    int? userId,
  }) {
    if (!end.isAfter(start))
      throw ArgumentError('وقت النهاية يجب أن يكون بعد البداية');
    return database.transaction((tx) {
      final rows = tx.query(
        'irrigations',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['status'] != 'posted') {
        throw StateError('السقاية غير موجودة أو ملغاة/غير مرحّلة');
      }
      final old = rows.first;
      final type = '${old['system_type']}';
      final oldStart = DateTime.parse('${old['start_datetime']}');
      final oldEnd = DateTime.parse('${old['end_datetime']}');
      try {
        _assertPeriodRangeOpen(
          tx,
          oldStart,
          oldEnd,
          stationId: (old['station_id'] as num).toInt(),
        );
        _assertPeriodRangeOpen(
          tx,
          start,
          end,
          stationId: (old['station_id'] as num).toInt(),
        );
      } on StateError {
        throw StateError(
          'لا يمكن تعديل السقاية داخل فترة محاسبية مقفلة. أعد فتح الفترة من شاشة الإقفال مع تسجيل السبب، ثم أعد التعديل؛ لم تُغيّر أي بيانات.',
        );
      }
      final overlap = tx.rawQuery(
        "SELECT id,start_datetime,end_datetime FROM irrigations WHERE id<>? AND pump_id=? AND status!='cancelled' AND start_datetime<? AND end_datetime>? LIMIT 1",
        [id, old['pump_id'], end.toIso8601String(), start.toIso8601String()],
      );
      if (overlap.isNotEmpty) {
        final conflict = overlap.first;
        throw StateError(
          'يتعارض الوقت المحدد مع السقاية رقم ${conflict['id']} من ${conflict['start_datetime']} إلى ${conflict['end_datetime']}. اختر وقتًا لا يتداخل معها.',
        );
      }
      final cfgRows = tx.query('settings', columns: ['key', 'value']);
      final cfg = {
        for (final row in cfgRows) row['key'] as String: row['value'] as String,
      };
      final rounding = cfg['rounding'] ?? 'nearest';
      final partialHour = cfg['partial_hour'] != 'false';
      final oldCloudPeriods = tx.query(
        'cloud_periods',
        where: 'irrigation_id=?',
        whereArgs: [id],
        orderBy: 'start_datetime,id',
      );
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
            shiftedCloudPeriods.add({
              'id': period['id'],
              'delete': true,
              'old': period,
            });
            continue;
          }
          final mins = shiftedEnd.difference(shiftedStart).inMinutes;
          cloudSum += mins;
          shiftedCloudPeriods.add({
            'id': period['id'],
            'start_datetime': shiftedStart.toIso8601String(),
            'end_datetime': shiftedEnd.toIso8601String(),
            'minutes': mins,
            'old': period,
          });
        }
        cloud = cloudSum.clamp(0, end.difference(start).inMinutes).toInt();
      } else {
        // Older irrigation rows may store only a total cloud-minute value.
        // Clamp it to the edited duration just as recordIrrigation does.
        cloud = cloud.clamp(0, end.difference(start).inMinutes).toInt();
      }
      // Cloud stoppage is only billable for solar systems. Keep diesel and
      // equivalent-system recalculation consistent with recordIrrigation.
      final effectiveCloud = type == 'solar' ? cloud : 0;
      final allowMidnight = cfg['allow_midnight_crossing'] == 'true';
      var result = type == 'diesel'
          ? AccountingCalculations.diesel(
              start: start,
              end: end,
              hourlyWaterRate:
                  (old['water_hourly_rate_snapshot'] as num?)?.toInt() ?? 0,
              litersPerHour:
                  (old['diesel_liters_per_hour_snapshot'] as num?)
                      ?.toDouble() ??
                  0,
              dieselPrice: (old['diesel_price_snapshot'] as num?)?.toInt() ?? 0,
              cloudMinutes: effectiveCloud,
              allowMidnightCrossing: allowMidnight,
              rounding: rounding,
              partialHour: partialHour,
            )
          : type == 'solar'
          ? AccountingCalculations.solar(
              start: start,
              end: end,
              hourlyRate:
                  (old['solar_hourly_rate_snapshot'] as num?)?.toInt() ?? 0,
              cloudMinutes: cloud,
              allowMidnightCrossing: allowMidnight,
              rounding: rounding,
              partialHour: partialHour,
            )
          : AccountingCalculations.equivalent(
              start: start,
              end: end,
              hourlyRate:
                  (old['third_type_hourly_rate_snapshot'] as num?)?.toInt() ??
                  0,
              allowMidnightCrossing: allowMidnight,
              rounding: rounding,
              partialHour: partialHour,
            );
      var chargedDiesel = result.dieselAmount;
      var shortageLiters = 0.0;
      final partyTypeForDiesel = '${old['party_type'] ?? 'beneficiary'}';
      final dieselBeneficiaryId = (old['beneficiary_id'] as num?)?.toInt();
      if (type == 'diesel' &&
          partyTypeForDiesel == 'beneficiary' &&
          result.dieselLiters > 0) {
        final stockRows = tx.rawQuery(_beneficiaryDieselStockSql, [
          dieselBeneficiaryId,
          dieselBeneficiaryId,
          dieselBeneficiaryId,
        ]);
        var stockWithoutThisIrrigation =
            (stockRows.first['stock'] as num?)?.toDouble() ?? 0;
        final oldMoves = tx.query(
          'diesel_movements',
          where: 'irrigation_id=?',
          whereArgs: [id],
        );
        for (final move in oldMoves) {
          final liters = (move['liters'] as num?)?.toDouble() ?? 0;
          if ('${move['kind']}' == 'advance')
            stockWithoutThisIrrigation -= liters;
          if ('${move['kind']}' == 'consumption')
            stockWithoutThisIrrigation += liters;
        }
        shortageLiters = (result.dieselLiters - stockWithoutThisIrrigation)
            .clamp(0, result.dieselLiters)
            .toDouble();
        final financialCredit =
            (cfg['diesel_delivery_financial_credit'] ?? '').toLowerCase() ==
            'true';
        if (!financialCredit) {
          chargedDiesel = AccountingCalculations.roundAmount(
            shortageLiters *
                ((old['diesel_price_snapshot'] as num?)?.toDouble() ?? 0),
            rounding,
          );
        }
        result = IrrigationResult(
          minutes: result.minutes,
          cloudMinutes: result.cloudMinutes,
          chargeableMinutes: result.chargeableMinutes,
          waterAmount: result.waterAmount,
          dieselAmount: chargedDiesel,
          totalAmount: result.waterAmount + chargedDiesel,
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
        throw StateError(
          'بيانات صاحب حساب السقاية غير مكتملة؛ لم تُغيّر أي بيانات',
        );
      }
      if (!{'beneficiary', 'worker', 'partner'}.contains(partyType)) {
        throw StateError(
          'نوع صاحب حساب السقاية غير مدعوم؛ لم تُغيّر أي بيانات',
        );
      }

      // Reverse linked wage and partner accrual rows without deleting history.
      final workerRows = tx.query(
        'worker_transactions',
        where:
            "reference_type='irrigation' AND reference_id=? AND type='irrigation' AND NOT EXISTS (SELECT 1 FROM worker_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=worker_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in workerRows) {
        final transactionId = (item['id'] as num).toInt();
        _reverseEntriesTx(
          tx,
          referenceType: 'worker',
          referenceId: transactionId,
          reason: 'إعادة احتساب السقاية رقم $id',
          userId: userId,
          date: oldStart,
        );
        final reversesPersonalIrrigation = '${item['notes'] ?? ''}'.startsWith(
          'خصم قيمة سقاية',
        );
        tx.insert('worker_transactions', {
          'worker_id': item['worker_id'],
          'date': oldStart.toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_edit',
          'reference_id': transactionId,
          'notes':
              '${reversesPersonalIrrigation ? 'عكس سقاية العامل' : 'عكس استحقاق العامل'} لإعادة احتساب السقاية رقم $id',
          'created_by': userId,
        });
      }
      final directPartnerRows = tx.query(
        'partner_transactions',
        where:
            "reference_type='irrigation' AND reference_id=? AND type='irrigation' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=partner_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in directPartnerRows) {
        tx.insert('partner_transactions', {
          'partner_id': item['partner_id'],
          'date': oldStart.toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_edit',
          'reference_id': (item['id'] as num).toInt(),
          'notes':
              'عكس سقاية الشريك: خصم سابق من السقاية رقم $id لإعادة احتسابها',
          'created_by': userId,
        });
      }
      final partnerRows = tx.query(
        'partner_transactions',
        where:
            "reference_type='irrigation_profit' AND reference_id=? AND type='share_accrual' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=partner_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in partnerRows) {
        final transactionId = (item['id'] as num).toInt();
        final priorAdjustments = tx.query(
          'partner_transactions',
          where:
              "reference_type='partner_profit_adjustment' AND reference_id=? AND type='share_adjustment' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='partner_profit_adjustment_cancel' AND rev.reference_id=partner_transactions.id AND rev.type='share_adjustment_reversal')",
          whereArgs: [transactionId],
        );
        for (final adjustment in priorAdjustments) {
          final adjustmentId = (adjustment['id'] as num).toInt();
          _reverseEntriesTx(
            tx,
            referenceType: 'partner_profit_adjustment',
            referenceId: adjustmentId,
            reason: 'إعادة احتساب السقاية رقم $id',
            userId: userId,
            date: oldStart,
          );
          tx.insert('partner_transactions', {
            'partner_id': adjustment['partner_id'],
            'date': oldStart.toIso8601String(),
            'type': 'share_adjustment_reversal',
            'amount': (adjustment['amount'] as num).round(),
            'reference_type': 'partner_profit_adjustment_cancel',
            'reference_id': adjustmentId,
            'notes': 'عكس تسوية حصة الشريك بسبب تعديل السقاية رقم $id',
            'created_by': userId,
          });
        }
        _reverseEntriesTx(
          tx,
          referenceType: 'partner',
          referenceId: transactionId,
          reason: 'إعادة احتساب السقاية رقم $id',
          userId: userId,
          date: oldStart,
        );
        tx.insert('partner_transactions', {
          'partner_id': item['partner_id'],
          'date': oldStart.toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_edit',
          'reference_id': transactionId,
          'notes': 'عكس حصة الشريك السابقة من السقاية رقم $id لإعادة احتسابها',
          'created_by': userId,
        });
      }
      _reverseEntriesTx(
        tx,
        referenceType: 'irrigation',
        referenceId: id,
        reason: 'تصحيح بيانات السقاية رقم $id',
        userId: userId,
        date: oldStart,
      );
      final waterRevenue = _accountIdTx(tx, '4000');
      final fuelRevenue = _accountIdTx(tx, '4010');
      final receivable = partyType == 'worker'
          ? _workerAccountIdTx(tx, workerId!)
          : partyType == 'partner'
          ? _partnerAccountIdTx(tx, partnerId!)
          : _accountIdTx(tx, '1200');
      final lines = <Map<String, Object?>>[
        {
          'account_id': receivable,
          'beneficiary_id': beneficiaryId,
          'worker_id': workerId,
          'partner_id': partnerId,
          'debit': result.totalAmount,
          'credit': 0,
          'memo': partyType == 'beneficiary'
              ? 'استحقاق سقاية بعد التعديل'
              : 'خصم سقاية من مستحقات الطرف بعد التعديل',
        },
      ];
      if (result.waterAmount > 0) {
        lines.add({
          'account_id': waterRevenue,
          'debit': 0,
          'credit': result.waterAmount,
          'memo': 'إيراد السقي بعد التعديل',
        });
      }
      if (result.dieselAmount > 0) {
        lines.add({
          'account_id': fuelRevenue,
          'debit': 0,
          'credit': result.dieselAmount,
          'memo': 'قيمة ديزل السقي بعد التعديل',
        });
      }
      if (result.totalAmount > 0) {
        _entry(
          tx,
          description: 'تعديل سقاية رقم $id',
          referenceType: 'irrigation',
          referenceId: id,
          lines: lines,
          userId: userId,
          date: start,
          stationId: (old['station_id'] as num).toInt(),
        );
      }
      final now = clock.toIso8601String();
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
      tx.update('irrigations', values, where: 'id=?', whereArgs: [id]);

      // Keep detailed cloud intervals aligned with the edited irrigation window.
      for (final period in shiftedCloudPeriods) {
        final periodId = (period['id'] as num).toInt();
        if (period['delete'] == true) {
          tx.update(
            'cloud_periods',
            {
              'start_datetime': start.toIso8601String(),
              'end_datetime': start.toIso8601String(),
              'minutes': 0,
            },
            where: 'id=?',
            whereArgs: [periodId],
          );
        } else {
          tx.update(
            'cloud_periods',
            {
              'start_datetime': period['start_datetime'],
              'end_datetime': period['end_datetime'],
              'minutes': period['minutes'],
            },
            where: 'id=?',
            whereArgs: [periodId],
          );
        }
      }

      // Keep original stock movements and append signed, linked reversals.
      final oldDieselMoves = tx.query(
        'diesel_movements',
        where: 'irrigation_id=?',
        whereArgs: [id],
        orderBy: 'id',
      );
      _reverseIrrigationDieselTx(tx, id, userId, 'تعديل السقاية');
      if (type == 'diesel' &&
          partyType == 'beneficiary' &&
          result.dieselLiters > 0) {
        final price = (old['diesel_price_snapshot'] as num?)?.toInt() ?? 0;
        if (shortageLiters > 0) {
          tx.insert('diesel_movements', {
            'beneficiary_id': beneficiaryId,
            'irrigation_id': id,
            'kind': 'advance',
            'liters': shortageLiters,
            'unit_price': price,
            'amount': AccountingCalculations.roundAmount(
              shortageLiters * price,
              rounding,
            ),
            'date': start.toIso8601String(),
            'created_by': userId,
            'notes': 'سلفة ديزل تلقائية (بعد تعديل السقاية)',
          });
        }
        tx.insert('diesel_movements', {
          'beneficiary_id': beneficiaryId,
          'irrigation_id': id,
          'kind': 'consumption',
          'liters': result.dieselLiters,
          'unit_price': price,
          'amount': result.dieselAmount,
          'date': start.toIso8601String(),
          'created_by': userId,
          'notes': 'استهلاك السقاية (بعد التعديل)',
        });
      }
      // Capture the persisted post-recalculation state, not the planning list:
      // this makes deleted/updated/inserted records reviewable from the audit log.
      final newCloudPeriods = tx.query(
        'cloud_periods',
        where: 'irrigation_id=?',
        whereArgs: [id],
        orderBy: 'start_datetime,id',
      );
      final newDieselMoves = tx.query(
        'diesel_movements',
        where: 'irrigation_id=?',
        whereArgs: [id],
        orderBy: 'id',
      );
      Map<int, Map<String, Object?>> indexById(
        List<Map<String, Object?>> rows,
      ) => {
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
                ? (newCloudById[(before['id'] as num).toInt()].toString() ==
                          before.toString()
                      ? 'retained'
                      : 'updated')
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
                ? (newDieselById[(before['id'] as num).toInt()].toString() ==
                          before.toString()
                      ? 'retained'
                      : 'updated')
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
      if (oldCloudPeriods.isNotEmpty ||
          oldDieselMoves.isNotEmpty ||
          newCloudPeriods.isNotEmpty ||
          newDieselMoves.isNotEmpty) {
        database.auditTx(
          tx,
          userId: userId,
          operation: 'update',
          table: 'irrigation_related_movements',
          recordId: id,
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
          reason:
              'إعادة احتساب الحركات التابعة للسقاية؛ يتضمن السجل حالة كل حركة (محتفظ بها/معدلة/محذوفة/مضافة) والقيم قبل وبعد',
        );
      }

      // Recreate wage accruals and partner allocations from the edited amount.
      var totalWorkerEntitlement = 0;
      final wageWorkers = tx.query(
        'workers',
        columns: ['id'],
        where:
            "station_id=? AND active=1 AND pay_type IN ('hourly', 'percentage')",
        whereArgs: [(old['station_id'] as num).toInt()],
        orderBy: 'id',
      );
      for (final wageWorker in wageWorkers) {
        totalWorkerEntitlement += _accrueWorkerIrrigationTx(
          tx,
          workerId: (wageWorker['id'] as num).toInt(),
          irrigationId: id,
          amount: result.totalAmount,
          hours: result.chargeableMinutes / 60.0,
          date: start,
          userId: userId,
        );
      }
      if (partyType == 'worker') {
        tx.insert('worker_transactions', {
          'worker_id': workerId,
          'date': start.toIso8601String(),
          'type': 'irrigation',
          'amount': result.totalAmount,
          'reference_type': 'irrigation',
          'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب العامل',
          'created_by': userId,
        });
      } else if (partyType == 'partner') {
        tx.insert('partner_transactions', {
          'partner_id': partnerId,
          'date': start.toIso8601String(),
          'type': 'irrigation',
          'amount': result.totalAmount,
          'ownership_snapshot': null,
          'reference_type': 'irrigation',
          'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب الشريك',
          'created_by': userId,
        });
      }
      final partnerPool = (result.totalAmount - totalWorkerEntitlement)
          .clamp(0, result.totalAmount)
          .toInt();
      if (partnerPool > 0) {
        _accruePartnersFromIrrigationTx(
          tx,
          irrigationId: id,
          stationId: (old['station_id'] as num).toInt(),
          amount: partnerPool,
          date: start,
          userId: userId,
        );
      }
      database.auditTx(
        tx,
        userId: userId,
        operation: 'update',
        table: 'irrigations',
        recordId: id,
        oldValues: old,
        newValues: values,
        reason: 'تعديل وقت السقاية وإعادة ترحيل قيدها',
      );
      return result.totalAmount;
    }, captureSyncTables: const {'irrigations'});
  }

  void cancelIrrigation(int id, int userId, String reason) {
    if (reason.trim().isEmpty) throw ArgumentError('سبب إلغاء السقاية مطلوب');
    database.transaction((tx) {
      final rows = tx.query(
        'irrigations',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['status'] == 'cancelled') {
        throw StateError('السقاية غير موجودة أو ملغاة مسبقًا');
      }
      final old = rows.first;
      final cancelledAt = clock.toIso8601String();
      _assertPeriodRangeOpen(
        tx,
        DateTime.parse('${old['start_datetime']}'),
        DateTime.parse('${old['end_datetime']}'),
        stationId: (old['station_id'] as num).toInt(),
      );
      _assertPeriodOpen(
        tx,
        clock,
        stationId: (old['station_id'] as num).toInt(),
      );
      tx.update(
        'irrigations',
        {
          'status': 'cancelled',
          'cancel_reason': reason.trim(),
          'cancelled_at': cancelledAt,
          'notes': '${old['notes'] ?? ''}\nإلغاء: $reason',
          'updated_at': cancelledAt,
        },
        where: 'id=?',
        whereArgs: [id],
      );
      // 1) عكس الدفعات المرتبطة (إن وُجدت). يُسمح برصيد صندوق سالب
      final pays = tx.query(
        'payments',
        where:
            "(irrigation_id=? OR (irrigation_id IS NULL AND reference_number=?)) AND status='posted'",
        whereArgs: [id, 'IRR-$id'],
      );
      for (final pay in pays) {
        _cancelPaymentRowTx(tx, pay, reason: reason, userId: userId);
      }
      // 2) قيود عكسية لباقي قيود السقاية (الاستحقاق، وقيود الدفعات القديمة المربوطة بالسقاية)
      _reverseEntriesTx(
        tx,
        referenceType: 'irrigation',
        referenceId: id,
        reason: reason,
        userId: userId,
      );
      _reverseIrrigationDieselTx(tx, id, userId, reason);
      // 4) عكس كل استحقاقات الأطراف المرتبطة بالسقاية (العامل والشركاء).
      // لا نحذف الحركة الأصلية حتى يبقى كشف الحساب قابلاً للتدقيق.
      final workerAccruals = tx.query(
        'worker_transactions',
        where:
            "reference_type='irrigation' AND reference_id=? AND type='irrigation' AND NOT EXISTS (SELECT 1 FROM worker_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=worker_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in workerAccruals) {
        _reverseEntriesTx(
          tx,
          referenceType: 'worker',
          referenceId: (item['id'] as num).toInt(),
          reason: reason,
          userId: userId,
        );
        final originalNotes = '${item['notes'] ?? ''}';
        final reversesPersonalIrrigation = originalNotes.startsWith(
          'خصم قيمة سقاية',
        );
        tx.insert('worker_transactions', {
          'worker_id': item['worker_id'],
          'date': clock.toIso8601String(),
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
      final directPartnerIrrigations = tx.query(
        'partner_transactions',
        where:
            "reference_type='irrigation' AND reference_id=? AND type='irrigation' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=partner_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in directPartnerIrrigations) {
        tx.insert('partner_transactions', {
          'partner_id': item['partner_id'],
          'date': clock.toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': 'عكس سقاية الشريك رقم $id: $reason',
          'created_by': userId,
        });
      }
      final partnerAccruals = tx.query(
        'partner_transactions',
        where:
            "reference_type='irrigation_profit' AND reference_id=? AND type='share_accrual' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='irrigation_edit' AND rev.reference_id=partner_transactions.id AND rev.type='irrigation_reversal')",
        whereArgs: [id],
      );
      for (final item in partnerAccruals) {
        final accrualId = (item['id'] as num).toInt();
        _reverseEntriesTx(
          tx,
          referenceType: 'partner',
          referenceId: accrualId,
          reason: reason,
          userId: userId,
        );
        // إذا سُوّي فائض هذه الحصة عند توزيع أرباح الفترة، نعكس التسوية أيضًا
        // حتى لا يبقى خصم من حساب الشريك بعد إلغاء السقاية الأصلية.
        final adjustments = tx.query(
          'partner_transactions',
          where:
              "reference_type='partner_profit_adjustment' AND reference_id=? AND type='share_adjustment' AND NOT EXISTS (SELECT 1 FROM partner_transactions rev WHERE rev.reference_type='partner_profit_adjustment_cancel' AND rev.reference_id=partner_transactions.id)",
          whereArgs: [accrualId],
        );
        for (final adjustment in adjustments) {
          final adjustmentId = (adjustment['id'] as num).toInt();
          _reverseEntriesTx(
            tx,
            referenceType: 'partner_profit_adjustment',
            referenceId: adjustmentId,
            reason: 'إلغاء السقاية الأصلية: $reason',
            userId: userId,
          );
          tx.insert('partner_transactions', {
            'partner_id': item['partner_id'],
            'date': clock.toIso8601String(),
            'type': 'share_adjustment_reversal',
            'amount': (adjustment['amount'] as num).round(),
            'reference_type': 'partner_profit_adjustment_cancel',
            'reference_id': adjustmentId,
            'notes': 'عكس تسوية حصة الشريك بسبب إلغاء السقاية رقم $id',
            'created_by': userId,
          });
        }
        tx.insert('partner_transactions', {
          'partner_id': item['partner_id'],
          'date': clock.toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (item['amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': 'عكس نصيب الشريك من السقاية رقم $id: $reason',
          'created_by': userId,
        });
      }
      database.auditTx(
        tx,
        userId: userId,
        operation: 'cancel',
        table: 'irrigations',
        recordId: id,
        oldValues: old,
        reason: reason,
      );
    }, captureSyncTables: const {'irrigations'});
  }

  void _cancelPaymentRowTx(
    _P1Tx tx,
    Map<String, Object?> pay, {
    required String reason,
    int? userId,
  }) {
    final payId = (pay['id'] as num).toInt();
    // حارس إضافي داخل المعاملة: لا نسمح بعكس الدفعة إذا لم تعد مرحّلة.
    // يمنع تكرار تعديل الصندوق أو إنشاء حركة عكسية للطرف عند استدعاء المساعد
    // من مسار آخر أو تمرير سجل قديم.
    final currentPayment = tx.query(
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
    tx.update(
      'payments',
      {'status': 'cancelled', 'notes': '${pay['notes'] ?? ''}\nإلغاء: $reason'},
      where: 'id=?',
      whereArgs: [payId],
    );
    if (incoming) {
      // عكس القبض يُخرج المبلغ من الصندوق؛ يُسمح بالرصيد السالب حسب سياسة الصراف.
      tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
        [amount, cashboxId],
      );
    } else {
      tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
        [amount, cashboxId],
      );
    }
    // القيد: الحديث مرتبط بالدفعة نفسها؛ القديم كان مرتبطًا بالسقاية بنفس وصف القيد.
    var n = _reverseEntriesTx(
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
        n = _reverseEntriesTx(
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
        tx.rawUpdate(
          'UPDATE irrigations SET paid_amount=MAX(paid_amount-?,0) WHERE id=?',
          [amount, irrId],
        );
      }
    }
    final now = clock.toIso8601String();
    if (pay['worker_id'] != null) {
      tx.insert('worker_transactions', {
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
      tx.insert('partner_transactions', {
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
    database.auditTx(
      tx,
      userId: userId,
      operation: 'cancel',
      table: 'payments',
      recordId: payId,
      oldValues: pay,
      reason: reason,
    );
  }
}

class _P1Tx {
  final Database db;
  final int station;
  _P1Tx(this.db, this.station);
  List<Map<String, Object?>> rawQuery(
    String sql, [
    List<Object?> args = const [],
  ]) => db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList();
  List<Map<String, Object?>> query(
    String table, {
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) {
    if (table == 'settings')
      return rawQuery(
        'SELECT key,value FROM station_settings WHERE station_id=?',
        [station],
      );
    return rawQuery(
      'SELECT ${columns?.join(',') ?? '*'} FROM $table${where == null ? '' : ' WHERE $where'}${orderBy == null ? '' : ' ORDER BY $orderBy'}${limit == null ? '' : ' LIMIT $limit'}',
      whereArgs ?? [],
    );
  }

  int insert(String table, Map<String, Object?> input) {
    final values = Map<String, Object?>.from(input);
    if (const {
      'payments',
      'diesel_movements',
      'worker_transactions',
      'partner_transactions',
      'journal_entries',
    }.contains(table))
      values['station_id'] = station;
    db.execute(
      'INSERT INTO $table (${values.keys.join(',')}) VALUES (${List.filled(values.length, '?').join(',')})',
      values.values.toList(),
    );
    return db.lastInsertRowId;
  }

  int rawUpdate(String sql, [List<Object?> args = const []]) {
    db.execute(sql, args);
    return db.updatedRows;
  }

  int update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
  }) => rawUpdate(
    'UPDATE $table SET ${values.keys.map((k) => '$k=?').join(',')}${where == null ? '' : ' WHERE $where'}',
    [...values.values, ...?whereArgs],
  );
  int delete(String table, {String? where, List<Object?>? whereArgs}) {
    if (table != 'cloud_periods')
      throw StateError('P1 forbids deleting financial history');
    return rawUpdate(
      'DELETE FROM $table${where == null ? '' : ' WHERE $where'}',
      whereArgs ?? [],
    );
  }
}

class _P1Db {
  final _P1Tx tx;
  final DateTime clock;
  _P1Db(this.tx, this.clock);
  T transaction<T>(
    T Function(_P1Tx) action, {
    Set<String>? captureSyncTables,
  }) => action(tx);
  void auditTx(
    _P1Tx tx, {
    int? userId,
    required String operation,
    required String table,
    int? recordId,
    Object? oldValues,
    Object? newValues,
    String? reason,
  }) {
    tx.insert('audit_logs', {
      'user_id': userId,
      'operation': operation,
      'table_name': table,
      'record_id': recordId,
      'old_values': oldValues == null ? null : jsonEncode(oldValues),
      'new_values': newValues == null ? null : jsonEncode(newValues),
      'reason': reason,
      'created_at': clock.toIso8601String(),
    });
  }
}

extension _P1Sync on SaqiaServer {
  void _ensureP1Schema() {
    for (final item in const [
      ['irrigations', 'cancel_reason', 'TEXT'],
      ['irrigations', 'cancelled_at', 'TEXT'],
      ['payments', 'irrigation_id', 'INTEGER REFERENCES irrigations(id)'],
      [
        'diesel_movements',
        'reversal_of',
        'INTEGER REFERENCES diesel_movements(id)',
      ],
    ]) {
      if (!_hasTable(item[0])) continue;
      final cols = db.select('PRAGMA table_info(${item[0]})');
      if (!cols.any((r) => r['name'] == item[1]))
        db.execute('ALTER TABLE ${item[0]} ADD COLUMN ${item[1]} ${item[2]}');
    }
    if (_hasTable('diesel_movements'))
      db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_diesel_reversal ON diesel_movements(reversal_of) WHERE reversal_of IS NOT NULL',
      );
  }

  void _applyP1Irrigation({
    required int station,
    required String entityKey,
    required Map payload,
    required int? userId,
    required String? role,
  }) {
    if (!const {'manager', 'accountant'}.contains(role) ||
        userId == null ||
        _stationForUser(userId) != station) {
      throw StateError('صلاحية تعديل السقاية غير متاحة');
    }
    if (payload['_p1_effect_ids'] is! Map)
      throw StateError(
        'بيان آثار تعديل السقاية مفقود؛ يلزم مراجعة الحدث القديم',
      );
    final globalId = payload['_global_id'];
    if (entityKey != 'irrigations:$globalId')
      throw StateError('هوية تعديل السقاية غير مطابقة');
    final roots = db.select(
      "SELECT i.* FROM sync_entity_links l JOIN irrigations i ON i.id=l.local_id AND i.station_id=l.station_id WHERE l.station_id=? AND l.entity_type='irrigations' AND l.global_id=?",
      [station, globalId],
    );
    if (roots.length != 1 || roots.single['status'] != 'posted')
      throw StateError('السقاية غير موجودة أو ملغاة');
    final old = roots.single;
    final id = (old['id'] as num).toInt();
    // Refuse inconsistent historical ownership instead of touching another station.
    for (final table in ['worker_transactions', 'partner_transactions']) {
      if (db.select(
        "SELECT 1 FROM $table WHERE reference_type IN ('irrigation','irrigation_profit') AND reference_id=? AND (station_id IS NULL OR station_id<>?) LIMIT 1",
        [id, station],
      ).isNotEmpty) {
        throw StateError('ملكية استحقاق تابع للسقاية غير مثبتة');
      }
    }
    if (db.select(
      'SELECT 1 FROM diesel_movements WHERE irrigation_id=? AND (station_id IS NULL OR station_id<>?) LIMIT 1',
      [id, station],
    ).isNotEmpty) {
      throw StateError('ملكية ديزل السقاية غير مثبتة');
    }
    for (final payment in db.select(
      "SELECT * FROM payments WHERE (irrigation_id=? OR (irrigation_id IS NULL AND reference_number=?)) AND status='posted'",
      [id, 'IRR-$id'],
    )) {
      if (payment['irrigation_id'] != id ||
          payment['station_id'] != station ||
          payment['beneficiary_id'] != old['beneficiary_id'] ||
          !_owns(
            'cashboxes',
            (payment['cashbox_id'] as num).toInt(),
            station,
          )) {
        throw StateError(
          'ربط القبض التاريخي بالسقاية غير مثبت؛ يلزم مراجعة السند',
        );
      }
    }
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع السقاية مفقودة');
    for (final entry in const {
      'pump_id': 'pumps',
      'beneficiary_id': 'beneficiaries',
      'worker_id': 'workers',
      'partner_id': 'partners',
    }.entries) {
      final value = payload[entry.key] == null
          ? null
          : _resolveSyncReference(
              station: station,
              entityType: entry.value,
              column: entry.key,
              references: refs,
            );
      if (value != old[entry.key])
        throw StateError('لا يسمح بتغيير صاحب السقاية أو مضختها');
    }
    for (final entry in const {
      'session_id': 'irrigation_sessions',
      'queue_entry_id': 'queue_entries',
      'booking_id': 'booking_requests',
    }.entries) {
      final value = payload[entry.key] == null
          ? null
          : _resolveOperationalSyncRef(
              station: station,
              entityType: entry.value,
              column: entry.key,
              references: refs,
              beneficiaryId: old['beneficiary_id'] as int?,
            );
      if (value != old[entry.key])
        throw StateError('لا يسمح بتغيير روابط تشغيل السقاية');
    }
    // P0 stores zero for inactive tariff fields on the server. Only the
    // effective system's immutable prices participate in P1 calculations.
    final immutable = <String>['system_type', 'party_type'];
    switch (old['system_type']) {
      case 'diesel':
        immutable.addAll([
          'water_hourly_rate_snapshot',
          'diesel_liters_per_hour_snapshot',
          'diesel_price_snapshot',
        ]);
      case 'solar':
        immutable.add('solar_hourly_rate_snapshot');
      case 'equivalent_hybrid':
        immutable.add('third_type_hourly_rate_snapshot');
    }
    for (final key in immutable) {
      if (payload[key] != old[key])
        throw StateError('لا يسمح بتغيير لقطة أسعار السقاية أو نوعها: $key');
    }
    final clock = DateTime.tryParse('${payload['updated_at']}');
    if (clock == null) throw StateError('تاريخ تعديل السقاية مطلوب');
    final service = _P1Mutations(this, station, clock);
    if (payload['status'] == 'cancelled') {
      if (payload['cancelled_at'] != payload['updated_at'] ||
          '${payload['cancel_reason'] ?? ''}'.trim().isEmpty)
        throw StateError('سبب وتاريخ الإلغاء مطلوبان');
      service.cancelIrrigation(id, userId, payload['cancel_reason'].toString());
    } else if (payload['status'] == 'posted') {
      final start = DateTime.tryParse('${payload['start_datetime']}');
      final end = DateTime.tryParse('${payload['end_datetime']}');
      if (start == null || end == null)
        throw StateError('أوقات السقاية غير صالحة');
      service.updateIrrigationBasic(
        id: id,
        start: start,
        end: end,
        userId: userId,
      );
    } else {
      throw StateError('حالة تعديل السقاية غير مدعومة');
    }
    final saved = db.select('SELECT * FROM irrigations WHERE id=?', [
      id,
    ]).single;
    for (final key in const [
      'minutes',
      'cloud_minutes',
      'chargeable_minutes',
      'water_amount',
      'diesel_amount',
      'total_amount',
      'paid_amount',
      'start_datetime',
      'end_datetime',
    ]) {
      if (payload[key] != saved[key])
        throw StateError('حساب تعديل السقاية لا يطابق لقطة العميل: $key');
    }
  }

  static const _p1Tables = [
    'payments',
    'worker_transactions',
    'partner_transactions',
    'diesel_movements',
    'cloud_periods',
    'journal_entries',
    'journal_lines',
    'cashboxes',
    'irrigation_sessions',
    'queue_entries',
    'booking_requests',
  ];
  Map<String, Map<int, Map<String, Object?>>> _p1Snapshot(int station) {
    final result = <String, Map<int, Map<String, Object?>>>{};
    for (final table in _p1Tables) {
      if (!_hasTable(table)) {
        result[table] = {};
        continue;
      }
      final scope = switch (table) {
        'journal_lines' =>
          'id IN (SELECT jl.id FROM journal_lines jl JOIN journal_entries j ON j.id=jl.journal_entry_id WHERE j.station_id=?)',
        'cloud_periods' =>
          'irrigation_id IN (SELECT id FROM irrigations WHERE station_id=?)',
        'irrigation_sessions' || 'queue_entries' || 'booking_requests' =>
          'beneficiary_id IN (SELECT id FROM beneficiaries WHERE station_id=?)',
        _ => 'station_id=?',
      };
      result[table] = {
        for (final row in db.select(
          'SELECT * FROM $table WHERE $scope ORDER BY id',
          [station],
        ))
          (row['id'] as num).toInt(): Map<String, Object?>.from(row),
      };
    }
    return result;
  }

  void _appendP1Effects(
    int station,
    String device,
    Map payload,
    String now,
    Map<String, Map<int, Map<String, Object?>>> before,
  ) {
    final after = _p1Snapshot(station);
    final manifest = payload['_p1_effect_ids'] as Map;
    for (final table in _p1Tables) {
      final old = before[table]!;
      final rows = after[table]!;
      if (old.keys.any((id) => !rows.containsKey(id)))
        throw StateError('لا يسمح بفقد أثر سابق أثناء تعديل السقاية');
      final created = rows.keys.where((id) => !old.containsKey(id)).toList()
        ..sort();
      final requested = manifest[table];
      if (requested is! List ||
          requested.length != created.length ||
          requested.any((id) => id is! String))
        throw StateError('بيان آثار P1 غير مطابق: $table');
      for (final id in rows.keys) {
        if (old.containsKey(id) &&
            _canonicalSyncJson(old[id]) == _canonicalSyncJson(rows[id]))
          continue;
        _appendSyncProjectionRow(
          station: station,
          sourceDevice: device,
          publishToOrigin: true,
          now: now,
          table: table,
          localId: id,
          requestedGlobalId: old.containsKey(id)
              ? null
              : requested[created.indexOf(id)] as String,
        );
      }
    }
  }
}
