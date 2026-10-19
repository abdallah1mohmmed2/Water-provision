import 'dart:convert';
import '../data/local/database.dart';
import '../api/api_client.dart';

class SyncService {
  final AppDatabase db;
  final ApiClient api;
  SyncService(this.api, [AppDatabase? database])
    : db = database ?? AppDatabase.instance;
  Future<int> pendingCount() async {
    final r = await db.query(
      "SELECT COUNT(*) n FROM sync_queue WHERE status='pending'",
    );
    return (r.first['n'] as int?) ?? 0;
  }

  Future<void> enqueue(
    String operation,
    String table,
    int? recordId,
    Map<String, dynamic> payload,
  ) async => db.insert('sync_queue', {
    'operation': operation,
    'table_name': table,
    'record_id': recordId,
    'payload': jsonEncode(payload),
    'status': 'pending',
    'attempts': 0,
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  });
  Future<void> push() async {
    final rows = await db.query(
      "SELECT * FROM sync_queue WHERE status='pending' ORDER BY id LIMIT 50",
    );
    for (final row in rows) {
      try {
        await api.post('/sync', {
          'operation': row['operation'],
          'table': row['table_name'],
          'record_id': row['record_id'],
          'payload': jsonDecode(row['payload'] as String),
        });
        await db.update(
          'sync_queue',
          {'status': 'synced', 'updated_at': DateTime.now().toIso8601String()},
          'id=?',
          [row['id']],
        );
      } catch (e) {
        await db.update(
          'sync_queue',
          {
            'attempts': (row['attempts'] as int) + 1,
            'last_error': '$e',
            'updated_at': DateTime.now().toIso8601String(),
          },
          'id=?',
          [row['id']],
        );
      }
    }
  }
}
