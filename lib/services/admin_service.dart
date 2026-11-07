import '../core/app_clock.dart';
import '../core/security/password_hasher.dart';
import '../data/local/database.dart';
import '../domain/accounting/accounting_service.dart';

class AdminService {
  final AppDatabase db;
  AdminService([AppDatabase? d]) : db = d ?? AppDatabase.instance;
  Future<String> hashPassword(String password) =>
      PasswordHasher.hash(password);

  Future<Map<String, Object?>?> authenticate(
    String username,
    String password,
  ) async {
    final rows = await db.query(
      'SELECT id, station_id, name, username, role, password_hash FROM app_users WHERE username=? AND active=1 LIMIT 1',
      args: [username.trim()],
    );
    if (rows.isEmpty) return null;

    final user = rows.first;
    final storedHash = '${user['password_hash'] ?? ''}';
    if (!await PasswordHasher.verify(password, storedHash)) return null;

    if (!PasswordHasher.isArgon2id(storedHash)) {
      final upgradedHash = await PasswordHasher.hash(password);
      final changed = await db.update(
        'app_users',
        {'password_hash': upgradedHash},
        'id=? AND password_hash=?',
        [user['id'], storedHash],
      );
      if (changed == 0) {
        // Another login may have upgraded the same account concurrently.
        final latest = await db.query(
          'SELECT password_hash FROM app_users WHERE id=? AND active=1 LIMIT 1',
          args: [user['id']],
        );
        if (latest.isEmpty ||
            !await PasswordHasher.verify(
              password,
              '${latest.first['password_hash'] ?? ''}',
            )) {
          return null;
        }
      }
    }

    user.remove('password_hash');
    return user;
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
    if (password.length < 6) {
      throw ArgumentError('كلمة المرور يجب ألا تقل عن 6 أحرف');
    }
    final id = await db.insert('app_users', {
      'station_id': stationId,
      'name': name,
      'phone': phone,
      'username': username,
      'password_hash': await hashPassword(password),
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
    if (openingTransfer) {
      throw ArgumentError('الأرصدة تُدوَّر باستمرار في الدفتر؛ لا تُنشأ قيود افتتاحية مكررة');
    }
    final firstDay = DateTime(start.year, start.month, start.day);
    final endExclusive = DateTime(end.year, end.month, end.day + 1);
    return AccountingService(db).closeFiscalYear(
      stationId: stationId,
      start: firstDay,
      endExclusive: endExclusive,
      userId: userId,
      notes: notes,
    );
  }

  Future<List<Map<String, Object?>>> closedPeriods() =>
      db.query('SELECT * FROM period_closures ORDER BY closed_at DESC');
}
