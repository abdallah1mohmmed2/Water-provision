part of 'server.dart';

/// P2 reuses the verified P0 receipt posting and P1 reversal implementation.
extension _P2Sync on SaqiaServer {
  static const _p2Tables = [
    'payments',
    'worker_transactions',
    'partner_transactions',
    'journal_entries',
    'journal_lines',
    'cashboxes',
    'irrigations',
  ];

  void _ensureP2Schema() {
    if (!_hasTable('payments')) return;
    for (final entry in const {
      'cancel_reason': 'TEXT',
      'cancelled_at': 'TEXT',
      'updated_at': 'TEXT',
      'currency': 'TEXT',
      'replaces_payment_id': 'INTEGER REFERENCES payments(id)',
    }.entries) {
      if (!db
          .select('PRAGMA table_info(payments)')
          .any((r) => r['name'] == entry.key)) {
        db.execute(
          'ALTER TABLE payments ADD COLUMN ${entry.key} ${entry.value}',
        );
      }
    }
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_payment_replacement ON payments(replaces_payment_id) WHERE replaces_payment_id IS NOT NULL',
    );
  }

  void _validateP2Payment(int station, Map payload, {bool creating = true}) {
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع السند مفقودة');
    final parties = {
      'beneficiary_id': 'beneficiaries',
      'worker_id': 'workers',
      'partner_id': 'partners',
    };
    if (parties.keys.where((k) => payload[k] != null).length != 1)
      throw StateError('يجب تحديد طرف واحد للسند');
    for (final e in parties.entries) {
      if (payload[e.key] != null)
        _resolveSyncReference(
          station: station,
          entityType: e.value,
          column: e.key,
          references: refs,
        );
    }
    final methodId = _resolveSyncReference(
      station: station,
      entityType: 'payment_methods',
      column: 'payment_method_id',
      references: refs,
    );
    final cashId = _resolveSyncReference(
      station: station,
      entityType: 'cashboxes',
      column: 'cashbox_id',
      references: refs,
    );
    final method = db.select(
      'SELECT * FROM payment_methods WHERE id=? AND station_id=?',
      [methodId, station],
    ).single;
    final cash = db.select(
      'SELECT * FROM cashboxes WHERE id=? AND station_id=?',
      [cashId, station],
    ).single;
    if (creating && (method['active'] != 1 || cash['active'] != 1))
      throw StateError('طريقة الدفع أو الصندوق غير نشط');
    if (creating &&
        method['cashbox_id'] != null &&
        method['cashbox_id'] != cashId)
      throw StateError('الصندوق لا يطابق طريقة الدفع');
    if (payload['currency'] != null && payload['currency'] != cash['currency'])
      throw StateError('عملة السند لا تطابق الصندوق');
    final amount = payload['amount'];
    if (amount is! num || amount <= 0 || amount != amount.round())
      throw StateError('مبلغ السند غير صالح');
    final date = DateTime.tryParse('${payload['date']}');
    if (date == null) throw StateError('تاريخ السند غير صالح');
    // Older protocol fixtures without period tables retain the existing P0 contract.
    if (_hasTable('period_closures'))
      _P1Mutations(
        this,
        station,
        date,
      )._assertPeriodOpen(_P1Tx(db, station), date, stationId: station);
  }

  int _createP2Payment(
    int station,
    String key,
    Map payload,
    String now,
    int userId,
    String role, {
    int? replaces,
  }) {
    _validateP2Payment(station, payload);
    if (payload['status'] != 'posted')
      throw StateError('الإنشاء يتطلب سنداً مرحلاً');
    final refs = payload['_global_refs'] as Map;
    final global = payload['_global_id'];
    if (key != 'payments:$global' ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
        ).hasMatch('$global'))
      throw StateError('هوية السند غير صالحة');
    if (db.select(
      "SELECT 1 FROM sync_entity_links WHERE station_id=? AND entity_type='payments' AND global_id=?",
      [station, global],
    ).isNotEmpty)
      throw StateError('السند موجود مسبقاً');
    if (replaces == null && payload['replaces_payment_id'] != null)
      throw StateError('البديل يحتاج أمر الاستبدال الذري');
    if (payload['beneficiary_id'] != null) {
      _applySyncPaymentReceipt(
        station: station,
        entityKey: key,
        payload: payload,
        now: now,
        userId: userId,
        role: role,
      );
    } else {
      if (payload['irrigation_id'] != null)
        throw StateError('قبض السقاية للمستفيد فقط');
      final worker = payload['worker_id'] != null;
      final partyColumn = worker ? 'worker_id' : 'partner_id';
      final party = _resolveSyncReference(
        station: station,
        entityType: worker ? 'workers' : 'partners',
        column: partyColumn,
        references: refs,
      );
      final cash = _resolveSyncReference(
        station: station,
        entityType: 'cashboxes',
        column: 'cashbox_id',
        references: refs,
      );
      final method = _resolveSyncReference(
        station: station,
        entityType: 'payment_methods',
        column: 'payment_method_id',
        references: refs,
      );
      final amount = (payload['amount'] as num).toInt();
      final tx = _P1Tx(db, station);
      final id = tx.insert('payments', {
        'station_id': station,
        partyColumn: party,
        'amount': amount,
        'date': payload['date'],
        'payment_method_id': method,
        'cashbox_id': cash,
        'reference_number': payload['reference_number'],
        'notes': payload['notes'],
        'status': 'posted',
        'created_by': userId,
      });
      tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=? AND station_id=?',
        [amount, cash, station],
      );
      final clock = DateTime.parse(now);
      _P1Mutations(this, station, clock)._entry(
        tx,
        description: 'دفع لطرف رقم $id',
        referenceType: 'payment',
        referenceId: id,
        userId: userId,
        lines: [
          {
            'account_id': _accountId(_syncCashboxLedgerCode(station, cash)),
            'debit': 0,
            'credit': amount,
          },
          {
            'account_id': worker
                ? _syncWorkerAccountId(party)
                : _syncPartnerAccountId(party),
            partyColumn: party,
            'debit': amount,
            'credit': 0,
          },
        ],
      );
      tx.insert(worker ? 'worker_transactions' : 'partner_transactions', {
        partyColumn: party,
        'date': payload['date'],
        'type': 'payment',
        'amount': amount,
        if (worker) 'cashbox_id': cash,
        'reference_type': 'payment',
        'reference_id': id,
        'notes': payload['notes'],
        'created_by': userId,
      });
      db.execute(
        "INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,'payments',?,?,?)",
        [station, global, id, now],
      );
    }
    final id =
        (db.select(
                  "SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='payments' AND global_id=?",
                  [station, global],
                ).single['local_id']
                as num)
            .toInt();
    db.execute(
      'UPDATE payments SET currency=?,replaces_payment_id=?,updated_at=? WHERE id=?',
      [payload['currency'], replaces, payload['updated_at'], id],
    );
    return id;
  }

  void _applyP2Payment({
    required int station,
    required String entityKey,
    required String operation,
    required Map payload,
    required String now,
    required int? userId,
    required String? role,
  }) {
    _ensureP2Schema();
    if (!const {'manager', 'accountant'}.contains(role) ||
        userId == null ||
        _stationForUser(userId) != station)
      throw StateError('صلاحية السند غير متاحة');
    if (operation == 'delete')
      throw StateError('حذف السند المالي ممنوع؛ استخدم الإلغاء');
    if (operation == 'create') {
      if (payload['beneficiary_id'] == null &&
          payload['_p2_effect_ids'] is! Map)
        throw StateError('بيان آثار الصرف مفقود');
      _createP2Payment(station, entityKey, payload, now, userId, role!);
      return;
    }
    if (operation != 'update' || payload['_p2_effect_ids'] is! Map)
      throw StateError('أمر تعديل السند غير صالح');
    if (entityKey != 'payments:${payload['_global_id']}')
      throw StateError('هوية السند غير مطابقة');
    final roots = db.select(
      "SELECT p.* FROM payments p JOIN sync_entity_links l ON l.local_id=p.id AND l.station_id=p.station_id WHERE l.station_id=? AND l.entity_type='payments' AND l.global_id=?",
      [station, payload['_global_id']],
    );
    if (roots.length != 1 || roots.single['status'] != 'posted')
      throw StateError('السند غير موجود أو ملغى');
    final old = roots.single;
    final id = (old['id'] as num).toInt();
    _validateP2Payment(station, payload, creating: false);
    final refs = payload['_global_refs'] as Map;
    for (final e in const {
      'beneficiary_id': 'beneficiaries',
      'worker_id': 'workers',
      'partner_id': 'partners',
      'cashbox_id': 'cashboxes',
      'payment_method_id': 'payment_methods',
      'irrigation_id': 'irrigations',
      'replaces_payment_id': 'payments',
    }.entries) {
      final value = payload[e.key] == null
          ? null
          : _resolveSyncReference(
              station: station,
              entityType: e.value,
              column: e.key,
              references: refs,
            );
      if (value != old[e.key])
        throw StateError('لا يسمح بتعديل أطراف السند أو روابطه مباشرة');
    }
    for (final key in ['amount', 'date', 'currency']) {
      if (payload[key] != old[key])
        throw StateError('التعديل المالي يتطلب استبدال السند: $key');
    }
    final cancelled = payload['status'] == 'cancelled';
    final clock = DateTime.tryParse(
      '${payload[cancelled ? 'cancelled_at' : 'updated_at']}',
    );
    if (clock == null) throw StateError('وقت التعديل مطلوب');
    final engine = _P1Mutations(this, station, clock);
    final tx = _P1Tx(db, station);
    engine._assertPeriodOpen(tx, clock, stationId: station);
    if (!cancelled) {
      if (payload['status'] != 'posted' || payload['_p2_replacement'] != null)
        throw StateError('حالة السند غير صالحة');
      if (old['irrigation_id'] != null &&
          payload['reference_number'] != old['reference_number'])
        throw StateError('مرجع قبض السقاية ثابت');
      tx.update(
        'payments',
        {
          'notes': payload['notes'],
          'reference_number': payload['reference_number'],
          'updated_at': clock.toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      engine.database.auditTx(
        tx,
        userId: userId,
        operation: 'update',
        table: 'payments',
        recordId: id,
        oldValues: old,
        newValues: {
          'notes': payload['notes'],
          'reference_number': payload['reference_number'],
        },
      );
      return;
    }
    final reason = '${payload['cancel_reason'] ?? ''}'.trim();
    if (reason.isEmpty) throw StateError('سبب الإلغاء مطلوب');
    if (old['irrigation_id'] == null &&
        '${old['reference_number'] ?? ''}'.startsWith('IRR-'))
      throw StateError('ربط القبض القديم غير مثبت؛ يلزم مراجعة صريحة');
    if (old['irrigation_id'] != null) {
      final irrigation = db.select(
        'SELECT beneficiary_id FROM irrigations WHERE id=? AND station_id=?',
        [old['irrigation_id'], station],
      );
      if (irrigation.length != 1 ||
          irrigation.single['beneficiary_id'] != old['beneficiary_id'])
        throw StateError('مرجع قبض السقاية غير صالح');
    }
    for (final table in ['worker_transactions', 'partner_transactions']) {
      if (db.select(
        "SELECT 1 FROM $table WHERE reference_type='payment' AND reference_id=? AND (station_id IS NULL OR station_id<>?)",
        [id, station],
      ).isNotEmpty)
        throw StateError('ملكية أثر الدفع غير مثبتة');
    }
    if (db.select(
      "SELECT 1 FROM journal_entries WHERE reference_type='payment' AND reference_id=? AND station_id=?",
      [id, station],
    ).isEmpty)
      throw StateError('لا يوجد قيد أصلي مثبت لعكس السند');
    if (db.select(
      "SELECT 1 FROM journal_entries WHERE reference_type='payment' AND reference_id=? AND (station_id IS NULL OR station_id<>?)",
      [id, station],
    ).isNotEmpty) {
      throw StateError('ملكية قيد السند غير مثبتة');
    }
    if (db.select(
      "SELECT 1 FROM journal_entries j JOIN journal_entries r ON r.reference_type='reversal' AND r.reference_id=j.id WHERE j.reference_type='payment' AND j.reference_id=?",
      [id],
    ).isNotEmpty) {
      throw StateError('قيد السند معكوس مسبقاً؛ يلزم مراجعة الحالة');
    }
    engine._cancelPaymentRowTx(
      tx,
      Map<String, Object?>.from(old),
      reason: reason,
      userId: userId,
    );
    tx.update(
      'payments',
      {'cancel_reason': reason, 'cancelled_at': clock.toIso8601String()},
      where: 'id=?',
      whereArgs: [id],
    );
    final replacement = payload['_p2_replacement'];
    if (replacement != null) {
      if (replacement is! Map || old['irrigation_id'] != null)
        throw StateError('استبدال قبض السقاية غير مسموح');
      if (replacement['date'] != old['date'] ||
          replacement['currency'] != old['currency'] ||
          replacement['irrigation_id'] != null)
        throw StateError('تاريخ أو عملة البديل لا يطابق الأصل');
      final replacementRefs = replacement['_global_refs'];
      if (replacementRefs is! Map ||
          _resolveSyncReference(
                station: station,
                entityType: 'payments',
                column: 'replaces_payment_id',
                references: replacementRefs,
              ) !=
              id)
        throw StateError('مرجع أصل البديل غير صالح');
      final newId = _createP2Payment(
        station,
        'payments:${replacement['_global_id']}',
        replacement,
        now,
        userId,
        role!,
        replaces: id,
      );
      // This nested row is published as a child create, not a second command.
      db.execute(
        "DELETE FROM sync_entity_links WHERE station_id=? AND entity_type='payments' AND local_id=?",
        [station, newId],
      );
      engine.database.auditTx(
        tx,
        userId: userId,
        operation: 'replace',
        table: 'payments',
        recordId: newId,
        oldValues: {'replaced_payment_id': id, 'payment': old},
        newValues: {'replacement_payment_id': newId},
        reason: reason,
      );
    }
  }

  Map<String, Map<int, Map<String, Object?>>> _p2Snapshot(int station) {
    final result = <String, Map<int, Map<String, Object?>>>{};
    for (final table in _p2Tables) {
      final scope = table == 'journal_lines'
          ? 'id IN (SELECT jl.id FROM journal_lines jl JOIN journal_entries j ON j.id=jl.journal_entry_id WHERE j.station_id=?)'
          : 'station_id=?';
      result[table] = !_hasTable(table)
          ? {}
          : {
              for (final r in db.select(
                'SELECT * FROM $table WHERE $scope ORDER BY id',
                [station],
              ))
                (r['id'] as num).toInt(): Map<String, Object?>.from(r),
            };
    }
    return result;
  }

  void _appendP2Effects(
    int station,
    String device,
    Map payload,
    String now,
    Map<String, Map<int, Map<String, Object?>>> before,
  ) {
    final after = _p2Snapshot(station);
    final root =
        (db.select(
                  "SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='payments' AND global_id=?",
                  [station, payload['_global_id']],
                ).single['local_id']
                as num)
            .toInt();
    before['payments']!.remove(root);
    after['payments']!.remove(root);
    final manifest = payload['_p2_effect_ids'];
    if (manifest is! Map) throw StateError('بيان آثار السند مفقود');
    for (final table in _p2Tables) {
      final old = before[table]!, rows = after[table]!;
      if (old.keys.any((id) => !rows.containsKey(id)))
        throw StateError('حذف أثر مالي أثناء السند ممنوع');
      final created = rows.keys.where((id) => !old.containsKey(id)).toList()
        ..sort();
      final requested = manifest[table];
      if (requested is! List ||
          requested.length != created.length ||
          requested.any((id) => id is! String))
        throw StateError('بيان آثار P2 غير مطابق: $table');
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
