import 'package:sqflite/sqflite.dart';
import 'global_identity.dart';

/// Snapshots a business command and its derived identities in the write transaction.
class BusinessSyncPayload {
  static const additionalCommands = {
    'expenses',
    'cashbox_transfers',
    'diesel_movements',
    'beneficiary_manual_debts',
    'worker_transactions',
    'partner_transactions',
  };
  final DatabaseExecutor executor;
  BusinessSyncPayload(this.executor);

  Future<Map<String, Object?>> prepare(
    String table,
    int recordId,
    Map<String, Object?> original, {
    List<Map<String, Object?>>? changes,
  }) async {
    final payload = Map<String, Object?>.from(original);
    if (table == 'payments' && changes != null &&
        (original['beneficiary_id'] == null || changes.any((r) => r['table_name']==table && r['record_id']==recordId && r['operation']=='update'))) {
      final manifest = <String,List<String>>{};
      for (final child in const ['payments','worker_transactions','partner_transactions','journal_entries','journal_lines','cashboxes','irrigations']) {
        final ids = changes.where((r) => r['table_name']==child && r['operation']=='create' && !(child==table && r['record_id']==recordId)).map((r)=>(r['record_id'] as num).toInt()).toList()..sort();
        manifest[child] = ids.isEmpty ? [] : await _globalIdsForQuery('SELECT id FROM $child WHERE id IN (${List.filled(ids.length,'?').join(',')}) ORDER BY id',ids,child);
      }
      payload['_p2_effect_ids'] = manifest;
      final replacements = await executor.query('payments',where:'replaces_payment_id=?',whereArgs:[recordId]);
      if (replacements.length > 1) throw StateError('أكثر من سند بديل للأصل');
      if (replacements.isNotEmpty) {
        final replacement = replacements.single;
        payload['_p2_replacement'] = await GlobalIdentity.decoratePayload(executor,'payments',replacement,(replacement['id'] as num).toInt());
      }
      return payload;
    }
    if (table == 'irrigations' &&
        changes != null &&
        changes.any(
          (r) =>
              r['table_name'] == table &&
              r['record_id'] == recordId &&
              r['operation'] == 'update',
        )) {
      final manifest = <String, List<String>>{};
      for (final child in const [
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
      ]) {
        final added =
            changes
                .where(
                  (r) => r['table_name'] == child && r['operation'] == 'create',
                )
                .map((r) => (r['record_id'] as num).toInt())
                .toList()
              ..sort();
        manifest[child] = added.isEmpty
            ? []
            : await _globalIdsForQuery(
                'SELECT id FROM $child WHERE id IN (${List.filled(added.length, '?').join(',')}) ORDER BY id',
                added,
                child,
              );
      }
      payload['_p1_effect_ids'] = manifest;
      return payload;
    }
    if (table == 'irrigations') {
      // The receipt is a separate payments command; never charge it twice.
      payload['paid_amount'] = 0;
      final periods = await executor.rawQuery(
        'SELECT start_datetime,end_datetime FROM cloud_periods WHERE irrigation_id=? ORDER BY start_datetime,id',
        [recordId],
      );
      payload['cloud_periods'] = periods
          .map(
            (row) => {
              'start_datetime': row['start_datetime'],
              'end_datetime': row['end_datetime'],
            },
          )
          .toList();
    }
    if (table == 'irrigations' || table == 'payments') {
      payload['_derived_global_ids'] = await _derivedGlobalIds(table, recordId);
    }
    // One fixed-salary batch root owns all worker transactions and journals.
    // Only the first worker row goes to Outbox; every member has a stable UUID.
    if (table == 'worker_transactions' &&
        original['type'] == 'accrual' &&
        original['reference_type'] == 'fixed_salary_batch') {
      final root = await executor.query(
        'worker_transactions', where: 'id=?', whereArgs: [recordId], limit: 1,
      );
      if (root.isEmpty) throw StateError('دفعة الاستحقاق غير موجودة');
      final notes = original['notes']?.toString() ?? '';
      final parts = notes.split(' | ');
      const labelPrefix = 'استحقاق راتب ثابت للفترة ';
      if (parts.length < 4 || !parts[1].startsWith(labelPrefix)) {
        throw StateError('بيان فترة دفعة الاستحقاق غير صالح');
      }
      final periodKey = parts[0].trim();
      final label = parts[1].substring(labelPrefix.length).trim();
      if (periodKey.isEmpty || periodKey.length > 120 || label.isEmpty ||
          label.length > 120) throw StateError('بيانات فترة الاستحقاق غير صالحة');
      if (changes == null) throw StateError('سجل حركات الدفعة مطلوب');
      final ids = changes.where(
        (change) => change['table_name'] == 'worker_transactions' &&
            change['operation'] == 'create',
      ).map((change) => (change['record_id'] as num).toInt()).toList()
        ..sort();
      if (ids.isEmpty || ids.first != recordId) {
        throw StateError('جذر الدفعة لا يطابق هويات الحركات التابعة');
      }
      final members = <Map<String,Object?>>[];
      final journals = <String>[], lines = <String>[];
      for (final id in ids) {
        final rows = await executor.query('worker_transactions',
          where:'id=?', whereArgs:[id],limit:1);
        if (rows.length != 1 ||
            rows.single['type'] != 'accrual' ||
            rows.single['reference_type'] != 'fixed_salary_batch' ||
            !(rows.single['notes']?.toString() ?? '').startsWith('$periodKey |')) {
          throw StateError('حركات الدفعة غير متجانسة');
        }
        final decorated = await GlobalIdentity.decoratePayload(
          executor,'worker_transactions',rows.single,id,
        );
        final refs = decorated['_global_refs'];
        if (refs is! Map || refs['worker_id'] is! Map) {
          throw StateError('هوية عامل في الدفعة مفقودة');
        }
        members.add({
          'global_id':decorated['_global_id'],
          'worker_ref':refs['worker_id'],
          'amount':rows.single['amount'],
        });
        journals.addAll(await _globalIdsForQuery(
          "SELECT id FROM journal_entries WHERE reference_type='worker' AND reference_id=? ORDER BY id",
          [id],'journal_entries',
        ));
        lines.addAll(await _globalIdsForQuery(
          "SELECT jl.id FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.reference_type='worker' AND je.reference_id=? ORDER BY jl.id",
          [id],'journal_lines',
        ));
      }
      if (journals.length != ids.length || lines.length != ids.length * 2) {
        throw StateError('عدد القيود التابعة لا يطابق دفعة الاستحقاق');
      }
      // The local domain method already validated the dates; the server
      // independently validates them against the signed station/period.
      const rangeMarker = ' | P3C_RANGE:';
      final markerAt = notes.lastIndexOf(rangeMarker);
      if (markerAt < 0) throw StateError('حدود فترة الدفعة مفقودة');
      final bounds = notes.substring(markerAt + rangeMarker.length).split(':');
      if (bounds.length != 2 ||
          !RegExp(r'^\\d{4}-\\d{2}-\\d{2}$').hasMatch(bounds[0]) ||
          !RegExp(r'^\\d{4}-\\d{2}-\\d{2}$').hasMatch(bounds[1])) {
        throw StateError('صيغة تواريخ فترة الدفعة غير صالحة');
      }
      payload['_p3c_batch'] = {
        'period_key':periodKey,
        'period_label':label,
        'period_from':bounds[0],
        'period_end_exclusive':bounds[1],
        'members':members,
      };
      payload['_derived_global_ids'] = {
        'journal_entries':journals,
        'journal_lines':lines,
        'cashboxes':<String>[],
      };
      return payload;
    }
    // P3c monthly payroll produces several worker rows in one local
    // transaction. Each worker command must own only its journal identities,
    // not those of the other salaries in the same transaction.
    if (table == 'worker_transactions' &&
        original['type'] == 'worker_entitlement' &&
        original['reference_type'] == 'monthly_salary') {
      payload['_derived_global_ids'] = {
        'journal_entries': await _globalIdsForQuery(
          "SELECT id FROM journal_entries WHERE reference_type='worker' AND reference_id=? ORDER BY id",
          [recordId], 'journal_entries',
        ),
        'journal_lines': await _globalIdsForQuery(
          "SELECT jl.id FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.reference_type='worker' AND je.reference_id=? ORDER BY jl.id",
          [recordId], 'journal_lines',
        ),
        'cashboxes': <String>[],
      };
      return payload;
    }
    if (additionalCommands.contains(table) && changes != null) {
      final ids = <String, List<String>>{};
      for (final child in const [
        'journal_entries',
        'journal_lines',
        'cashboxes',
      ]) {
        final localIds =
            changes
                .where(
                  (r) =>
                      r['table_name'] == child &&
                      (child == 'cashboxes'
                          ? r['operation'] != 'delete'
                          : r['operation'] == 'create'),
                )
                .map((r) => (r['record_id'] as num).toInt())
                .toSet()
                .toList()
              ..sort();
        ids[child] = localIds.isEmpty
            ? []
            : await _globalIdsForQuery(
                'SELECT id FROM $child WHERE id IN (${List.filled(localIds.length, '?').join(',')}) ORDER BY id',
                localIds,
                child,
              );
      }
      payload['_derived_global_ids'] = ids;
      // These backlinks point to journals generated by the command. They are
      // filled from the authoritative final projection, after the journals arrive.
      if (table == 'beneficiary_manual_debts') {
        payload['journal_entry_id'] = null;
        final refs = Map<String, dynamic>.from(
          payload['_global_refs'] as Map? ?? {},
        );
        refs.remove('journal_entry_id');
        payload['_global_refs'] = refs;
      }
      if ((table == 'worker_transactions' || table == 'partner_transactions') &&
          payload['reference_type'] == 'previous_debt') {
        payload['reference_id'] = null;
      }
    }
    return payload;
  }

  Future<List<String>> _globalIdsForQuery(
    String sql,
    List<Object?> args,
    String table,
  ) async {
    final rows = await executor.rawQuery(sql, args);
    final result = <String>[];
    for (final row in rows) {
      final localId = (row['id'] as num).toInt();
      final identity = await executor.rawQuery(
        'SELECT global_id FROM sync_global_identities WHERE table_name=? AND local_id=? LIMIT 1',
        [table, localId],
      );
      if (identity.isEmpty) {
        throw StateError(
          'الهوية العالمية للأثر التابع مفقودة: $table:$localId',
        );
      }
      result.add(identity.single['global_id'] as String);
    }
    return result;
  }

  /// Stable child identities let the server publish its authoritative effects
  /// back to every device, including the origin, without creating duplicates.
  Future<Map<String, List<String>>> _derivedGlobalIds(
    String table,
    int recordId,
  ) async {
    if (table == 'irrigations') {
      final irrigationRows = await executor.rawQuery(
        'SELECT session_id,queue_entry_id,booking_id FROM irrigations WHERE id=? LIMIT 1',
        [recordId],
      );
      if (irrigationRows.isEmpty) return const {};
      final irrigation = irrigationRows.single;
      const journalFilter = """
        (je.reference_type='irrigation' AND je.reference_id=?) OR
        (je.reference_type='worker' AND je.reference_id IN (
          SELECT wt.id FROM worker_transactions wt
          WHERE wt.reference_type='irrigation' AND wt.reference_id=?
        )) OR
        (je.reference_type='partner' AND je.reference_id IN (
          SELECT pt.id FROM partner_transactions pt
          WHERE pt.reference_type IN ('irrigation_profit','irrigation') AND pt.reference_id=?
        )) OR
        (je.reference_type='diesel_advance' AND je.reference_id IN (
          SELECT dm.id FROM diesel_movements dm WHERE dm.irrigation_id=?
        ))
      """;
      final result = <String, List<String>>{
        'cloud_periods': await _globalIdsForQuery(
          'SELECT id FROM cloud_periods WHERE irrigation_id=? ORDER BY start_datetime,id',
          [recordId],
          'cloud_periods',
        ),
        'journal_entries': await _globalIdsForQuery(
          'SELECT je.id FROM journal_entries je WHERE $journalFilter ORDER BY je.id',
          [recordId, recordId, recordId, recordId],
          'journal_entries',
        ),
        'journal_lines': await _globalIdsForQuery(
          'SELECT jl.id FROM journal_lines jl WHERE jl.journal_entry_id IN (SELECT je.id FROM journal_entries je WHERE $journalFilter) ORDER BY jl.id',
          [recordId, recordId, recordId, recordId],
          'journal_lines',
        ),
        'worker_transactions': await _globalIdsForQuery(
          "SELECT id FROM worker_transactions WHERE reference_type='irrigation' AND reference_id=? ORDER BY id",
          [recordId],
          'worker_transactions',
        ),
        'partner_transactions': await _globalIdsForQuery(
          "SELECT id FROM partner_transactions WHERE reference_type IN ('irrigation_profit','irrigation') AND reference_id=? ORDER BY id",
          [recordId],
          'partner_transactions',
        ),
        'diesel_movements': await _globalIdsForQuery(
          'SELECT id FROM diesel_movements WHERE irrigation_id=? ORDER BY id',
          [recordId],
          'diesel_movements',
        ),
      };
      for (final relation in const [
        ('irrigation_sessions', 'session_id'),
        ('queue_entries', 'queue_entry_id'),
        ('booking_requests', 'booking_id'),
      ]) {
        final value = irrigation[relation.$2];
        result[relation.$1] = value == null
            ? const []
            : await _globalIdsForQuery(
                'SELECT id FROM ${relation.$1} WHERE id=? ORDER BY id',
                [(value as num).toInt()],
                relation.$1,
              );
      }
      return result;
    }
    if (table == 'payments') {
      final paymentRows = await executor.rawQuery(
        'SELECT cashbox_id FROM payments WHERE id=? LIMIT 1',
        [recordId],
      );
      if (paymentRows.isEmpty) return const {};
      final cashboxId = (paymentRows.single['cashbox_id'] as num).toInt();
      return {
        'journal_entries': await _globalIdsForQuery(
          "SELECT id FROM journal_entries WHERE reference_type='payment' AND reference_id=? ORDER BY id",
          [recordId],
          'journal_entries',
        ),
        'journal_lines': await _globalIdsForQuery(
          "SELECT id FROM journal_lines WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE reference_type='payment' AND reference_id=?) ORDER BY id",
          [recordId],
          'journal_lines',
        ),
        'cashboxes': await _globalIdsForQuery(
          'SELECT id FROM cashboxes WHERE id=?',
          [cashboxId],
          'cashboxes',
        ),
      };
    }
    return const {};
  }
}
)
          .firstMatch(notes);
      if (dates == null) throw StateError('حدود فترة الدفعة مفقودة');
      payload['_p3c_batch'] = {
        'period_key':periodKey,
        'period_label':label,
        'period_from':dates.group(1),
        'period_end_exclusive':dates.group(2),
        'members':members,
      };
      payload['_derived_global_ids'] = {
        'journal_entries':journals,
        'journal_lines':lines,
        'cashboxes':<String>[],
      };
      return payload;
    }
    // P3c monthly payroll produces several worker rows in one local
    // transaction. Each worker command must own only its journal identities,
    // not those of the other salaries in the same transaction.
    if (table == 'worker_transactions' &&
        original['type'] == 'worker_entitlement' &&
        original['reference_type'] == 'monthly_salary') {
      payload['_derived_global_ids'] = {
        'journal_entries': await _globalIdsForQuery(
          "SELECT id FROM journal_entries WHERE reference_type='worker' AND reference_id=? ORDER BY id",
          [recordId], 'journal_entries',
        ),
        'journal_lines': await _globalIdsForQuery(
          "SELECT jl.id FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.reference_type='worker' AND je.reference_id=? ORDER BY jl.id",
          [recordId], 'journal_lines',
        ),
        'cashboxes': <String>[],
      };
      return payload;
    }
    if (additionalCommands.contains(table) && changes != null) {
      final ids = <String, List<String>>{};
      for (final child in const [
        'journal_entries',
        'journal_lines',
        'cashboxes',
      ]) {
        final localIds =
            changes
                .where(
                  (r) =>
                      r['table_name'] == child &&
                      (child == 'cashboxes'
                          ? r['operation'] != 'delete'
                          : r['operation'] == 'create'),
                )
                .map((r) => (r['record_id'] as num).toInt())
                .toSet()
                .toList()
              ..sort();
        ids[child] = localIds.isEmpty
            ? []
            : await _globalIdsForQuery(
                'SELECT id FROM $child WHERE id IN (${List.filled(localIds.length, '?').join(',')}) ORDER BY id',
                localIds,
                child,
              );
      }
      payload['_derived_global_ids'] = ids;
      // These backlinks point to journals generated by the command. They are
      // filled from the authoritative final projection, after the journals arrive.
      if (table == 'beneficiary_manual_debts') {
        payload['journal_entry_id'] = null;
        final refs = Map<String, dynamic>.from(
          payload['_global_refs'] as Map? ?? {},
        );
        refs.remove('journal_entry_id');
        payload['_global_refs'] = refs;
      }
      if ((table == 'worker_transactions' || table == 'partner_transactions') &&
          payload['reference_type'] == 'previous_debt') {
        payload['reference_id'] = null;
      }
    }
    return payload;
  }

  Future<List<String>> _globalIdsForQuery(
    String sql,
    List<Object?> args,
    String table,
  ) async {
    final rows = await executor.rawQuery(sql, args);
    final result = <String>[];
    for (final row in rows) {
      final localId = (row['id'] as num).toInt();
      final identity = await executor.rawQuery(
        'SELECT global_id FROM sync_global_identities WHERE table_name=? AND local_id=? LIMIT 1',
        [table, localId],
      );
      if (identity.isEmpty) {
        throw StateError(
          'الهوية العالمية للأثر التابع مفقودة: $table:$localId',
        );
      }
      result.add(identity.single['global_id'] as String);
    }
    return result;
  }

  /// Stable child identities let the server publish its authoritative effects
  /// back to every device, including the origin, without creating duplicates.
  Future<Map<String, List<String>>> _derivedGlobalIds(
    String table,
    int recordId,
  ) async {
    if (table == 'irrigations') {
      final irrigationRows = await executor.rawQuery(
        'SELECT session_id,queue_entry_id,booking_id FROM irrigations WHERE id=? LIMIT 1',
        [recordId],
      );
      if (irrigationRows.isEmpty) return const {};
      final irrigation = irrigationRows.single;
      const journalFilter = """
        (je.reference_type='irrigation' AND je.reference_id=?) OR
        (je.reference_type='worker' AND je.reference_id IN (
          SELECT wt.id FROM worker_transactions wt
          WHERE wt.reference_type='irrigation' AND wt.reference_id=?
        )) OR
        (je.reference_type='partner' AND je.reference_id IN (
          SELECT pt.id FROM partner_transactions pt
          WHERE pt.reference_type IN ('irrigation_profit','irrigation') AND pt.reference_id=?
        )) OR
        (je.reference_type='diesel_advance' AND je.reference_id IN (
          SELECT dm.id FROM diesel_movements dm WHERE dm.irrigation_id=?
        ))
      """;
      final result = <String, List<String>>{
        'cloud_periods': await _globalIdsForQuery(
          'SELECT id FROM cloud_periods WHERE irrigation_id=? ORDER BY start_datetime,id',
          [recordId],
          'cloud_periods',
        ),
        'journal_entries': await _globalIdsForQuery(
          'SELECT je.id FROM journal_entries je WHERE $journalFilter ORDER BY je.id',
          [recordId, recordId, recordId, recordId],
          'journal_entries',
        ),
        'journal_lines': await _globalIdsForQuery(
          'SELECT jl.id FROM journal_lines jl WHERE jl.journal_entry_id IN (SELECT je.id FROM journal_entries je WHERE $journalFilter) ORDER BY jl.id',
          [recordId, recordId, recordId, recordId],
          'journal_lines',
        ),
        'worker_transactions': await _globalIdsForQuery(
          "SELECT id FROM worker_transactions WHERE reference_type='irrigation' AND reference_id=? ORDER BY id",
          [recordId],
          'worker_transactions',
        ),
        'partner_transactions': await _globalIdsForQuery(
          "SELECT id FROM partner_transactions WHERE reference_type IN ('irrigation_profit','irrigation') AND reference_id=? ORDER BY id",
          [recordId],
          'partner_transactions',
        ),
        'diesel_movements': await _globalIdsForQuery(
          'SELECT id FROM diesel_movements WHERE irrigation_id=? ORDER BY id',
          [recordId],
          'diesel_movements',
        ),
      };
      for (final relation in const [
        ('irrigation_sessions', 'session_id'),
        ('queue_entries', 'queue_entry_id'),
        ('booking_requests', 'booking_id'),
      ]) {
        final value = irrigation[relation.$2];
        result[relation.$1] = value == null
            ? const []
            : await _globalIdsForQuery(
                'SELECT id FROM ${relation.$1} WHERE id=? ORDER BY id',
                [(value as num).toInt()],
                relation.$1,
              );
      }
      return result;
    }
    if (table == 'payments') {
      final paymentRows = await executor.rawQuery(
        'SELECT cashbox_id FROM payments WHERE id=? LIMIT 1',
        [recordId],
      );
      if (paymentRows.isEmpty) return const {};
      final cashboxId = (paymentRows.single['cashbox_id'] as num).toInt();
      return {
        'journal_entries': await _globalIdsForQuery(
          "SELECT id FROM journal_entries WHERE reference_type='payment' AND reference_id=? ORDER BY id",
          [recordId],
          'journal_entries',
        ),
        'journal_lines': await _globalIdsForQuery(
          "SELECT id FROM journal_lines WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE reference_type='payment' AND reference_id=?) ORDER BY id",
          [recordId],
          'journal_lines',
        ),
        'cashboxes': await _globalIdsForQuery(
          'SELECT id FROM cashboxes WHERE id=?',
          [cashboxId],
          'cashboxes',
        ),
      };
    }
    return const {};
  }
}
