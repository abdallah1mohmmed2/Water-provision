import 'package:sqflite/sqflite.dart';

enum InboxApplyResult { applied, conflict }

/// Applies allow-listed domain events inside a caller-owned SQLite transaction.
class SyncInboxApplier {
  SyncInboxApplier._();

  static const Map<String, String> domains = {
    'pumps': 'operations',
    'beneficiaries': 'parties',
    'partners': 'parties',
    'workers': 'parties',
    'accounts': 'accounting',
    'payment_methods': 'accounting',
    'cashboxes': 'accounting',
    'cashbox_transfers': 'finance',
    'payments': 'finance',
    'expenses': 'finance',
    'worker_transactions': 'finance',
    'partner_transactions': 'finance',
    'journal_entries': 'accounting',
    'journal_lines': 'accounting',
    'irrigations': 'operations',
    'cloud_periods': 'operations',
    'diesel_movements': 'operations',
    'queue_entries': 'operations',
    'booking_requests': 'operations',
    'irrigation_sessions': 'operations',
    'beneficiary_manual_debts': 'finance',
    'general_accounts': 'parties',
    'general_account_transactions': 'finance',
    'accountant_reconciliation_months': 'accounting',
    'period_closures': 'accounting',
    'cash_reconciliations': 'accounting',
  };

  static const _reserved = {'_global_id', '_global_refs', '_unresolved_refs'};
  static const _localOnly = {'id', 'station_id', 'created_by', 'reference_id'};
  static const _noDelete = {
    'accounts', 'payments', 'expenses', 'cashbox_transfers', 'irrigations',
    'worker_transactions', 'partner_transactions', 'journal_entries',
    'journal_lines', 'diesel_movements', 'beneficiary_manual_debts',
    'general_account_transactions', 'accountant_reconciliation_months',
    'period_closures', 'cash_reconciliations',
  };
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static Future<InboxApplyResult> apply(
    Transaction tx,
    Map<String, dynamic> event,
  ) async {
    final table = event['entity_type'];
    final operation = event['operation'];
    final rawPayload = event['payload'];
    final globalKey = event['entity_key'];
    final serverVersion = (event['server_version'] as num?)?.toInt();

    if (table is! String || !domains.containsKey(table)) {
      throw StateError('نوع سجل Inbox غير مسموح: $table');
    }
    if (!const {'create', 'update', 'delete'}.contains(operation)) {
      throw StateError('عملية Inbox غير مسموحة: $operation');
    }
    if (rawPayload is! Map || serverVersion == null || serverVersion < 1) {
      throw StateError('حمولة أو إصدار Inbox غير صالح.');
    }
    final payload = Map<String, dynamic>.from(rawPayload);
    final globalId = payload['_global_id'];
    if (globalId is! String || !_uuid.hasMatch(globalId) ||
        globalKey != '$table:$globalId') {
      throw StateError('هوية السجل العالمية لا تطابق مفتاح الحدث.');
    }
    // The irrigation event carries the validated interval list for server-side pricing.
    // Cloud-period rows themselves arrive as ordered, independently identified Inbox events.
    if (table == 'irrigations') {
      final cloudPeriods = payload.remove('cloud_periods');
      if (cloudPeriods != null && cloudPeriods is! List) {
        throw StateError('قائمة فترات الغيم الواردة غير صالحة.');
      }
    }

    final unresolved = payload['_unresolved_refs'];
    if (unresolved is Map && unresolved.isNotEmpty) {
      throw StateError('الحدث يحتوي على علاقات مصدر غير محلولة.');
    }

    final entityKey = '$table:$globalId';
    final versionRows = await tx.query(
      'sync_entity_versions',
      columns: ['server_version'],
      where: 'entity_type=? AND entity_key=?',
      whereArgs: [table, entityKey],
      limit: 1,
    );
    final currentVersion = versionRows.isEmpty
        ? 0
        : (versionRows.single['server_version'] as num).toInt();
    if (serverVersion <= currentVersion) return InboxApplyResult.applied;
    if (serverVersion != currentVersion + 1) {
      throw StateError('تسلسل إصدار $table غير مكتمل.');
    }

    final identityRows = await tx.query(
      'sync_global_identities',
      columns: ['local_id', 'retired_at'],
      where: 'table_name=? AND global_id=?',
      whereArgs: [table, globalId],
      limit: 1,
    );
    final localId = identityRows.isEmpty
        ? null
        : (identityRows.single['local_id'] as num).toInt();

    if (localId != null) {
      final pending = await tx.rawQuery(
        "SELECT COUNT(*) AS n FROM sync_queue WHERE table_name=? AND record_id=? AND status IN ('pending','sending','conflict')",
        [table, localId],
      );
      if (((pending.first['n'] as num?)?.toInt() ?? 0) > 0) {
        return InboxApplyResult.conflict;
      }
    }

    if (operation == 'delete') {
      if (_noDelete.contains(table)) return InboxApplyResult.conflict;
      if (localId == null) {
        throw StateError('وصل حذف لسجل غير معروف محلياً: $table');
      }
      await tx.delete(table, where: 'id=?', whereArgs: [localId]);
      await tx.update(
        'sync_global_identities',
        {'retired_at': DateTime.now().toUtc().toIso8601String()},
        where: 'table_name=? AND local_id=?',
        whereArgs: [table, localId],
      );
      return InboxApplyResult.applied;
    }

    final columns = await tx.rawQuery('PRAGMA table_info($table)');
    if (columns.isEmpty || !columns.any((c) => c['name'] == 'id')) {
      throw StateError('مخطط الجدول غير متاح: $table');
    }
    final allowed = columns.map((c) => c['name'].toString()).toSet();
    final foreignKeys = await tx.rawQuery('PRAGMA foreign_key_list($table)');
    final fkByColumn = <String, String>{
      for (final fk in foreignKeys) fk['from'].toString(): fk['table'].toString(),
      if (table == 'diesel_movements') 'cashbox_id': 'cashboxes',
      if (table == 'payment_methods') 'cashbox_id': 'cashboxes',
    };
    final rawRefs = payload['_global_refs'];
    if (rawRefs != null && rawRefs is! Map) {
      throw StateError('صيغة مراجع العلاقات غير صالحة.');
    }
    final refs = rawRefs == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(rawRefs as Map);
    for (final key in refs.keys) {
      if (!fkByColumn.containsKey(key)) {
        throw StateError('مرجع غير معلن في مخطط $table: $key');
      }
    }

    final values = <String, Object?>{};
    for (final entry in payload.entries) {
      final column = entry.key;
      if (_reserved.contains(column) || _localOnly.contains(column)) continue;
      if (!allowed.contains(column)) {
        throw StateError('عمود غير معروف في حمولة $table: $column');
      }
      if (fkByColumn.containsKey(column)) {
        values[column] = await _resolveForeignKey(
          tx, table, column, fkByColumn[column]!, entry.value, refs[column],
        );
      } else {
        if (column.endsWith('_id') && entry.value != null) {
          throw StateError('رفض معرف محلي غير قابل للتحويل في $table.$column');
        }
        values[column] = entry.value;
      }
    }

    if (allowed.contains('station_id')) {
      final stations = await tx.query(
        'stations', columns: ['id'], orderBy: 'id', limit: 1,
      );
      if (stations.isEmpty) throw StateError('لا توجد محطة محلية لربط السجل.');
      values['station_id'] = (stations.first['id'] as num).toInt();
    }
    values.remove('created_by');
    values.remove('reference_id');
    _validateDomainValues(table, values);
    if (table == 'irrigation_sessions') {
      final beneficiaryId = (values['beneficiary_id'] as num?)?.toInt();
      final pumpId = (values['pump_id'] as num?)?.toInt();
      if (beneficiaryId == null || pumpId == null) {
        throw StateError('جلسة التشغيل الواردة بلا مستفيد أو مضخة.');
      }
      final ownership = await tx.rawQuery(
        'SELECT b.station_id beneficiary_station,p.station_id pump_station,p.active '
        'FROM beneficiaries b JOIN pumps p ON p.id=? WHERE b.id=? LIMIT 1',
        [pumpId, beneficiaryId],
      );
      if (ownership.isEmpty ||
          ownership.single['beneficiary_station'] != ownership.single['pump_station'] ||
          (ownership.single['active'] as num?)?.toInt() != 1) {
        throw StateError('جلسة التشغيل الواردة تربط أطرافاً من محطات مختلفة أو مضخة غير نشطة.');
      }
      for (final relation in const [
        ('queue_entry_id', 'queue_entries'),
        ('booking_id', 'booking_requests'),
      ]) {
        final relatedId = (values[relation.$1] as num?)?.toInt();
        if (relatedId == null) continue;
        final related = await tx.query(
          relation.$2,
          columns: ['beneficiary_id'],
          where: 'id=?',
          whereArgs: [relatedId],
          limit: 1,
        );
        if (related.isEmpty ||
            (related.single['beneficiary_id'] as num).toInt() != beneficiaryId) {
          throw StateError('جلسة التشغيل الواردة مرتبطة بحجز أو دور لمستفيد آخر.');
        }
      }
      final nextStatus = (values['status'] ?? (operation == 'create' ? 'running' : '')).toString();
      if (operation == 'create') {
        if (nextStatus != 'running' ||
            DateTime.tryParse('${values['actual_start'] ?? ''}') == null) {
          throw StateError('إنشاء جلسة التشغيل الواردة يجب أن يبدأ بوقت وحالة running.');
        }
      } else if (localId != null) {
        final existing = await tx.query(
          'irrigation_sessions',
          columns: ['status', 'actual_start', 'actual_end'],
          where: 'id=?',
          whereArgs: [localId],
          limit: 1,
        );
        if (existing.isEmpty) throw StateError('جلسة التشغيل المحلية غير موجودة.');
        final oldStatus = '${existing.single['status']}';
        final transitions = <String, Set<String>>{
          'running': {'running', 'postponed', 'completed'},
          'postponed': {'postponed'},
          'completed': {'completed'},
        };
        if (!(transitions[oldStatus]?.contains(nextStatus) ?? false)) {
          throw StateError('انتقال حالة جلسة التشغيل الواردة غير مسموح.');
        }
        if (nextStatus == 'postponed' &&
            '${values['postponement_reason'] ?? ''}'.trim().isEmpty) {
          throw StateError('سبب تأجيل جلسة التشغيل الواردة مطلوب.');
        }
        if (nextStatus == 'completed') {
          final start = DateTime.tryParse('${existing.single['actual_start'] ?? ''}');
          final end = DateTime.tryParse('${values['actual_end'] ?? existing.single['actual_end'] ?? ''}');
          if (start == null || end == null || !end.isAfter(start)) {
            throw StateError('وقت إنهاء جلسة التشغيل الواردة غير صالح.');
          }
        }
      }
    }

    int appliedLocalId;
    if (localId == null) {
      // These catalogs are seeded independently on each device. Never create
      // duplicate chart/payment-method rows merely because their UUIDs differ.
      if (table == 'accounts' && payload['code'] is String) {
        final matches = await tx.query(
          'accounts',
          columns: ['id'],
          where: 'code=?',
          whereArgs: [payload['code']],
          limit: 1,
        );
        if (matches.isNotEmpty) return InboxApplyResult.conflict;
      }
      if (table == 'payment_methods' &&
          payload['name'] is String && payload['type'] is String) {
        final matches = await tx.query(
          'payment_methods',
          columns: ['id'],
          where: 'name=? AND type=?',
          whereArgs: [payload['name'], payload['type']],
          limit: 2,
        );
        if (matches.length == 1) return InboxApplyResult.conflict;
      }
      if (table == 'pumps' &&
          payload['name'] is String && payload['system_type'] is String) {
        final matches = await tx.query(
          'pumps',
          columns: ['id'],
          where: 'name=? AND system_type=?',
          whereArgs: [payload['name'], payload['system_type']],
          limit: 2,
        );
        if (matches.length == 1) return InboxApplyResult.conflict;
      }
      if (table == 'cashboxes' &&
          payload['name'] is String && payload['currency'] is String) {
        final matches = await tx.query(
          'cashboxes',
          columns: ['id'],
          where: 'name=? AND currency=?',
          whereArgs: [payload['name'], payload['currency']],
          limit: 2,
        );
        if (matches.length == 1) return InboxApplyResult.conflict;
      }
      if (operation != 'create') {
        throw StateError('وصل تحديث قبل إنشاء السجل $table/$globalId');
      }
      appliedLocalId = await tx.insert(table, values);
      await tx.insert('sync_global_identities', {
        'table_name': table,
        'local_id': appliedLocalId,
        'global_id': globalId,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } else {
      if (identityRows.single['retired_at'] != null) {
        throw StateError('وصل تحديث لهوية سبق إيقافها: $table');
      }
      final existingRecord = await tx.query(
        table,
        columns: ['id'],
        where: 'id=?',
        whereArgs: [localId],
        limit: 1,
      );
      if (existingRecord.isEmpty) {
        throw StateError('خريطة الهوية تشير إلى سجل محلي مفقود: $table/$globalId');
      }
      await tx.update(table, values, where: 'id=?', whereArgs: [localId]);
      appliedLocalId = localId;
    }

    if (table == 'journal_entries') {
      await tx.update('journal_entries', {'status': 'draft'},
          where: 'id=?', whereArgs: [appliedLocalId]);
      await _refreshJournalStatus(tx, appliedLocalId);
    } else if (table == 'journal_lines') {
      final parentRows = await tx.query(
        'journal_lines',
        columns: ['journal_entry_id'],
        where: 'id=?',
        whereArgs: [appliedLocalId],
        limit: 1,
      );
      if (parentRows.isNotEmpty) {
        await _refreshJournalStatus(
          tx, (parentRows.first['journal_entry_id'] as num).toInt(),
        );
      }
    }
    return InboxApplyResult.applied;
  }

  static void _validateDomainValues(
    String table,
    Map<String, Object?> values,
  ) {
    const positiveAmountTables = {
      'payments',
      'expenses',
      'cashbox_transfers',
      'worker_transactions',
      'partner_transactions',
      'beneficiary_manual_debts',
      'general_account_transactions',
    };
    if (positiveAmountTables.contains(table) && values.containsKey('amount')) {
      final amount = values['amount'];
      if (amount is! num || amount <= 0) {
        throw StateError('يجب أن يكون المبلغ موجباً في سجل $table');
      }
    }
    if (table == 'cashbox_transfers') {
      final from = values['from_cashbox_id'];
      final to = values['to_cashbox_id'];
      if (from != null && to != null && from == to) {
        throw StateError('لا يمكن تحويل الرصيد إلى الصندوق نفسه.');
      }
    }
  }

  static Future<Object?> _resolveForeignKey(
    Transaction tx,
    String sourceTable,
    String column,
    String targetTable,
    Object? sourceValue,
    Object? referenceValue,
  ) async {
    if (sourceValue == null) return null;
    if (targetTable == 'stations') {
      final rows = await tx.query('stations', columns: ['id'], orderBy: 'id', limit: 1);
      if (rows.isEmpty) throw StateError('المحطة المحلية غير موجودة.');
      return (rows.first['id'] as num).toInt();
    }
    if (referenceValue is! Map) {
      throw StateError('العلاقة $sourceTable.$column بلا مرجع عالمي.');
    }
    final ref = Map<String, dynamic>.from(referenceValue);
    final refTable = ref['table'];
    final globalId = ref['global_id'];
    if (refTable != targetTable || globalId is! String || !_uuid.hasMatch(globalId)) {
      throw StateError('مرجع العلاقة $sourceTable.$column غير مطابق.');
    }
    final rows = await tx.query(
      'sync_global_identities',
      columns: ['local_id', 'retired_at'],
      where: 'table_name=? AND global_id=?',
      whereArgs: [targetTable, globalId],
      limit: 1,
    );
    if (rows.isNotEmpty && rows.single['retired_at'] == null) {
      return (rows.single['local_id'] as num).toInt();
    }
    if (targetTable == 'accounts' && ref['code'] is String) {
      final natural = await tx.query(
        'accounts',
        columns: ['id'],
        where: 'code=?',
        whereArgs: [ref['code']],
        limit: 2,
      );
      if (natural.length == 1) return (natural.single['id'] as num).toInt();
    }
    if (targetTable == 'payment_methods' &&
        ref['name'] is String && ref['type'] is String) {
      final natural = await tx.query(
        'payment_methods',
        columns: ['id'],
        where: 'name=? AND type=?',
        whereArgs: [ref['name'], ref['type']],
        limit: 2,
      );
      if (natural.length == 1) return (natural.single['id'] as num).toInt();
    }
    if (targetTable == 'pumps' &&
        ref['name'] is String && ref['system_type'] is String) {
      final natural = await tx.query(
        'pumps',
        columns: ['id'],
        where: 'name=? AND system_type=?',
        whereArgs: [ref['name'], ref['system_type']],
        limit: 2,
      );
      if (natural.length == 1) return (natural.single['id'] as num).toInt();
    }
    if (targetTable == 'cashboxes' &&
        ref['name'] is String && ref['currency'] is String) {
      final natural = await tx.query(
        'cashboxes',
        columns: ['id'],
        where: 'name=? AND currency=?',
        whereArgs: [ref['name'], ref['currency']],
        limit: 2,
      );
      if (natural.length == 1) return (natural.single['id'] as num).toInt();
    }
    throw StateError('السجل المرتبط $targetTable/$globalId لم يصل بعد.');
  }

  static Future<void> _refreshJournalStatus(Transaction tx, int journalId) async {
    final rows = await tx.rawQuery(
      'SELECT COUNT(*) AS n, COALESCE(SUM(debit),0) AS d, COALESCE(SUM(credit),0) AS c FROM journal_lines WHERE journal_entry_id=?',
      [journalId],
    );
    final row = rows.single;
    final count = (row['n'] as num).toInt();
    final debit = (row['d'] as num).toDouble();
    final credit = (row['c'] as num).toDouble();
    await tx.update(
      'journal_entries',
      {'status': count > 0 && debit == credit && debit > 0 ? 'posted' : 'draft'},
      where: 'id=?',
      whereArgs: [journalId],
    );
  }
}
