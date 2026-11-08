import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';
import '../data/local/database.dart';
import '../data/local/global_identity.dart';
import 'sync_inbox_applier.dart';

typedef IncomingSyncApplier = Future<InboxApplyResult> Function(
  Transaction tx,
  Map<String, dynamic> event,
);

class SyncService {
  final AppDatabase db;
  final ApiClient api;
  final IncomingSyncApplier? applyIncoming;

  SyncService(this.api, [AppDatabase? database])
    : db = database ?? AppDatabase.instance,
      applyIncoming = null;

  SyncService.withInboxHandler(
    this.api, {
    AppDatabase? database,
    required this.applyIncoming,
  }) : db = database ?? AppDatabase.instance;

  static const _batchSize = 50;

  Future<int> pendingCount() async {
    final rows = await db.query(
      "SELECT COUNT(*) AS n FROM sync_queue WHERE status IN ('pending','sending')",
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<String> _uuid() async {
    final random = Random.secure();
    String hex(int count) => List.generate(
      count,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + random.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  Future<String> _metadata(String key, Future<String> Function() create) async {
    final rows = await db.query(
      'SELECT value FROM sync_metadata WHERE key=? LIMIT 1',
      args: [key],
    );
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final value = await create();
    await db.insert('sync_metadata', {
      'key': key,
      'value': value,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final latest = await db.query(
      'SELECT value FROM sync_metadata WHERE key=? LIMIT 1',
      args: [key],
    );
    return latest.first['value'] as String;
  }

  Future<String> _deviceId() => _metadata('device_id', _uuid);

  Future<void> enqueue(
    String operation,
    String table,
    int? recordId,
    Map<String, dynamic> payload, {
    int baseVersion = 0,
  }) async {
    if (!const {'create', 'update', 'delete'}.contains(operation)) {
      throw ArgumentError.value(operation, 'operation', 'Unsupported sync operation');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('sync_queue', {
      'operation': operation,
      'table_name': table,
      'record_id': recordId,
      'payload': jsonEncode(payload),
      'event_id': await _uuid(),
      'base_version': baseVersion,
      'device_id': await _deviceId(),
      'status': 'pending',
      'attempts': 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<String>> _globalIdsForQuery(
    String sql,
    List<Object?> args,
    String table,
  ) async {
    final rows = await db.query(sql, args: args);
    final result = <String>[];
    for (final row in rows) {
      final localId = (row['id'] as num).toInt();
      final identity = await db.query(
        'SELECT global_id FROM sync_global_identities WHERE table_name=? AND local_id=? LIMIT 1',
        args: [table, localId],
      );
      if (identity.isEmpty) {
        throw StateError('الهوية العالمية للأثر التابع مفقودة: $table:$localId');
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
      final irrigationRows = await db.query(
        'SELECT session_id,queue_entry_id,booking_id FROM irrigations WHERE id=? LIMIT 1',
        args: [recordId],
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
          WHERE pt.reference_type='irrigation_profit' AND pt.reference_id=?
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
          "SELECT id FROM partner_transactions WHERE reference_type='irrigation_profit' AND reference_id=? ORDER BY id",
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
      final paymentRows = await db.query(
        'SELECT cashbox_id FROM payments WHERE id=? LIMIT 1',
        args: [recordId],
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

  /// Sends immutable event IDs. Retrying a request can never create a second
  /// event-log entry because the server enforces (station_id,event_id).
  Future<void> push() async {
    final deviceId = await _deviceId();
    final rows = await db.query(
      "SELECT * FROM sync_queue WHERE status IN ('pending','sending') ORDER BY id LIMIT ?",
      args: [_batchSize],
    );
    if (rows.isEmpty) return;

    final events = <Map<String, dynamic>>[];
    for (final row in rows) {
      final eventId = (row['event_id'] as String?)?.trim().isNotEmpty == true
          ? row['event_id'] as String
          : await _uuid();
      await db.update(
        'sync_queue',
        {
          'event_id': eventId,
          'device_id': deviceId,
          'status': 'sending',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        'id=?',
        [row['id']],
      );
      final table = row['table_name'] as String;
      final recordId = (row['record_id'] as num?)?.toInt();
      var payload = Map<String, dynamic>.from(
        jsonDecode(row['payload'] as String) as Map,
      );
      if (recordId != null && payload['_global_id'] == null) {
        await GlobalIdentity.ensureRecord(await db.db, table, recordId);
        payload = Map<String, dynamic>.from(
          await GlobalIdentity.decoratePayload(
            await db.db,
            table,
            payload,
            recordId,
          ),
        );
        await db.update(
          'sync_queue',
          {'payload': jsonEncode(payload)},
          'id=?',
          [row['id']],
        );
      }
      if (table == 'irrigations' && recordId != null) {
        final cloudRows = await db.query(
          'SELECT start_datetime,end_datetime FROM cloud_periods WHERE irrigation_id=? ORDER BY start_datetime',
          args: [recordId],
        );
        payload['cloud_periods'] = cloudRows.map((period) => {
          'start_datetime': period['start_datetime'],
          'end_datetime': period['end_datetime'],
        }).toList();
      }
      if ((table == 'irrigations' || table == 'payments') && recordId != null) {
        payload['_derived_global_ids'] =
            await _derivedGlobalIds(table, recordId);
        await db.update(
          'sync_queue',
          {'payload': jsonEncode(payload)},
          'id=?',
          [row['id']],
        );
      }
      final unresolved = payload['_unresolved_refs'];
      if (unresolved is Map && unresolved.isNotEmpty) {
        await db.update(
          'sync_queue',
          {
            'status': 'failed',
            'last_error':
                'تعذر إرسال الحدث لوجود علاقات غير محلولة: ${unresolved.keys.join(', ')}',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          'id=?',
          [row['id']],
        );
        continue;
      }
      events.add({
        'event_id': eventId,
        'entity_type': table,
        'entity_key': recordId == null
            ? '$table:$eventId'
            : GlobalIdentity.entityKey(table, payload),
        'operation': row['operation'],
        'base_version': (row['base_version'] as num?)?.toInt() ?? 0,
        'payload': payload,
      });
    }

    if (events.isEmpty) return;

    try {
      final response = await api.post('/sync/events', {
        'device_id': deviceId,
        'events': events,
      }) as Map<String, dynamic>;
      final results = (response['results'] as List<dynamic>? ?? const []);
      for (final item in results) {
        if (item is! Map) continue;
        final eventId = item['event_id'] as String?;
        if (eventId == null) continue;
        final status = item['status'];
        final nextStatus = status == 'accepted' || status == 'duplicate'
            ? 'acknowledged'
            : status == 'conflict'
                ? 'conflict'
                : status == 'rejected'
                    ? 'failed'
                    : 'pending';
        final queueRows = await db.query(
          'SELECT id,attempts FROM sync_queue WHERE event_id=? LIMIT 1',
          args: [eventId],
        );
        if (queueRows.isEmpty) continue;
        final updatedAt = DateTime.now().toUtc().toIso8601String();
        await db.transaction((tx) async {
          await tx.update(
            'sync_queue',
            {
              'status': nextStatus,
              'attempts': (queueRows.first['attempts'] as num).toInt() +
                  (nextStatus == 'pending' ? 1 : 0),
              'last_error': item['message'],
              'conflict_version': item['current_version'],
              'updated_at': updatedAt,
            },
            where: 'event_id=?',
            whereArgs: [eventId],
          );
          if (nextStatus == 'acknowledged' || nextStatus == 'conflict') {
            final eventRows = await tx.query(
              'sync_queue',
              columns: ['table_name', 'record_id', 'payload'],
              where: 'event_id=?',
              whereArgs: [eventId],
              limit: 1,
            );
            if (eventRows.isNotEmpty) {
              final entityType = '${eventRows.first['table_name']}';
              final entityPayload = Map<String, dynamic>.from(
                jsonDecode(eventRows.first['payload'] as String) as Map,
              );
              final entityKey = (eventRows.first['record_id'] == null)
                  ? '$entityType:$eventId'
                  : GlobalIdentity.entityKey(entityType, entityPayload);
              final serverVersion = nextStatus == 'conflict'
                  ? (item['current_version'] as num?)?.toInt() ?? 0
                  : (item['server_version'] as num?)?.toInt() ??
                        (item['current_version'] as num?)?.toInt() ??
                        0;
              await tx.insert(
                'sync_entity_versions',
                {
                  'entity_type': entityType,
                  'entity_key': entityKey,
                  'server_version': serverVersion,
                  'updated_at': updatedAt,
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
          }
        });
      }
    } catch (error) {
      // Only reset rows that were actually part of the failed HTTP batch.
      // Rows rejected locally for unresolved references must remain failed;
      // otherwise a network error would silently make them eligible again.
      for (final row in rows) {
        await db.update(
          'sync_queue',
          {
            'status': 'pending',
            'attempts': (row['attempts'] as num).toInt() + 1,
            'last_error': error.toString(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          "id=? AND status='sending'",
          [row['id']],
        );
      }
      rethrow;
    }
  }

  /// Re-queues a user/repository-merged conflict as a NEW event against the
  /// server version. The original conflicted event remains in the local queue
  /// as resolved for auditability; the server's immutable conflict record stays.
  Future<void> resolveConflict(
    String eventId, {
    required Map<String, dynamic> resolvedPayload,
  }) async {
    final rows = await db.query(
      "SELECT * FROM sync_queue WHERE event_id=? AND status='conflict' LIMIT 1",
      args: [eventId],
    );
    if (rows.isEmpty) {
      throw StateError('حدث التعارض غير موجود أو تمت معالجته مسبقاً.');
    }
    final row = rows.first;
    final serverVersion = (row['conflict_version'] as num?)?.toInt();
    if (serverVersion == null) {
      throw StateError('إصدار الخادم غير متاح؛ أعد جلب حالة السجل قبل الحل.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final replacementEventId = await _uuid();
    final deviceId = await _deviceId();
    await db.transaction((tx) async {
      await tx.insert('sync_queue', {
        'operation': 'update',
        'table_name': row['table_name'],
        'record_id': row['record_id'],
        'payload': jsonEncode(resolvedPayload),
        'event_id': replacementEventId,
        'base_version': serverVersion,
        'device_id': deviceId,
        'status': 'pending',
        'attempts': 0,
        'created_at': now,
        'updated_at': now,
      });
      await tx.update(
        'sync_queue',
        {
          'status': 'resolved',
          'last_error': 'تم إنشاء حدث دمج جديد انطلاقاً من الإصدار $serverVersion',
          'updated_at': now,
        },
        where: 'event_id=?',
        whereArgs: [eventId],
      );
    });
  }

  /// Downloads and durably stores remote events before advancing the cursor.
  Future<int> pull() async {
    final deviceId = await _deviceId();
    final cursor = await _metadata('inbox_cursor', () async => '0');
    final response = await api.get(
      '/sync/inbox?after=$cursor&device_id=$deviceId',
    ) as Map<String, dynamic>;
    final events = (response['events'] as List<dynamic>? ?? const []);
    final highWatermark = (response['cursor'] as num?)?.toInt() ?? int.parse(cursor);
    final now = DateTime.now().toUtc().toIso8601String();

    await db.transaction((tx) async {
      for (final raw in events) {
        if (raw is! Map) continue;
        final event = Map<String, dynamic>.from(raw);
        await tx.insert('sync_inbox', {
          'event_id': event['event_id'],
          'server_sequence': event['server_sequence'],
          'entity_type': event['entity_type'],
          'entity_key': event['entity_key'],
          'operation': event['operation'],
          'payload_json': jsonEncode(event['payload']),
          'base_version': event['base_version'],
          'server_version': event['server_version'],
          'source_device': event['source_device'],
          'status': 'pending',
          'received_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await tx.insert('sync_metadata', {
        'key': 'inbox_cursor',
        'value': highWatermark.toString(),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return events.length;
  }

  /// Applies persisted Inbox events through a feature-owned repository handler.
  /// No generic SQL is executed from an untrusted remote payload.
  Future<int> applyInbox({int limit = _batchSize}) async {
    final handler = applyIncoming;
    if (handler == null) {
      throw StateError(
        'يجب ربط معالج Inbox بمستودع البيانات قبل تطبيق الأحداث الواردة.',
      );
    }
    final rows = await db.query(
      "SELECT * FROM sync_inbox WHERE status='pending' ORDER BY server_sequence LIMIT ?",
      args: [limit],
    );
    var applied = 0;
    for (final row in rows) {
      final event = <String, dynamic>{
        'event_id': row['event_id'],
        'server_sequence': row['server_sequence'],
        'entity_type': row['entity_type'],
        'entity_key': row['entity_key'],
        'operation': row['operation'],
        'payload': jsonDecode(row['payload_json'] as String),
        'base_version': row['base_version'],
        'server_version': row['server_version'],
        'source_device': row['source_device'],
      };
      try {
        await db.transaction((tx) async {
          final current = await tx.query(
            'sync_inbox',
            columns: ['status'],
            where: 'event_id=?',
            whereArgs: [row['event_id']],
            limit: 1,
          );
          if (current.isEmpty || current.single['status'] != 'pending') return;

          final result = await handler(tx, event);
          final now = DateTime.now().toUtc().toIso8601String();
          if (result == InboxApplyResult.conflict) {
            await tx.update(
              'sync_inbox',
              {
                'status': 'conflict',
                'last_error': 'تعارض مع تغييرات محلية غير مرسلة؛ يتطلب حلاً يدوياً.',
              },
              where: 'event_id=?',
              whereArgs: [row['event_id']],
            );
            return;
          }

          final entityType = row['entity_type'] as String;
          final entityKey = row['entity_key'] as String;
          final incomingVersion = (row['server_version'] as num).toInt();
          final existing = await tx.query(
            'sync_entity_versions',
            columns: ['server_version'],
            where: 'entity_type=? AND entity_key=?',
            whereArgs: [entityType, entityKey],
            limit: 1,
          );
          final knownVersion = existing.isEmpty
              ? 0
              : (existing.single['server_version'] as num).toInt();
          await tx.insert(
            'sync_entity_versions',
            {
              'entity_type': entityType,
              'entity_key': entityKey,
              'server_version': knownVersion > incomingVersion
                  ? knownVersion
                  : incomingVersion,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          await tx.update(
            'sync_inbox',
            {
              'status': 'applied',
              'applied_at': now,
              'last_error': null,
            },
            where: 'event_id=?',
            whereArgs: [row['event_id']],
          );
          applied++;
        }, captureSync: false);
      } catch (error) {
        await db.update(
          'sync_inbox',
          {
            'status': 'failed',
            'last_error': error.toString(),
          },
          'event_id=?',
          [row['event_id']],
        );
      }
    }
    return applied;
  }

  /// Retries only dependency-order failures after a later Inbox page may
  /// have delivered the missing parent entity.
  Future<int> retryDeferredInbox() async {
    return db.update(
      'sync_inbox',
      {'status': 'pending', 'last_error': null},
      "status='failed' AND (last_error LIKE '%لم يصل بعد%' OR last_error LIKE '%قبل إنشاء السجل%' OR last_error LIKE '%تسلسل إصدار%')",
      const [],
    );
  }

  /// Makes failed events eligible for a deliberate retry after their
  /// prerequisite records or local configuration have been repaired.
  Future<int> retryFailedInbox({String? eventId}) async {
    return db.update(
      'sync_inbox',
      {'status': 'pending', 'last_error': null},
      eventId == null ? "status='failed'" : "status='failed' AND event_id=?",
      eventId == null ? const [] : [eventId],
    );
  }

}
