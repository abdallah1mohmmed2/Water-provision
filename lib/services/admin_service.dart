import '../core/app_clock.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../data/local/database.dart';

class AdminService {
  final AppDatabase db;
  AdminService([AppDatabase? d]) : db = d ?? AppDatabase.instance;
  String hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  Future<Map<String, Object?>?> authenticate(
    String username,
    String password,
  ) async {
    final hash = hashPassword(password);
    final rows = await db.query(
      'SELECT id, station_id,name,username,role FROM app_users WHERE username=? AND password_hash=? AND active=1 LIMIT 1',
      args: [username.trim(), hash],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<List<Map<String, Object?>>> users() => db.query(
    'SELECT id,name,phone,username,role,active,created_at FROM app_users ORDER BY name',
  );
  Future<int> createUser({
    required int stationId,
    required String name,
    required String username,
    required String password,
    required String role,
    String? phone,
  }) async {
    if (password.length < 6)
      throw ArgumentError('كلمة المرور يجب ألا تقل عن 6 أحرف');
    final id = await db.insert('app_users', {
      'station_id': stationId,
      'name': name,
      'phone': phone,
      'username': username,
      'password_hash': hashPassword(password),
      'role': role,
      'active': 1,
      'created_at': AppClock.now().toIso8601String(),
    });
    await db.audit(
      operation: 'create',
      table: 'app_users',
      recordId: id,
      newValues: {'username': username, 'role': role},
    );
    return id;
  }

  Future<void> setUserActive(int id, bool active, int actorId) async {
    await db.update('app_users', {'active': active ? 1 : 0}, 'id=?', [id]);
    await db.audit(
      userId: actorId,
      operation: 'user_status',
      table: 'app_users',
      recordId: id,
      newValues: {'active': active},
    );
  }

  Future<int> closePeriod({
    required int stationId,
    required DateTime start,
    required DateTime end,
    required int userId,
    bool openingTransfer = false,
    String? notes,
  }) async {
    if (!end.isAfter(start))
      throw ArgumentError('نهاية الفترة يجب أن تكون بعد بدايتها');
    final existing = await db.query(
      'SELECT id FROM period_closures WHERE station_id=? AND period_start=? AND period_end=?',
      args: [stationId, start.toIso8601String(), end.toIso8601String()],
    );
    if (existing.isNotEmpty) throw StateError('الفترة مغلقة مسبقًا');
    final id = await db.insert('period_closures', {
      'station_id': stationId,
      'period_start': start.toIso8601String(),
      'period_end': end.toIso8601String(),
      'closed_at': AppClock.now().toIso8601String(),
      'closed_by': userId,
      'opening_transfer': openingTransfer ? 1 : 0,
      'notes': notes,
    });
    await db.audit(
      userId: userId,
      operation: 'close_period',
      table: 'period_closures',
      recordId: id,
      newValues: {
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
      },
      reason: notes,
    );
    return id;
  }

  Future<List<Map<String, Object?>>> closedPeriods() =>
      db.query('SELECT * FROM period_closures ORDER BY closed_at DESC');
}
