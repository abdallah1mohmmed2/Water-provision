import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Stable cross-device identities. Local integer primary keys remain untouched.
class GlobalIdentity {
  GlobalIdentity._();

  static const tables = <String>[
    'stations', 'pumps', 'beneficiaries', 'partners', 'workers',
    'irrigations', 'cloud_periods', 'diesel_movements', 'payment_methods',
    'cashboxes', 'cashbox_transfers', 'payments', 'expenses',
    'worker_transactions', 'partner_transactions', 'journal_entries',
    'journal_lines', 'queue_entries', 'booking_requests',
    'irrigation_sessions', 'beneficiary_manual_debts', 'general_accounts',
    'general_account_transactions', 'accountant_reconciliation_months',
    'period_closures', 'cash_reconciliations', 'accounts', 'app_users',
  ];

  static Future<void> ensure(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_global_identities (
        table_name TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        global_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        retired_at TEXT,
        PRIMARY KEY(table_name, local_id),
        UNIQUE(global_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_global_relations (
        source_table TEXT NOT NULL,
        source_global_id TEXT NOT NULL,
        source_column TEXT NOT NULL,
        target_table TEXT NOT NULL,
        target_global_id TEXT NOT NULL,
        PRIMARY KEY(source_table, source_global_id, source_column)
      )
    ''');
    final now = DateTime.now().toUtc().toIso8601String();
    var addedIdentities = false;
    for (final table in tables) {
      final exists = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      if (exists.isEmpty) continue;
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      if (!columns.any((column) => column['name'] == 'id')) continue;
      final missing = await db.rawQuery('''
        SELECT t.id FROM $table t
        LEFT JOIN sync_global_identities g
          ON g.table_name=? AND g.local_id=t.id
        WHERE g.global_id IS NULL
      ''', [table]);
      for (final row in missing) {
        await db.insert('sync_global_identities', {
          'table_name': table,
          'local_id': (row['id'] as num).toInt(),
          'global_id': const Uuid().v4(),
          'created_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        addedIdentities = true;
      }
    }
    final relationCount = await db.rawQuery('SELECT COUNT(*) AS n FROM sync_global_relations');
    if (addedIdentities || ((relationCount.first['n'] as num?)?.toInt() ?? 0) == 0) {
      await rebuildRelations(db);
    }
    await _migrateLocalEntityVersions(db);
  }

  static Future<void> _migrateLocalEntityVersions(DatabaseExecutor db) async {
    final versions = await db.query('sync_entity_versions');
    for (final version in versions) {
      final table = version['entity_type'] as String;
      final key = version['entity_key'] as String;
      final prefix = '$table:';
      if (!key.startsWith(prefix)) continue;
      final localId = int.tryParse(key.substring(prefix.length));
      if (localId == null) continue;
      final identities = await db.query(
        'sync_global_identities',
        columns: ['global_id'],
        where: 'table_name=? AND local_id=?',
        whereArgs: [table, localId],
        limit: 1,
      );
      if (identities.isEmpty) continue;
      final globalKey = '$table:${identities.single['global_id']}';
      if (globalKey == key) continue;
      final existing = await db.query(
        'sync_entity_versions',
        columns: ['server_version'],
        where: 'entity_type=? AND entity_key=?',
        whereArgs: [table, globalKey],
        limit: 1,
      );
      final oldVersion = (version['server_version'] as num).toInt();
      final mergedVersion = existing.isEmpty
          ? oldVersion
          : ((existing.single['server_version'] as num).toInt() > oldVersion
                ? (existing.single['server_version'] as num).toInt()
                : oldVersion);
      if (existing.isEmpty) {
        await db.update(
          'sync_entity_versions',
          {
            'entity_key': globalKey,
            'server_version': mergedVersion,
          },
          where: 'entity_type=? AND entity_key=?',
          whereArgs: [table, key],
        );
      } else {
        await db.update(
          'sync_entity_versions',
          {'server_version': mergedVersion},
          where: 'entity_type=? AND entity_key=?',
          whereArgs: [table, globalKey],
        );
        await db.delete(
          'sync_entity_versions',
          where: 'entity_type=? AND entity_key=?',
          whereArgs: [table, key],
        );
      }
    }
  }

  static Future<void> ensureRecord(
    DatabaseExecutor db,
    String table,
    int localId,
  ) async {
    final rows = await db.query(
      'sync_global_identities',
      columns: ['global_id', 'retired_at'],
      where: 'table_name=? AND local_id=?',
      whereArgs: [table, localId],
      limit: 1,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    if (rows.isEmpty) {
      await db.insert('sync_global_identities', {
        'table_name': table,
        'local_id': localId,
        'global_id': const Uuid().v4(),
        'created_at': now,
      });
    } else if (rows.single['retired_at'] != null) {
      await db.update(
        'sync_global_identities',
        {
          'global_id': const Uuid().v4(),
          'created_at': now,
          'retired_at': null,
        },
        where: 'table_name=? AND local_id=?',
        whereArgs: [table, localId],
      );
    }
  }

  static Future<void> rebuildRelations(DatabaseExecutor db) async {
    await db.delete('sync_global_relations');
    for (final source in tables) {
      final exists = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [source],
      );
      if (exists.isEmpty) continue;
      final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list($source)');
      for (final fk in foreignKeys) {
        final target = '${fk['table']}';
        final column = '${fk['from']}';
        final targetColumn = '${fk['to'] ?? 'id'}';
        if (targetColumn != 'id' || !tables.contains(target)) continue;
        final sourceRows = await db.rawQuery('''
          SELECT s.id AS source_id, s.$column AS target_id,
                 sg.global_id AS source_global_id,
                 tg.global_id AS target_global_id
          FROM $source s
          JOIN sync_global_identities sg
            ON sg.table_name=? AND sg.local_id=s.id
          JOIN sync_global_identities tg
            ON tg.table_name=? AND tg.local_id=s.$column
          WHERE s.$column IS NOT NULL
        ''', [source, target]);
        for (final row in sourceRows) {
          await db.insert('sync_global_relations', {
            'source_table': source,
            'source_global_id': row['source_global_id'],
            'source_column': column,
            'target_table': target,
            'target_global_id': row['target_global_id'],
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
  }

  static Future<Map<String, Object?>> decoratePayload(
    DatabaseExecutor db,
    String table,
    Map<String, Object?> row,
    int localId,
  ) async {
    final identity = await db.query(
      'sync_global_identities',
      columns: ['global_id'],
      where: 'table_name=? AND local_id=?',
      whereArgs: [table, localId],
      limit: 1,
    );
    if (identity.isEmpty) {
      throw StateError('Missing global identity for $table:$localId');
    }
    final payload = Map<String, Object?>.from(row);
    final globalId = identity.single['global_id'] as String;
    payload['_global_id'] = globalId;
    final refs = <String, Map<String, String>>{};
    await db.delete(
      'sync_global_relations',
      where: 'source_table=? AND source_global_id=?',
      whereArgs: [table, globalId],
    );
    final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list($table)');
    for (final fk in foreignKeys) {
      final column = '${fk['from']}';
      final localTargetId = row[column];
      if (localTargetId == null) continue;
      final targetTable = '${fk['table']}';
      final target = await db.query(
        'sync_global_identities',
        columns: ['global_id'],
        where: 'table_name=? AND local_id=?',
        whereArgs: [targetTable, localTargetId],
        limit: 1,
      );
      if (target.isEmpty) {
        throw StateError(
          'Unresolved relation $table.$column -> $targetTable:$localTargetId',
        );
      }
      final targetGlobalId = target.single['global_id'] as String;
      refs[column] = {
        'table': targetTable,
        'global_id': targetGlobalId,
      };
      await db.insert('sync_global_relations', {
        'source_table': table,
        'source_global_id': globalId,
        'source_column': column,
        'target_table': targetTable,
        'target_global_id': targetGlobalId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    payload['_global_refs'] = refs;
    return payload;
  }

  static String entityKey(String table, Map<String, dynamic> payload) {
    final id = payload['_global_id'];
    if (id is! String || id.isEmpty) {
      throw StateError('Outbox event is missing _global_id for $table');
    }
    return '$table:$id';
  }
}
