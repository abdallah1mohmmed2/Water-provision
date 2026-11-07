import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';
import '../data/local/database.dart';
import '../data/local/global_identity.dart';

typedef IncomingSyncApplier = Future<void> Function(
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

  /// Sends immutable event IDs. Retrying a request can never create a second
  /// second event-log entry because the server enforces (station_id,event_id).
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
      events.add({
        'event_id': eventId,
        'entity_type': table,
        'entity_key': recordId == null
            ? '${table}:$eventId'
            : GlobalIdentity.entityKey(table, payload),
        'operation': row['operation'],
        'base_version': (row['base_version'] as num?)?.toInt() ?? 0,
        'payload': payload,
      });
    }

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
      for (final row in rows) {
        await db.update(
          'sync_queue',
          {
            'status': 'pending',
            'attempts': (row['attempts'] as num).toInt() + 1,
            'last_error': error.toString(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          'id=?',
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
        await handler(event);
        await db.update(
          'sync_inbox',
          {
            'status': 'applied',
            'applied_at': DateTime.now().toUtc().toIso8601String(),
            'last_error': null,
          },
          'event_id=?',
          [row['event_id']],
        );
        applied++;
      } catch (error) {
        await db.update(
          'sync_inbox',
          {'status': 'failed', 'last_error': error.toString()},
          'event_id=?',
          [row['event_id']],
        );
      }
    }
    return applied;
  }
}
