import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'password_hasher.dart';

class SaqiaServer {
  final Database db;
  final String jwtSecret;
  SaqiaServer(this.db, {required this.jwtSecret}) {
    _ensureFinancialStationOwnership();
    _ensureLoginRateLimitTable();
    _ensureSyncTables();
  }

  void _ensureLoginRateLimitTable() {
    db.execute('''CREATE TABLE IF NOT EXISTS auth_rate_limits (
      scope_key TEXT PRIMARY KEY,
      window_started_at TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      blocked_until TEXT
    )''');
  }

  String _loginIp(Request request) {
    final connection = request.context['shelf.io.connection_info'];
    if (connection is HttpConnectionInfo) return connection.remoteAddress.address;
    return 'unknown';
  }

  List<String> _loginScopes(Request request, String username) {
    final ip = _loginIp(request);
    return ['admin-ip:$ip', 'admin-user:$ip:${username.trim().toLowerCase()}'];
  }

  bool _loginIsBlocked(List<String> scopes, DateTime now) {
    for (final scope in scopes) {
      final rows = db.select(
        'SELECT window_started_at, attempts, blocked_until FROM auth_rate_limits WHERE scope_key=?',
        [scope],
      );
      if (rows.isEmpty) continue;
      final row = rows.first;
      final blockedUntil = DateTime.tryParse('${row['blocked_until'] ?? ''}');
      if (blockedUntil != null && blockedUntil.isAfter(now)) return true;
      final started = DateTime.tryParse('${row['window_started_at']}');
      if (started == null || now.difference(started) >= const Duration(minutes: 15)) {
        db.execute('DELETE FROM auth_rate_limits WHERE scope_key=?', [scope]);
      }
    }
    return false;
  }

  void _recordFailedLogin(List<String> scopes, DateTime now) {
    final nowText = now.toIso8601String();
    for (final scope in scopes) {
      final rows = db.select(
        'SELECT window_started_at, attempts FROM auth_rate_limits WHERE scope_key=?',
        [scope],
      );
      var attempts = 1;
      var windowStart = nowText;
      if (rows.isNotEmpty) {
        final started = DateTime.tryParse('${rows.first['window_started_at']}');
        if (started != null && now.difference(started) < const Duration(minutes: 15)) {
          attempts = (rows.first['attempts'] as num).toInt() + 1;
          windowStart = started.toIso8601String();
        }
      }
      final blockedUntil = attempts >= 5
          ? now.add(const Duration(minutes: 15)).toIso8601String()
          : null;
      db.execute('''INSERT INTO auth_rate_limits(scope_key,window_started_at,attempts,blocked_until)
        VALUES(?,?,?,?) ON CONFLICT(scope_key) DO UPDATE SET
        window_started_at=excluded.window_started_at, attempts=excluded.attempts,
        blocked_until=excluded.blocked_until''',
        [scope, windowStart, attempts, blockedUntil]);
    }
  }

  void _clearLoginFailures(List<String> scopes) {
    for (final scope in scopes) {
      db.execute('DELETE FROM auth_rate_limits WHERE scope_key=?', [scope]);
    }
  }

  bool _hasTable(String table) => db.select("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", [table]).isNotEmpty;
  static const _syncEntityTypes = <String>{
    'pumps', 'beneficiaries', 'partners', 'workers', 'accounts',
    'payment_methods', 'cashboxes', 'cashbox_transfers', 'payments',
    'expenses', 'worker_transactions', 'partner_transactions',
    'journal_entries', 'journal_lines', 'irrigations', 'cloud_periods',
    'diesel_movements', 'queue_entries', 'booking_requests',
    'irrigation_sessions', 'beneficiary_manual_debts', 'general_accounts',
    'general_account_transactions', 'accountant_reconciliation_months',
    'period_closures', 'cash_reconciliations',
  };

  Object? _canonicalSyncValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalSyncValue(value[key]),
      };
    }
    if (value is List) return value.map(_canonicalSyncValue).toList();
    return value;
  }

  String _canonicalSyncJson(Object? value) => jsonEncode(_canonicalSyncValue(value));

  void _ensureFinancialStationOwnership() {
    const tables = ['payments','expenses','diesel_movements','cashbox_transfers','worker_transactions','partner_transactions'];
    for (final table in tables) {
      if (!_hasTable(table)) continue;
      final cols = db.select('PRAGMA table_info($table)');
      if (!cols.any((x) => x['name'] == 'station_id')) db.execute('ALTER TABLE $table ADD COLUMN station_id INTEGER REFERENCES stations(id)');
      db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_station_date ON $table(station_id,date)');
    }
    if (!tables.every(_hasTable) || !['stations','cashboxes','payment_methods','beneficiaries','workers','partners','irrigations'].every(_hasTable)) return;
    db.execute("""UPDATE payments SET station_id=(SELECT station_id FROM cashboxes WHERE id=payments.cashbox_id)
      WHERE station_id IS NULL AND (SELECT station_id FROM cashboxes WHERE id=payments.cashbox_id) IS NOT NULL
      AND (SELECT station_id FROM payment_methods WHERE id=payments.payment_method_id)=(SELECT station_id FROM cashboxes WHERE id=payments.cashbox_id)
      AND ((beneficiary_id IS NOT NULL AND (SELECT station_id FROM beneficiaries WHERE id=payments.beneficiary_id)=(SELECT station_id FROM cashboxes WHERE id=payments.cashbox_id))
        OR (worker_id IS NOT NULL AND (SELECT station_id FROM workers WHERE id=payments.worker_id)=(SELECT station_id FROM cashboxes WHERE id=payments.cashbox_id))
        OR (partner_id IS NOT NULL AND (SELECT station_id FROM partners WHERE id=payments.partner_id)=(SELECT station_id FROM cashboxes WHERE id=payments.cashbox_id)))""");
    db.execute("""UPDATE expenses SET station_id=(SELECT station_id FROM cashboxes WHERE id=expenses.cashbox_id)
      WHERE station_id IS NULL AND cashbox_id IS NOT NULL AND payment_method_id IS NOT NULL
      AND (SELECT station_id FROM cashboxes WHERE id=expenses.cashbox_id) IS NOT NULL
      AND (SELECT station_id FROM payment_methods WHERE id=expenses.payment_method_id)=(SELECT station_id FROM cashboxes WHERE id=expenses.cashbox_id)
      AND (beneficiary_id IS NULL OR (SELECT station_id FROM beneficiaries WHERE id=expenses.beneficiary_id)=(SELECT station_id FROM cashboxes WHERE id=expenses.cashbox_id))
      AND (worker_id IS NULL OR (SELECT station_id FROM workers WHERE id=expenses.worker_id)=(SELECT station_id FROM cashboxes WHERE id=expenses.cashbox_id))
      AND (partner_id IS NULL OR (SELECT station_id FROM partners WHERE id=expenses.partner_id)=(SELECT station_id FROM cashboxes WHERE id=expenses.cashbox_id))""");
    db.execute("""UPDATE diesel_movements SET station_id=COALESCE((SELECT station_id FROM irrigations WHERE id=diesel_movements.irrigation_id),(SELECT station_id FROM beneficiaries WHERE id=diesel_movements.beneficiary_id),(SELECT station_id FROM cashboxes WHERE id=diesel_movements.cashbox_id))
      WHERE station_id IS NULL AND (irrigation_id IS NOT NULL OR beneficiary_id IS NOT NULL OR cashbox_id IS NOT NULL)
      AND (irrigation_id IS NULL OR (SELECT station_id FROM irrigations WHERE id=diesel_movements.irrigation_id) IS NOT NULL)
      AND (beneficiary_id IS NULL OR (SELECT station_id FROM beneficiaries WHERE id=diesel_movements.beneficiary_id) IS NOT NULL)
      AND (cashbox_id IS NULL OR (SELECT station_id FROM cashboxes WHERE id=diesel_movements.cashbox_id) IS NOT NULL)
      AND (SELECT COUNT(DISTINCT station_id) FROM (SELECT station_id FROM irrigations WHERE id=diesel_movements.irrigation_id AND diesel_movements.irrigation_id IS NOT NULL UNION ALL SELECT station_id FROM beneficiaries WHERE id=diesel_movements.beneficiary_id AND diesel_movements.beneficiary_id IS NOT NULL UNION ALL SELECT station_id FROM cashboxes WHERE id=diesel_movements.cashbox_id AND diesel_movements.cashbox_id IS NOT NULL))=1""");
    db.execute("""UPDATE cashbox_transfers SET station_id=(SELECT station_id FROM cashboxes WHERE id=cashbox_transfers.to_cashbox_id)
      WHERE station_id IS NULL AND to_cashbox_id IS NOT NULL AND (SELECT station_id FROM cashboxes WHERE id=cashbox_transfers.to_cashbox_id) IS NOT NULL
      AND (from_cashbox_id IS NULL OR (SELECT station_id FROM cashboxes WHERE id=cashbox_transfers.from_cashbox_id)=(SELECT station_id FROM cashboxes WHERE id=cashbox_transfers.to_cashbox_id))""");
    db.execute("""UPDATE worker_transactions SET station_id=(SELECT station_id FROM workers WHERE id=worker_transactions.worker_id)
      WHERE station_id IS NULL AND (SELECT station_id FROM workers WHERE id=worker_transactions.worker_id) IS NOT NULL
      AND (cashbox_id IS NULL OR (SELECT station_id FROM cashboxes WHERE id=worker_transactions.cashbox_id)=(SELECT station_id FROM workers WHERE id=worker_transactions.worker_id))""");
    db.execute("""UPDATE partner_transactions SET station_id=(SELECT station_id FROM partners WHERE id=partner_transactions.partner_id)
      WHERE station_id IS NULL AND (SELECT station_id FROM partners WHERE id=partner_transactions.partner_id) IS NOT NULL""");
  }


  Router router() {
    final r = Router();
    // وقت الخادم لمزامنة «مصدر الوقت = الخادم» في التطبيق (مسار عام بلا مصادقة).
    r.get('/api/v1/time', (Request req) => Response.ok(jsonEncode({'now': DateTime.now().toUtc().toIso8601String()}), headers: {'Content-Type': 'application/json'}));
    r.post('/api/v1/auth/login', _adminLogin);
    r.post('/api/v1/sync/events', _auth(_syncPush, roles: {'manager','accountant','operations'}));
    r.get('/api/v1/sync/inbox', _auth(_syncInbox, roles: {'manager','accountant','operations'}));
    r.get('/api/v1/dashboard', _auth(_dashboard, roles: {'manager','accountant','operations'}));
    r.get('/api/v1/settings', _auth(_settings, roles: {'manager','accountant'}));
    r.put('/api/v1/settings', _auth(_settingsPut, roles: {'manager'}));
    r.get('/api/v1/beneficiaries', _auth(_beneficiaries, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/beneficiaries', _auth(_beneficiaryCreate, roles: {'manager','accountant'}));
    r.get('/api/v1/beneficiaries/<id>', _auth(_beneficiary, roles: {'manager','accountant','operations'}));
    r.put('/api/v1/beneficiaries/<id>', _auth(_beneficiaryUpdate, roles: {'manager','accountant'}));
    r.delete('/api/v1/beneficiaries/<id>', _auth(_beneficiaryDelete, roles: {'manager','accountant'}));
    r.get('/api/v1/beneficiaries/<id>/statement', _auth(_beneficiaryStatement, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/irrigations', _auth(_irrigationCreate, roles: {'manager','accountant'}));
    r.get('/api/v1/irrigations', _auth(_irrigations, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/irrigations/<id>/cancel', _auth(_irrigationCancel, roles: {'manager','accountant'}));
    r.get('/api/v1/sessions', _auth(_sessions, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/sessions/start', _auth(_sessionStart, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/sessions/<id>/finish', _auth(_sessionFinish, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/sessions/<id>/postpone', _auth(_sessionPostpone, roles: {'manager','accountant','operations'}));
    r.get('/api/v1/queue', _auth(_queue, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/queue', _auth(_queueAdd, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/queue/<id>/postpone', _auth(_queuePostpone, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/queue/<id>/skip', _auth(_queueSkip, roles: {'manager'}));
    r.get('/api/v1/bookings', _auth(_bookings, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/bookings/<id>/schedule', _auth(_bookingSchedule, roles: {'manager','accountant'}));
    r.post('/api/v1/bookings/<id>/cancel', _auth(_bookingCancel, roles: {'manager','accountant'}));
    r.get('/api/v1/payments', _auth(_payments, roles: {'manager','accountant'}));
    r.post('/api/v1/payments', _auth(_paymentCreate, roles: {'manager','accountant'}));
    r.get('/api/v1/cashboxes', _auth(_cashboxes, roles: {'manager','accountant'}));
    r.post('/api/v1/cashbox-transfers', _auth(_cashboxTransfer, roles: {'manager','accountant'}));
    r.get('/api/v1/diesel', _auth(_diesel, roles: {'manager','accountant','operations'}));
    r.post('/api/v1/diesel/movements', _auth(_dieselMovement, roles: {'manager','accountant'}));
    r.get('/api/v1/expenses', _auth(_expenses, roles: {'manager','accountant'}));
    r.post('/api/v1/expenses', _auth(_expenseCreate, roles: {'manager','accountant'}));
    r.get('/api/v1/workers', _auth(_workers, roles: {'manager','accountant'}));
    r.post('/api/v1/workers', _auth(_workerCreate, roles: {'manager','accountant'}));
    r.post('/api/v1/workers/<id>/transactions', _auth(_workerTransaction, roles: {'manager','accountant'}));
    r.get('/api/v1/partners', _auth(_partners, roles: {'manager','accountant'}));
    r.post('/api/v1/partners', _auth(_partnerCreate, roles: {'manager','accountant'}));
    r.post('/api/v1/partners/<id>/transactions', _auth(_partnerTransaction, roles: {'manager','accountant'}));
    r.get('/api/v1/accounting/journal', _auth(_journalReport, roles: {'manager','accountant'}));
    r.get('/api/v1/accounting/ledger', _auth(_ledger, roles: {'manager','accountant'}));
    r.get('/api/v1/reports/<name>', _auth(_reports, roles: {'manager','accountant'}));
    r.post('/api/v1/backup', _auth(_backup, roles: {'manager'}));
    r.post('/api/v1/restore', _auth(_restore, roles: {'manager'}));
    r.post('/api/v1/beneficiary/request-code', _beneficiaryRequestCode);
    r.post('/api/v1/beneficiary/session', _beneficiaryLogin);
    r.get('/api/v1/beneficiary/me', _beneficiaryAuth(_beneficiaryMe));
    r.get('/api/v1/beneficiary/requests', _beneficiaryAuth(_beneficiaryRequests));
    r.post('/api/v1/beneficiary/requests', _beneficiaryAuth(_beneficiaryRequestCreate));
    r.post('/api/v1/beneficiary/requests/<id>/cancel', _beneficiaryAuth(_beneficiaryRequestCancel));
    r.get('/api/v1/beneficiary/account', _beneficiaryAuth(_beneficiaryAccount));
    r.get('/api/v1/beneficiary/notifications', _beneficiaryAuth(_beneficiaryNotifications));
    r.post('/api/v1/beneficiary/notifications/<id>/read', _beneficiaryAuth(_beneficiaryNotificationRead));
    return r;
  }

  List<Map<String,Object?>> _rows(ResultSet rows) => rows.map((row) => {
    for (final column in rows.columnNames) column: row[column]
  }).toList();
  Response _json(Object body, {int status = 200}) => Response(status, body: jsonEncode(body), headers: {'content-type':'application/json; charset=utf-8'});
  Future<Map<String,dynamic>> _body(Request r) async { try { final raw = await r.readAsString(); if (raw.trim().isEmpty) return {}; return jsonDecode(raw) as Map<String,dynamic>; } catch (_) { return {}; } }
  String _hash(String v) => sha256.convert(utf8.encode(v)).toString();
  String _token(Map<String,dynamic> claims) => JWT(claims).sign(SecretKey(jwtSecret), expiresIn: const Duration(hours: 12));
  Map<String,dynamic>? _verify(Request r) { final h=r.headers['authorization']??''; if(!h.startsWith('Bearer ')) return null; try { return JWT.verify(h.substring(7),SecretKey(jwtSecret)).payload as Map<String,dynamic>; } catch (_) { return null; } }
  Handler _auth(
    Future<Response> Function(Request, Map<String, dynamic>) fn, {
    Set<String> roles = const {},
  }) => (Request r) async {
    final claims = _verify(r);
    if (claims == null || claims['kind'] != 'admin') {
      return _json({'error': 'جلسة غير صالحة'}, status: 401);
    }

    final userId = (claims['userId'] as num?)?.toInt() ?? 0;
    final stationId = (claims['stationId'] as num?)?.toInt() ?? 0;
    final tokenRole = claims['role'];
    if (userId <= 0 || stationId <= 0 || tokenRole is! String) {
      return _json({'error': 'جلسة غير صالحة'}, status: 401);
    }

    // Re-check the account on every request so disabling a user, changing
    // their role, or moving them to another station revokes existing JWTs.
    final users = db.select(
      'SELECT station_id, role, active FROM app_users WHERE id=? LIMIT 1',
      [userId],
    );
    if (users.isEmpty) {
      return _json({'error': 'الحساب غير موجود أو تم إيقافه'}, status: 401);
    }
    final user = users.first;
    final currentStation = (user['station_id'] as num?)?.toInt() ?? 0;
    final currentRole = user['role'];
    final active = (user['active'] as num?)?.toInt() == 1;
    if (!active ||
        currentStation != stationId ||
        currentRole != tokenRole) {
      return _json({'error': 'انتهت صلاحية الجلسة؛ يرجى تسجيل الدخول مجدداً'}, status: 401);
    }

    if (roles.isNotEmpty && !roles.contains(tokenRole)) {
      return _json({'error': 'لا تملك صلاحية تنفيذ العملية'}, status: 403);
    }
    return await fn(r, claims);
  };
  Handler _beneficiaryAuth(Future<Response> Function(Request,Map<String,dynamic>) fn)=>(Request r) async { final c=_verify(r); if(c==null||c['kind']!='beneficiary')return _json({'error':'جلسة المستفيد غير صالحة'},status:401); final exp=db.select("SELECT bs.id FROM beneficiary_sessions bs JOIN beneficiaries b ON b.id=bs.beneficiary_id WHERE bs.beneficiary_id=? AND bs.token_hash=? AND bs.revoked_at IS NULL AND bs.expires_at>? AND b.status='active' LIMIT 1",[c['beneficiaryId'],c['session'],DateTime.now().toIso8601String()]); if(exp.isEmpty)return _json({'error':'جلسة المستفيد منتهية'},status:401); return await fn(r,c); };

  int _stationForUser(int? userId) {
    if (userId == null || userId <= 0) {
      throw StateError('لا يمكن إنشاء قيد دون مستخدم ومحطة موثوقين');
    }
    final rows = db.select(
      'SELECT station_id FROM app_users WHERE id=? AND active=1 LIMIT 1',
      [userId],
    );
    if (rows.isEmpty) throw StateError('مستخدم القيد غير موجود أو غير نشط');
    final stationId = (rows.first['station_id'] as num?)?.toInt() ?? 0;
    if (stationId <= 0) throw StateError('محطة مستخدم القيد غير صالحة');
    return stationId;
  }

  void _journal({required String description, required String referenceType, int? referenceId, required List<Map<String,Object?>> lines, int? userId, DateTime? date}) {
    final debit=lines.fold<int>(0,(s,x)=>s+((x['debit'] as num?)?.round()??0));
    final credit=lines.fold<int>(0,(s,x)=>s+((x['credit'] as num?)?.round()??0));
    if(debit<=0 || debit!=credit) throw StateError('القيد غير متوازن');
    final stationId = _stationForUser(userId);
    final now=DateTime.now().toIso8601String();
    db.execute('INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)',[stationId,(date ?? DateTime.now()).toIso8601String(),referenceType,referenceId,description,'posted',userId,now]);
    final id=db.lastInsertRowId;
    for(final line in lines){db.execute('INSERT INTO journal_lines(journal_entry_id,account_id,beneficiary_id,worker_id,partner_id,debit,credit,memo) VALUES(?,?,?,?,?,?,?,?)',[id,line['account_id'],line['beneficiary_id'],line['worker_id'],line['partner_id'],line['debit'],line['credit'],line['memo']]);}
  }
  Future<Response> _atomic(Future<Response> Function() work) async {
    db.execute('BEGIN IMMEDIATE');
    try { final response=await work(); if(response.statusCode>=400){db.execute('ROLLBACK');}else{db.execute('COMMIT');} return response; }
    catch(e){try{db.execute('ROLLBACK');}catch(_){} return _json({'error':'فشلت العملية الذرية: $e'},status:422);}
  }
  int _accountId(String code){final r=db.select('SELECT id FROM accounts WHERE code=? LIMIT 1',[code]);if(r.isEmpty)throw StateError('الحساب غير موجود: $code');return r.first['id'] as int;}
  void _ensureSyncTables() {
    db.execute('''CREATE TABLE IF NOT EXISTS sync_entity_versions (
      station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
      entity_type TEXT NOT NULL,
      entity_key TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(station_id,entity_type,entity_key)
    )''');
    db.execute('''CREATE TABLE IF NOT EXISTS sync_event_log (
      server_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
      event_id TEXT NOT NULL,
      source_device TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_key TEXT NOT NULL,
      operation TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      base_version INTEGER NOT NULL,
      server_version INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('accepted','conflict')),
      created_at TEXT NOT NULL,
      UNIQUE(station_id,event_id)
    )''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_sync_event_station_sequence ON sync_event_log(station_id,server_sequence)');
    db.execute('''CREATE TABLE IF NOT EXISTS sync_entity_links (
      station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
      entity_type TEXT NOT NULL,
      global_id TEXT NOT NULL,
      local_id INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY(station_id,entity_type,global_id),
      UNIQUE(station_id,entity_type,local_id)
    )''');
  }

  String _ensureProjectionTargetIdentity({
    required int station,
    required String entityType,
    required int localId,
    required String now,
  }) {
    final existing = db.select(
      'SELECT global_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND local_id=? LIMIT 1',
      [station, entityType, localId],
    );
    if (existing.isNotEmpty) return existing.first['global_id'].toString();
    if (!_hasTable(entityType)) {
      throw StateError('جدول مرجع الإسقاط غير موجود: $entityType');
    }
    final columns = db.select('PRAGMA table_info($entityType)')
        .map((row) => row['name'].toString()).toSet();
    final rows = db.select('SELECT * FROM $entityType WHERE id=? LIMIT 1', [localId]);
    if (rows.isEmpty) throw StateError('مرجع الإسقاط غير موجود: $entityType/$localId');
    if (columns.contains('station_id') &&
        (rows.first['station_id'] as num?)?.toInt() != station) {
      throw StateError('مرجع الإسقاط يتبع محطة أخرى: $entityType/$localId');
    }
    final globalId = const Uuid().v4();
    db.execute(
      'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
      [station, entityType, globalId, localId, now],
    );
    return globalId;
  }

  Map<String, Object?> _projectionReference({
    required int station,
    required String targetTable,
    required int localId,
    required String now,
  }) {
    final globalId = _ensureProjectionTargetIdentity(
      station: station,
      entityType: targetTable,
      localId: localId,
      now: now,
    );
    final reference = <String, Object?>{
      'table': targetTable,
      'global_id': globalId,
    };
    final naturalColumns = switch (targetTable) {
      'accounts' => const ['code'],
      'cashboxes' => const ['name', 'currency'],
      'pumps' => const ['name', 'system_type'],
      'payment_methods' => const ['name', 'type'],
      _ => const <String>[],
    };
    if (naturalColumns.isNotEmpty) {
      final row = db.select(
        'SELECT ${naturalColumns.join(',')} FROM $targetTable WHERE id=? LIMIT 1',
        [localId],
      );
      if (row.isNotEmpty) {
        for (final column in naturalColumns) {
          reference[column] = row.first[column];
        }
      }
    }
    return reference;
  }

  void _appendSyncProjectionRow({
    required int station,
    required String sourceDevice,
    required bool publishToOrigin,
    required String now,
    required String table,
    required int localId,
    String? requestedGlobalId,
  }) {
    if (!_syncEntityTypes.contains(table) || !_hasTable(table)) {
      throw StateError('نوع إسقاط غير مدعوم: $table');
    }
    final columns = db.select('PRAGMA table_info($table)')
        .map((row) => row['name'].toString()).toSet();
    if (!columns.contains('id')) throw StateError('سجل الإسقاط بلا مفتاح محلي: $table');
    final rows = db.select('SELECT * FROM $table WHERE id=? LIMIT 1', [localId]);
    if (rows.isEmpty) throw StateError('سجل الإسقاط غير موجود: $table/$localId');
    final row = rows.first;
    if (columns.contains('station_id') &&
        (row['station_id'] as num?)?.toInt() != station) {
      throw StateError('سجل الإسقاط لا يتبع المحطة الحالية: $table/$localId');
    }
    final existing = db.select(
      'SELECT global_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND local_id=? LIMIT 1',
      [station, table, localId],
    );
    final existingGlobalId = existing.isEmpty ? null : existing.first['global_id'].toString();
    if (requestedGlobalId != null && existingGlobalId != null &&
        requestedGlobalId != existingGlobalId) {
      throw StateError('الهوية المحلية للأثر التابع لا تطابق هوية الخادم: $table/$localId');
    }
    final globalId = existingGlobalId ?? requestedGlobalId ?? const Uuid().v4();
    if (existing.isEmpty) {
      db.execute(
        'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
        [station, table, globalId, localId, now],
      );
    }

    const relations = <String, Map<String, String>>{
      'cloud_periods': {'irrigation_id': 'irrigations'},
      'journal_lines': {
        'journal_entry_id': 'journal_entries',
        'account_id': 'accounts',
        'beneficiary_id': 'beneficiaries',
        'worker_id': 'workers',
        'partner_id': 'partners',
      },
      'worker_transactions': {
        'worker_id': 'workers',
        'cashbox_id': 'cashboxes',
      },
      'partner_transactions': {'partner_id': 'partners'},
      'diesel_movements': {
        'beneficiary_id': 'beneficiaries',
        'irrigation_id': 'irrigations',
        'cashbox_id': 'cashboxes',
      },
      'irrigation_sessions': {
        'beneficiary_id': 'beneficiaries',
        'pump_id': 'pumps',
        'queue_entry_id': 'queue_entries',
        'booking_id': 'booking_requests',
      },
      'queue_entries': {'beneficiary_id': 'beneficiaries'},
      'booking_requests': {'beneficiary_id': 'beneficiaries'},
    };
    final refs = <String, Object?>{};
    for (final entry in (relations[table] ?? const <String, String>{}).entries) {
      if (!columns.contains(entry.key) || row[entry.key] == null) continue;
      final targetId = (row[entry.key] as num).toInt();
      refs[entry.key] = _projectionReference(
        station: station,
        targetTable: entry.value,
        localId: targetId,
        now: now,
      );
    }
    if (columns.contains('reference_id') && row['reference_id'] != null) {
      final referenceType = (row['reference_type'] ?? '').toString();
      final referenceTable = switch (table) {
        'journal_entries' => switch (referenceType) {
            'irrigation' => 'irrigations',
            'payment' => 'payments',
            'worker' => 'worker_transactions',
            'partner' => 'partner_transactions',
            'diesel_advance' => 'diesel_movements',
            _ => null,
          },
        'worker_transactions' when referenceType == 'irrigation' => 'irrigations',
        'partner_transactions' when referenceType == 'irrigation_profit' => 'irrigations',
        _ => null,
      };
      if (referenceTable != null) {
        refs['reference_id'] = _projectionReference(
          station: station,
          targetTable: referenceTable,
          localId: (row['reference_id'] as num).toInt(),
          now: now,
        );
      }
    }

    final payload = <String, Object?>{
      for (final column in columns)
        if (!const {'id', 'station_id', 'created_by'}.contains(column) &&
            (column != 'reference_id' || refs.containsKey('reference_id')))
          column: row[column],
      '_global_id': globalId,
      '_global_refs': refs,
      '_unresolved_refs': const <String, Object?>{},
    };
    final entityKey = '$table:$globalId';
    final versions = db.select(
      'SELECT version FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=? LIMIT 1',
      [station, table, entityKey],
    );
    final currentVersion = versions.isEmpty
        ? 0
        : (versions.first['version'] as num).toInt();
    final nextVersion = currentVersion + 1;
    final operation = existing.isEmpty ? 'create' : 'update';
    db.execute('''INSERT INTO sync_event_log
      (station_id,event_id,source_device,entity_type,entity_key,operation,payload_json,base_version,server_version,status,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,'accepted',?)''', [
      station,
      const Uuid().v4(),
      publishToOrigin ? '__server_projection__' : sourceDevice,
      table,
      entityKey,
      operation,
      _canonicalSyncJson(payload),
      currentVersion,
      nextVersion,
      now,
    ]);
    db.execute('''INSERT INTO sync_entity_versions
      (station_id,entity_type,entity_key,version,updated_at)
      VALUES(?,?,?,?,?) ON CONFLICT(station_id,entity_type,entity_key)
      DO UPDATE SET version=excluded.version,updated_at=excluded.updated_at''',
      [station, table, entityKey, nextVersion, now]);
  }

  void _appendSyncProjectionQuery({
    required int station,
    required String sourceDevice,
    required bool publishToOrigin,
    required String now,
    required String table,
    required String sql,
    required List<Object?> args,
    required List<String>? requestedIds,
  }) {
    if (!_hasTable(table)) {
      if (requestedIds != null && requestedIds.isNotEmpty) {
        throw StateError('جدول الإسقاط المطلوب غير موجود: $table');
      }
      return;
    }
    final rows = db.select(sql, args);
    if (requestedIds != null && requestedIds.length != rows.length) {
      throw StateError('عدد هويات الإسقاط لا يطابق عدد السجلات: $table');
    }
    for (var index = 0; index < rows.length; index++) {
      _appendSyncProjectionRow(
        station: station,
        sourceDevice: sourceDevice,
        publishToOrigin: publishToOrigin,
        now: now,
        table: table,
        localId: (rows[index]['id'] as num).toInt(),
        requestedGlobalId: requestedIds == null ? null : requestedIds[index],
      );
    }
  }

  void _appendBusinessEffectProjections({
    required int station,
    required String sourceDevice,
    required String entityType,
    required int businessId,
    required Map payload,
    required String now,
  }) {
    final rawIds = payload['_derived_global_ids'];
    final ids = rawIds is Map ? Map<String, dynamic>.from(rawIds) : const <String, dynamic>{};
    List<String>? requested(String table) {
      final value = ids[table];
      if (value == null) return null;
      if (value is! List || value.any((item) => item is! String)) {
        throw StateError('قائمة هويات الإسقاط غير صالحة: $table');
      }
      return value.cast<String>();
    }
    final publishToOrigin = rawIds is Map;
    void append(String table, String sql, List<Object?> args) {
      _appendSyncProjectionQuery(
        station: station,
        sourceDevice: sourceDevice,
        publishToOrigin: publishToOrigin,
        now: now,
        table: table,
        sql: sql,
        args: args,
        requestedIds: requested(table),
      );
    }

    if (entityType == 'irrigations') {
      append('cloud_periods',
        'SELECT cp.id FROM cloud_periods cp JOIN irrigations i ON i.id=cp.irrigation_id WHERE i.station_id=? AND cp.irrigation_id=? ORDER BY cp.start_datetime,cp.id',
        [station, businessId]);
      append('worker_transactions',
        "SELECT id FROM worker_transactions WHERE station_id=? AND reference_type='irrigation' AND reference_id=? ORDER BY id",
        [station, businessId]);
      append('partner_transactions',
        "SELECT id FROM partner_transactions WHERE station_id=? AND reference_type='irrigation_profit' AND reference_id=? ORDER BY id",
        [station, businessId]);
      append('diesel_movements',
        'SELECT id FROM diesel_movements WHERE station_id=? AND irrigation_id=? ORDER BY id',
        [station, businessId]);
      final journalClauses = <String>[
        "(je.reference_type='irrigation' AND je.reference_id=?)",
      ];
      final journalArgs = <Object?>[businessId];
      if (_hasTable('worker_transactions')) {
        journalClauses.add("""(je.reference_type='worker' AND je.reference_id IN (
          SELECT wt.id FROM worker_transactions wt
          WHERE wt.station_id=? AND wt.reference_type='irrigation' AND wt.reference_id=?
        ))""");
        journalArgs.addAll([station, businessId]);
      }
      if (_hasTable('partner_transactions')) {
        journalClauses.add("""(je.reference_type='partner' AND je.reference_id IN (
          SELECT pt.id FROM partner_transactions pt
          WHERE pt.station_id=? AND pt.reference_type='irrigation_profit' AND pt.reference_id=?
        ))""");
        journalArgs.addAll([station, businessId]);
      }
      if (_hasTable('diesel_movements')) {
        journalClauses.add("""(je.reference_type='diesel_advance' AND je.reference_id IN (
          SELECT dm.id FROM diesel_movements dm WHERE dm.station_id=? AND dm.irrigation_id=?
        ))""");
        journalArgs.addAll([station, businessId]);
      }
      final journalWhere = journalClauses.join(' OR ');
      append('journal_entries',
        'SELECT je.id FROM journal_entries je WHERE je.station_id=? AND ($journalWhere) ORDER BY je.id',
        [station, ...journalArgs]);
      append('journal_lines',
        'SELECT jl.id FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.station_id=? AND ($journalWhere) ORDER BY jl.id',
        [station, ...journalArgs]);
      final irrigation = db.select(
        'SELECT session_id,queue_entry_id,booking_id FROM irrigations WHERE id=? AND station_id=? LIMIT 1',
        [businessId, station],
      );
      if (irrigation.isEmpty) throw StateError('السقاية غير موجودة عند نشر آثارها');
      final values = irrigation.first;
      final sessionId = (values['session_id'] as num?)?.toInt();
      if (sessionId != null) append('irrigation_sessions',
        'SELECT s.id FROM irrigation_sessions s JOIN beneficiaries b ON b.id=s.beneficiary_id JOIN pumps p ON p.id=s.pump_id WHERE s.id=? AND b.station_id=? AND p.station_id=?',
        [sessionId, station, station]);
      final queueId = (values['queue_entry_id'] as num?)?.toInt();
      if (queueId != null) append('queue_entries',
        'SELECT q.id FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE q.id=? AND b.station_id=?',
        [queueId, station]);
      final bookingId = (values['booking_id'] as num?)?.toInt();
      if (bookingId != null) append('booking_requests',
        'SELECT bq.id FROM booking_requests bq JOIN beneficiaries b ON b.id=bq.beneficiary_id WHERE bq.id=? AND b.station_id=?',
        [bookingId, station]);
      return;
    }
    if (entityType == 'payments') {
      final payment = db.select(
        'SELECT cashbox_id FROM payments WHERE id=? AND station_id=? LIMIT 1',
        [businessId, station],
      );
      if (payment.isEmpty) throw StateError('سند القبض غير موجود عند نشر آثاره');
      final cashboxId = (payment.first['cashbox_id'] as num).toInt();
      append('journal_entries',
        "SELECT id FROM journal_entries WHERE station_id=? AND reference_type='payment' AND reference_id=? ORDER BY id",
        [station, businessId]);
      append('journal_lines',
        "SELECT jl.id FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.station_id=? AND je.reference_type='payment' AND je.reference_id=? ORDER BY jl.id",
        [station, businessId]);
      append('cashboxes',
        'SELECT id FROM cashboxes WHERE id=? AND station_id=?',
        [cashboxId, station]);
    }
  }

  bool _hasSyncProjectionLink(int station, String entityType, Map payload) {
    final globalId = (payload['_global_id'] ?? '').toString();
    if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId)) {
      return false;
    }
    return db.select(
      'SELECT 1 FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',
      [station, entityType, globalId],
    ).isNotEmpty;
  }

  bool _isDerivedSyncEvent(
    int station,
    String entityType,
    String operation,
    Map payload,
  ) {
    // A child command is superseded only after the parent handler has created
    // and linked that exact child row. This prevents early child events from
    // being silently acknowledged before their parent arrives.
    if (const {'journal_entries', 'journal_lines', 'cloud_periods'}.contains(entityType)) {
      return _hasSyncProjectionLink(station, entityType, payload);
    }
    if (entityType == 'diesel_movements' &&
        payload['irrigation_id'] != null) {
      return _hasSyncProjectionLink(station, entityType, payload);
    }
    if (entityType == 'worker_transactions' &&
        payload['reference_type'] == 'irrigation') {
      return _hasSyncProjectionLink(station, entityType, payload);
    }
    if (entityType == 'partner_transactions' &&
        payload['reference_type'] == 'irrigation_profit') {
      return _hasSyncProjectionLink(station, entityType, payload);
    }
    // A completed session is closed by the accepted irrigation command. A
    // legacy queued update for the same completion is acknowledged as covered.
    if (entityType == 'irrigation_sessions' &&
        operation == 'update' && payload['status'] == 'completed') {
      final globalId = (payload['_global_id'] ?? '').toString();
      final links = db.select(
        "SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='irrigation_sessions' AND global_id=? LIMIT 1",
        [station, globalId],
      );
      if (links.isNotEmpty) {
        final localId = (links.first['local_id'] as num).toInt();
        final current = db.select(
          'SELECT status,actual_end,timer_stopped_at FROM irrigation_sessions WHERE id=? LIMIT 1',
          [localId],
        );
        if (current.isNotEmpty &&
            current.first['status'] == 'completed' &&
            current.first['actual_end'] == payload['actual_end'] &&
            current.first['timer_stopped_at'] == payload['timer_stopped_at']) {
          return true;
        }
      }
    }
    return false;
  }

  int _resolveSyncReference({
    required int station, required String entityType, required String column, required Map references,
  }) {
    final raw = references[column];
    if (raw is! Map || raw['table'] != entityType) throw StateError('مرجع ' + column + ' العالمي غير صالح');
    final globalId = (raw['global_id'] ?? '').toString();
    final valid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId);
    if (!valid) throw StateError('هوية مرجع ' + column + ' غير صالحة');
    final linked = db.select('SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',[station,entityType,globalId]);
    final foreignLink = db.select('SELECT station_id FROM sync_entity_links WHERE entity_type=? AND global_id=? AND station_id<>? LIMIT 1',[entityType,globalId,station]);
    if (foreignLink.isNotEmpty) throw StateError('المرجع العالمي تابع لمحطة أخرى');
    if (linked.isNotEmpty) {
      final id = (linked.first['local_id'] as num).toInt();
      if (!_owns(entityType,id,station)) throw StateError('مرجع ' + column + ' لا يتبع المحطة الحالية');
      return id;
    }
    if (entityType == 'payment_methods') {
      final name = (raw['name'] ?? '').toString().trim();
      final type = (raw['type'] ?? '').toString().trim();
      if (name.isNotEmpty && type.isNotEmpty) {
        final rows = db.select('SELECT id FROM payment_methods WHERE station_id=? AND name=? AND type=? AND active=1 LIMIT 2',[station,name,type]);
        if (rows.length == 1) return (rows.first['id'] as num).toInt();
      }
    }
    if (entityType == 'cashboxes') {
      final name = (raw['name'] ?? '').toString().trim();
      final currency = (raw['currency'] ?? '').toString().trim();
      if (name.isNotEmpty && currency.isNotEmpty) {
        final rows = db.select('SELECT id FROM cashboxes WHERE station_id=? AND name=? AND currency=? AND active=1 LIMIT 2',[station,name,currency]);
        if (rows.length == 1) return (rows.first['id'] as num).toInt();
      }
    }
    throw StateError('لم يُعثر على مرجع ' + entityType + ' داخل المحطة');
  }

  String _syncCashboxLedgerCode(int station, int cashboxId) {
    final rows = db.select('SELECT ledger_account_code FROM cashboxes WHERE id=? AND station_id=? AND active=1 LIMIT 1',[cashboxId,station]);
    if (rows.isEmpty) throw StateError('الصندوق غير موجود أو غير مفعّل داخل المحطة');
    final own = (rows.first['ledger_account_code'] ?? '').toString();
    if (own.isNotEmpty) return own;
    final methods = db.select('SELECT ledger_account_code,type FROM payment_methods WHERE cashbox_id=? AND station_id=? AND active=1 ORDER BY id LIMIT 1',[cashboxId,station]);
    if (methods.isEmpty) return '1000';
    final configured = (methods.first['ledger_account_code'] ?? '').toString();
    if (configured.isNotEmpty) return configured;
    return switch (methods.first['type'].toString()) {'bank_transfer' => '1100', 'wallet' => '1120', _ => '1000'};
  }

  int _syncWorkerAccountId(int workerId) {
    final worker = db.select('SELECT name FROM workers WHERE id=? LIMIT 1', [workerId]);
    if (worker.isEmpty) throw StateError('العامل غير موجود');
    final code = '2100.W' + workerId.toString();
    final existing = db.select('SELECT id FROM accounts WHERE code=? LIMIT 1', [code]);
    if (existing.isNotEmpty) return (existing.first['id'] as num).toInt();
    final parent = _accountId('2100');
    db.execute(
      'INSERT INTO accounts(parent_id,code,name,type) VALUES(?,?,?,?)',
      [parent, code, 'حساب العامل الشخصي: ' + worker.first['name'].toString(), 'liability'],
    );
    return db.lastInsertRowId;
  }

  int _syncPartnerAccountId(int partnerId) {
    final partner = db.select('SELECT name FROM partners WHERE id=? LIMIT 1',[partnerId]);
    if (partner.isEmpty) throw StateError('الشريك غير موجود');
    final code = '2200.P' + partnerId.toString();
    final existing = db.select('SELECT id FROM accounts WHERE code=? LIMIT 1',[code]);
    if (existing.isNotEmpty) return (existing.first['id'] as num).toInt();
    final parent = _accountId('2200');
    db.execute('INSERT INTO accounts(parent_id,code,name,type) VALUES(?,?,?,?)',[parent,code,'حساب الشريك الشخصي: ' + partner.first['name'].toString(),'liability']);
    return db.lastInsertRowId;
  }

  void _ensureSyncCancellationColumns(String table) {
    if (!const {'expenses','cashbox_transfers'}.contains(table)) throw StateError('جدول الإلغاء غير مسموح');
    final columns = db.select('PRAGMA table_info($table)').map((row)=>(row['name'] ?? '').toString()).toSet();
    if (!columns.contains('status')) db.execute("ALTER TABLE $table ADD COLUMN status TEXT NOT NULL DEFAULT 'posted'");
    if (!columns.contains('cancelled_at')) db.execute('ALTER TABLE $table ADD COLUMN cancelled_at TEXT');
    if (!columns.contains('cancel_reason')) db.execute('ALTER TABLE $table ADD COLUMN cancel_reason TEXT');
  }

  void _applySyncExpense({required int station, required String entityKey, required String operation, required Map payload, required String now, required int? userId, required String? role}) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بمزامنة المصروفات');
    if (userId == null || _stationForUser(userId) != station) throw StateError('مستخدم المصروف لا يتبع المحطة الموثقة');
    final globalId = (payload['_global_id'] ?? '').toString();
    final valid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId);
    if (!valid || entityKey != 'expenses:' + globalId) throw StateError('الهوية العالمية للمصروف غير صالحة');
    final links = db.select("SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='expenses' AND global_id=? LIMIT 1",[station,globalId]);
    _ensureSyncCancellationColumns('expenses');
    if (operation == 'delete') throw UnsupportedError('استخدم تحديث status=cancelled مع سبب الإلغاء وتاريخه؛ الحذف المباشر ممنوع');
    if (operation == 'update' && payload['status'] == 'cancelled') {
      if (links.isEmpty) throw StateError('المصروف غير مرتبط بهذه الهوية العالمية');
      final id = (links.first['local_id'] as num).toInt();
      final rows = db.select("SELECT * FROM expenses WHERE id=? AND station_id=? LIMIT 1",[id,station]);
      if (rows.isEmpty || rows.first['status'] != 'posted') throw StateError('المصروف غير موجود أو سبق إلغاؤه');
      final expense = rows.first;
      final reason = (payload['cancel_reason'] ?? '').toString().trim();
      final cancelledAt = DateTime.tryParse((payload['cancelled_at'] ?? '').toString());
      if (reason.isEmpty || cancelledAt == null) throw StateError('سبب الإلغاء وتاريخه مطلوبان');
      for (final key in const ['amount','category','date','cashbox_id','payment_method_id','partner_id','title']) {
        if (payload.containsKey(key) && payload[key] != expense[key]) throw StateError('لا يسمح بتغيير بيانات المصروف أثناء الإلغاء');
      }
      final amount = (expense['amount'] as num).toInt();
      final cashboxId = (expense['cashbox_id'] as num?)?.toInt();
      if (cashboxId == null) throw StateError('الصندوق الأصلي للمصروف غير محدد');
      final original = db.select("SELECT id FROM journal_entries WHERE station_id=? AND reference_type='expense' AND reference_id=? AND status='posted' ORDER BY id",[station,id]);
      if (original.length != 1) throw StateError('يجب وجود قيد أصلي واحد مرحّل للمصروف');
      final originalId = (original.single['id'] as num).toInt();
      final lines = db.select('SELECT account_id,beneficiary_id,worker_id,partner_id,debit,credit,memo FROM journal_lines WHERE journal_entry_id=? ORDER BY id',[originalId]);
      final debit = lines.fold<int>(0,(sum,line)=>sum+(line['debit'] as num).toInt());
      final credit = lines.fold<int>(0,(sum,line)=>sum+(line['credit'] as num).toInt());
      final cashAccountId = _accountId(_syncCashboxLedgerCode(station,cashboxId));
      final cashLineValid = lines.any((line) => (line['account_id'] as num).toInt()==cashAccountId &&
          (line['debit'] as num).toInt()==0 && (line['credit'] as num).toInt()==amount);
      final expenseLineValid = lines.any((line) => (line['debit'] as num).toInt()==amount &&
          (line['credit'] as num).toInt()==0);
      if (lines.length != 2 || debit != amount || credit != amount || !cashLineValid || !expenseLineValid ||
          db.select("SELECT 1 FROM journal_entries WHERE reference_type='reversal' AND reference_id=? LIMIT 1",[originalId]).isNotEmpty) {
        throw StateError('القيد الأصلي غير متوازن أو لا يطابق حساب الصندوق وقيمة المصروف أو سبق عكسه');
      }
      db.execute('UPDATE cashboxes SET current_balance=current_balance+? WHERE id=? AND station_id=?',[amount,cashboxId,station]);
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر رد مبلغ المصروف إلى الصندوق');
      db.execute("INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)",[station,cancelledAt.toIso8601String(),'reversal',originalId,'عكس مصروف رقم $id: $reason','posted',userId,now]);
      final reversalId = db.lastInsertRowId;
      for (final line in lines) {
        db.execute('INSERT INTO journal_lines(journal_entry_id,account_id,beneficiary_id,worker_id,partner_id,debit,credit,memo) VALUES(?,?,?,?,?,?,?,?)',[reversalId,line['account_id'],line['beneficiary_id'],line['worker_id'],line['partner_id'],line['credit'],line['debit'],'عكس: ${line['memo'] ?? ''}']);
      }
      db.execute("UPDATE expenses SET status='cancelled',cancelled_at=?,cancel_reason=? WHERE id=? AND station_id=? AND status='posted'",[cancelledAt.toIso8601String(),reason,id,station]);
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تثبيت إلغاء المصروف');
      return;
    }
    if (operation == 'update') {
      if (links.isEmpty) throw StateError('المصروف غير مرتبط بهذه الهوية العالمية');
      final id = (links.first['local_id'] as num).toInt();
      final rows = db.select("SELECT title,notes,amount,category,date,cashbox_id,payment_method_id,partner_id FROM expenses WHERE id=? AND station_id=? AND status='posted' LIMIT 1",[id,station]);
      if (rows.isEmpty) throw StateError('المصروف غير موجود أو غير مرحّل ضمن المحطة');
      final row = rows.first;
      for (final key in const ['amount','category','date','cashbox_id','payment_method_id','partner_id']) {
        if (payload.containsKey(key) && payload[key] != row[key]) throw StateError('يسمح بتعديل عنوان المصروف وملاحظاته فقط دون تغيير أثره المالي');
      }
      final title = (payload['title'] ?? row['title']).toString().trim();
      if (title.isEmpty) throw StateError('عنوان المصروف مطلوب');
      db.execute('UPDATE expenses SET title=?,notes=? WHERE id=? AND station_id=?',[title,payload.containsKey('notes') ? payload['notes'] : row['notes'],id,station]);
      return;
    }
    if (operation != 'create' || links.isNotEmpty) throw StateError('هوية المصروف مستخدمة أو العملية غير مدعومة');
    if (!_hasTable('expenses')) throw StateError('جدول المصروفات غير موجود');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع المصروف العالمية مفقودة');
    final methodId = _resolveSyncReference(station:station,entityType:'payment_methods',column:'payment_method_id',references:refs);
    final cashboxId = _resolveSyncReference(station:station,entityType:'cashboxes',column:'cashbox_id',references:refs);
    final method = db.select('SELECT cashbox_id,active FROM payment_methods WHERE id=? AND station_id=? LIMIT 1',[methodId,station]);
    final cash = db.select('SELECT active FROM cashboxes WHERE id=? AND station_id=? LIMIT 1',[cashboxId,station]);
    if (method.isEmpty || (method.first['active'] as num?)?.toInt()!=1 || cash.isEmpty || (cash.first['active'] as num?)?.toInt()!=1) throw StateError('طريقة الدفع أو الصندوق غير نشط أو لا يتبع المحطة');
    final methodCashbox = (method.first['cashbox_id'] as num?)?.toInt();
    if (methodCashbox != null && methodCashbox != cashboxId) throw StateError('الصندوق المختار لا يطابق الصندوق المرتبط بطريقة الدفع');
    int? beneficiaryId, workerId, partnerId;
    if (payload['beneficiary_id'] != null) beneficiaryId = _resolveSyncReference(station:station,entityType:'beneficiaries',column:'beneficiary_id',references:refs);
    if (payload['worker_id'] != null) workerId = _resolveSyncReference(station:station,entityType:'workers',column:'worker_id',references:refs);
    if (payload['partner_id'] != null) partnerId = _resolveSyncReference(station:station,entityType:'partners',column:'partner_id',references:refs);
    final category = (payload['category'] ?? 'other').toString();
    if (!const {'workers','partners','fuel','oil','grease','maintenance','parts','transport','admin','other'}.contains(category)) throw StateError('تصنيف المصروف غير صالح');
    if (category == 'workers' && partnerId == null) throw StateError('أجور العاملين تسجل كاستحقاق عامل ثم تسوى بالدفع، ولا تسجل كمصروف عام');
    final amountValue = payload['amount'];
    if (amountValue is! num || amountValue <= 0 || amountValue != amountValue.round()) throw StateError('قيمة المصروف يجب أن تكون عدداً صحيحاً أكبر من صفر');
    final amount = amountValue.toInt();
    final title = (payload['title'] ?? 'مصروف').toString().trim();
    if (title.isEmpty) throw StateError('عنوان المصروف مطلوب');
    final date = DateTime.tryParse((payload['date'] ?? '').toString());
    if (date == null) throw StateError('تاريخ المصروف غير صالح');
    if (payload['status'] != null && payload['status'] != 'posted') throw StateError('لا تقبل مزامنة مصروف غير مرحّل كإنشاء مالي');
    db.execute('INSERT INTO expenses(station_id,category,title,amount,date,payment_method_id,cashbox_id,beneficiary_id,worker_id,partner_id,attachment_path,notes,status,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[station,category,title,amount,date.toIso8601String(),methodId,cashboxId,beneficiaryId,workerId,partnerId,payload['attachment_path'],payload['notes'],'posted',userId]);
    final expenseId = db.lastInsertRowId;
    db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=? AND station_id=? AND active=1',[amount,cashboxId,station]);
    if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تحديث رصيد صندوق المصروف');
    final expenseCode = switch(category) {'workers' => '5000', 'partners' => '5030', 'fuel' || 'diesel' => '5010', 'oil' || 'grease' => '5020', 'maintenance' || 'parts' => '5030', _ => '5030'};
    final debitAccount = partnerId == null ? _accountId(expenseCode) : _syncPartnerAccountId(partnerId);
    final cashAccount = _accountId(_syncCashboxLedgerCode(station,cashboxId));
    _journal(description:partnerId == null ? title : title + ' (مصروف خاص بالشريك)',referenceType:'expense',referenceId:expenseId,userId:userId,date:date,lines:[{'account_id':debitAccount,'partner_id':partnerId,'debit':amount,'credit':0},{'account_id':cashAccount,'debit':0,'credit':amount}]);
    db.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,'expenses',?,?,?)",[station,globalId,expenseId,now]);
  }

  void _applySyncCashboxTransfer({required int station, required String entityKey, required String operation, required Map payload, required String now, required int? userId, required String? role}) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بمزامنة التحويلات');
    if (userId == null || _stationForUser(userId) != station) throw StateError('مستخدم التحويل لا يتبع المحطة الموثقة');
    final globalId = (payload['_global_id'] ?? '').toString();
    final valid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId);
    if (!valid || entityKey != 'cashbox_transfers:' + globalId) throw StateError('الهوية العالمية للتحويل غير صالحة');
    final links = db.select("SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='cashbox_transfers' AND global_id=? LIMIT 1",[station,globalId]);
    _ensureSyncCancellationColumns('cashbox_transfers');
    if (operation == 'delete') throw UnsupportedError('استخدم تحديث status=cancelled مع سبب الإلغاء وتاريخه؛ الحذف المباشر ممنوع');
    if (operation == 'update' && payload['status'] == 'cancelled') {
      if (links.isEmpty) throw StateError('التحويل غير مرتبط بهذه الهوية العالمية');
      final id = (links.first['local_id'] as num).toInt();
      final rows = db.select("SELECT * FROM cashbox_transfers WHERE id=? AND station_id=? LIMIT 1",[id,station]);
      if (rows.isEmpty || rows.first['status'] != 'posted') throw StateError('التحويل غير موجود أو سبق إلغاؤه');
      final transfer = rows.first;
      final reason = (payload['cancel_reason'] ?? '').toString().trim();
      final cancelledAt = DateTime.tryParse((payload['cancelled_at'] ?? '').toString());
      if (reason.isEmpty || cancelledAt == null) throw StateError('سبب الإلغاء وتاريخه مطلوبان');
      for (final key in const ['amount','from_cashbox_id','to_cashbox_id','is_opening_transfer','date']) {
        if (payload.containsKey(key) && payload[key] != transfer[key]) throw StateError('لا يسمح بتغيير بيانات التحويل أثناء الإلغاء');
      }
      final amount = (transfer['amount'] as num).toInt();
      final fromId = (transfer['from_cashbox_id'] as num?)?.toInt();
      final toId = (transfer['to_cashbox_id'] as num).toInt();
      final opening = (transfer['is_opening_transfer'] as num).toInt() == 1;
      final original = db.select("SELECT id FROM journal_entries WHERE station_id=? AND reference_type='cashbox_transfer' AND reference_id=? AND status='posted' ORDER BY id",[station,id]);
      if (original.length != 1) throw StateError('يجب وجود قيد أصلي واحد مرحّل للتحويل');
      final originalId = (original.single['id'] as num).toInt();
      final lines = db.select('SELECT account_id,beneficiary_id,worker_id,partner_id,debit,credit,memo FROM journal_lines WHERE journal_entry_id=? ORDER BY id',[originalId]);
      final debit = lines.fold<int>(0,(sum,line)=>sum+(line['debit'] as num).toInt());
      final credit = lines.fold<int>(0,(sum,line)=>sum+(line['credit'] as num).toInt());
      final expectedDebitAccount = _accountId(_syncCashboxLedgerCode(station,toId));
      final expectedCreditAccount = _accountId(opening ? '3000' : _syncCashboxLedgerCode(station,fromId!));
      final debitLineValid = lines.any((line) => (line['account_id'] as num).toInt()==expectedDebitAccount &&
          (line['debit'] as num).toInt()==amount && (line['credit'] as num).toInt()==0);
      final creditLineValid = lines.any((line) => (line['account_id'] as num).toInt()==expectedCreditAccount &&
          (line['debit'] as num).toInt()==0 && (line['credit'] as num).toInt()==amount);
      if (lines.length != 2 || debit != amount || credit != amount || !debitLineValid || !creditLineValid ||
          db.select("SELECT 1 FROM journal_entries WHERE reference_type='reversal' AND reference_id=? LIMIT 1",[originalId]).isNotEmpty) {
        throw StateError('القيد الأصلي غير متوازن أو لا يطابق حسابي التحويل وقيمته أو سبق عكسه');
      }
      if (fromId != null) {
        db.execute('UPDATE cashboxes SET current_balance=current_balance+? WHERE id=? AND station_id=?',[amount,fromId,station]);
        if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر رد المبلغ إلى صندوق المصدر');
      }
      db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=? AND station_id=?',[amount,toId,station]);
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر خصم المبلغ المعاد من صندوق الوجهة');
      db.execute("INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)",[station,cancelledAt.toIso8601String(),'reversal',originalId,'عكس تحويل صندوق رقم $id: $reason','posted',userId,now]);
      final reversalId = db.lastInsertRowId;
      for (final line in lines) {
        db.execute('INSERT INTO journal_lines(journal_entry_id,account_id,beneficiary_id,worker_id,partner_id,debit,credit,memo) VALUES(?,?,?,?,?,?,?,?)',[reversalId,line['account_id'],line['beneficiary_id'],line['worker_id'],line['partner_id'],line['credit'],line['debit'],'عكس: ${line['memo'] ?? ''}']);
      }
      db.execute("UPDATE cashbox_transfers SET status='cancelled',cancelled_at=?,cancel_reason=? WHERE id=? AND station_id=? AND status='posted'",[cancelledAt.toIso8601String(),reason,id,station]);
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تثبيت إلغاء التحويل');
      return;
    }
    if (operation == 'update') {
      if (links.isEmpty) throw StateError('التحويل غير مرتبط بهذه الهوية العالمية');
      final id = (links.first['local_id'] as num).toInt();
      final rows = db.select('SELECT reference,notes FROM cashbox_transfers WHERE id=? AND station_id=? LIMIT 1',[id,station]);
      if (rows.isEmpty) throw StateError('التحويل غير موجود ضمن المحطة');
      db.execute('UPDATE cashbox_transfers SET reference=?,notes=? WHERE id=? AND station_id=?',[payload['reference'] ?? rows.first['reference'],payload['notes'] ?? rows.first['notes'],id,station]);
      return;
    }
    if (operation != 'create' || links.isNotEmpty) throw StateError('هوية التحويل مستخدمة أو العملية غير مدعومة');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع التحويل العالمية مفقودة');
    final toId = _resolveSyncReference(station:station,entityType:'cashboxes',column:'to_cashbox_id',references:refs);
    final fromId = payload['from_cashbox_id'] == null ? null : _resolveSyncReference(station:station,entityType:'cashboxes',column:'from_cashbox_id',references:refs);
    final target = db.select('SELECT active,currency FROM cashboxes WHERE id=? AND station_id=? LIMIT 1',[toId,station]);
    if (target.isEmpty || (target.first['active'] as num?)?.toInt()!=1) throw StateError('صندوق الوجهة غير نشط أو لا يتبع المحطة');
    if (fromId != null) {
      final source = db.select('SELECT active,currency FROM cashboxes WHERE id=? AND station_id=? LIMIT 1',[fromId,station]);
      if (source.isEmpty || (source.first['active'] as num?)?.toInt()!=1) throw StateError('صندوق المصدر غير نشط أو لا يتبع المحطة');
      if (fromId == toId) throw StateError('لا يمكن التحويل إلى الصندوق نفسه');
      if (source.first['currency'] != target.first['currency']) throw StateError('لا يمكن التحويل بين صندوقين بعملتين مختلفتين');
    }
    final openingValue = payload['is_opening_transfer'];
    final opening = openingValue == true || openingValue == 1;
    if ((fromId == null) != opening) throw StateError('التحويل الافتتاحي يجب أن يكون بلا صندوق مصدر، والتحويل العادي يتطلب مصدراً');
    final amountValue = payload['amount'];
    if (amountValue is! num || amountValue <= 0 || amountValue != amountValue.round()) throw StateError('قيمة التحويل يجب أن تكون عدداً صحيحاً أكبر من صفر');
    final amount = amountValue.toInt();
    final date = DateTime.tryParse((payload['date'] ?? '').toString());
    if (date == null) throw StateError('تاريخ التحويل غير صالح');
    db.execute('INSERT INTO cashbox_transfers(station_id,from_cashbox_id,to_cashbox_id,amount,date,is_opening_transfer,reference,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?)',[station,fromId,toId,amount,date.toIso8601String(),opening ? 1 : 0,payload['reference'],payload['notes'],userId]);
    final transferId = db.lastInsertRowId;
    if (fromId != null) {
      db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=? AND station_id=? AND active=1',[amount,fromId,station]);
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تحديث رصيد صندوق المصدر');
    }
    db.execute('UPDATE cashboxes SET current_balance=current_balance+? WHERE id=? AND station_id=? AND active=1',[amount,toId,station]);
    if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تحديث رصيد صندوق الوجهة');
    final debitAccount = _accountId(_syncCashboxLedgerCode(station,toId));
    final creditAccount = _accountId(opening ? '3000' : _syncCashboxLedgerCode(station,fromId!));
    _journal(description:opening ? 'تحويل افتتاحي' : 'تحويل بين الصناديق',referenceType:'cashbox_transfer',referenceId:transferId,userId:userId,date:date,lines:[{'account_id':debitAccount,'debit':amount,'credit':0},{'account_id':creditAccount,'debit':0,'credit':amount}]);
    db.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,'cashbox_transfers',?,?,?)",[station,globalId,transferId,now]);
  }
  void _applySyncDieselMovement({
    required int station, required String entityKey, required String operation,
    required Map payload, required String now, required int? userId, required String? role,
  }) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بمزامنة حركات الديزل');
    if (userId == null || _stationForUser(userId) != station) throw StateError('مستخدم حركة الديزل لا يتبع المحطة الموثقة');
    final globalId = (payload['_global_id'] ?? '').toString();
    final validId = globalId.length == 36 && globalId[8] == '-' && globalId[13] == '-' && globalId[18] == '-' && globalId[23] == '-' && RegExp(r'^[0-9a-fA-F-]{36}').hasMatch(globalId);
    if (!validId || entityKey != 'diesel_movements:' + globalId) throw StateError('هوية حركة الديزل العالمية غير صالحة');
    final columns = db.select('PRAGMA table_info(diesel_movements)').map((row) => row['name'].toString()).toSet();
    const requiredColumns = {'id','station_id','beneficiary_id','irrigation_id','cashbox_id','kind','liters','unit_price','amount','date','notes','created_by'};
    if (!requiredColumns.every(columns.contains)) throw StateError('مخطط حركات الديزل لا يدعم المزامنة الآمنة');
    final links = db.select("SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='diesel_movements' AND global_id=? LIMIT 1", [station,globalId]);
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع حركة الديزل العالمية مفقودة');
    final beneficiaryId = payload['beneficiary_id'] == null ? null : _resolveSyncReference(station:station,entityType:'beneficiaries',column:'beneficiary_id',references:refs);
    final irrigationId = payload['irrigation_id'] == null ? null : _resolveSyncReference(station:station,entityType:'irrigations',column:'irrigation_id',references:refs);
    int? cashboxId;
    if (payload['cashbox_id'] != null) {
      final ref = refs['cashbox_id'];
      if (ref is! Map || ref['table'] != 'cashboxes') throw StateError('مرجع صندوق حركة الديزل غير صالح');
      cashboxId = _resolveSyncReference(station:station,entityType:'cashboxes',column:'cashbox_id',references:refs);
      final box = db.select('SELECT active FROM cashboxes WHERE id=? AND station_id=? LIMIT 1',[cashboxId,station]);
      if (box.isEmpty || (box.first['active'] as num?)?.toInt()!=1) throw StateError('صندوق حركة الديزل غير نشط أو لا يتبع المحطة');
    }
    if (beneficiaryId != null) _requireOwn('beneficiaries',beneficiaryId,station,'المستفيد');
    if (irrigationId != null) _requireOwn('irrigations',irrigationId,station,'السقاية');
    final kind = (payload['kind'] ?? '').toString();
    if (!const {'receipt','delivery','advance','consumption','correction','opening_balance'}.contains(kind)) throw StateError('نوع حركة الديزل غير صالح');
    if ((kind == 'correction' || kind == 'opening_balance') && beneficiaryId != null) throw StateError('التصحيح والرصيد الافتتاحي يخصان مخزون المحطة فقط');
    final litersValue = payload['liters'];
    final priceValue = payload['unit_price'];
    final amountValue = payload['amount'];
    if (litersValue is! num || !litersValue.toDouble().isFinite || litersValue <= 0 || priceValue is! num || priceValue < 0 || priceValue != priceValue.round() || amountValue is! num || amountValue < 0 || amountValue != amountValue.round()) throw StateError('كمية أو سعر أو قيمة حركة الديزل غير صالحة');
    final liters = litersValue.toDouble();
    final unitPrice = priceValue.toInt();
    final amount = amountValue.toInt();
    if ((liters * unitPrice).round() != amount) throw StateError('قيمة حركة الديزل لا تطابق الكمية وسعر اللتر');
    final date = DateTime.tryParse((payload['date'] ?? '').toString());
    if (date == null) throw StateError('تاريخ حركة الديزل غير صالح');
    final notes = payload['notes']?.toString();
    final financialCredit = _settingsForStation(station)['diesel_delivery_financial_credit'] == 'true';
    final requiresJournal = kind == 'consumption' || kind == 'correction' || kind == 'opening_balance' || (kind == 'receipt' && cashboxId != null) || (kind == 'advance' && beneficiaryId != null) || (kind == 'delivery' && beneficiaryId != null && financialCredit);
    if (requiresJournal && amount <= 0) throw StateError('الحركة التي تتطلب قيداً محاسبياً يجب أن تكون قيمتها موجبة');
    if (operation == 'delete') throw UnsupportedError('إلغاء حركة الديزل يتطلب القيد العكسي؛ لم يُسمح بحذفها مباشرة');
    if (operation == 'update') {
      if (links.isEmpty) throw StateError('لا توجد حركة ديزل مرتبطة لتحديثها');
      final id = (links.first['local_id'] as num).toInt();
      final rows = db.select('SELECT * FROM diesel_movements WHERE id=? AND station_id=? LIMIT 1',[id,station]);
      if (rows.isEmpty) throw StateError('حركة الديزل لا تتبع المحطة الحالية');
      final row = rows.first;
      if (row['kind'] != kind || (row['liters'] as num).toDouble() != liters || (row['unit_price'] as num).toInt() != unitPrice || (row['amount'] as num).toInt() != amount || (row['beneficiary_id'] as num?)?.toInt() != beneficiaryId || (row['irrigation_id'] as num?)?.toInt() != irrigationId || (row['cashbox_id'] as num?)?.toInt() != cashboxId || DateTime.tryParse(row['date'].toString())?.toIso8601String() != date.toIso8601String()) throw StateError('يسمح بتعديل ملاحظات حركة الديزل فقط؛ لا تغيّر قيمها المالية');
      db.execute('UPDATE diesel_movements SET notes=? WHERE id=? AND station_id=?',[notes,id,station]);
      return;
    }
    if (operation != 'create') throw UnsupportedError('عملية حركة الديزل غير مدعومة');
    if (links.isNotEmpty) throw StateError('هوية حركة الديزل مستخدمة مسبقاً');
    // The irrigation handler already creates its own consumption/advance rows.
    // Link those rows instead of applying stock and journal effects twice.
    if (irrigationId != null) {
      final matches = db.select('SELECT id FROM diesel_movements WHERE station_id=? AND irrigation_id=? AND kind=? AND liters=? AND unit_price=? AND amount=? AND beneficiary_id IS ? LIMIT 2',[station,irrigationId,kind,liters,unitPrice,amount,beneficiaryId]);
      if (matches.length != 1) throw StateError('حركة الديزل المرتبطة بالسقاية لم تطابق حركة الخادم؛ أُوقف التطبيق لمنع تكرار المخزون والقيود');
      db.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,'diesel_movements',?,?,?)",[station,globalId,matches.first['id'],now]);
      return;
    }
    if ((kind == 'correction' || kind == 'opening_balance') && amount <= 0) throw StateError('تصحيح المخزون والرصيد الافتتاحي يتطلبان قيمة مالية موجبة');
    final stock = db.select("SELECT COALESCE(SUM(CASE WHEN kind='receipt' OR (kind IN ('opening_balance','correction') AND beneficiary_id IS NULL) THEN liters WHEN kind IN ('delivery','consumption') THEN -liters WHEN kind='advance' AND irrigation_id IS NULL THEN -liters ELSE 0 END),0) AS stock FROM diesel_movements WHERE station_id=?",[station]);
    final currentStock = (stock.first['stock'] as num?)?.toDouble() ?? 0;
    if ((kind == 'delivery' || kind == 'consumption' || kind == 'advance') && liters > currentStock + 0.0000001) throw StateError('كمية الديزل المطلوبة أكبر من مخزون المحطة المتاح');
    if (kind == 'receipt' && cashboxId != null) {
      final cash = db.select('SELECT current_balance,ledger_account_code FROM cashboxes WHERE id=? AND station_id=? LIMIT 1',[cashboxId,station]);
      if (cash.isEmpty || (cash.first['current_balance'] as num).toInt() < amount) throw StateError('رصيد الصندوق لا يكفي لشراء الديزل');
    }
    db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,cashbox_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?)',[station,beneficiaryId,null,cashboxId,kind,liters,unitPrice,amount,date.toIso8601String(),notes,userId]);
    final movementId = db.lastInsertRowId;
    if (kind == 'receipt' && cashboxId != null) {
      db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=? AND station_id=?',[amount,cashboxId,station]);
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تحديث رصيد صندوق شراء الديزل');
      final box = db.select('SELECT ledger_account_code FROM cashboxes WHERE id=? AND station_id=?',[cashboxId,station]).first;
      var code = (box['ledger_account_code'] ?? '').toString();
      if (code.isEmpty) {
        final methods = db.select('SELECT ledger_account_code,type FROM payment_methods WHERE cashbox_id=? AND station_id=? AND active=1 ORDER BY id LIMIT 1',[cashboxId,station]);
        if (methods.isNotEmpty) {
          final configured = (methods.first['ledger_account_code'] ?? '').toString();
          code = configured.isNotEmpty ? configured : (methods.first['type'] == 'bank_transfer' ? '1100' : methods.first['type'] == 'wallet' ? '1120' : '1000');
        } else { code = '1000'; }
      }
      _journal(description:'شراء/إضافة ديزل للمخزون',referenceType:'diesel_receipt',referenceId:movementId,userId:userId,date:date,lines:[{'account_id':_accountId('1300'),'debit':amount,'credit':0},{'account_id':_accountId(code),'debit':0,'credit':amount}]);
    }
    if (kind == 'consumption') _journal(description:'استهلاك ديزل',referenceType:'diesel_consumption',referenceId:movementId,userId:userId,date:date,lines:[{'account_id':_accountId('5010'),'debit':amount,'credit':0},{'account_id':_accountId('1300'),'debit':0,'credit':amount}]);
    if (kind == 'correction') _journal(description:'تصحيح زيادة مخزون الديزل',referenceType:'diesel_correction',referenceId:movementId,userId:userId,date:date,lines:[{'account_id':_accountId('1300'),'debit':amount,'credit':0},{'account_id':_accountId('5010'),'debit':0,'credit':amount}]);
    if (kind == 'opening_balance') _journal(description:'رصيد افتتاحي لمخزون الديزل',referenceType:'diesel_opening_balance',referenceId:movementId,userId:userId,date:date,lines:[{'account_id':_accountId('1300'),'debit':amount,'credit':0},{'account_id':_accountId('3000'),'debit':0,'credit':amount}]);
    if (kind == 'delivery' && beneficiaryId != null && financialCredit) _journal(description:'تسليم ديزل من المستفيد (رصيد مالي)',referenceType:'diesel',referenceId:movementId,userId:userId,date:date,lines:[{'account_id':_accountId('1300'),'debit':amount,'credit':0},{'account_id':_accountId('1200'),'beneficiary_id':beneficiaryId,'debit':0,'credit':amount}]);
    if (kind == 'advance' && beneficiaryId != null) _journal(description:'سلفة ديزل للمستفيد',referenceType:'diesel_advance',referenceId:movementId,userId:userId,date:date,lines:[{'account_id':_accountId('1200'),'beneficiary_id':beneficiaryId,'debit':amount,'credit':0},{'account_id':_accountId('1300'),'debit':0,'credit':amount}]);
    db.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,'diesel_movements',?,?,?)",[station,globalId,movementId,now]);
  }
  void _applySyncPaymentReceipt({
    required int station, required String entityKey, required Map payload,
    required String now, required int? userId, required String? role,
  }) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بقبض المستفيد');
    final globalId = (payload['_global_id'] ?? '').toString();
    final validGlobalId = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId);
    if (!validGlobalId || entityKey != 'payments:' + globalId) throw StateError('هوية عملية القبض العالمية غير صالحة');
    if (db.select("SELECT 1 FROM sync_entity_links WHERE station_id=? AND entity_type='payments' AND global_id=? LIMIT 1",[station,globalId]).isNotEmpty) throw StateError('عملية القبض موجودة مسبقاً');
    if (userId == null || userId <= 0 || _stationForUser(userId) != station) throw StateError('مستخدم عملية القبض لا يتبع المحطة الموثقة');
    final amountValue = payload['amount'];
    if (amountValue is! num || amountValue <= 0 || amountValue != amountValue.round()) throw StateError('مبلغ القبض يجب أن يكون عدداً صحيحاً أكبر من صفر');
    final date = DateTime.tryParse((payload['date'] ?? '').toString());
    if (date == null) throw StateError('تاريخ القبض غير صالح');
    if ((payload['status'] ?? 'posted') != 'posted') throw StateError('لا يقبل معالج القبض إلا عملية posted جديدة');
    if (payload['beneficiary_id'] == null || payload['partner_id'] != null || payload['worker_id'] != null) throw StateError('هذه الشريحة مخصصة لقبض المستفيد فقط');
    final references = payload['_global_refs'];
    if (references is! Map) throw StateError('مراجع عملية القبض العالمية مفقودة');
    final beneficiaryId = _resolveSyncReference(station:station,entityType:'beneficiaries',column:'beneficiary_id',references:references);
    final methodId = _resolveSyncReference(station:station,entityType:'payment_methods',column:'payment_method_id',references:references);
    final cashboxId = _resolveSyncReference(station:station,entityType:'cashboxes',column:'cashbox_id',references:references);
    final method = db.select('SELECT station_id,ledger_account_code,cashbox_id,active FROM payment_methods WHERE id=? LIMIT 1',[methodId]).single;
    final cashbox = db.select('SELECT station_id,ledger_account_code,active FROM cashboxes WHERE id=? LIMIT 1',[cashboxId]).single;
    if ((method['station_id'] as num).toInt()!=station || (cashbox['station_id'] as num).toInt()!=station || (method['active'] as num).toInt()!=1 || (cashbox['active'] as num).toInt()!=1) throw StateError('طريقة الدفع أو الصندوق غير نشط أو لا يتبع المحطة');
    final configuredCashbox = (method['cashbox_id'] as num?)?.toInt();
    if (configuredCashbox != null && configuredCashbox != cashboxId) throw StateError('الصندوق لا يطابق طريقة الدفع');
    final columns = db.select('PRAGMA table_info(payments)').map((row)=>(row['name'] ?? '').toString()).toSet();
    const requiredColumns = {'id','station_id','beneficiary_id','amount','date','payment_method_id','cashbox_id','status','created_by'};
    if (!requiredColumns.every(columns.contains)) throw StateError('مخطط payments لا يدعم القبض الآمن');
    db.execute('INSERT INTO payments(station_id,beneficiary_id,amount,date,payment_method_id,cashbox_id,reference_number,notes,status,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[station,beneficiaryId,amountValue.toInt(),date.toIso8601String(),methodId,cashboxId,payload['reference_number'],payload['notes'],'posted',userId]);
    final paymentId = db.lastInsertRowId;
    db.execute('UPDATE cashboxes SET current_balance=current_balance+? WHERE id=? AND station_id=?',[amountValue.toInt(),cashboxId,station]);
    if ((db.select('SELECT changes() AS n').first['n'] as num).toInt()!=1) throw StateError('تعذر تحديث رصيد الصندوق');
    final cashCode = (cashbox['ledger_account_code'] ?? method['ledger_account_code'] ?? '1000').toString();
    _journal(description:'قبض من مستفيد رقم ' + paymentId.toString(),referenceType:'payment',referenceId:paymentId,userId:userId,lines:[
      {'account_id':_accountId(cashCode),'debit':amountValue.toInt(),'credit':0},
      {'account_id':_accountId('1200'),'beneficiary_id':beneficiaryId,'debit':0,'credit':amountValue.toInt()},
    ]);
    db.execute('INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',[station,'payments',globalId,paymentId,now]);
  }



  void _applySyncBeneficiaryManualDebt({
    required int station, required String entityKey, required String operation,
    required Map payload, required String now, required int? userId, required String? role,
  }) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بإدارة مديونية المستفيد');
    if (userId == null || userId <= 0 || _stationForUser(userId) != station) throw StateError('مستخدم المديونية لا يتبع المحطة الموثقة');
    final globalId = (payload['_global_id'] ?? '').toString();
    final compactGlobalId = globalId.replaceAll('-', '');
    final validGlobalId = globalId.length == 36 &&
        globalId[8] == '-' && globalId[13] == '-' &&
        globalId[18] == '-' && globalId[23] == '-' &&
        compactGlobalId.length == 32 &&
        RegExp(r'^[0-9a-fA-F]{32}').hasMatch(compactGlobalId) &&
        compactGlobalId[12] == '4' &&
        '89abAB'.contains(compactGlobalId[16]);
    if (!validGlobalId || entityKey != 'beneficiary_manual_debts:' + globalId) throw StateError('هوية سند المديونية العالمية غير صالحة');
    if (!_hasTable('beneficiary_manual_debts')) throw StateError('جدول المديونيات اليدوية غير موجود');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مرجع المستفيد العالمي مفقود');
    final beneficiaryId = _resolveSyncReference(station:station,entityType:'beneficiaries',column:'beneficiary_id',references:refs);
    final beneficiaries = db.select("SELECT id,name,status FROM beneficiaries WHERE id=? AND station_id=? LIMIT 1",[beneficiaryId,station]);
    if (beneficiaries.isEmpty || beneficiaries.first['status']!='active') throw StateError('المستفيد غير موجود أو غير نشط في المحطة');
    final amountValue = payload['amount'];
    if (amountValue is! num || amountValue<=0 || amountValue!=amountValue.round()) throw StateError('مبلغ المديونية يجب أن يكون عدداً صحيحاً موجباً');
    final amount=amountValue.toInt();
    final debtDate=DateTime.tryParse((payload['date']??'').toString());
    if (debtDate==null) throw StateError('تاريخ المديونية غير صالح');
    final notes=(payload['notes']??'').toString().trim();
    if (notes.isEmpty) throw StateError('بيان المديونية مطلوب');
    final cols=db.select('PRAGMA table_info(beneficiary_manual_debts)').map((x)=>(x['name']??'').toString()).toSet();
    const required={'id','beneficiary_id','date','amount','notes','status','journal_entry_id','created_by','created_at','cancelled_at','cancel_reason'};
    if (!required.every(cols.contains)) throw StateError('مخطط جدول المديونيات لا يدعم المعالجة الآمنة');
    final links=db.select("SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='beneficiary_manual_debts' AND global_id=? LIMIT 1",[station,globalId]);
    if (operation=='create') {
      if (links.isNotEmpty) throw StateError('سند المديونية موجود مسبقاً');
      if ((payload['status']??'posted')!='posted') throw StateError('إنشاء المديونية يجب أن يبدأ بحالة posted');
      final receivable=_accountId('1200');
      final carried=_accountId('3100');
      db.execute("INSERT INTO beneficiary_manual_debts(beneficiary_id,date,amount,notes,status,created_by,created_at) VALUES(?,?,?,?,?,?,?)",[beneficiaryId,debtDate.toIso8601String(),amount,notes,'posted',userId,now]);
      final debtId=db.lastInsertRowId;
      db.execute("INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)",[station,debtDate.toIso8601String(),'beneficiary_manual_debt',debtId,'إضافة مديونية سابقة للمستفيد: ' + beneficiaries.first['name'].toString(),'posted',userId,now]);
      final journalId=db.lastInsertRowId;
      db.execute("INSERT INTO journal_lines(journal_entry_id,account_id,beneficiary_id,debit,credit,memo) VALUES(?,?,?,?,?,?)",[journalId,receivable,beneficiaryId,amount,0,notes]);
      db.execute("INSERT INTO journal_lines(journal_entry_id,account_id,debit,credit,memo) VALUES(?,?,?,?,?)",[journalId,carried,0,amount,'مديونية سابقة غير مسجلة بالتطبيق']);
      db.execute("UPDATE beneficiary_manual_debts SET journal_entry_id=? WHERE id=?",[journalId,debtId]);
      db.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)",[station,'beneficiary_manual_debts',globalId,debtId,now]);
      return;
    }
    if (operation!='update') throw UnsupportedError('حذف سند المديونية ممنوع؛ استخدم إلغاءً محاسبياً');
    if (links.isEmpty || payload['status']!='cancelled') throw StateError('التحديث الوحيد المسموح هو إلغاء سند موجود');
    final debtId=(links.first['local_id'] as num).toInt();
    final rows=db.select("SELECT md.* FROM beneficiary_manual_debts md JOIN beneficiaries b ON b.id=md.beneficiary_id WHERE md.id=? AND b.station_id=? LIMIT 1",[debtId,station]);
    if (rows.isEmpty) throw StateError('سند المديونية لا يتبع المحطة الحالية');
    final debt=rows.first;
    if (debt['status']!='posted') throw StateError('سند المديونية ملغى مسبقاً أو غير مرحّل');
    if ((debt['beneficiary_id'] as num).toInt()!=beneficiaryId ||
        (debt['amount'] as num).toInt()!=amount ||
        DateTime.tryParse(debt['date'].toString())?.toIso8601String()!=debtDate.toIso8601String() ||
        debt['notes'].toString()!=notes) throw StateError('لا يسمح بتغيير بيانات المديونية أثناء الإلغاء');
    final reason=(payload['cancel_reason']??'').toString().trim();
    final cancelledAt=DateTime.tryParse((payload['cancelled_at']??'').toString());
    if (reason.isEmpty || cancelledAt==null) throw StateError('سبب الإلغاء وتاريخه مطلوبان');
    final originalId=(debt['journal_entry_id'] as num?)?.toInt();
    if (originalId==null || originalId<=0) throw StateError('القيد الأصلي للمديونية غير موجود');
    final original=db.select("SELECT id,reference_type,reference_id,status FROM journal_entries WHERE id=? AND station_id=? LIMIT 1",[originalId,station]);
    if (original.isEmpty || original.first['status']!='posted' || original.first['reference_type']!='beneficiary_manual_debt' || (original.first['reference_id'] as num?)?.toInt()!=debtId) throw StateError('القيد الأصلي غير صالح');
    if (db.select("SELECT 1 FROM journal_entries WHERE reference_type='reversal' AND reference_id=? LIMIT 1",[originalId]).isNotEmpty) throw StateError('سبق عكس القيد الأصلي');
    final lines=db.select("SELECT jl.account_id,jl.beneficiary_id,jl.debit,jl.credit,jl.memo,a.code FROM journal_lines jl JOIN accounts a ON a.id=jl.account_id WHERE jl.journal_entry_id=? ORDER BY jl.id",[originalId]);
    final debit=lines.fold<int>(0,(s,l)=>s+(l['debit'] as num).toInt());
    final credit=lines.fold<int>(0,(s,l)=>s+(l['credit'] as num).toInt());
    final hasReceivable=lines.any((l)=>l['code']=='1200' && (l['beneficiary_id'] as num?)?.toInt()==beneficiaryId && (l['debit'] as num).toInt()==amount && (l['credit'] as num).toInt()==0);
    final hasCarried=lines.any((l)=>l['code']=='3100' && l['beneficiary_id']==null && (l['debit'] as num).toInt()==0 && (l['credit'] as num).toInt()==amount);
    if (lines.length!=2 || debit!=amount || credit!=amount || !hasReceivable || !hasCarried) throw StateError('القيد الأصلي غير متوازن أو لا يطابق السند');
    db.execute("INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)",[station,cancelledAt.toIso8601String(),'reversal',originalId,'عكس مديونية المستفيد رقم ' + debtId.toString() + ': ' + reason,'posted',userId,now]);
    final reversalId=db.lastInsertRowId;
    for(final line in lines){db.execute("INSERT INTO journal_lines(journal_entry_id,account_id,beneficiary_id,worker_id,partner_id,debit,credit,memo) VALUES(?,?,?,?,?,?,?,?)",[reversalId,line['account_id'],line['beneficiary_id'],null,null,line['credit'],line['debit'],'عكس: ' + (line['memo']??'').toString()]);}
    db.execute("UPDATE beneficiary_manual_debts SET status='cancelled',cancelled_at=?,cancel_reason=? WHERE id=? AND status='posted'",[cancelledAt.toIso8601String(),reason,debtId]);
    if ((db.select('SELECT changes() n').first['n'] as num).toInt()!=1) throw StateError('تعذر تحديث حالة سند المديونية');
  }



  void _applySyncPartyOpeningDebt({
    required int station, required String entityType, required String entityKey,
    required String operation, required Map payload, required String now,
    required int? userId, required String? role,
  }) {
    if (operation != 'create') throw UnsupportedError('تعديل أو حذف المديونية السابقة للعامل أو الشريك غير مسموح؛ يلزم قيد عكسي مخصص');
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بإضافة مديونية سابقة');
    if (userId == null || userId <= 0 || _stationForUser(userId) != station) throw StateError('مستخدم المديونية لا يتبع المحطة الموثقة');
    final isWorker = entityType == 'worker_transactions';
    final partyType = isWorker ? 'worker' : 'partner';
    final partyTable = isWorker ? 'workers' : 'partners';
    final partyColumn = isWorker ? 'worker_id' : 'partner_id';
    final parentCode = isWorker ? '2100' : '2200';
    final personalCode = isWorker ? '2100.W' : '2200.P';
    final globalId = (payload['_global_id'] ?? '').toString();
    final validGlobalId = globalId.length == 36 &&
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}').hasMatch(globalId);
    if (!validGlobalId || entityKey != entityType + ':' + globalId) throw StateError('هوية حركة المديونية العالمية غير صالحة');
    if ((payload['type'] ?? '') != 'opening_balance' || (payload['reference_type'] ?? '') != 'previous_debt') throw StateError('المعالج يقبل مديونية سابقة فقط');
    if (payload[isWorker ? 'partner_id' : 'worker_id'] != null) throw StateError('نوع الطرف في حمولة المديونية غير متطابق');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('المرجع العالمي للطرف مفقود');
    final partyId = _resolveSyncReference(station:station,entityType:partyTable,column:partyColumn,references:refs);
    final partyColumns = db.select('PRAGMA table_info(' + partyTable + ')').map((row)=>row['name'].toString()).toSet();
    if (!{'id','station_id','name'}.every(partyColumns.contains)) throw StateError('مخطط جدول الطرف لا يدعم العزل الآمن');
    final partyRows = db.select(
      'SELECT id,name' + (partyColumns.contains('active') ? ',active' : '') + ' FROM ' + partyTable + ' WHERE id=? AND station_id=? LIMIT 1',
      [partyId,station],
    );
    if (partyRows.isEmpty || (partyRows.first['active'] != null && (partyRows.first['active'] as num).toInt() != 1)) throw StateError('الطرف غير موجود أو غير نشط ضمن المحطة');
    final amountValue = payload['amount'];
    if (amountValue is! num || amountValue <= 0 || amountValue != amountValue.round()) throw StateError('مبلغ المديونية يجب أن يكون عدداً صحيحاً موجباً');
    final amount = amountValue.toInt();
    final debtDate = DateTime.tryParse((payload['date'] ?? '').toString());
    if (debtDate == null) throw StateError('تاريخ المديونية غير صالح');
    final notes = (payload['notes'] ?? '').toString().trim();
    if (notes.isEmpty) throw StateError('بيان المديونية مطلوب');
    if (isWorker) {
      for (final field in ['hours','rate_snapshot','percentage_snapshot']) {
        final value = payload[field];
        if (value is! num || value != 0) throw StateError('لقطات ساعات وأجر العامل يجب أن تكون صفراً للمديونية السابقة');
      }
    } else if (payload['ownership_snapshot'] != null) throw StateError('لا تقبل لقطة ملكية ضمن المديونية السابقة للشريك');
    final transactionColumns = db.select('PRAGMA table_info(' + entityType + ')').map((row)=>row['name'].toString()).toSet();
    final requiredColumns = isWorker
      ? {'id','worker_id','station_id','date','type','hours','rate_snapshot','percentage_snapshot','amount','reference_type','reference_id','notes','created_by'}
      : {'id','partner_id','station_id','date','type','amount','ownership_snapshot','reference_type','reference_id','notes','created_by'};
    if (!requiredColumns.every(transactionColumns.contains)) throw StateError('مخطط دفتر الطرف لا يدعم معالجة المديونية الآمنة');
    final existing = db.select('SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',[station,entityType,globalId]);
    final collision = db.select('SELECT station_id FROM sync_entity_links WHERE entity_type=? AND global_id=? AND station_id<>? LIMIT 1',[entityType,globalId,station]);
    if (existing.isNotEmpty || collision.isNotEmpty) throw StateError('هوية حركة المديونية مستخدمة مسبقاً');
    final accountColumns = db.select('PRAGMA table_info(accounts)').map((row)=>row['name'].toString()).toSet();
    if (!{'id','code','name','type','parent_id'}.every(accountColumns.contains)) throw StateError('مخطط دليل الحسابات لا يدعم الحسابات الفرعية');
    final parentRows = db.select('SELECT id FROM accounts WHERE code=? LIMIT 1',[parentCode]);
    if (parentRows.isEmpty) throw StateError('الحساب التجميعي ' + parentCode + ' غير موجود');
    final parentId = (parentRows.first['id'] as num).toInt();
    final openingAccount = _accountId('3000');
    final accountCode = personalCode + partyId.toString();
    final personalRows = db.select('SELECT id,parent_id FROM accounts WHERE code=? LIMIT 1',[accountCode]);
    int personalAccount;
    if (personalRows.isEmpty) {
      db.execute('INSERT INTO accounts(parent_id,code,name,type) VALUES(?,?,?,?)',[parentId,accountCode,'حساب ' + partyType + ' الشخصي: ' + partyRows.first['name'].toString(),'liability']);
      personalAccount = db.lastInsertRowId;
    } else {
      if ((personalRows.first['parent_id'] as num?)?.toInt() != parentId) throw StateError('الحساب الشخصي موجود تحت حساب تجميعي غير صحيح');
      personalAccount = (personalRows.first['id'] as num).toInt();
    }
    final columns = isWorker
      ? 'worker_id,station_id,date,type,hours,rate_snapshot,percentage_snapshot,amount,reference_type,reference_id,notes,created_by'
      : 'partner_id,station_id,date,type,amount,ownership_snapshot,reference_type,reference_id,notes,created_by';
    final values = isWorker
      ? [partyId,station,debtDate.toIso8601String(),'opening_balance',0,0,0,amount,'previous_debt',null,notes,userId]
      : [partyId,station,debtDate.toIso8601String(),'opening_balance',amount,null,'previous_debt',null,notes,userId];
    final placeholders = List.filled(values.length,'?').join(',');
    db.execute('INSERT INTO ' + entityType + '(' + columns + ') VALUES(' + placeholders + ')',values);
    final transactionId = db.lastInsertRowId;
    final referenceType = isWorker ? 'worker_opening' : 'partner_opening';
    final description = 'مديونية سابقة مستحقة لـ' + (isWorker ? 'العامل ' : 'الشريك ') + partyRows.first['name'].toString();
    db.execute('INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)',
      [station,debtDate.toIso8601String(),referenceType,partyId,description,'posted',userId,now]);
    final journalId = db.lastInsertRowId;
    if (isWorker) {
      db.execute('INSERT INTO journal_lines(journal_entry_id,account_id,worker_id,debit,credit,memo) VALUES(?,?,?,?,?,?)',[journalId,personalAccount,partyId,0,amount,notes]);
    } else {
      db.execute('INSERT INTO journal_lines(journal_entry_id,account_id,partner_id,debit,credit,memo) VALUES(?,?,?,?,?,?)',[journalId,personalAccount,partyId,0,amount,notes]);
    }
    db.execute('INSERT INTO journal_lines(journal_entry_id,account_id,debit,credit,memo) VALUES(?,?,?,?,?)',[journalId,openingAccount,amount,0,'مقابل مديونية سابقة']);
    final totals = db.select('SELECT COALESCE(SUM(debit),0) debit,COALESCE(SUM(credit),0) credit,COUNT(*) lines FROM journal_lines WHERE journal_entry_id=?',[journalId]).single;
    if ((totals['debit'] as num).toInt()!=amount || (totals['credit'] as num).toInt()!=amount || (totals['lines'] as num).toInt()!=2) throw StateError('القيد المركزي للمديونية غير متوازن');
    db.execute('UPDATE ' + entityType + ' SET reference_id=? WHERE id=?',[journalId,transactionId]);
    db.execute('INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',[station,entityType,globalId,transactionId,now]);
  }



  /// Applies only non-financial master data. Financial balances and ledger rows
  /// are intentionally excluded from this generic master-data command.
  /// Applies only non-financial master data. Financial balances and ledger rows
  /// are intentionally excluded from this generic master-data command.
  void _applySyncMasterData({
    required int station,
    required String entityType,
    required String entityKey,
    required String operation,
    required Map payload,
    required String now,
    required String? role,
  }) {
    const fields = <String, Set<String>>{
      'pumps': {'name', 'system_type', 'active', 'notes'},
      'partners': {'name', 'phone', 'ownership_mode', 'shares_count', 'ownership_percentage', 'active', 'notes'},
      'workers': {'name', 'phone', 'job_title', 'pay_type', 'fixed_salary', 'hourly_rate', 'percentage_rate', 'active', 'notes'},
      'payment_methods': {'name', 'type', 'account_number', 'bank_name', 'cashbox_id', 'ledger_account_code', 'active'},
      'cashboxes': {'name', 'currency', 'ledger_account_code', 'active'},
    };
    final allowed = fields[entityType];
    if (allowed == null) throw UnsupportedError('مجال البيانات الأساسية غير مدعوم');
    if (role != 'manager' && role != 'accountant') {
      throw StateError('صلاحية المستخدم لا تسمح بتعديل البيانات الأساسية');
    }
    final globalId = (payload['_global_id'] ?? '').toString();
    final compactId = globalId.replaceAll('-', '');
    final validGlobalId = globalId.length == 36 &&
        globalId[8] == '-' && globalId[13] == '-' &&
        globalId[18] == '-' && globalId[23] == '-' &&
        compactId.length == 32 &&
        RegExp(r'^[0-9a-fA-F]{32}').hasMatch(compactId) &&
        compactId[12] == '4' && '89abAB'.contains(compactId[16]);
    if (!validGlobalId || entityKey != entityType + ':' + globalId) {
      throw StateError('الهوية العالمية للبيانات الأساسية غير صالحة');
    }
    if (!_hasTable(entityType)) throw StateError('جدول البيانات الأساسية غير موجود');
    final columns = db.select('PRAGMA table_info(' + entityType + ')')
        .map((row) => row['name'].toString()).toSet();
    if (!{'id', 'station_id', 'active'}.every(columns.contains)) {
      throw StateError('مخطط البيانات الأساسية لا يدعم العزل الآمن');
    }
    final foreignLink = db.select(
      'SELECT station_id FROM sync_entity_links WHERE entity_type=? AND global_id=? AND station_id<>? LIMIT 1',
      [entityType, globalId, station],
    );
    if (foreignLink.isNotEmpty) throw StateError('الهوية العالمية مرتبطة بمحطة أخرى');
    final links = db.select(
      'SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',
      [station, entityType, globalId],
    );
    final localId = links.isEmpty ? null : (links.first['local_id'] as num).toInt();

    if (operation == 'delete') {
      if (localId == null) throw StateError('لا يوجد سجل أساسي مرتبط بالهوية العالمية');
      final updatedAtSql = columns.contains('updated_at') ? ',updated_at=?' : '';
      final args = columns.contains('updated_at') ? [now, localId, station] : [localId, station];
      db.execute(
        'UPDATE ' + entityType + ' SET active=0' + updatedAtSql +
            ' WHERE id=? AND station_id=? AND active=1',
        args,
      );
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt() != 1) {
        throw StateError('السجل غير موجود أو معطل مسبقاً ضمن المحطة');
      }
      return;
    }
    if (operation != 'create' && operation != 'update') {
      throw UnsupportedError('عملية البيانات الأساسية غير مدعومة');
    }

    final refs = payload['_global_refs'];
    if (refs != null && refs is! Map) throw StateError('مراجع العلاقات غير صالحة');
    final values = <String, Object?>{};
    for (final entry in payload.entries) {
      final key = entry.key.toString();
      if (const {
        '_global_id', '_global_refs', '_unresolved_refs',
        'id', 'station_id', 'created_by', 'created_at', 'updated_at',
      }.contains(key)) continue;
      if (const {'opening_balance', 'carried_balance', 'current_balance'}.contains(key)) {
        final value = entry.value;
        if (value != null && (!(value is num) || value != 0)) {
          throw StateError('لا تقبل المزامنة العامة تغيير الأرصدة المالية');
        }
        continue;
      }
      if (!allowed.contains(key) || !columns.contains(key)) {
        throw StateError('حقل غير مسموح في البيانات الأساسية: ' + key);
      }
      if (key == 'cashbox_id') {
        if (entry.value == null) {
          values[key] = null;
        } else {
          if (refs is! Map) throw StateError('مرجع الصندوق العالمي مفقود');
          values[key] = _resolveSyncReference(
            station: station, entityType: 'cashboxes', column: key,
            references: Map.from(refs),
          );
        }
      } else if (key == 'active') {
        final value = entry.value;
        if (value is bool) {
          values[key] = value ? 1 : 0;
        } else if (value is num && (value == 0 || value == 1)) {
          values[key] = value.toInt();
        } else {
          throw StateError('قيمة active غير صالحة');
        }
      } else {
        values[key] = entry.value;
      }
    }

    if (values.containsKey('name') && (values['name'] ?? '').toString().trim().isEmpty) {
      throw StateError('اسم السجل مطلوب');
    }
    if (entityType == 'pumps' && values.containsKey('system_type') &&
        !const {'diesel', 'solar', 'equivalent_hybrid'}.contains(values['system_type'])) {
      throw StateError('نوع المضخة غير صالح');
    }
    if (entityType == 'partners' && values.containsKey('ownership_mode') &&
        !const {'shares', 'percentage'}.contains(values['ownership_mode'])) {
      throw StateError('نمط ملكية الشريك غير صالح');
    }
    if (entityType == 'workers' && values.containsKey('pay_type') &&
        !const {'fixed', 'hourly', 'percentage'}.contains(values['pay_type'])) {
      throw StateError('نوع أجر العامل غير صالح');
    }
    if (entityType == 'payment_methods' && values.containsKey('type') &&
        !const {'cash', 'check', 'bank_transfer', 'wallet', 'other'}.contains(values['type'])) {
      throw StateError('نوع طريقة الدفع غير صالح');
    }

    if (operation == 'create') {
      if (localId != null) throw StateError('السجل موجود مسبقاً؛ استخدم update');
      final requiredFields = <String, List<String>>{
        'pumps': ['name', 'system_type'],
        'partners': ['name', 'ownership_mode'],
        'workers': ['name', 'pay_type'],
        'payment_methods': ['name', 'type'],
        'cashboxes': ['name', 'currency'],
      }[entityType]!;
      for (final field in requiredFields) {
        final value = values[field];
        if (value == null || (value is String && value.trim().isEmpty)) {
          throw StateError('الحقل المطلوب مفقود: ' + field);
        }
      }
      if (entityType == 'payment_methods') {
        final matches = db.select(
          'SELECT id FROM payment_methods WHERE station_id=? AND name=? AND type=? AND active=1 LIMIT 2',
          [station, values['name'], values['type']],
        );
        if (matches.length > 1) throw StateError('طريقة الدفع المطابقة غير فريدة');
        if (matches.length == 1) {
          db.execute(
            'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
            [station, entityType, globalId, matches.first['id'], now],
          );
          return;
        }
      } else if (entityType == 'cashboxes') {
        final matches = db.select(
          'SELECT id FROM cashboxes WHERE station_id=? AND name=? AND currency=? AND active=1 LIMIT 2',
          [station, values['name'], values['currency']],
        );
        if (matches.length > 1) throw StateError('الصندوق المطابق غير فريد');
        if (matches.length == 1) {
          db.execute(
            'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
            [station, entityType, globalId, matches.first['id'], now],
          );
          return;
        }
      }
      values['station_id'] = station;
      if (columns.contains('created_at')) values['created_at'] = now;
      if (columns.contains('updated_at')) values['updated_at'] = now;
      final names = values.keys.toList();
      db.execute(
        'INSERT INTO ' + entityType + '(' + names.join(',') + ') VALUES(' +
            List.filled(names.length, '?').join(',') + ')',
        names.map((name) => values[name]).toList(),
      );
      db.execute(
        'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
        [station, entityType, globalId, db.lastInsertRowId, now],
      );
      return;
    }

    if (localId == null) throw StateError('لا يوجد سجل مرتبط بهذه الهوية العالمية');
    if (!_owns(entityType, localId, station)) throw StateError('السجل لا يتبع المحطة الحالية');
    if (values.isEmpty) throw StateError('لا توجد حقول قابلة للتحديث');
    if (columns.contains('updated_at')) values['updated_at'] = now;
    final names = values.keys.toList();
    db.execute(
      'UPDATE ' + entityType + ' SET ' +
          names.map((name) => name + '=?').join(',') +
          ' WHERE id=? AND station_id=?',
      [...names.map((name) => values[name]), localId, station],
    );
    if ((db.select('SELECT changes() AS n').first['n'] as num).toInt() != 1) {
      throw StateError('تعذر تحديث السجل ضمن المحطة الحالية');
    }
  }

  void _applySyncIrrigation({
    required int station, required String entityKey, required Map payload,
    required String now, required int? userId, required String? role,
  }) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بترحيل السقايات');
    final globalId = (payload['_global_id'] ?? '').toString();
    final valid = globalId.length == 36 && RegExp(r'^[0-9a-fA-F-]{36}').hasMatch(globalId) && globalId[8] == '-' && globalId[13] == '-' && globalId[18] == '-' && globalId[23] == '-' && globalId[14] == '4' && '89abAB'.contains(globalId[19]);
    if (!valid || entityKey != 'irrigations:' + globalId) throw StateError('هوية السقاية العالمية غير صالحة');
    if (db.select("SELECT 1 FROM sync_entity_links WHERE station_id=? AND entity_type='irrigations' AND global_id=? LIMIT 1",[station,globalId]).isNotEmpty) throw StateError('السقاية موجودة مسبقاً');
    if (userId == null || _stationForUser(userId) != station) throw StateError('مستخدم السقاية لا يتبع المحطة الموثقة');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع السقاية العالمية مفقودة');
    final pumpId = _resolveSyncReference(station:station,entityType:'pumps',column:'pump_id',references:refs);
    final beneficiaryId = _resolveSyncReference(station:station,entityType:'beneficiaries',column:'beneficiary_id',references:refs);
    final pump = db.select('SELECT system_type,active FROM pumps WHERE id=? AND station_id=? LIMIT 1',[pumpId,station]);
    final beneficiary = db.select('SELECT status FROM beneficiaries WHERE id=? AND station_id=? LIMIT 1',[beneficiaryId,station]);
    if (pump.isEmpty || (pump.first['active'] as num?)?.toInt()!=1) throw StateError('المضخة غير نشطة أو لا تتبع المحطة');
    if (beneficiary.isEmpty || beneficiary.first['status'] != 'active') throw StateError('المستفيد غير نشط أو لا يتبع المحطة');
    final sessionId = payload['session_id'] == null ? null : _resolveOperationalSyncRef(station:station,entityType:'irrigation_sessions',column:'session_id',references:refs,beneficiaryId:beneficiaryId);
    final queueId = payload['queue_entry_id'] == null ? null : _resolveOperationalSyncRef(station:station,entityType:'queue_entries',column:'queue_entry_id',references:refs,beneficiaryId:beneficiaryId);
    final bookingId = payload['booking_id'] == null ? null : _resolveOperationalSyncRef(station:station,entityType:'booking_requests',column:'booking_id',references:refs,beneficiaryId:beneficiaryId);
    final startText = (payload['start_datetime'] ?? '').toString();
    final endText = (payload['end_datetime'] ?? '').toString();
    final start = DateTime.tryParse(startText);
    final end = DateTime.tryParse(endText);
    if (start == null || end == null || !end.isAfter(start)) throw StateError('وقت بداية أو نهاية السقاية غير صالح');
    final settings = _settingsForStation(station);
    final minutes = _minutes(start,end,settings['allow_midnight_crossing']=='true');
    if (minutes <= 0 || minutes > 1440) throw StateError('مدة السقاية خارج النطاق المسموح');
    final system = (payload['system_type'] ?? pump.first['system_type'] ?? settings['system_type'] ?? 'diesel').toString();
    if (!const {'diesel','solar','equivalent_hybrid'}.contains(system) || system != pump.first['system_type'].toString()) throw StateError('نوع النظام لا يطابق نوع المضخة');
    final rawCloud = payload['cloud_periods'];
    if (rawCloud != null && rawCloud is! List) throw StateError('فترات الغيم غير صالحة');
    final cloudPeriods = rawCloud == null ? <Map>[] : rawCloud.map((x) { if (x is! Map) throw StateError('فترة غيم غير صالحة'); return x; }).toList();
    final ranges = <List<DateTime>>[];
    var cloudMinutes = 0;
    for (final item in cloudPeriods) {
      final a = DateTime.tryParse((item['start_datetime'] ?? '').toString());
      final b = DateTime.tryParse((item['end_datetime'] ?? '').toString());
      if (a == null || b == null || !b.isAfter(a) || a.isBefore(start) || b.isAfter(end)) throw StateError('فترة الغيم يجب أن تقع داخل زمن السقاية');
      if (ranges.any((r) => a.isBefore(r[1]) && b.isAfter(r[0]))) throw StateError('فترات الغيم متداخلة');
      ranges.add([a,b]);
      cloudMinutes += b.difference(a).inMinutes;
    }
    final cloudReported = (payload['cloud_minutes'] as num?)?.toInt() ?? cloudMinutes;
    if (cloudReported != cloudMinutes || cloudMinutes > minutes) throw StateError('مجموع فترات الغيم لا يطابق دقائق الغيم أو يتجاوز مدة السقاية');
    final chargeable = system == 'solar' ? minutes-cloudMinutes : minutes;
    final waterRate = system == 'diesel' ? (int.tryParse(settings['diesel_hourly_water_rate'] ?? '0') ?? 0) : system == 'solar' ? (int.tryParse(settings['solar_hourly_rate'] ?? '0') ?? 0) : (int.tryParse(settings['third_type_hourly_rate'] ?? '0') ?? 0);
    final litersPerHour = system == 'diesel' ? (double.tryParse(settings['diesel_liters_per_hour'] ?? '0') ?? 0) : 0.0;
    final dieselPrice = int.tryParse(settings['diesel_price_per_liter'] ?? '0') ?? 0;
    if (waterRate < 0 || litersPerHour < 0 || dieselPrice < 0) throw StateError('إعدادات أسعار السقاية غير صالحة');
    final rounding = settings['rounding'] ?? 'nearest';
    final waterAmount = _round(chargeable/60*waterRate,rounding);
    final liters = chargeable/60*litersPerHour;
    final dieselAmount = _round(liters*dieselPrice,rounding);
    final total = waterAmount+dieselAmount;
    if (total <= 0) throw StateError('إجمالي السقاية المحسوب غير صالح');
    final paidValue = payload['paid_amount'] ?? 0;
    if (paidValue is! num || paidValue != 0) throw StateError('يجب مزامنة القبض كحدث مستقل؛ لا يقبل paid_amount داخل السقاية');
    if (db.select("SELECT 1 FROM irrigations WHERE station_id=? AND pump_id=? AND status!='cancelled' AND start_datetime<? AND end_datetime>? LIMIT 1",[station,pumpId,endText,startText]).isNotEmpty) throw StateError('وقت السقاية يتداخل مع تشغيل آخر للمضخة');
    if (!_hasTable('cloud_periods') || !_hasTable('diesel_movements')) throw StateError('جداول الغيم والديزل غير متاحة');
    final columns = db.select('PRAGMA table_info(irrigations)').map((r)=>r['name'].toString()).toSet();
    final required = {'station_id','pump_id','beneficiary_id','party_type','date','start_datetime','end_datetime','minutes','system_type','water_hourly_rate_snapshot','diesel_liters_per_hour_snapshot','diesel_price_snapshot','solar_hourly_rate_snapshot','third_type_hourly_rate_snapshot','cloud_minutes','chargeable_minutes','water_amount','diesel_amount','total_amount','paid_amount','status','created_by','created_at','updated_at'};
    if (!required.every(columns.contains)) throw StateError('مخطط السقايات لا يدعم الترحيل الآمن');
    final irrigationValues=<String,Object?>{
      'station_id':station,'pump_id':pumpId,'beneficiary_id':beneficiaryId,'party_type':'beneficiary',
      'date':startText.substring(0,10),'start_datetime':startText,'end_datetime':endText,'minutes':minutes,
      'system_type':system,'water_hourly_rate_snapshot':system=='diesel'?waterRate:0,
      'diesel_liters_per_hour_snapshot':litersPerHour,'diesel_price_snapshot':dieselPrice,
      'solar_hourly_rate_snapshot':system=='solar'?waterRate:0,'third_type_hourly_rate_snapshot':system=='equivalent_hybrid'?waterRate:0,
      'cloud_minutes':cloudMinutes,'chargeable_minutes':chargeable,'water_amount':waterAmount,
      'diesel_amount':dieselAmount,'total_amount':total,'paid_amount':0,'status':'posted',
      'created_by':userId,'created_at':now,'updated_at':now,
    };
    if (columns.contains('session_id')) irrigationValues['session_id']=sessionId;
    if (columns.contains('queue_entry_id')) irrigationValues['queue_entry_id']=queueId;
    if (columns.contains('booking_id')) irrigationValues['booking_id']=bookingId;
    if ((sessionId!=null && !columns.contains('session_id')) || (queueId!=null && !columns.contains('queue_entry_id')) || (bookingId!=null && !columns.contains('booking_id'))) throw StateError('مخطط السقايات لا يدعم مراجع الجلسة أو الحجز أو الطابور');
    final irrigationNames=irrigationValues.keys.toList();
    db.execute('INSERT INTO irrigations('+irrigationNames.join(',')+') VALUES('+List.filled(irrigationNames.length,'?').join(',')+')',irrigationNames.map((key)=>irrigationValues[key]).toList());
    final irrigationId = db.lastInsertRowId;
    for (final item in cloudPeriods) {
      final aText = item['start_datetime'].toString();
      final bText = item['end_datetime'].toString();
      final a = DateTime.parse(aText);
      final b = DateTime.parse(bText);
      db.execute('INSERT INTO cloud_periods(irrigation_id,start_datetime,end_datetime,minutes,created_at) VALUES(?,?,?,?,?)',[irrigationId,aText,bText,b.difference(a).inMinutes,now]);
    }
    final receivable = _accountId('1200');
    final lines = <Map<String,Object?>>[{'account_id':receivable,'beneficiary_id':beneficiaryId,'debit':total,'credit':0,'memo':'استحقاق سقاية'}];
    if (waterAmount>0) lines.add({'account_id':_accountId('4000'),'debit':0,'credit':waterAmount,'memo':'إيراد الماء'});
    if (dieselAmount>0) lines.add({'account_id':_accountId('4010'),'debit':0,'credit':dieselAmount,'memo':'قيمة الديزل'});
    _journal(description:'سقاية رقم ' + irrigationId.toString(),referenceType:'irrigation',referenceId:irrigationId,lines:lines,userId:userId);

    // The server is the sole owner of irrigation-linked worker and partner
    // accruals. Clients send only the irrigation command; these rows and their
    // journals are published later as projections.
    var totalWorkerEntitlement = 0;
    if (_hasTable('workers') && _hasTable('worker_transactions')) {
      final workers = db.select(
        "SELECT id,pay_type,hourly_rate,percentage_rate FROM workers WHERE station_id=? AND active=1 AND pay_type IN ('hourly','percentage') ORDER BY id",
        [station],
      );
      for (final worker in workers) {
        final workerId = (worker['id'] as num).toInt();
        final payType = worker['pay_type'].toString();
        final hourlyRate = (worker['hourly_rate'] as num?)?.round() ?? 0;
        final percentageRate = (worker['percentage_rate'] as num?)?.toDouble() ?? 0;
        final entitlement = payType == 'hourly'
            ? (chargeable / 60.0 * hourlyRate).round()
            : (total * percentageRate / 100).round();
        final amount = entitlement.clamp(0, total).toInt();
        if (amount <= 0) continue;
        db.execute('''INSERT INTO worker_transactions
          (station_id,worker_id,date,type,hours,rate_snapshot,percentage_snapshot,amount,reference_type,reference_id,notes,created_by)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''', [
          station, workerId, start.toIso8601String(), 'irrigation',
          chargeable / 60.0, hourlyRate, percentageRate, amount,
          'irrigation', irrigationId,
          payType == 'hourly' ? 'استحقاق بالساعة من السقاية' : 'استحقاق نسبة من السقاية',
          userId,
        ]);
        final transactionId = db.lastInsertRowId;
        _journal(
          description: 'أجر العامل عن السقاية $irrigationId',
          referenceType: 'worker',
          referenceId: transactionId,
          userId: userId,
          date: start,
          lines: [
            {'account_id': _accountId('5000'), 'worker_id': workerId, 'debit': amount, 'credit': 0},
            {'account_id': _syncWorkerAccountId(workerId), 'worker_id': workerId, 'debit': 0, 'credit': amount},
          ],
        );
        totalWorkerEntitlement += amount;
      }
    }

    final partnerPool = (total - totalWorkerEntitlement).clamp(0, total).toInt();
    if (partnerPool > 0 && _hasTable('partners') && _hasTable('partner_transactions')) {
      final partners = db.select(
        'SELECT id,ownership_mode,shares_count,ownership_percentage FROM partners WHERE station_id=? AND active=1 ORDER BY id',
        [station],
      );
      final percentagePartners = partners
          .where((partner) => partner['ownership_mode'] == 'percentage')
          .toList();
      final sharePartners = partners
          .where((partner) => partner['ownership_mode'] != 'percentage')
          .toList();
      final percentageTotal = percentagePartners.fold<double>(0, (sum, partner) {
        final value = (partner['ownership_percentage'] as num?)?.toDouble() ?? 0;
        if (value < 0) throw StateError('نسبة ملكية الشريك لا يمكن أن تكون سالبة');
        return sum + value;
      });
      if (percentageTotal > 100.0000001) {
        throw StateError('مجموع نسب ملكية الشركاء يتجاوز 100%');
      }
      final percentagePool = (partnerPool * percentageTotal / 100)
          .floor().clamp(0, partnerPool).toInt();
      var percentageAllocated = 0;
      for (final partner in percentagePartners) {
        final partnerId = (partner['id'] as num).toInt();
        final percentage = (partner['ownership_percentage'] as num?)?.toDouble() ?? 0;
        final amount = percentageTotal <= 0
            ? 0
            : (percentagePool * percentage / percentageTotal)
                .floor().clamp(0, percentagePool - percentageAllocated).toInt();
        percentageAllocated += amount;
        if (amount <= 0) continue;
        db.execute('''INSERT INTO partner_transactions
          (station_id,partner_id,date,type,amount,ownership_snapshot,reference_type,reference_id,created_by)
          VALUES(?,?,?,?,?,?,?,?,?)''', [
          station, partnerId, start.toIso8601String(), 'share_accrual',
          amount, percentage, 'irrigation_profit', irrigationId, userId,
        ]);
        final transactionId = db.lastInsertRowId;
        _journal(
          description: 'نصيب الشريك من صافي السقاية $irrigationId',
          referenceType: 'partner',
          referenceId: transactionId,
          userId: userId,
          date: start,
          lines: [
            {'account_id': _accountId('3200'), 'partner_id': partnerId, 'debit': amount, 'credit': 0},
            {'account_id': _syncPartnerAccountId(partnerId), 'partner_id': partnerId, 'debit': 0, 'credit': amount},
          ],
        );
      }
      if (sharePartners.isNotEmpty) {
        final totalShares = sharePartners.fold<double>(0, (sum, partner) {
          final value = (partner['shares_count'] as num?)?.toDouble() ?? 0;
          if (value < 0) throw StateError('عدد حصص الشريك لا يمكن أن يكون سالباً');
          return sum + value;
        });
        if (totalShares <= 0) throw StateError('إجمالي حصص الشركاء يجب أن يكون أكبر من صفر');
        final sharePool = partnerPool - percentagePool;
        var sharesAllocated = 0;
        for (final partner in sharePartners) {
          final partnerId = (partner['id'] as num).toInt();
          final shares = (partner['shares_count'] as num?)?.toDouble() ?? 0;
          final amount = (sharePool * shares / totalShares)
              .floor().clamp(0, sharePool - sharesAllocated).toInt();
          sharesAllocated += amount;
          if (amount <= 0) continue;
          db.execute('''INSERT INTO partner_transactions
            (station_id,partner_id,date,type,amount,ownership_snapshot,reference_type,reference_id,created_by)
            VALUES(?,?,?,?,?,?,?,?,?)''', [
            station, partnerId, start.toIso8601String(), 'share_accrual',
            amount, shares, 'irrigation_profit', irrigationId, userId,
          ]);
          final transactionId = db.lastInsertRowId;
          _journal(
            description: 'نصيب الشريك من صافي السقاية $irrigationId',
            referenceType: 'partner',
            referenceId: transactionId,
            userId: userId,
            date: start,
            lines: [
              {'account_id': _accountId('3200'), 'partner_id': partnerId, 'debit': amount, 'credit': 0},
              {'account_id': _syncPartnerAccountId(partnerId), 'partner_id': partnerId, 'debit': 0, 'credit': amount},
            ],
          );
        }
      }
    }

    if (system=='diesel' && liters>0) {
      final stock = (db.select("SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements WHERE station_id=?",[station]).first['stock'] as num).toDouble();
      final shortage = liters-stock;
      if (shortage>0) {
        final advanceAmount = _round(shortage*dieselPrice,rounding);
        db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[station,beneficiaryId,irrigationId,'advance',shortage,dieselPrice,advanceAmount,now,'سلفة ديزل تلقائية',userId]);
        // The advance is a quantity-only movement. Its value is already
        // included in the irrigation total and must not create a second journal.
      }
      db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[station,beneficiaryId,irrigationId,'consumption',liters,dieselPrice,dieselAmount,now,'استهلاك السقاية',userId]);
    }
    if (sessionId != null) {
      final session=db.select('SELECT status,actual_start,actual_end FROM irrigation_sessions WHERE id=?',[sessionId]);
      if (session.isEmpty || DateTime.tryParse(session.first['actual_start'].toString())?.toIso8601String()!=start.toIso8601String()) throw StateError('جلسة التشغيل لا تطابق وقت السقاية');
      final sessionStatus=session.first['status'].toString();
      if (sessionStatus=='running') {
        db.execute("UPDATE irrigation_sessions SET status='completed',actual_end=?,timer_stopped_at=?,diesel_consumed=? WHERE id=? AND status='running'",[end.toIso8601String(),end.toIso8601String(),liters,sessionId]);
      } else if (sessionStatus!='completed' || DateTime.tryParse((session.first['actual_end']??'').toString())?.toIso8601String()!=end.toIso8601String()) {
        throw StateError('جلسة التشغيل ليست قابلة للإقفال بهذه السقاية');
      }
    }
    db.execute('INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',[station,'irrigations',globalId,irrigationId,now]);
  }

  void _applySyncCloudPeriod({
    required int station, required String entityKey, required Map payload,
    required String now, required int? userId, required String? role,
  }) {
    if (role != 'manager' && role != 'accountant') throw StateError('صلاحية المستخدم لا تسمح بمزامنة فترات الغيم');
    final globalId = (payload['_global_id'] ?? '').toString();
    final valid = globalId.length == 36 && RegExp(r'^[0-9a-fA-F-]{36}').hasMatch(globalId) && globalId[8] == '-' && globalId[13] == '-' && globalId[18] == '-' && globalId[23] == '-' && globalId[14] == '4' && '89abAB'.contains(globalId[19]);
    if (!valid || entityKey != 'cloud_periods:' + globalId) throw StateError('هوية فترة الغيم العالمية غير صالحة');
    if (db.select("SELECT 1 FROM sync_entity_links WHERE station_id=? AND entity_type='cloud_periods' AND global_id=? LIMIT 1",[station,globalId]).isNotEmpty) throw StateError('فترة الغيم موجودة مسبقاً');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مرجع السقاية العالمي مفقود لفترة الغيم');
    final irrigationId = _resolveSyncReference(station:station,entityType:'irrigations',column:'irrigation_id',references:refs);
    final parent = db.select("SELECT start_datetime,end_datetime FROM irrigations WHERE id=? AND station_id=? AND status='posted' LIMIT 1",[irrigationId,station]);
    if (parent.isEmpty) throw StateError('السقاية المرتبطة بفترة الغيم غير موجودة أو غير مرحلة');
    final startText = (payload['start_datetime'] ?? '').toString();
    final endText = (payload['end_datetime'] ?? '').toString();
    final start = DateTime.tryParse(startText);
    final end = DateTime.tryParse(endText);
    if (start == null || end == null || !end.isAfter(start)) throw StateError('نطاق فترة الغيم غير صالح');
    if (start.isBefore(DateTime.parse(parent.first['start_datetime'].toString())) || end.isAfter(DateTime.parse(parent.first['end_datetime'].toString()))) throw StateError('فترة الغيم خارج نطاق السقاية');
    final minutes = end.difference(start).inMinutes;
    if (minutes <= 0 || (payload['minutes'] is num && (payload['minutes'] as num).toInt()!=minutes)) throw StateError('عدد دقائق فترة الغيم غير مطابق للوقت');
    final matching = db.select('SELECT id FROM cloud_periods WHERE irrigation_id=? AND start_datetime=? AND end_datetime=? AND minutes=? LIMIT 2',[irrigationId,startText,endText,minutes]);
    if (matching.length != 1) throw StateError('فترة الغيم يجب أن تطابق الفترات التي تحقق منها الخادم مع السقاية');
    db.execute('INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',[station,'cloud_periods',globalId,matching.first['id'],now]);
  }

  int _resolveOperationalSyncRef({
    required int station, required String entityType, required String column,
    required Map references, int? beneficiaryId,
  }) {
    if (!const {'queue_entries','booking_requests','irrigation_sessions'}.contains(entityType)) throw StateError('نوع مرجع التشغيل غير مدعوم');
    final raw=references[column];
    if (raw is! Map || raw['table']!=entityType) throw StateError('مرجع ' + column + ' العالمي غير صالح');
    final globalId=(raw['global_id']??'').toString();
    if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId)) throw StateError('هوية مرجع التشغيل غير صالحة');
    final links=db.select('SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',[station,entityType,globalId]);
    final foreign=db.select('SELECT 1 FROM sync_entity_links WHERE entity_type=? AND global_id=? AND station_id<>? LIMIT 1',[entityType,globalId,station]);
    if (foreign.isNotEmpty) throw StateError('مرجع التشغيل تابع لمحطة أخرى');
    if (links.isEmpty) throw StateError('مرجع التشغيل لم يصل إلى الخادم بعد');
    final id=(links.first['local_id'] as num).toInt();
    final rows = entityType=='queue_entries'
      ? db.select('SELECT q.beneficiary_id FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE q.id=? AND b.station_id=?',[id,station])
      : entityType=='booking_requests'
        ? db.select('SELECT q.beneficiary_id FROM booking_requests q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE q.id=? AND b.station_id=?',[id,station])
        : db.select('SELECT s.beneficiary_id FROM irrigation_sessions s JOIN pumps p ON p.id=s.pump_id JOIN beneficiaries b ON b.id=s.beneficiary_id WHERE s.id=? AND p.station_id=? AND b.station_id=?',[id,station,station]);
    if (rows.isEmpty) throw StateError('مرجع التشغيل لا يتبع المحطة الحالية');
    if (beneficiaryId!=null && (rows.first['beneficiary_id'] as num).toInt()!=beneficiaryId) throw StateError('مرجع التشغيل يخص مستفيداً آخر');
    return id;
  }

  void _applySyncIrrigationSession({required int station, required String entityKey, required String operation, required Map payload, required String now, required String? role}) {
    if (role!='manager' && role!='accountant') throw StateError('صلاحية المستخدم لا تسمح بمزامنة جلسات التشغيل');
    final globalId=(payload['_global_id']??'').toString();
    if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId) || entityKey!='irrigation_sessions:'+globalId) throw StateError('هوية جلسة التشغيل العالمية غير صالحة');
    if (!_hasTable('irrigation_sessions')) throw StateError('جدول جلسات التشغيل غير موجود');
    final refs=payload['_global_refs'];
    if (refs is! Map) throw StateError('مراجع جلسة التشغيل العالمية مفقودة');
    final beneficiaryId=_resolveSyncReference(station:station,entityType:'beneficiaries',column:'beneficiary_id',references:refs);
    final pumpId=_resolveSyncReference(station:station,entityType:'pumps',column:'pump_id',references:refs);
    if (db.select("SELECT 1 FROM beneficiaries WHERE id=? AND station_id=? AND status='active'",[beneficiaryId,station]).isEmpty || db.select('SELECT 1 FROM pumps WHERE id=? AND station_id=? AND active=1',[pumpId,station]).isEmpty) throw StateError('المستفيد أو المضخة غير نشط أو لا يتبع المحطة');
    final columns=db.select('PRAGMA table_info(irrigation_sessions)').map((x)=>x['name'].toString()).toSet();
    const required={'id','beneficiary_id','pump_id','queue_entry_id','booking_id','planned_start','actual_start','actual_end','status','timer_started_at','timer_stopped_at','diesel_before','diesel_consumed','diesel_after','diesel_warning_shown','postponement_reason','notes'};
    if (!required.every(columns.contains)) throw StateError('مخطط جلسات التشغيل غير مكتمل');
    final queueId=payload['queue_entry_id']==null?null:_resolveOperationalSyncRef(station:station,entityType:'queue_entries',column:'queue_entry_id',references:refs,beneficiaryId:beneficiaryId);
    final bookingId=payload['booking_id']==null?null:_resolveOperationalSyncRef(station:station,entityType:'booking_requests',column:'booking_id',references:refs,beneficiaryId:beneficiaryId);
    if (operation=='create' && queueId!=null && db.select("SELECT 1 FROM queue_entries WHERE id=? AND status IN ('waiting','postponed')",[queueId]).isEmpty) throw StateError('عنصر الطابور لم يعد متاحاً لبدء الجلسة');
    if (operation=='create' && bookingId!=null && db.select("SELECT 1 FROM booking_requests WHERE id=? AND status IN ('new','under_review','scheduled','accepted','notified')",[bookingId]).isEmpty) throw StateError('الحجز لم يعد متاحاً لبدء الجلسة');
    final links=db.select("SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type='irrigation_sessions' AND global_id=?",[station,globalId]);
    final localId=links.isEmpty?null:(links.first['local_id'] as num).toInt();
    if (operation=='create') {
      if (localId!=null || payload['status']!='running') throw StateError('إنشاء جلسة التشغيل يجب أن يكون جديداً وبحالة running');
      final start=DateTime.tryParse((payload['actual_start']??'').toString());
      if (start==null) throw StateError('وقت بدء الجلسة غير صالح');
      if (db.select("SELECT 1 FROM irrigation_sessions s JOIN pumps p ON p.id=s.pump_id JOIN beneficiaries b ON b.id=s.beneficiary_id WHERE s.pump_id=? AND s.status='running' AND p.station_id=? AND b.station_id=?",[pumpId,station,station]).isNotEmpty) throw StateError('المضخة لديها جلسة فعالة');
      final values=<String,Object?>{'beneficiary_id':beneficiaryId,'pump_id':pumpId,'queue_entry_id':queueId,'booking_id':bookingId,'planned_start':payload['planned_start'],'actual_start':start.toIso8601String(),'actual_end':null,'status':'running','timer_started_at':payload['timer_started_at']??start.toIso8601String(),'timer_stopped_at':null,'diesel_before':0,'diesel_consumed':0,'diesel_after':0,'diesel_warning_shown':0,'postponement_reason':null,'notes':payload['notes']};
      final names=values.keys.toList();
      db.execute('INSERT INTO irrigation_sessions('+names.join(',')+') VALUES('+List.filled(names.length,'?').join(',')+')',names.map((k)=>values[k]).toList());
      db.execute('INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',[station,'irrigation_sessions',globalId,db.lastInsertRowId,now]);
      return;
    }
    if (operation!='update' || localId==null) throw StateError('لا توجد جلسة مرتبطة بهذه الهوية العالمية');
    final current=db.select('SELECT * FROM irrigation_sessions WHERE id=?',[localId]);
    if (current.isEmpty || (current.first['beneficiary_id'] as num).toInt()!=beneficiaryId || (current.first['pump_id'] as num).toInt()!=pumpId || (current.first['queue_entry_id'] as num?)?.toInt()!=queueId || (current.first['booking_id'] as num?)?.toInt()!=bookingId) throw StateError('مراجع الجلسة لا تطابق السجل المرتبط');
    final oldStatus=current.first['status'].toString();
    final nextStatus=(payload['status']??oldStatus).toString();
    final transitions=<String,Set<String>>{'running':{'running','postponed','completed'},'postponed':{'postponed'},'completed':{'completed'}};
    if (!(transitions[oldStatus]?.contains(nextStatus)??false)) throw StateError('انتقال حالة جلسة التشغيل غير مسموح');
    final values=<String,Object?>{};
    for (final key in ['status','actual_end','timer_stopped_at','postponement_reason','notes']) { if (payload.containsKey(key)) values[key]=payload[key]; }
    if (nextStatus=='postponed' && (values['postponement_reason']??current.first['postponement_reason']??'').toString().trim().isEmpty) throw StateError('سبب تأجيل الجلسة مطلوب');
    if (nextStatus=='completed') { final start=DateTime.tryParse(current.first['actual_start'].toString()); final end=DateTime.tryParse((values['actual_end']??current.first['actual_end']??'').toString()); if (start==null || end==null || !end.isAfter(start)) throw StateError('وقت إنهاء الجلسة غير صالح'); values['actual_end']=end.toIso8601String(); values['timer_stopped_at']=values['timer_stopped_at']??end.toIso8601String(); }
    if (nextStatus=='completed') { final linked=db.select("SELECT id FROM irrigations WHERE station_id=? AND session_id=? AND status='posted' AND start_datetime=? AND end_datetime=? LIMIT 2",[station,localId,current.first['actual_start'],values['actual_end']]); if (linked.length!=1) throw StateError('لا يمكن اعتماد إنهاء الجلسة دون سقاية مالية مرتبطة ومطبقة'); }
    if (values.isEmpty) throw StateError('لا توجد حقول جلسة قابلة للتحديث');
    if (oldStatus=='completed' && values.entries.any((entry)=>entry.value!=current.first[entry.key])) throw StateError('لا يمكن تعديل بيانات جلسة مكتملة');
    db.execute('UPDATE irrigation_sessions SET '+values.keys.map((k)=>k+'=?').join(',')+' WHERE id=?',[...values.values,localId]);
  }

  void _applySyncQueueOrBooking({
    required int station, required String entityType, required String entityKey,
    required String operation, required Map payload, required String now,
  }) {
    if (!const {'queue_entries', 'booking_requests'}.contains(entityType)) {
      throw StateError('نوع تشغيل غير مدعوم');
    }
    if (operation == 'delete') {
      throw UnsupportedError('لا يسمح بحذف الحجز أو عنصر الطابور؛ استخدم انتقال حالة موثقاً');
    }
    final globalId = (payload['_global_id'] ?? '').toString();
    final valid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(globalId);
    if (!valid || entityKey != entityType + ':' + globalId) {
      throw StateError('الهوية العالمية لسجل التشغيل غير صالحة');
    }
    if (!_hasTable(entityType)) throw StateError('جدول $entityType غير موجود');
    final refs = payload['_global_refs'];
    if (refs is! Map) throw StateError('مرجع المستفيد العالمي مفقود');
    final beneficiaryId = _resolveSyncReference(
      station: station, entityType: 'beneficiaries',
      column: 'beneficiary_id', references: refs,
    );
    final beneficiary = db.select(
      "SELECT id FROM beneficiaries WHERE id=? AND station_id=? AND status='active' LIMIT 1",
      [beneficiaryId, station],
    );
    if (beneficiary.isEmpty) throw StateError('المستفيد غير نشط أو لا يتبع المحطة');
    final links = db.select(
      'SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',
      [station, entityType, globalId],
    );
    final localId = links.isEmpty ? null : (links.first['local_id'] as num).toInt();
    final columns = db.select('PRAGMA table_info($entityType)')
        .map((row) => row['name'].toString()).toSet();
    final allowed = entityType == 'queue_entries'
        ? const {'position', 'cycle_number', 'status', 'last_served_at', 'postponed_count', 'skip_reason', 'created_at', 'updated_at'}
        : const {'status', 'scheduled_date', 'scheduled_start', 'scheduled_end', 'priority', 'notes', 'cancel_reason'};
    if (operation == 'create') {
      if (localId != null) throw StateError('السجل موجود مسبقاً؛ استخدم update');
      final values = <String, Object?>{
        'beneficiary_id': beneficiaryId,
        if (entityType == 'queue_entries') ...{
          'position': (payload['position'] as num?)?.toInt() ?? 0,
          'cycle_number': (payload['cycle_number'] as num?)?.toInt() ?? 1,
          'status': payload['status'] ?? 'waiting',
          'postponed_count': (payload['postponed_count'] as num?)?.toInt() ?? 0,
          'created_at': payload['created_at'] ?? now,
          'updated_at': now,
        },
        if (entityType == 'booking_requests') ...{
          'created_at': payload['created_at'] ?? now,
          'status': payload['status'] ?? 'new',
        },
      };
      for (final key in allowed) {
        if (payload.containsKey(key) && columns.contains(key)) values[key] = payload[key];
      }
      if (entityType == 'queue_entries') {
        if ((values['position'] as num).toInt() < 1 ||
            (values['cycle_number'] as num).toInt() < 1 ||
            (values['postponed_count'] as num).toInt() < 0 ||
            values['status'] != 'waiting') {
          throw StateError('بيانات عنصر الطابور الجديد غير صالحة؛ يجب أن يبدأ بحالة انتظار');
        }
      } else {
        if (values['status'] != 'new') {
          throw StateError('يجب أن يبدأ الحجز الجديد بحالة جديد');
        }
        final start = values['scheduled_start'];
        final end = values['scheduled_end'];
        if ((start == null) != (end == null)) throw StateError('يجب تحديد بداية ونهاية الحجز معاً');
        if (start != null && (DateTime.tryParse(start.toString()) == null ||
            DateTime.tryParse(end.toString()) == null ||
            !DateTime.parse(end.toString()).isAfter(DateTime.parse(start.toString())))) {
          throw StateError('وقت الحجز غير صالح');
        }
      }
      if (!allowed.every(columns.contains)) {
        throw StateError('مخطط $entityType لا يدعم الحقول المطلوبة');
      }
      final names = values.keys.toList();
      db.execute(
        'INSERT INTO $entityType(${names.join(',')}) VALUES(${List.filled(names.length, '?').join(',')})',
        names.map((name) => values[name]).toList(),
      );
      db.execute(
        'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
        [station, entityType, globalId, db.lastInsertRowId, now],
      );
      return;
    }
    if (operation != 'update' || localId == null) {
      throw StateError('لا يوجد سجل تشغيل مرتبط بهذه الهوية العالمية');
    }
    final owned = db.select(
      'SELECT id FROM $entityType WHERE id=? AND beneficiary_id=? LIMIT 1',
      [localId, beneficiaryId],
    );
    if (owned.isEmpty) throw StateError('سجل التشغيل لا يطابق المستفيد المرتبط');
    final values = <String, Object?>{};
    for (final key in allowed) {
      if (payload.containsKey(key) && columns.contains(key)) values[key] = payload[key];
    }
    if (values.isEmpty) throw StateError('لا توجد حقول تشغيل قابلة للتحديث');
    if (values.containsKey('status')) {
      final current = db.select('SELECT status FROM $entityType WHERE id=? AND beneficiary_id=? LIMIT 1', [localId, beneficiaryId]);
      if (current.isEmpty) throw StateError('سجل التشغيل غير موجود');
      final oldStatus = current.first['status'].toString();
      final nextStatus = values['status'].toString();
      final allowedTransitions = entityType == 'queue_entries'
          ? <String, Set<String>>{
              'waiting': {'waiting', 'postponed', 'served', 'completed', 'skipped'},
              'postponed': {'postponed', 'waiting', 'served', 'completed', 'skipped'},
              'completed': {'completed'},
              'served': {'served'},
              'skipped': {'skipped'},
            }
          : <String, Set<String>>{
              'new': {'new', 'under_review', 'cancelled'},
              'under_review': {'under_review', 'scheduled', 'cancelled'},
              'scheduled': {'scheduled', 'cancelled', 'completed'},
              'accepted': {'accepted', 'notified', 'cancelled', 'completed'},
              'notified': {'notified', 'cancelled', 'completed'},
              'cancelled': {'cancelled'},
              'completed': {'completed'},
            };
      if (!(allowedTransitions[oldStatus]?.contains(nextStatus) ?? false)) {
        throw StateError('انتقال الحالة من $oldStatus إلى $nextStatus غير مسموح');
      }
    }
    if (entityType == 'queue_entries' && columns.contains('updated_at')) values['updated_at'] = now;
    final names = values.keys.toList();
    db.execute(
      'UPDATE $entityType SET ${names.map((name) => '$name=?').join(',')} WHERE id=? AND beneficiary_id=?',
      [...names.map((name) => values[name]), localId, beneficiaryId],
    );
    if ((db.select('SELECT changes() AS n').first['n'] as num).toInt() != 1) {
      throw StateError('تعذر تحديث سجل التشغيل');
    }
  }

  void _applySyncBusinessEvent({
    required int station, required String entityType, required String entityKey,
    required String operation, required Map payload, required String now, required int? userId, required String? role,
  }) {
    if (const {'pumps','partners','workers','payment_methods','cashboxes'}.contains(entityType)) {
      _applySyncMasterData(station:station,entityType:entityType,entityKey:entityKey,operation:operation,payload:payload,now:now,role:role);
      return;
    }
    if (entityType == 'irrigation_sessions') {
      _applySyncIrrigationSession(station:station,entityKey:entityKey,operation:operation,payload:payload,now:now,role:role);
      return;
    }
    if (entityType == 'queue_entries' || entityType == 'booking_requests') {
      _applySyncQueueOrBooking(
        station: station, entityType: entityType, entityKey: entityKey,
        operation: operation, payload: payload, now: now,
      );
      return;
    }
    if (entityType == 'cloud_periods') {
      if (operation != 'create') throw UnsupportedError('فترة الغيم لا تقبل التعديل المباشر بعد ترحيل السقاية');
      _applySyncCloudPeriod(station:station,entityKey:entityKey,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'irrigations') {
      if (operation != 'create') throw UnsupportedError('تعديل أو حذف السقاية يحتاج معالج عكس محاسبي مخصصاً');
      _applySyncIrrigation(station:station,entityKey:entityKey,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'expenses') {
      _applySyncExpense(station:station,entityKey:entityKey,operation:operation,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'cashbox_transfers') {
      _applySyncCashboxTransfer(station:station,entityKey:entityKey,operation:operation,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'diesel_movements') {
      _applySyncDieselMovement(station:station,entityKey:entityKey,operation:operation,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'payments') {
      if (operation != 'create') throw UnsupportedError('تعديل أو حذف القبض يحتاج معالج عكس محاسبي مخصصاً');
      _applySyncPaymentReceipt(station:station,entityKey:entityKey,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'beneficiary_manual_debts') {
      _applySyncBeneficiaryManualDebt(station:station,entityKey:entityKey,operation:operation,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType == 'worker_transactions' || entityType == 'partner_transactions') {
      _applySyncPartyOpeningDebt(station:station,entityType:entityType,entityKey:entityKey,operation:operation,payload:payload,now:now,userId:userId,role:role);
      return;
    }
    if (entityType != 'beneficiaries') throw UnsupportedError('معالج المزامنة لهذا المجال غير منفذ بعد');
    final globalId = '${payload['_global_id'] ?? ''}';
    final validGlobalId = globalId.length == 36 &&
        globalId[8] == '-' && globalId[13] == '-' &&
        globalId[18] == '-' && globalId[23] == '-' &&
        globalId.replaceAll('-', '').length == 32 &&
        RegExp(r'^[0-9a-fA-F-]{36}').hasMatch(globalId);
    if (!validGlobalId || entityKey != 'beneficiaries:$globalId') {
      throw StateError('هوية المستفيد العالمية غير صالحة');
    }
    if (!_hasTable('beneficiaries')) {
      throw StateError('جدول المستفيدين غير موجود في قاعدة الأعمال');
    }
    final columns = db.select('PRAGMA table_info(beneficiaries)')
        .map((row) => '${row['name']}').toSet();
    if (!columns.contains('station_id') || !columns.contains('name')) {
      throw StateError('مخطط جدول المستفيدين لا يدعم تطبيق المزامنة الآمن');
    }
    final links = db.select(
      'SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',
      [station, entityType, globalId],
    );
    final localId = links.isEmpty ? null : (links.first['local_id'] as num).toInt();
    const allowed = {
      'name', 'phone', 'address', 'location', 'jerba_number',
      'area', 'is_needy', 'notes',
    };
    for (final financialField in const {
      'opening_balance', 'carried_balance', 'opening_diesel_liters',
    }) {
      final value = payload[financialField];
      if (value != null) {
        final amount = value is num ? value : num.tryParse(value.toString());
        if (amount == null || amount != 0) {
          throw UnsupportedError(
            'تغيير الرصيد الافتتاحي أو رصيد الديزل يحتاج معالجاً محاسبياً مخصصاً',
          );
        }
      }
    }
    if (operation == 'create') {
      if (localId != null) throw StateError('هوية المستفيد موجودة مسبقاً؛ استخدم update');
      final values = <String, Object?>{
        'station_id': station,
        'name': '${payload['name'] ?? ''}'.trim(),
        if (columns.contains('status')) 'status': 'active',
        if (columns.contains('created_at')) 'created_at': now,
        if (columns.contains('updated_at')) 'updated_at': now,
      };
      if ((values['name'] as String).isEmpty) throw StateError('اسم المستفيد مطلوب');
      for (final key in allowed) {
        if (payload.containsKey(key) && columns.contains(key)) {
          final value = payload[key];
          values[key] = key == 'is_needy' && value is bool ? (value ? 1 : 0) : value;
        }
      }
      values['name'] = '${values['name']}'.trim();
      final names = values.keys.toList();
      db.execute(
        'INSERT INTO beneficiaries(${names.join(',')}) VALUES(${List.filled(names.length, '?').join(',')})',
        names.map((key) => values[key]).toList(),
      );
      db.execute(
        'INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,?,?,?,?)',
        [station, entityType, globalId, db.lastInsertRowId, now],
      );
      return;
    }
    if (localId == null) throw StateError('لا يوجد سجل أعمال مرتبط بهذه الهوية العالمية');
    if (operation == 'delete') {
      if (!columns.contains('status')) throw StateError('الحذف الآمن يتطلب عمود حالة في جدول المستفيدين');
      db.execute(
        "UPDATE beneficiaries SET status='deleted'${columns.contains('updated_at') ? ',updated_at=?' : ''} WHERE id=? AND station_id=?",
        columns.contains('updated_at') ? [now, localId, station] : [localId, station],
      );
      if ((db.select('SELECT changes() AS n').first['n'] as num).toInt() != 1) {
        throw StateError('المستفيد غير موجود ضمن المحطة الحالية');
      }
      return;
    }
    final values = <String, Object?>{};
    for (final key in allowed) {
      if (payload.containsKey(key) && columns.contains(key)) {
        final value = payload[key];
        values[key] = key == 'is_needy' && value is bool ? (value ? 1 : 0) : value;
      }
    }
    if (values.isEmpty) throw StateError('لا توجد حقول مستفيد قابلة للتحديث');
    if (values.containsKey('name') && '${values['name']}'.trim().isEmpty) {
      throw StateError('اسم المستفيد مطلوب');
    }
    if (values.containsKey('name')) values['name'] = '${values['name']}'.trim();
    if (columns.contains('updated_at')) values['updated_at'] = now;
    final names = values.keys.toList();
    db.execute(
      'UPDATE beneficiaries SET ${names.map((key) => '$key=?').join(',')} WHERE id=? AND station_id=?',
      [...names.map((key) => values[key]), localId, station],
    );
    if ((db.select('SELECT changes() AS n').first['n'] as num).toInt() != 1) {
      throw StateError('المستفيد غير موجود ضمن المحطة الحالية');
    }
  }

  Future<Response> _syncPush(Request request, Map<String,dynamic> claims) async {
    final body = await _body(request);
    final device = '${body['device_id'] ?? ''}'.trim();
    final rawEvents = body['events'];
    if (device.isEmpty || device.length > 128 || rawEvents is! List ||
        rawEvents.isEmpty || rawEvents.length > 100) {
      return _json({'error':'دفعة المزامنة غير صالحة'},status:400);
    }
    final station = _stationId(claims);
    final now = DateTime.now().toUtc().toIso8601String();
    final results = <Map<String,Object?>>[];
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final raw in rawEvents) {
        if (raw is! Map) {
          results.add({'status':'rejected','message':'صيغة الحدث غير صالحة'});
          continue;
        }
        final event = Map<String,dynamic>.from(raw);
        final eventId = '${event['event_id'] ?? ''}'.trim();
        final entityType = '${event['entity_type'] ?? ''}'.trim();
        final entityKey = '${event['entity_key'] ?? ''}'.trim();
        final operation = '${event['operation'] ?? ''}'.trim();
        final payload = event['payload'];
        final baseVersion = (event['base_version'] as num?)?.toInt();
        final validUuid = RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
        ).hasMatch(eventId);
        if (!validUuid || !_syncEntityTypes.contains(entityType) ||
            entityKey.isEmpty || entityKey.length > 160 ||
            !const {'create','update','delete'}.contains(operation) ||
            payload is! Map || baseVersion == null || baseVersion < 0 ||
            utf8.encode(_canonicalSyncJson(payload)).length > 262144) {
          results.add({'event_id':eventId,'status':'rejected','message':'حقول الحدث غير صالحة'});
          continue;
        }
        final duplicate = db.select(
          '''SELECT server_sequence,status,server_version,source_device,
            entity_type,entity_key,operation,payload_json,base_version
            FROM sync_event_log WHERE station_id=? AND event_id=? LIMIT 1''',
          [station,eventId],
        );
        if (duplicate.isNotEmpty) {
          final previous = duplicate.first;
          final sameRequest = previous['source_device'] == device &&
              previous['entity_type'] == entityType &&
              previous['entity_key'] == entityKey &&
              previous['operation'] == operation &&
              (previous['base_version'] as num).toInt() == baseVersion &&
              previous['payload_json'] == _canonicalSyncJson(payload);
          if (!sameRequest) {
            results.add({
              'event_id': eventId,
              'status': 'rejected',
              'message': 'أعيد استخدام event_id لحمولة أو مصدر مختلف؛ رُفض الحدث لحماية سلامة Idempotency.',
            });
            continue;
          }
          if (previous['status'] == 'conflict') {
            results.add({
              'event_id': eventId,
              'status': 'conflict',
              'server_sequence': previous['server_sequence'],
              'server_version': previous['server_version'],
              'current_version': previous['server_version'],
              'message': 'الحدث مسجل كتعارض سابق',
            });
            continue;
          }
          // Do not replay legacy "accepted" log entries as success unless
          // the corresponding business row can still be proven to exist.
          var businessRowExists = false;
          if (payload is Map) {
            final globalId = '${payload['_global_id'] ?? ''}';
            if (entityType == 'beneficiaries') {
              businessRowExists = db.select('''
                SELECT 1 FROM sync_entity_links l JOIN beneficiaries b
                  ON b.id=l.local_id AND b.station_id=l.station_id
                WHERE l.station_id=? AND l.entity_type='beneficiaries' AND l.global_id=? LIMIT 1
              ''', [station, globalId]).isNotEmpty;
            } else if (entityType == 'expenses') {
              businessRowExists = db.select("SELECT 1 FROM sync_entity_links l JOIN expenses e ON e.id=l.local_id AND e.station_id=l.station_id WHERE l.station_id=? AND l.entity_type='expenses' AND l.global_id=? LIMIT 1",[station,globalId]).isNotEmpty;
            } else if (entityType == 'cashbox_transfers') {
              businessRowExists = db.select("SELECT 1 FROM sync_entity_links l JOIN cashbox_transfers t ON t.id=l.local_id AND t.station_id=l.station_id WHERE l.station_id=? AND l.entity_type='cashbox_transfers' AND l.global_id=? LIMIT 1",[station,globalId]).isNotEmpty;
            } else if (entityType == 'diesel_movements') {
              businessRowExists = db.select('''SELECT 1 FROM sync_entity_links l JOIN diesel_movements d ON d.id=l.local_id AND d.station_id=l.station_id WHERE l.station_id=? AND l.entity_type='diesel_movements' AND l.global_id=? LIMIT 1''',[station,globalId]).isNotEmpty;
            } else if (entityType == 'irrigations') {
              businessRowExists = db.select('SELECT 1 FROM sync_entity_links l JOIN irrigations i ON i.id=l.local_id AND i.station_id=l.station_id WHERE l.station_id=? AND l.entity_type=\'irrigations\' AND l.global_id=? LIMIT 1',[station,globalId]).isNotEmpty;
            } else if (entityType == 'irrigation_sessions') {
              businessRowExists = db.select('''
                SELECT 1 FROM sync_entity_links l
                JOIN irrigation_sessions s ON s.id=l.local_id
                JOIN pumps p ON p.id=s.pump_id AND p.station_id=l.station_id
                JOIN beneficiaries b ON b.id=s.beneficiary_id AND b.station_id=l.station_id
                WHERE l.station_id=? AND l.entity_type='irrigation_sessions' AND l.global_id=? LIMIT 1
              ''',[station,globalId]).isNotEmpty;
            } else if (entityType == 'queue_entries' || entityType == 'booking_requests') {
              businessRowExists = db.select(
                'SELECT 1 FROM sync_entity_links l JOIN ' + entityType +
                ' q ON q.id=l.local_id JOIN beneficiaries b ON b.id=q.beneficiary_id AND b.station_id=l.station_id ' +
                'WHERE l.station_id=? AND l.entity_type=? AND l.global_id=? LIMIT 1',
                [station,entityType,globalId],
              ).isNotEmpty;
            } else if (entityType == 'cloud_periods') {
              businessRowExists = db.select('SELECT 1 FROM sync_entity_links l JOIN cloud_periods cp ON cp.id=l.local_id JOIN irrigations i ON i.id=cp.irrigation_id AND i.station_id=l.station_id WHERE l.station_id=? AND l.entity_type=\'cloud_periods\' AND l.global_id=? LIMIT 1',[station,globalId]).isNotEmpty;
            } else if (entityType == 'payments') {
              businessRowExists = db.select('''
                SELECT 1 FROM sync_entity_links l JOIN payments p
                  ON p.id=l.local_id AND p.station_id=l.station_id
                WHERE l.station_id=? AND l.entity_type='payments' AND l.global_id=? AND p.status='posted' LIMIT 1
              ''', [station, globalId]).isNotEmpty;
            } else if (entityType == 'beneficiary_manual_debts') {
              businessRowExists = db.select('''
                SELECT 1 FROM sync_entity_links l
                JOIN beneficiary_manual_debts md ON md.id=l.local_id
                JOIN beneficiaries b ON b.id=md.beneficiary_id AND b.station_id=l.station_id
                WHERE l.station_id=? AND l.entity_type='beneficiary_manual_debts'
                  AND l.global_id=? LIMIT 1
              ''', [station, globalId]).isNotEmpty;
            } else if (const {'pumps','partners','workers','payment_methods','cashboxes'}.contains(entityType)) {
              businessRowExists = db.select(
                'SELECT 1 FROM sync_entity_links l JOIN ' + entityType +
                ' t ON t.id=l.local_id AND t.station_id=l.station_id ' +
                'WHERE l.station_id=? AND l.entity_type=? AND l.global_id=? LIMIT 1',
                [station,entityType,globalId],
              ).isNotEmpty;
            } else if (entityType == 'worker_transactions' || entityType == 'partner_transactions') {
              final partyTable = entityType == 'worker_transactions' ? 'workers' : 'partners';
              final partyColumn = entityType == 'worker_transactions' ? 'worker_id' : 'partner_id';
              businessRowExists = db.select(
                'SELECT 1 FROM sync_entity_links l JOIN ' + entityType + ' t ON t.id=l.local_id AND t.station_id=l.station_id JOIN ' + partyTable + ' p ON p.id=t.' + partyColumn + ' AND p.station_id=l.station_id WHERE l.station_id=? AND l.entity_type=? AND l.global_id=? LIMIT 1',
                [station,entityType,globalId],
              ).isNotEmpty;
            }
          }
          if (!businessRowExists) {
            results.add({
              'event_id': eventId,
              'status': 'rejected',
              'message': 'الحدث مسجل قديماً دون دليل كافٍ على تطبيقه في سجل الأعمال؛ يحتاج مراجعة.',
            });
          } else {
            results.add({
              'event_id': eventId,
              'status': 'duplicate',
              'server_sequence': previous['server_sequence'],
              'server_version': previous['server_version'],
              'current_version': previous['server_version'],
              'message': 'الحدث مسجل ومطبق مسبقاً',
            });
          }
          continue;
        }
        // New clients identify entities by UUID. Bridge the previous
        // table:local_id version key without resetting its server version.
        if (payload is Map && payload['_global_id'] != null) {
          final globalId = payload['_global_id'].toString();
          final validGlobalId = RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
          ).hasMatch(globalId);
          if (!validGlobalId || entityKey != entityType + ':' + globalId) {
            results.add({'event_id':eventId,'status':'rejected','message':'هوية السجل العالمية أو مفتاح الكيان غير متطابق'});
            continue;
          }
          final localId = (payload['id'] as num?)?.toInt();
          if (localId != null) {
            final legacyKey = entityType + ':' + localId.toString();
            if (legacyKey != entityKey) {
              final globalVersion = db.select(
                'SELECT version FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=? LIMIT 1',
                [station,entityType,entityKey],
              );
              final legacyVersion = db.select(
                'SELECT version FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=? LIMIT 1',
                [station,entityType,legacyKey],
              );
              if (globalVersion.isEmpty && legacyVersion.isNotEmpty) {
                db.execute('''INSERT INTO sync_entity_versions
                  (station_id,entity_type,entity_key,version,updated_at)
                  VALUES(?,?,?,?,?)''',[
                  station,entityType,entityKey,legacyVersion.first['version'],now
                ]);
                db.execute(
                  'DELETE FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=?',
                  [station,entityType,legacyKey],
                );
                db.execute(
                  'UPDATE sync_event_log SET entity_key=? WHERE station_id=? AND entity_type=? AND entity_key=?',
                  [entityKey,station,entityType,legacyKey],
                );
              }
            }
          }
        }
        if (_isDerivedSyncEvent(station, entityType, operation, payload)) {
          final versionRows = db.select(
            'SELECT version FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=? LIMIT 1',
            [station, entityType, entityKey],
          );
          final current = versionRows.isEmpty
              ? 0
              : (versionRows.first['version'] as num).toInt();
          // Legacy clients may still have child rows in their Outbox. They are
          // acknowledged as superseded, never applied as a second command.
          results.add({
            'event_id': eventId,
            'status': 'accepted',
            'server_version': current,
            'current_version': current,
            'message': 'أثر تابع؛ أنشأه أمر العمل الأصلي على الخادم ولم يُنفذ كأمر مستقل.',
          });
          continue;
        }
        final currentRows = db.select(
          'SELECT version FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=? LIMIT 1',
          [station,entityType,entityKey],
        );
        final currentVersion = currentRows.isEmpty ? 0 : (currentRows.first['version'] as num).toInt();
        final conflict = baseVersion != currentVersion;
        final nextVersion = conflict ? currentVersion : currentVersion + 1;
        if (conflict) {
          db.execute('''INSERT INTO sync_event_log
            (station_id,event_id,source_device,entity_type,entity_key,operation,payload_json,base_version,server_version,status,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)''',[
            station,eventId,device,entityType,entityKey,operation,
            _canonicalSyncJson(payload),baseVersion,nextVersion,'conflict',now
          ]);
          results.add({
            'event_id':eventId,
            'status':'conflict',
            'server_version':nextVersion,
            'current_version':currentVersion,
            'message':'تعارض إصدار؛ لم يتم اعتماد الحدث تلقائياً',
          });
          continue;
        }

        // A successful acknowledgement means the business row, event log and
        // entity version were all committed together. A failed domain handler
        // rolls back only this event and never advances its version.
        db.execute('SAVEPOINT apply_sync_event');
        try {
          _applySyncBusinessEvent(
            station: station,
            entityType: entityType,
            entityKey: entityKey,
            operation: operation,
            payload: Map.from(payload),
            now: now,
            userId: (claims['userId'] as num?)?.toInt(),
            role: claims['role']?.toString(),
          );
          db.execute('''INSERT INTO sync_event_log
            (station_id,event_id,source_device,entity_type,entity_key,operation,payload_json,base_version,server_version,status,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)''',[
            station,eventId,device,entityType,entityKey,operation,
            _canonicalSyncJson(payload),baseVersion,nextVersion,'accepted',now
          ]);
          db.execute('''INSERT INTO sync_entity_versions(station_id,entity_type,entity_key,version,updated_at)
            VALUES(?,?,?,?,?) ON CONFLICT(station_id,entity_type,entity_key)
            DO UPDATE SET version=excluded.version,updated_at=excluded.updated_at''',
            [station,entityType,entityKey,nextVersion,now]);
          if (entityType == 'irrigations' || entityType == 'payments') {
            final globalId = (payload['_global_id'] ?? '').toString();
            final linked = db.select(
              'SELECT local_id FROM sync_entity_links WHERE station_id=? AND entity_type=? AND global_id=? LIMIT 1',
              [station, entityType, globalId],
            );
            if (linked.isEmpty) {
              throw StateError('تعذر العثور على سجل أمر العمل لنشر آثاره التابعة');
            }
            _appendBusinessEffectProjections(
              station: station,
              sourceDevice: device,
              entityType: entityType,
              businessId: (linked.first['local_id'] as num).toInt(),
              payload: payload,
              now: now,
            );
          }
          db.execute('RELEASE SAVEPOINT apply_sync_event');
          results.add({
            'event_id':eventId,
            'status':'accepted',
            'server_version':nextVersion,
            'current_version':currentVersion,
          });
        } catch (error) {
          db.execute('ROLLBACK TO SAVEPOINT apply_sync_event');
          db.execute('RELEASE SAVEPOINT apply_sync_event');
          results.add({
            'event_id':eventId,
            'status':'rejected',
            'message':'لم يطبق الخادم سجل الأعمال؛ لم يتم اعتماد الحدث: $error',
          });
        }
      }
      db.execute('COMMIT');
    } catch (error) {
      try { db.execute('ROLLBACK'); } catch (_) {}
      return _json({'error':'تعذر حفظ أحداث المزامنة'},status:500);
    }
    return _json({'results':results});
  }

  Future<Response> _syncInbox(Request request, Map<String,dynamic> claims) async {
    final station = _stationId(claims);
    final after = int.tryParse(request.url.queryParameters['after'] ?? '0') ?? -1;
    final device = (request.url.queryParameters['device_id'] ?? '').trim();
    if (after < 0 || device.isEmpty || device.length > 128) {
      return _json({'error':'مؤشر Inbox أو معرف الجهاز غير صالح'},status:400);
    }
    final rows = db.select('''SELECT server_sequence,event_id,entity_type,entity_key,
      operation,payload_json,base_version,server_version,source_device
      FROM sync_event_log
      WHERE station_id=? AND server_sequence>? AND source_device<>? AND status='accepted'
      ORDER BY server_sequence LIMIT 100''',[station,after,device]);
    final events = rows.map((row) => <String,Object?>{
      'server_sequence':row['server_sequence'],
      'event_id':row['event_id'],
      'entity_type':row['entity_type'],
      'entity_key':row['entity_key'],
      'operation':row['operation'],
      'payload':jsonDecode(row['payload_json'] as String),
      'base_version':row['base_version'],
      'server_version':row['server_version'],
      'source_device':row['source_device'],
    }).toList();
    final high = db.select(
      'SELECT COALESCE(MAX(server_sequence),0) AS cursor FROM sync_event_log WHERE station_id=?',
      [station],
    ).first['cursor'] as int;
    // Do not skip the remainder when a station has more than one page.
    final cursor = rows.length == 100
        ? (rows.last['server_sequence'] as num).toInt()
        : high;
    return _json({'events':events,'cursor':cursor});
  }

  int _stationId(Map<String, dynamic> claims) {
    final stationId = (claims['stationId'] as num?)?.toInt();
    if (stationId == null || stationId <= 0) {
      throw StateError('رمز الجلسة لا يحتوي على محطة صالحة');
    }
    return stationId;
  }
  bool _owns(String table,int id,int stationId){final r=db.select('SELECT id FROM $table WHERE id=? AND station_id=? LIMIT 1',[id,stationId]);return r.isNotEmpty;}
  void _requireOwn(String table,int? id,int stationId,String label){if(id==null||!_owns(table,id,stationId))throw StateError('$label لا يتبع المحطة الحالية');}
  void _audit(int userId,String operation,String table,int? recordId,{String? reason}){db.execute('INSERT INTO audit_logs(user_id,operation,table_name,record_id,reason,created_at) VALUES(?,?,?,?,?,?)',[userId,operation,table,recordId,reason,DateTime.now().toIso8601String()]);}
  int _round(double v,String mode)=>mode=='up'?v.ceil():mode=='down'?v.floor():v.round();

  Future<Response> _adminLogin(Request r) async {
    final body = await _body(r);
    final username = '${body['username'] ?? ''}'.trim();
    final password = '${body['password'] ?? ''}';
    if (username.isEmpty || password.isEmpty) {
      return _json({'error': 'اسم المستخدم أو كلمة المرور غير صحيحة'}, status: 401);
    }
    final scopes = _loginScopes(r, username);
    final now = DateTime.now().toUtc();
    if (_loginIsBlocked(scopes, now)) {
      return Response(429,
        body: jsonEncode({'error': 'محاولات تسجيل الدخول كثيرة؛ حاول بعد 15 دقيقة'}),
        headers: {'content-type': 'application/json; charset=utf-8', 'retry-after': '900'});
    }
    final rows = db.select(
      'SELECT id,station_id,name,role,password_hash FROM app_users WHERE username=? AND active=1 LIMIT 1',
      [username],
    );
    if (rows.isEmpty ||
        !await PasswordHasher.verify(password, '${rows.first['password_hash'] ?? ''}')) {
      _recordFailedLogin(scopes, now);
      return _json({'error': 'اسم المستخدم أو كلمة المرور غير صحيحة'}, status: 401);
    }

    final row = rows.first;
    final storedHash = '${row['password_hash'] ?? ''}';
    if (!PasswordHasher.isArgon2id(storedHash)) {
      final upgradedHash = await PasswordHasher.hash(password);
      db.execute(
        'UPDATE app_users SET password_hash=? WHERE id=? AND password_hash=? AND active=1',
        [upgradedHash, row['id'], storedHash],
      );
      if (db.select('SELECT changes() AS affected').first['affected'] == 0) {
        // A concurrent successful login may already have upgraded the hash.
        final latest = db.select(
          'SELECT password_hash FROM app_users WHERE id=? AND active=1 LIMIT 1',
          [row['id']],
        );
        if (latest.isEmpty ||
            !await PasswordHasher.verify(
              password,
              '${latest.first['password_hash'] ?? ''}',
            )) {
          _recordFailedLogin(scopes, now);
          return _json({'error': 'اسم المستخدم أو كلمة المرور غير صحيحة'}, status: 401);
        }
      }
    }

    final activeRows = db.select(
      'SELECT id,station_id,name,role FROM app_users WHERE id=? AND active=1 LIMIT 1',
      [row['id']],
    );
    if (activeRows.isEmpty) {
      _recordFailedLogin(scopes, now);
      return _json({'error': 'اسم المستخدم أو كلمة المرور غير صحيحة'}, status: 401);
    }
    _clearLoginFailures(scopes);
    final user = _rows(activeRows).first;
    return _json({
      'token': _token({'kind': 'admin', 'userId': user['id'], 'stationId': user['station_id'], 'role': user['role']}),
      'user': {'id': user['id'], 'name': user['name'], 'role': user['role']},
    });
  }
  Future<Response> _dashboard(Request r,Map<String,dynamic> c) async {final station=_stationId(c);final x=_rows(db.select("SELECT (SELECT COUNT(*) FROM beneficiaries WHERE status='active' AND station_id=?) beneficiaries,(SELECT COUNT(*) FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE b.station_id=? AND q.status IN ('waiting','postponed')) queue,(SELECT COUNT(*) FROM booking_requests br JOIN beneficiaries b ON b.id=br.beneficiary_id WHERE b.station_id=? AND br.status IN ('new','under_review')) bookings,(SELECT COUNT(*) FROM irrigation_sessions s JOIN pumps p ON p.id=s.pump_id JOIN beneficiaries b ON b.id=s.beneficiary_id WHERE p.station_id=? AND b.station_id=? AND s.status='running') running_sessions,(SELECT COALESCE(SUM(total_amount),0) FROM irrigations WHERE status!='cancelled' AND station_id=?) revenue,(SELECT COALESCE(SUM(amount),0) FROM payments WHERE status='posted' AND station_id=?) paid,(SELECT COALESCE(SUM(amount),0) FROM expenses WHERE status='posted' AND station_id=?) expenses",[station,station,station,station,station,station,station,station])).first;return _json(x);}
  Map<String,String> _settingsForStation(int stationId) => {
    for(final x in db.select('SELECT key,value FROM station_settings WHERE station_id=?',[stationId]))
      x['key'] as String: x['value'] as String,
  };
  Future<Response> _settings(Request r,Map<String,dynamic> c) async => _json(_settingsForStation(_stationId(c)));
  Future<Response> _settingsPut(Request r,Map<String,dynamic> c) async {
    final b=await _body(r); final station=_stationId(c); final now=DateTime.now().toIso8601String();
    for(final e in b.entries){db.execute('INSERT INTO station_settings(station_id,key,value,updated_at) VALUES(?,?,?,?) ON CONFLICT(station_id,key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at',[station,e.key,'${e.value}',now]);}
    return _settings(r,c);
  }
  String _beneficiaryBalanceExpression() {
    final columns = db.select('PRAGMA table_info(beneficiaries)')
        .map((row) => '${row['name']}').toSet();
    final parts = <String>[];
    if (columns.contains('opening_balance')) parts.add('COALESCE(b.opening_balance,0)');
    if (columns.contains('carried_balance')) parts.add('COALESCE(b.carried_balance,0)');
    if (_hasTable('beneficiary_manual_debts')) {
      parts.add("(SELECT COALESCE(SUM(md.amount),0) FROM beneficiary_manual_debts md WHERE md.beneficiary_id=b.id AND md.status='posted')");
    }
    if (_hasTable('irrigations')) {
      parts.add("(SELECT COALESCE(SUM(i.total_amount),0) FROM irrigations i WHERE i.beneficiary_id=b.id AND i.station_id=b.station_id AND i.status!='cancelled')");
    }
    if (_hasTable('diesel_movements')) {
      parts.add("(SELECT COALESCE(SUM(d.amount),0) FROM diesel_movements d WHERE d.beneficiary_id=b.id AND d.station_id=b.station_id AND d.kind='advance' AND d.irrigation_id IS NULL)");
    }
    if (_hasTable('payments')) {
      parts.add("(SELECT -COALESCE(SUM(p.amount),0) FROM payments p WHERE p.beneficiary_id=b.id AND p.station_id=b.station_id AND p.status='posted')");
    }
    if (_hasTable('diesel_movements') && _hasTable('station_settings')) {
      parts.add("""CASE WHEN (SELECT value FROM station_settings WHERE station_id=b.station_id AND key='diesel_delivery_financial_credit')='true' THEN -(SELECT COALESCE(SUM(d2.amount),0) FROM diesel_movements d2 WHERE d2.beneficiary_id=b.id AND d2.station_id=b.station_id AND d2.kind='delivery') ELSE 0 END""");
    }
    return parts.isEmpty ? '0' : '(${parts.join(' + ')})';
  }

  Future<Response> _beneficiaries(Request r,Map<String,dynamic> c) async {
    final station = _stationId(c);
    // Give legacy server-side rows a stable identity once; never infer identity
    // from a local integer ID or from a beneficiary name.
    final missingLinks = db.select("""
      SELECT b.id FROM beneficiaries b
      LEFT JOIN sync_entity_links l
        ON l.station_id=b.station_id AND l.entity_type='beneficiaries' AND l.local_id=b.id
      WHERE b.station_id=? AND l.global_id IS NULL
    """, [station]);
    for (final row in missingLinks) {
      db.execute(
        "INSERT OR IGNORE INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(?,'beneficiaries',?,?,?)",
        [station, const Uuid().v4(), row['id'], DateTime.now().toIso8601String()],
      );
    }
    final balance = _beneficiaryBalanceExpression();
    final term = (r.url.queryParameters['q'] ?? '').trim();
    final args = <Object?>[station];
    var where = "b.status='active' AND b.station_id=?";
    if (term.isNotEmpty) {
      where += " AND (b.name LIKE ? OR COALESCE(b.phone,'') LIKE ?"
          " OR COALESCE(b.jerba_number,'') LIKE ? OR COALESCE(b.location,'') LIKE ?)";
      final pattern = '%$term%';
      args.addAll([pattern, pattern, pattern, pattern]);
    }
    return _json(_rows(db.select("""
      SELECT b.*, l.global_id AS _global_id, $balance AS balance
      FROM beneficiaries b
      JOIN sync_entity_links l
        ON l.station_id=b.station_id AND l.entity_type='beneficiaries' AND l.local_id=b.id
      WHERE $where
      ORDER BY b.name
    """, args)));
  }
  Future<Response> _beneficiaryCreate(Request r,Map<String,dynamic> c) async { final b=await _body(r); if('${b['name']??''}'.trim().isEmpty)return _json({'error':'اسم المستفيد مطلوب'},status:422); final now=DateTime.now().toIso8601String(); final id=db.lastInsertRowId; db.execute('INSERT INTO beneficiaries(station_id,name,phone,address,location,jerba_number,area,is_needy,opening_balance,carried_balance,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,\'active\',?,?)',[_stationId(c),b['name'],b['phone'],b['address'],b['location'],b['jerba_number'],b['area'],b['is_needy']==true?1:0,(b['opening_balance'] as num?)?.round()??0,(b['carried_balance'] as num?)?.round()??0,now,now]); return _json({'id':db.lastInsertRowId}); }
  int? _resolveBeneficiaryRouteId(String routeId, int stationId) {
    // API clients address entities by their stable global UUID. Numeric IDs
    // remain supported for legacy admin clients, but are always station-scoped.
    final localId = int.tryParse(routeId);
    if (localId != null) {
      return _owns('beneficiaries', localId, stationId) ? localId : null;
    }
    final rows = db.select('''
      SELECT b.id
      FROM sync_entity_links l
      JOIN beneficiaries b ON b.id=l.local_id AND b.station_id=l.station_id
      WHERE l.station_id=? AND l.entity_type='beneficiaries'
        AND l.global_id=? AND b.status='active'
      LIMIT 1
    ''', [stationId, routeId]);
    return rows.isEmpty ? null : (rows.first['id'] as num).toInt();
  }
  Future<Response> _beneficiary(Request r,Map<String,dynamic> c) async {
    final station = _stationId(c);
    final id = _resolveBeneficiaryRouteId(r.params['id']!, station);
    if (id == null) return _json({'error':'المستفيد غير موجود'},status:404);
    final rows = db.select('''
      SELECT b.*, l.global_id AS _global_id,
        ${_beneficiaryBalanceExpression()} AS balance
      FROM beneficiaries b
      JOIN sync_entity_links l
        ON l.station_id=b.station_id AND l.entity_type='beneficiaries'
        AND l.local_id=b.id
      WHERE b.id=? AND b.station_id=? AND b.status='active'
      LIMIT 1
    ''', [id, station]);
    return rows.isEmpty
        ? _json({'error':'المستفيد غير موجود'},status:404)
        : _json(_rows(rows).first);
  }
  Future<Response> _beneficiaryUpdate(Request r,Map<String,dynamic> c) async {
    final station = _stationId(c);
    final id = _resolveBeneficiaryRouteId(r.params['id']!, station);
    if (id == null) return _json({'error':'المستفيد غير موجود'},status:404);
    final b=await _body(r);
    const allowed=['name','phone','address','location','jerba_number','area','is_needy','notes'];
    final sets=<String>[];
    final args=<Object?>[];
    for(final k in allowed){if(b.containsKey(k)){sets.add('$k=?');args.add(b[k] is bool?(b[k]?1:0):b[k]);}}
    if(sets.isEmpty)return _json({'error':'لا توجد حقول قابلة للتعديل'},status:422);
    args.add(DateTime.now().toIso8601String());args.add(id);args.add(station);
    db.execute('UPDATE beneficiaries SET ${sets.join(',')},updated_at=? WHERE id=? AND station_id=?',args);
    return _beneficiary(r,c);
  }
  Future<Response> _beneficiaryDelete(Request r,Map<String,dynamic> c) async {
    final station = _stationId(c);
    final id = _resolveBeneficiaryRouteId(r.params['id']!, station);
    if (id == null) return _json({'error':'المستفيد غير موجود'},status:404);
    final b=await _body(r);
    if('${b['reason']??''}'.trim().isEmpty)return _json({'error':'سبب الحذف المنطقي مطلوب'},status:422);
    db.execute("UPDATE beneficiaries SET status='deleted',updated_at=? WHERE id=? AND station_id=?",[DateTime.now().toIso8601String(),id,station]);
    return _json({'ok':true});
  }
  Future<Response> _beneficiaryStatement(Request r,Map<String,dynamic> c) async {
    final station = _stationId(c);
    final id = _resolveBeneficiaryRouteId(r.params['id']!, station);
    if (id == null) return _json({'error':'المستفيد غير موجود'},status:404);
    final beneficiaryRows = db.select('''
      SELECT opening_balance,carried_balance
      FROM beneficiaries WHERE id=? AND station_id=? AND status='active'
      LIMIT 1
    ''', [id, station]);
    if (beneficiaryRows.isEmpty) {
      return _json({'error':'المستفيد غير موجود'},status:404);
    }
    final opening = (beneficiaryRows.first['opening_balance'] as num?)?.round() ?? 0;
    final carried = (beneficiaryRows.first['carried_balance'] as num?)?.round() ?? 0;
    final initialBalance = opening + carried;
    final creditDelivery =
        _settingsForStation(station)['diesel_delivery_financial_credit'] == 'true';

    // Every source is explicitly scoped to the authenticated station. Manual
    // debts inherit station ownership through their beneficiary relation.
    final events = db.select('''
      SELECT * FROM (
        SELECT i.id,i.date,i.start_datetime,i.end_datetime,i.system_type,
          i.minutes,i.cloud_minutes,i.chargeable_minutes,i.total_amount,
          i.paid_amount,'s' AS type,i.total_amount AS debit,0 AS credit,
          0 AS lah,i.total_amount AS alayh,'سقاية' AS description,
          'posted' AS status,i.notes AS notes,10 AS event_order
        FROM irrigations i
        WHERE i.beneficiary_id=? AND i.station_id=? AND i.status!='cancelled'

        UNION ALL
        SELECT p.id,p.date,p.date,p.date,'payment',0,0,0,0,-p.amount,
          'p',0,p.amount,p.amount,0,'قبض','posted',p.notes,20
        FROM payments p
        WHERE p.beneficiary_id=? AND p.station_id=? AND p.status='posted'

        UNION ALL
        SELECT d.id,d.date,d.date,d.date,'diesel_advance',0,0,0,0,0,
          'a',d.amount,0,0,d.amount,'سلفة ديزل','posted',d.notes,30
        FROM diesel_movements d
        WHERE d.beneficiary_id=? AND d.station_id=? AND d.kind='advance'
          AND d.irrigation_id IS NULL

        UNION ALL
        SELECT md.id,md.date,md.date,md.date,'manual_debt',0,0,0,0,0,
          'manual_debt',md.amount,0,0,md.amount,'إضافة مديونية',
          md.status,md.notes,40
        FROM beneficiary_manual_debts md
        JOIN beneficiaries owner ON owner.id=md.beneficiary_id
        WHERE md.beneficiary_id=? AND owner.station_id=?

        UNION ALL
        SELECT -md.id,md.cancelled_at,md.cancelled_at,md.cancelled_at,
          'manual_debt_reversal',0,0,0,0,0,'manual_debt_reversal',
          0,md.amount,md.amount,0,'إلغاء مديونية','cancelled',
          md.cancel_reason,50
        FROM beneficiary_manual_debts md
        JOIN beneficiaries owner ON owner.id=md.beneficiary_id
        WHERE md.beneficiary_id=? AND owner.station_id=?
          AND md.status='cancelled' AND md.cancelled_at IS NOT NULL

        ${creditDelivery ? '''
        UNION ALL
        SELECT d.id,d.date,d.date,d.date,'diesel_delivery',0,0,0,0,0,
          'd',0,d.amount,d.amount,0,'تسليم ديزل','posted',d.notes,60
        FROM diesel_movements d
        WHERE d.beneficiary_id=? AND d.station_id=? AND d.kind='delivery'
        ''' : ''}
      ) timeline
      ORDER BY COALESCE(date,''),event_order,id
    ''', [
      id, station,
      id, station,
      id, station,
      id, station,
      id, station,
      if (creditDelivery) id, if (creditDelivery) station,
    ]);

    final fromText = r.url.queryParameters['from'];
    final toText = r.url.queryParameters['to'];
    final fromParsed = fromText == null ? null : DateTime.tryParse(fromText);
    final toParsed = toText == null ? null : DateTime.tryParse(toText);
    if (fromText != null && fromParsed == null ||
        toText != null && toParsed == null) {
      return _json({'error':'نطاق التاريخ غير صالح'},status:422);
    }
    final fromDay = fromParsed == null
        ? null
        : DateTime(fromParsed.year,fromParsed.month,fromParsed.day);
    final toExclusive = toParsed == null
        ? null
        : DateTime(toParsed.year,toParsed.month,toParsed.day)
            .add(const Duration(days:1));

    var running = initialBalance;
    var periodOpeningBalance = initialBalance;
    final result = <Map<String,Object?>>[];
    for (final row in events) {
      final event = Map<String,Object?>.from(row);
      final debit = (event['debit'] as num?)?.round() ?? 0;
      final credit = (event['credit'] as num?)?.round() ?? 0;
      running += debit-credit;
      final date = DateTime.tryParse('${event['date'] ?? ''}');
      if (fromDay != null && (date == null || date.isBefore(fromDay))) {
        periodOpeningBalance = running;
        continue;
      }
      if (toExclusive != null && (date == null || !date.isBefore(toExclusive))) {
        continue;
      }
      final note = '${event['notes'] ?? ''}'.trim();
      final description = '${event['description'] ?? ''}'.trim();
      event['description'] = note.isEmpty || description.isEmpty
          ? description : '$description - $note';
      event['balance'] = running;
      event.remove('event_order');
      result.add(event);
    }

    if (fromDay != null) {
      result.insert(0, {
        'id':-3,'date':fromDay.toIso8601String(),
        'type':'opening_balance','description':'الرصيد المرحّل قبل الفترة',
        'debit':periodOpeningBalance>0?periodOpeningBalance:0,
        'credit':periodOpeningBalance<0?-periodOpeningBalance:0,
        'lah':periodOpeningBalance<0?-periodOpeningBalance:0,
        'alayh':periodOpeningBalance>0?periodOpeningBalance:0,
        'balance':periodOpeningBalance,
      });
    } else {
      if (opening != 0) {
        result.insert(0, {
          'id':-1,'date':null,'type':'opening_balance',
          'description':'رصيد افتتاحي',
          'debit':opening>0?opening:0,'credit':opening<0?-opening:0,
          'lah':opening<0?-opening:0,'alayh':opening>0?opening:0,
          'balance':opening,
        });
      }
      if (carried != 0) {
        result.insert(opening != 0 ? 1 : 0, {
          'id':-2,'date':null,'type':'carried_balance',
          'description':'رصيد مرحّل',
          'debit':carried>0?carried:0,'credit':carried<0?-carried:0,
          'lah':carried<0?-carried:0,'alayh':carried>0?carried:0,
          'balance':initialBalance,
        });
      }
    }
    return _json(result);
  }

  int _minutes(DateTime start,DateTime end,bool midnight){var e=end;if(!e.isAfter(start)){if(!midnight)throw StateError('وقت النهاية يجب أن يكون بعد وقت البداية');e=e.add(const Duration(days:1));}final m=e.difference(start).inMinutes;if(m<=0)throw StateError('مدة السقي غير صالحة');return m;}
  Future<Response> _irrigationCreateUnsafe(Request r,Map<String,dynamic> c) async { final b=await _body(r); try { _requireOwn('beneficiaries',(b['beneficiary_id'] as num?)?.toInt(),_stationId(c),'المستفيد'); _requireOwn('pumps',(b['pump_id'] as num?)?.toInt()??1,_stationId(c),'المضخة'); final start=DateTime.parse('${b['start']}');final end=DateTime.parse('${b['end']}');final settings=_settingsForStation(_stationId(c));final system='${b['system_type']??settings['system_type']??'diesel'}';final mins=_minutes(start,end,settings['allow_midnight_crossing']=='true');final cloud=(b['cloud_minutes'] as num?)?.round()??0;final charge=system=='solar'?((mins-cloud).clamp(0,mins)):mins;final waterRate=system=='diesel'?(int.tryParse(settings['diesel_hourly_water_rate']??'0')??0):system=='solar'?(int.tryParse(settings['solar_hourly_rate']??'0')??0):(int.tryParse(settings['third_type_hourly_rate']??'0')??0);final water=_round(charge/60*waterRate,settings['rounding']??'nearest');final liters=system=='diesel'?charge/60*(double.tryParse(settings['diesel_liters_per_hour']??'0')??0):0.0;final fuel=_round(liters*(int.tryParse(settings['diesel_price_per_liter']??'0')??0),settings['rounding']??'nearest');final total=water+fuel;final paid=(b['paid_amount'] as num?)?.round()??0;if(paid<0||paid>total)throw StateError('المدفوع يجب أن يكون بين صفر وإجمالي السقاية');final now=DateTime.now().toIso8601String();db.execute('INSERT INTO irrigations(station_id,pump_id,beneficiary_id,date,start_datetime,end_datetime,minutes,system_type,water_hourly_rate_snapshot,diesel_liters_per_hour_snapshot,diesel_price_snapshot,solar_hourly_rate_snapshot,third_type_hourly_rate_snapshot,cloud_minutes,chargeable_minutes,water_amount,diesel_amount,total_amount,paid_amount,status,created_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[_stationId(c),b['pump_id']??1,b['beneficiary_id'],start.toIso8601String().substring(0,10),start.toIso8601String(),end.toIso8601String(),mins,system,int.tryParse(settings['diesel_hourly_water_rate']??'0')??0,double.tryParse(settings['diesel_liters_per_hour']??'0')??0,int.tryParse(settings['diesel_price_per_liter']??'0')??0,int.tryParse(settings['solar_hourly_rate']??'0')??0,int.tryParse(settings['third_type_hourly_rate']??'0')??0,cloud,charge,water,fuel,total,paid,'posted',c['userId'],now,now]);final irrigationId=db.lastInsertRowId;final rec=_accountId('1200'),waterRev=_accountId('4000'),fuelRev=_accountId('4010');final lines=<Map<String,Object?>>[{'account_id':rec,'beneficiary_id':b['beneficiary_id'],'debit':total,'credit':0,'memo':'استحقاق سقاية'}];if(water>0)lines.add({'account_id':waterRev,'debit':0,'credit':water,'memo':'إيراد الماء'});if(fuel>0)lines.add({'account_id':fuelRev,'debit':0,'credit':fuel,'memo':'قيمة الديزل'});_journal(description:'سقاية رقم $irrigationId',referenceType:'irrigation',referenceId:irrigationId,lines:lines,userId:c['userId']);if(system=='diesel'&&liters>0){final stock=(db.select("SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements dm WHERE dm.station_id=?",[_stationId(c)]).first['stock'] as num).toDouble();final shortage=liters-stock;if(shortage>0){final advanceAmount=(shortage*(int.tryParse(settings['diesel_price_per_liter']??'0')??0)).round();db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[_stationId(c),b['beneficiary_id'],irrigationId,'advance',shortage,int.tryParse(settings['diesel_price_per_liter']??'0')??0,advanceAmount,now,'سلفة ديزل تلقائية',c['userId']]);final d=_accountId('1200'),cash=_accountId('1000');_journal(description:'سلفة ديزل تلقائية',referenceType:'diesel_advance',referenceId:db.lastInsertRowId,lines:[{'account_id':d,'beneficiary_id':b['beneficiary_id'],'debit':advanceAmount,'credit':0},{'account_id':cash,'debit':0,'credit':advanceAmount}],userId:c['userId']);}db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[_stationId(c),b['beneficiary_id'],irrigationId,'consumption',liters,int.tryParse(settings['diesel_price_per_liter']??'0')??0,fuel,now,'استهلاك السقاية',c['userId']]);}
if(paid>0){final pm=(b['payment_method_id'] as num?)?.toInt()??1;final cb=(b['cashbox_id'] as num?)?.toInt()??1;_requireOwn('payment_methods',pm,_stationId(c),'طريقة الدفع');_requireOwn('cashboxes',cb,_stationId(c),'الصندوق');db.execute('INSERT INTO payments(station_id,beneficiary_id,amount,date,payment_method_id,cashbox_id,reference_number,notes,status,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[_stationId(c),b['beneficiary_id'],paid,now,pm,cb,b['reference_number'],b['payment_notes'],'posted',c['userId']]);final method=db.select('SELECT ledger_account_code,type FROM payment_methods WHERE id=?',[pm]).first;final cashCode='${method['ledger_account_code']??'1000'}';_journal(description:'دفعة مرتبطة بالسقاية',referenceType:'payment',referenceId:db.lastInsertRowId,lines:[{'account_id':_accountId(cashCode),'debit':paid,'credit':0},{'account_id':rec,'beneficiary_id':b['beneficiary_id'],'debit':0,'credit':paid}],userId:c['userId']);}
return _json({'id':irrigationId,'minutes':mins,'chargeable_minutes':charge,'total_amount':total,'paid_amount':paid});}catch(e){return _json({'error':'تعذر تسجيل السقاية: $e'},status:422);} }
  Future<Response> _irrigationCreate(Request r,Map<String,dynamic> c) => _atomic(() => _irrigationCreateUnsafe(r,c));
  Future<Response> _irrigations(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT i.*,b.name beneficiary_name,p.name pump_name FROM irrigations i JOIN beneficiaries b ON b.id=i.beneficiary_id JOIN pumps p ON p.id=i.pump_id WHERE i.station_id=? AND b.station_id=? AND p.station_id=? AND i.status!=\'cancelled\' ORDER BY i.start_datetime DESC LIMIT 1000',[_stationId(c),_stationId(c),_stationId(c)])));
  Future<Response> _irrigationCancel(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);if('${b['reason']??''}'.trim().isEmpty)return _json({'error':'سبب الإلغاء مطلوب'},status:422);db.execute("UPDATE irrigations SET status='cancelled',override_reason=? WHERE id=? AND station_id=?",[b['reason'],id,_stationId(c)]);if((db.select('SELECT changes() affected').first['affected'] as num).toInt()==0)return _json({'error':'السقاية غير موجودة'},status:404);return _json({'ok':true});}

  Future<Response> _sessions(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT s.*,b.name beneficiary_name,p.name pump_name FROM irrigation_sessions s JOIN beneficiaries b ON b.id=s.beneficiary_id JOIN pumps p ON p.id=s.pump_id WHERE p.station_id=? AND b.station_id=? ORDER BY COALESCE(s.actual_start,s.planned_start) DESC',[_stationId(c),_stationId(c)])));
  Future<Response> _sessionStart(Request r,Map<String,dynamic> c) async {final b=await _body(r);final pump=(b['pump_id'] as num?)?.toInt()??1;final beneficiary=(b['beneficiary_id'] as num?)?.toInt();final station=_stationId(c);_requireOwn('pumps',pump,station,'المضخة');_requireOwn('beneficiaries',beneficiary,station,'المستفيد');final queueId=(b['queue_id'] as num?)?.toInt();if(queueId!=null&&db.select("SELECT q.id FROM queue_entries q JOIN beneficiaries x ON x.id=q.beneficiary_id WHERE q.id=? AND q.beneficiary_id=? AND x.station_id=? AND q.status IN ('waiting','postponed')",[queueId,beneficiary,station]).isEmpty)return _json({'error':'عنصر الطابور لا يتبع المستفيد أو المحطة الحالية'},status:404);final bookingId=(b['booking_id'] as num?)?.toInt();if(bookingId!=null&&db.select("SELECT br.id FROM booking_requests br JOIN beneficiaries x ON x.id=br.beneficiary_id WHERE br.id=? AND br.beneficiary_id=? AND x.station_id=? AND br.status IN ('new','under_review','scheduled')",[bookingId,beneficiary,station]).isEmpty)return _json({'error':'الحجز لا يتبع المستفيد أو المحطة الحالية'},status:404);final active=db.select("SELECT id FROM irrigation_sessions WHERE pump_id=? AND status='running'",[pump]);if(active.isNotEmpty)return _json({'error':'المضخة لديها جلسة فعالة'},status:409);final now=DateTime.now().toIso8601String();db.execute("INSERT INTO irrigation_sessions(beneficiary_id,queue_entry_id,booking_id,pump_id,planned_start,actual_start,timer_started_at,status) VALUES(?,?,?,?,?,?,?,\'running\')",[beneficiary,queueId,bookingId,pump,now,now,now]);return _json({'id':db.lastInsertRowId,'started_at':now});}
  Future<Response> _sessionFinishUnsafe(Request r,Map<String,dynamic> c) async {
    final id=int.parse(r.params['id']!); final rows=db.select('SELECT s.*,p.station_id,p.system_type FROM irrigation_sessions s JOIN pumps p ON p.id=s.pump_id JOIN beneficiaries b ON b.id=s.beneficiary_id WHERE s.id=? AND p.station_id=? AND b.station_id=?',[id,_stationId(c),_stationId(c)]);
    if(rows.isEmpty)return _json({'error':'الجلسة غير موجودة'},status:404); final s=rows.first; if(s['status']!='running')return _json({'error':'الجلسة ليست قيد التشغيل'},status:409);
    final end=DateTime.now(); final start=DateTime.parse(s['actual_start'] as String); final settings=_settingsForStation(_stationId(c));
    final mins=_minutes(start,end,settings['allow_midnight_crossing']=='true'); final cloud=(await _body(r))['cloud_minutes']; final cloudMin=(cloud as num?)?.round()??0; final charge=s['system_type']=='solar'?(mins-cloudMin).clamp(0,mins):mins;
    final rate=s['system_type']=='diesel'?(int.tryParse(settings['diesel_hourly_water_rate']??'0')??0):s['system_type']=='solar'?(int.tryParse(settings['solar_hourly_rate']??'0')??0):(int.tryParse(settings['third_type_hourly_rate']??'0')??0);
    final water=_round(charge/60*rate,settings['rounding']??'nearest'); final liters=s['system_type']=='diesel'?charge/60*(double.tryParse(settings['diesel_liters_per_hour']??'0')??0):0.0; final fuel=_round(liters*(int.tryParse(settings['diesel_price_per_liter']??'0')??0),settings['rounding']??'nearest'); final total=water+fuel;
    final now=end.toIso8601String(); db.execute('UPDATE irrigation_sessions SET actual_end=?,timer_stopped_at=?,status=\'completed\',diesel_consumed=? WHERE id=?',[now,now,liters,id]);
    db.execute('INSERT INTO irrigations(station_id,pump_id,beneficiary_id,booking_id,queue_entry_id,session_id,date,start_datetime,end_datetime,minutes,system_type,water_hourly_rate_snapshot,diesel_liters_per_hour_snapshot,diesel_price_snapshot,solar_hourly_rate_snapshot,third_type_hourly_rate_snapshot,cloud_minutes,chargeable_minutes,water_amount,diesel_amount,total_amount,paid_amount,status,created_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[s['station_id'],s['pump_id'],s['beneficiary_id'],s['booking_id'],s['queue_entry_id'],id,start.toIso8601String().substring(0,10),start.toIso8601String(),end.toIso8601String(),mins,s['system_type'],int.tryParse(settings['diesel_hourly_water_rate']??'0')??0,double.tryParse(settings['diesel_liters_per_hour']??'0')??0,int.tryParse(settings['diesel_price_per_liter']??'0')??0,int.tryParse(settings['solar_hourly_rate']??'0')??0,int.tryParse(settings['third_type_hourly_rate']??'0')??0,cloudMin,charge,water,fuel,total,0,'posted',c['userId'],now,now]);
    final irrigationId=db.lastInsertRowId; final rec=_accountId('1200'); final revenue=_accountId('4000'); _journal(description:'سقاية رقم $irrigationId',referenceType:'irrigation',referenceId:irrigationId,lines:[{'account_id':rec,'beneficiary_id':s['beneficiary_id'],'debit':total,'credit':0},{'account_id':revenue,'debit':0,'credit':total}],userId:c['userId']);
    if(s['queue_entry_id']!=null)db.execute("UPDATE queue_entries SET status='served',last_served_at=?,updated_at=? WHERE id=? AND EXISTS (SELECT 1 FROM beneficiaries b WHERE b.id=queue_entries.beneficiary_id AND b.station_id=?)",[now,now,s['queue_entry_id'],_stationId(c)]);
    if(s['booking_id']!=null)db.execute("UPDATE booking_requests SET status='completed',reviewed_at=? WHERE id=? AND EXISTS (SELECT 1 FROM beneficiaries b WHERE b.id=booking_requests.beneficiary_id AND b.station_id=?)",[now,s['booking_id'],_stationId(c)]);
    if(liters>0)db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?)',[_stationId(c),s['beneficiary_id'],irrigationId,'consumption',liters,int.tryParse(settings['diesel_price_per_liter']??'0')??0,fuel,now,'استهلاك جلسة السقي',c['userId']]);
    return _json({'id':irrigationId,'minutes':mins,'chargeable_minutes':charge,'total_amount':total});
  }
  Future<Response> _sessionFinish(Request r,Map<String,dynamic> c) => _atomic(() => _sessionFinishUnsafe(r,c));
  Future<Response> _sessionPostpone(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);if('${b['reason']??''}'.trim().isEmpty)return _json({'error':'سبب التأجيل مطلوب'},status:422);db.execute("UPDATE irrigation_sessions SET status='postponed',postponement_reason=? WHERE id=? AND EXISTS (SELECT 1 FROM pumps p JOIN beneficiaries x ON x.id=irrigation_sessions.beneficiary_id WHERE p.id=irrigation_sessions.pump_id AND p.station_id=? AND x.station_id=?)",[b['reason'],id,_stationId(c),_stationId(c)]);if((db.select('SELECT changes() affected').first['affected'] as num).toInt()==0)return _json({'error':'الجلسة غير موجودة'},status:404);return _json({'ok':true});}

  Future<Response> _queue(Request r,Map<String,dynamic> c) async => _json(_rows(db.select("SELECT q.*,b.name beneficiary_name,b.phone FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE b.station_id=? AND q.status IN ('waiting','postponed') ORDER BY q.position,q.cycle_number,q.created_at",[_stationId(c)])));
  Future<Response> _queueAdd(Request r,Map<String,dynamic> c) async {final b=await _body(r);final beneficiary=(b['beneficiary_id'] as num?)?.toInt();final station=_stationId(c);_requireOwn('beneficiaries',beneficiary,station,'المستفيد');final row=db.select("SELECT COALESCE(MAX(q.position),0)+1 n FROM queue_entries q JOIN beneficiaries x ON x.id=q.beneficiary_id WHERE x.station_id=? AND q.status IN ('waiting','postponed')",[station]).first;final pos=(row['n'] as num).toInt();db.execute("INSERT INTO queue_entries(beneficiary_id,position,status,created_at,updated_at) VALUES(?,?,\'waiting\',?,?)",[beneficiary,pos,DateTime.now().toIso8601String(),DateTime.now().toIso8601String()]);return _json({'id':db.lastInsertRowId,'position':pos});}
  Future<Response> _queuePostpone(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);if('${b['reason']??''}'.trim().isEmpty)return _json({'error':'سبب التأجيل مطلوب'},status:422);db.execute("UPDATE queue_entries SET status='postponed',postponed_count=postponed_count+1,skip_reason=?,updated_at=? WHERE id=? AND EXISTS (SELECT 1 FROM beneficiaries x WHERE x.id=queue_entries.beneficiary_id AND x.station_id=?)",[b['reason'],DateTime.now().toIso8601String(),id,_stationId(c)]);if((db.select('SELECT changes() affected').first['affected'] as num).toInt()==0)return _json({'error':'عنصر الطابور غير موجود'},status:404);return _json({'ok':true});}
  Future<Response> _queueSkip(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);if('${b['reason']??''}'.trim().isEmpty)return _json({'error':'سبب تجاوز الدور مطلوب'},status:422);db.execute("UPDATE queue_entries SET position=0,skip_reason=?,updated_at=? WHERE id=? AND EXISTS (SELECT 1 FROM beneficiaries x WHERE x.id=queue_entries.beneficiary_id AND x.station_id=?)",[b['reason'],DateTime.now().toIso8601String(),id,_stationId(c)]);if((db.select('SELECT changes() affected').first['affected'] as num).toInt()==0)return _json({'error':'عنصر الطابور غير موجود'},status:404);return _json({'ok':true});}
  Future<Response> _bookings(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT br.*,b.name beneficiary_name,b.phone FROM booking_requests br JOIN beneficiaries b ON b.id=br.beneficiary_id WHERE b.station_id=? ORDER BY br.created_at DESC',[_stationId(c)])));
  Future<Response> _bookingSchedule(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);if(b['start']==null||b['end']==null)return _json({'error':'يجب تحديد الموعد من الإدارة'},status:422);db.execute("UPDATE booking_requests SET status='scheduled',scheduled_date=?,scheduled_start=?,scheduled_end=?,reviewed_by=?,reviewed_at=? WHERE id=? AND EXISTS (SELECT 1 FROM beneficiaries x WHERE x.id=booking_requests.beneficiary_id AND x.station_id=?)",[b['date'],b['start'],b['end'],c['userId'],DateTime.now().toIso8601String(),id,_stationId(c)]);if((db.select('SELECT changes() affected').first['affected'] as num).toInt()==0)return _json({'error':'الحجز غير موجود'},status:404);return _json({'ok':true});}
  Future<Response> _bookingCancel(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);db.execute("UPDATE booking_requests SET status='cancelled',cancel_reason=?,reviewed_by=?,reviewed_at=? WHERE id=? AND EXISTS (SELECT 1 FROM beneficiaries x WHERE x.id=booking_requests.beneficiary_id AND x.station_id=?)",[b['reason'],c['userId'],DateTime.now().toIso8601String(),id,_stationId(c)]);if((db.select('SELECT changes() affected').first['affected'] as num).toInt()==0)return _json({'error':'الحجز غير موجود'},status:404);return _json({'ok':true});}

  Future<Response> _payments(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT p.*,COALESCE(b.name,COALESCE(w.name,pt.name)) party_name,pm.name method_name,c.name cashbox_name FROM payments p LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id LEFT JOIN workers w ON w.id=p.worker_id LEFT JOIN partners pt ON pt.id=p.partner_id JOIN payment_methods pm ON pm.id=p.payment_method_id JOIN cashboxes c ON c.id=p.cashbox_id WHERE p.station_id=? AND c.station_id=? AND pm.station_id=? AND (p.beneficiary_id IS NULL OR b.station_id=?) AND (p.worker_id IS NULL OR w.station_id=?) AND (p.partner_id IS NULL OR pt.station_id=?) ORDER BY p.date DESC',[_stationId(c),_stationId(c),_stationId(c),_stationId(c),_stationId(c),_stationId(c)])));
  Future<Response> _paymentCreateUnsafe(Request r,Map<String,dynamic> c) async {final b=await _body(r);final station=_stationId(c);_requireOwn('cashboxes',(b['cashbox_id'] as num?)?.toInt()??1,station,'الصندوق');_requireOwn('payment_methods',(b['payment_method_id'] as num?)?.toInt()??1,station,'طريقة الدفع');if(b['beneficiary_id']!=null)_requireOwn('beneficiaries',(b['beneficiary_id'] as num).toInt(),station,'المستفيد');if(b['worker_id']!=null)_requireOwn('workers',(b['worker_id'] as num).toInt(),station,'العامل');if(b['partner_id']!=null)_requireOwn('partners',(b['partner_id'] as num).toInt(),station,'الشريك');final amount=(b['amount'] as num?)?.round()??0;if(amount<=0)return _json({'error':'المبلغ يجب أن يكون أكبر من صفر'},status:422);final now=DateTime.now().toIso8601String();db.execute('INSERT INTO payments(station_id,beneficiary_id,partner_id,worker_id,amount,date,payment_method_id,cashbox_id,reference_number,notes,status,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',[station,b['beneficiary_id'],b['partner_id'],b['worker_id'],amount,now,b['payment_method_id']??1,b['cashbox_id']??1,b['reference_number'],b['notes'],'posted',c['userId']]); final paymentId=db.lastInsertRowId; db.execute('UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',[amount,b['cashbox_id']??1]);
    final party=(b['beneficiary_id']!=null)?'1200':(b['partner_id']!=null)?'2200':'2100';
    final method=db.select('SELECT ledger_account_code,type FROM payment_methods WHERE id=? LIMIT 1',[b['payment_method_id']??1]).first;
    final code='${method['ledger_account_code']??((method['type']=='bank_transfer')?'1100':(method['type']=='wallet')?'1120':'1000')}';
    _journal(description:'تسجيل دفعة',referenceType:'payment',referenceId:paymentId,lines:[{'account_id':_accountId(code),'beneficiary_id':b['beneficiary_id'],'worker_id':b['worker_id'],'partner_id':b['partner_id'],'debit':amount,'credit':0},{'account_id':_accountId(party),'beneficiary_id':b['beneficiary_id'],'worker_id':b['worker_id'],'partner_id':b['partner_id'],'debit':0,'credit':amount}],userId:c['userId']);
    return _json({'id':paymentId});}
  Future<Response> _paymentCreate(Request r,Map<String,dynamic> c) => _atomic(() => _paymentCreateUnsafe(r,c));
  Future<Response> _cashboxes(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT * FROM cashboxes WHERE active=1 AND station_id=?',[_stationId(c)])));
  Future<Response> _cashboxTransferUnsafe(Request r,Map<String,dynamic> c) async {final b=await _body(r);final from=(b['from_cashbox_id'] as num?)?.toInt();final to=(b['to_cashbox_id'] as num?)?.toInt();final amount=(b['amount'] as num?)?.round()??0;final station=_stationId(c);if(to==null||amount<=0)return _json({'error':'بيانات التحويل غير صحيحة'},status:422);_requireOwn('cashboxes',to,station,'الصندوق الهدف');if(from!=null)_requireOwn('cashboxes',from,station,'الصندوق المصدر');if(from!=null){db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=? AND station_id=?',[amount,from,station]);}db.execute('UPDATE cashboxes SET current_balance=current_balance+? WHERE id=? AND station_id=?',[amount,to,station]);db.execute('INSERT INTO cashbox_transfers(station_id,from_cashbox_id,to_cashbox_id,amount,date,is_opening_transfer,reference,created_by) VALUES(?,?,?,?,?,?,?,?)',[station,from,to,amount,DateTime.now().toIso8601String(),from==null?1:0,b['reference'],c['userId']]);final transferId=db.lastInsertRowId;_journal(description:'تحويل بين الصناديق',referenceType:'cashbox_transfer',referenceId:transferId,lines:[{'account_id':_accountId('1100'),'debit':amount,'credit':0},{'account_id':_accountId('1000'),'debit':0,'credit':amount}],userId:c['userId']);return _json({'id':transferId});}
  Future<Response> _cashboxTransfer(Request r,Map<String,dynamic> c) => _atomic(() => _cashboxTransferUnsafe(r,c));
  Future<Response> _diesel(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT dm.*,b.name beneficiary_name FROM diesel_movements dm LEFT JOIN beneficiaries b ON b.id=dm.beneficiary_id WHERE dm.station_id=? ORDER BY dm.date DESC LIMIT 1000',[_stationId(c)])));
  Future<Response> _dieselMovementUnsafe(Request r,Map<String,dynamic> c) async {final b=await _body(r);final station=_stationId(c);if(b['beneficiary_id']!=null)_requireOwn('beneficiaries',(b['beneficiary_id'] as num).toInt(),station,'المستفيد');if(b['cashbox_id']!=null)_requireOwn('cashboxes',(b['cashbox_id'] as num).toInt(),station,'الصندوق');if(b['irrigation_id']!=null)_requireOwn('irrigations',(b['irrigation_id'] as num).toInt(),station,'السقاية');final liters=(b['liters'] as num?)?.toDouble()??0;if(liters<=0)throw StateError('كمية الديزل يجب أن تكون أكبر من صفر');final kind='${b['kind']??'receipt'}';final price=(b['unit_price'] as num?)?.round()??0;final amount=(liters*price).round();final stock=(db.select("SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements dm WHERE dm.station_id=?",[_stationId(c)]).first['stock'] as num).toDouble();if((kind=='delivery'||kind=='consumption')&&liters>stock)throw StateError('كمية الديزل المطلوبة أكبر من المخزون المتاح');final cb=(b['cashbox_id'] as num?)?.toInt();if(kind=='receipt'&&cb!=null){final bal=(db.select('SELECT current_balance FROM cashboxes WHERE id=?',[cb]).first['current_balance'] as num).round();db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',[amount,cb]);}final now=DateTime.now().toIso8601String();db.execute('INSERT INTO diesel_movements(station_id,beneficiary_id,irrigation_id,cashbox_id,kind,liters,unit_price,amount,date,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?)',[station,b['beneficiary_id'],b['irrigation_id'],cb,kind,liters,price,amount,now,b['notes'],c['userId']]);final movementId=db.lastInsertRowId;if(kind=='receipt'){_journal(description:'شراء ديزل',referenceType:'diesel_receipt',referenceId:movementId,lines:[{'account_id':_accountId('1300'),'debit':amount,'credit':0},{'account_id':_accountId('1000'),'debit':0,'credit':amount}],userId:c['userId']);}else if(kind=='consumption'){_journal(description:'استهلاك ديزل',referenceType:'diesel_consumption',referenceId:movementId,lines:[{'account_id':_accountId('5010'),'debit':amount,'credit':0},{'account_id':_accountId('1300'),'debit':0,'credit':amount}],userId:c['userId']);}else if(kind=='advance'&&b['beneficiary_id']!=null){_journal(description:'سلفة ديزل',referenceType:'diesel_advance',referenceId:movementId,lines:[{'account_id':_accountId('1200'),'beneficiary_id':b['beneficiary_id'],'debit':amount,'credit':0},{'account_id':_accountId('1000'),'debit':0,'credit':amount}],userId:c['userId']);}else if(kind=='delivery'&&b['beneficiary_id']!=null){final financial=_settingsForStation(station)['diesel_delivery_financial_credit'];if(financial=='true')_journal(description:'تسليم ديزل',referenceType:'diesel_delivery',referenceId:movementId,lines:[{'account_id':_accountId('1200'),'beneficiary_id':b['beneficiary_id'],'debit':amount,'credit':0},{'account_id':_accountId('4010'),'debit':0,'credit':amount}],userId:c['userId']);}return _json({'id':movementId,'amount':amount,'stock_after':kind=='receipt'?stock+liters:(kind=='delivery'||kind=='consumption')?stock-liters:stock});}
  Future<Response> _dieselMovement(Request r,Map<String,dynamic> c) => _atomic(() => _dieselMovementUnsafe(r,c));
  Future<Response> _expenses(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT e.* FROM expenses e JOIN payment_methods pm ON pm.id=e.payment_method_id LEFT JOIN cashboxes cb ON cb.id=e.cashbox_id WHERE e.station_id=? AND pm.station_id=? AND (e.cashbox_id IS NULL OR cb.station_id=?) ORDER BY e.date DESC LIMIT 1000',[_stationId(c),_stationId(c),_stationId(c)])));
  Future<Response> _expenseCreateUnsafe(Request r,Map<String,dynamic> c) async {final b=await _body(r);final station=_stationId(c);final methodId=(b['payment_method_id'] as num?)?.toInt()??1;_requireOwn('payment_methods',methodId,station,'طريقة الدفع');final cash=(b['cashbox_id'] as num?)?.toInt();if(cash!=null)_requireOwn('cashboxes',cash,station,'الصندوق');if(b['beneficiary_id']!=null)_requireOwn('beneficiaries',(b['beneficiary_id'] as num).toInt(),station,'المستفيد');if(b['worker_id']!=null)_requireOwn('workers',(b['worker_id'] as num).toInt(),station,'العامل');if(b['partner_id']!=null)_requireOwn('partners',(b['partner_id'] as num).toInt(),station,'الشريك');final amount=(b['amount'] as num?)?.round()??0;if(amount<=0)return _json({'error':'قيمة المصروف يجب أن تكون أكبر من صفر'},status:422);if(cash!=null){final bal=(db.select('SELECT current_balance FROM cashboxes WHERE id=?',[cash]).first['current_balance'] as num).round();db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',[amount,cash]);}db.execute('INSERT INTO expenses(station_id,category,title,amount,date,payment_method_id,cashbox_id,status,created_by,notes) VALUES(?,?,?,?,?,?,?,\'posted\',?,?)',[station,b['category']??'other',b['title']??'مصروف',amount,DateTime.now().toIso8601String(),methodId,cash,c['userId'],b['notes']]); final expenseId=db.lastInsertRowId;
    final expenseCode=switch('${b['category']??'other'}'){ 'fuel'=>'5010','oil'=>'5020','grease'=>'5020','maintenance'=>'5030','parts'=>'5030', 'workers'=>'5000','partners'=>'5000', _=>'5030'};
    final pm=db.select('SELECT ledger_account_code,type FROM payment_methods WHERE id=? LIMIT 1',[methodId]).first; final payCode='${pm['ledger_account_code']??'1000'}';
    _journal(description:'${b['title']??'مصروف'}',referenceType:'expense',referenceId:expenseId,lines:[{'account_id':_accountId(expenseCode),'beneficiary_id':b['beneficiary_id'],'worker_id':b['worker_id'],'partner_id':b['partner_id'],'debit':amount,'credit':0},{'account_id':_accountId(payCode),'beneficiary_id':b['beneficiary_id'],'worker_id':b['worker_id'],'partner_id':b['partner_id'],'debit':0,'credit':amount}],userId:c['userId']);
    return _json({'id':expenseId});}
  Future<Response> _expenseCreate(Request r,Map<String,dynamic> c) => _atomic(() => _expenseCreateUnsafe(r,c));
  Future<Response> _workers(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT * FROM workers WHERE active=1 AND station_id=? ORDER BY name',[_stationId(c)])));
  Future<Response> _workerCreate(Request r,Map<String,dynamic> c) async {final b=await _body(r);final name='${b['name']??''}'.trim();if(name.isEmpty)return _json({'error':'اسم العامل مطلوب'},status:422);db.execute('INSERT INTO workers(station_id,name,phone,job_title,pay_type,fixed_salary,hourly_rate,percentage_rate,active) VALUES(?,?,?,?,?,?,?,?,1)',[_stationId(c),name,b['phone'],b['job_title'],b['pay_type']??'hourly',b['fixed_salary']??0,b['hourly_rate']??0,b['percentage_rate']??0]);_audit(c['userId'] as int,'create','workers',db.lastInsertRowId);return _json({'id':db.lastInsertRowId});}
  Future<Response> _workerTransactionUnsafe(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);_requireOwn('workers',id,_stationId(c),'العامل');final b=await _body(r);final type='${b['type']??'accrual'}';final amount=(b['amount'] as num?)?.round()??0;if(!const{'accrual','salary','payment'}.contains(type))throw StateError('نوع الحركة غير مدعوم');if(amount<=0)throw StateError('المبلغ يجب أن يكون أكبر من صفر');final now=DateTime.now().toIso8601String();db.execute('INSERT INTO worker_transactions(station_id,worker_id,date,type,hours,rate_snapshot,percentage_snapshot,amount,cashbox_id,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?)',[_stationId(c),id,now,type,b['hours']??0,b['rate_snapshot']??0,b['percentage_snapshot']??0,b['amount'],b['cashbox_id'],b['notes'],c['userId']]);final txId=db.lastInsertRowId;if(type=='payment'){final cb=(b['cashbox_id'] as num?)?.toInt()??1;_requireOwn('cashboxes',cb,_stationId(c),'الصندوق');final bal=(db.select('SELECT current_balance FROM cashboxes WHERE id=?',[cb]).first['current_balance'] as num).round();/* الصندوق حساب للصراف ويُسمح بأن يصبح رصيده سالبًا؛ لا نمنع الصرف بسبب الرصيد. */db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',[amount,cb]);_journal(description:'دفع عامل',referenceType:'worker_payment',referenceId:txId,lines:[{'account_id':_accountId('2100'),'worker_id':id,'debit':amount,'credit':0},{'account_id':_accountId('1000'),'debit':0,'credit':amount}],userId:c['userId']);}else{_journal(description:'استحقاق عامل',referenceType:'worker',referenceId:txId,lines:[{'account_id':_accountId('5000'),'worker_id':id,'debit':amount,'credit':0},{'account_id':_accountId('2100'),'worker_id':id,'debit':0,'credit':amount}],userId:c['userId']);}return _json({'id':txId});}
  Future<Response> _workerTransaction(Request r,Map<String,dynamic> c) => _atomic(() => _workerTransactionUnsafe(r,c));
  Future<Response> _partners(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT * FROM partners WHERE active=1 AND station_id=? ORDER BY name',[_stationId(c)])));
  Future<Response> _partnerCreate(Request r,Map<String,dynamic> c) async {final b=await _body(r);final name='${b['name']??''}'.trim();if(name.isEmpty)return _json({'error':'اسم الشريك مطلوب'},status:422);db.execute('INSERT INTO partners(station_id,name,phone,ownership_mode,shares_count,ownership_percentage,active) VALUES(?,?,?,?,?,?,1)',[_stationId(c),name,b['phone'],b['ownership_mode']??'percentage',b['shares_count'],b['ownership_percentage']??0]);_audit(c['userId'] as int,'create','partners',db.lastInsertRowId);return _json({'id':db.lastInsertRowId});}
  Future<Response> _partnerTransactionUnsafe(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);_requireOwn('partners',id,_stationId(c),'الشريك');final b=await _body(r);final type='${b['type']??'share_accrual'}';final amount=(b['amount'] as num?)?.round()??0;if(!const{'share_accrual','payment'}.contains(type))throw StateError('نوع الحركة غير مدعوم');if(amount<=0)throw StateError('المبلغ يجب أن يكون أكبر من صفر');final now=DateTime.now().toIso8601String();db.execute('INSERT INTO partner_transactions(station_id,partner_id,date,type,amount,ownership_snapshot,notes,created_by) VALUES(?,?,?,?,?,?,?,?)',[_stationId(c),id,now,type,amount,b['ownership_snapshot'],b['notes'],c['userId']]);final txId=db.lastInsertRowId;if(type=='payment'){final cb=(b['cashbox_id'] as num?)?.toInt()??1;_requireOwn('cashboxes',cb,_stationId(c),'الصندوق');final bal=(db.select('SELECT current_balance FROM cashboxes WHERE id=?',[cb]).first['current_balance'] as num).round();/* الصندوق حساب للصراف ويُسمح بأن يصبح رصيده سالبًا؛ لا نمنع الصرف بسبب الرصيد. */db.execute('UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',[amount,cb]);_journal(description:'دفع شريك',referenceType:'partner_payment',referenceId:txId,lines:[{'account_id':_accountId('2200'),'partner_id':id,'debit':amount,'credit':0},{'account_id':_accountId('1000'),'debit':0,'credit':amount}],userId:c['userId']);}else{_journal(description:'حصة شريك',referenceType:'partner',referenceId:txId,lines:[{'account_id':_accountId('5000'),'partner_id':id,'debit':amount,'credit':0},{'account_id':_accountId('2200'),'partner_id':id,'debit':0,'credit':amount}],userId:c['userId']);}return _json({'id':txId});}
  Future<Response> _partnerTransaction(Request r,Map<String,dynamic> c) => _atomic(() => _partnerTransactionUnsafe(r,c));
  Future<Response> _journalReport(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT je.*,jl.account_id,jl.debit,jl.credit,a.code account_code,a.name account_name FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? ORDER BY je.date DESC LIMIT 1000',[_stationId(c)])));
  Future<Response> _ledger(Request r,Map<String,dynamic> c) async {final code=r.url.queryParameters['account']??'1200';return _json(_rows(db.select('SELECT jl.*,je.date,je.description,a.code,a.name account_name FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE a.code=? AND je.station_id=? ORDER BY je.date,jl.id',[code,_stationId(c)])));}
  Future<Response> _reports(Request r, Map<String, dynamic> c) async {
    final name = r.params['name']!;
    const supported = {
      'cash_flow',
      'income',
      'system_comparison',
      'journal',
      'ledger',
    };
    const known = {
      'cash_flow', 'time_comparison', 'monthly_financial', 'income',
      'payment_methods', 'expenses', 'cashboxes', 'queue_bookings',
      'payment_log', 'beneficiary_statement', 'beneficiary_detailed',
      'beneficiary_stats', 'needy', 'diesel_inventory', 'activity_overview',
      'oil_status', 'debts', 'beneficiary_list', 'revenue_comparison',
      'system_comparison', 'journal', 'ledger', 'worker_transactions',
      'partner_accounts',
    };
    if (!known.contains(name)) {
      return _json({'error': 'التقرير غير معروف'}, status: 404);
    }
    if (!supported.contains(name)) {
      return _json({
        'error': 'التقرير معروف لكنه غير منفذ في واجهة الخادم بعد',
        'report': name,
        'code': 'REPORT_NOT_IMPLEMENTED',
      }, status: 501);
    }
    return _json({'report': name, 'rows': _reportRows(name, _stationId(c))});
  }

  List<Map<String, Object?>> _reportRows(String name, int station) {
    switch (name) {
      case 'cash_flow':
        return _rows(db.select(
          "SELECT date,'payment' kind,amount,'قبض' title FROM payments WHERE status='posted' AND station_id=? "
          "UNION ALL SELECT date,'expense' kind,-amount,title FROM expenses WHERE status='posted' AND station_id=? ORDER BY date DESC",
          [station, station],
        ));
      case 'income':
        return _rows(db.select(
          "SELECT system_type,COUNT(*) operations,SUM(water_amount) water_income,SUM(diesel_amount) diesel_income,SUM(total_amount) total "
          "FROM irrigations WHERE status!='cancelled' AND station_id=? GROUP BY system_type",
          [station],
        ));
      case 'system_comparison':
        return _rows(db.select(
          "SELECT system_type,COUNT(*) operations,SUM(minutes) minutes,SUM(total_amount) total,SUM(diesel_amount) diesel_cost "
          "FROM irrigations WHERE status!='cancelled' AND station_id=? GROUP BY system_type",
          [station],
        ));
      case 'journal':
        return _rows(db.select(
          'SELECT * FROM journal_entries WHERE station_id=? ORDER BY date DESC',
          [station],
        ));
      case 'ledger':
        return _rows(db.select(
          'SELECT jl.* FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id WHERE je.station_id=? ORDER BY jl.id DESC',
          [station],
        ));
      default:
        throw StateError('Unsupported report reached the query layer: $name');
    }
  }
  // Full-file SQLite backups/restores are unsafe for a shared multi-station database.
  // Keep these endpoints explicitly blocked until station-scoped export/import exists.
  Future<Response> _backup(Request r,Map<String,dynamic> c) async =>
      _json({'error':'النسخ الاحتياطي الكامل معطل مؤقتاً؛ يلزم دعم نسخة مستقلة لكل محطة.'}, status:409);

  Future<Response> _restore(Request r,Map<String,dynamic> c) async =>
      _json({'error':'استعادة ملف قاعدة البيانات الكامل معطلة مؤقتاً؛ يلزم التحقق من ملكية المحطة قبل الاستعادة.'}, status:409);

  Future<Response> _beneficiaryRequestCode(Request r) async {
    final body = await _body(r);
    final phone = '${body['phone'] ?? ''}'.trim();
    if (phone.isEmpty) return _json({'error': 'رقم الهاتف مطلوب'}, status: 400);
    final scopes = ['beneficiary-otp-ip:${_loginIp(r)}', 'beneficiary-otp-phone:${_loginIp(r)}:$phone'];
    final now = DateTime.now().toUtc();
    if (_loginIsBlocked(scopes, now)) {
      return Response(429, body: jsonEncode({'error': 'طلبات الرموز كثيرة؛ حاول بعد 15 دقيقة'}),
        headers: {'content-type': 'application/json; charset=utf-8', 'retry-after': '900'});
    }
    _recordFailedLogin(scopes, now);
    final rows = db.select("SELECT id FROM beneficiaries WHERE phone=? AND status='active' ORDER BY id", [phone]);
    if (rows.isEmpty) return _json({'error': 'رقم الهاتف غير مسجل'}, status: 404);
    if (rows.length != 1) {
      return _json({'error': 'رقم الهاتف مرتبط بأكثر من حساب؛ يلزم رقم فريد لكل مستفيد'}, status: 409);
    }
    final id = rows.first['id'] as int;
    final code = (100000 + Random.secure().nextInt(900000)).toString();
    final createdAt = now.toIso8601String();
    db.execute('INSERT INTO beneficiary_auth_codes(beneficiary_id,code_hash,expires_at,created_at) VALUES(?,?,?,?)',
      [id, _hash(code), now.add(const Duration(minutes: 10)).toIso8601String(), createdAt]);
    final out = <String, Object?>{'ok': true, 'message': 'تم إنشاء رمز آمن صالح لمدة 10 دقائق'};
    if (Platform.environment['SAQIA_DEV_OTP'] == 'true') out['dev_code'] = code;
    return _json(out);
  }
  Future<Response> _beneficiaryLogin(Request r) async {final b=await _body(r);final phone='${b['phone']??''}'.trim();final code='${b['code']??''}';final rows=db.select("SELECT id FROM beneficiaries WHERE phone=? AND status='active' ORDER BY id",[phone]);if(rows.isEmpty)return _json({'error':'رقم الهاتف غير مسجل'},status:401);if(rows.length!=1)return _json({'error':'رقم الهاتف مرتبط بأكثر من حساب؛ يلزم رقم فريد لكل مستفيد'},status:409);final id=rows.first['id'] as int;final expected=db.select('SELECT id,code_hash,attempts FROM beneficiary_auth_codes WHERE beneficiary_id=? AND used_at IS NULL AND expires_at>? ORDER BY id DESC LIMIT 1',[id,DateTime.now().toIso8601String()]);if(expected.isEmpty)return _json({'error':'الرمز غير صحيح أو منتهي'},status:401);
    final attempts=(expected.first['attempts'] as int?)??0; if(attempts>=5)return _json({'error':'تم تجاوز عدد محاولات الرمز'},status:429);
    if(expected.first['code_hash']!=_hash(code)){db.execute('UPDATE beneficiary_auth_codes SET attempts=attempts+1 WHERE id=?',[expected.first['id']]);return _json({'error':'الرمز غير صحيح أو منتهي'},status:401);}db.execute('UPDATE beneficiary_auth_codes SET used_at=? WHERE id=?',[DateTime.now().toIso8601String(),expected.first['id']]);final session=const Uuid().v4();db.execute('INSERT INTO beneficiary_sessions(beneficiary_id,token_hash,expires_at,created_at) VALUES(?,?,?,?)',[id,_hash(session),DateTime.now().add(const Duration(hours:12)).toIso8601String(),DateTime.now().toIso8601String()]);return _json({'token':_token({'kind':'beneficiary','beneficiaryId':id,'session':_hash(session)})});}
  int _bid(Map<String,dynamic> c)=>c['beneficiaryId'] as int;
  Future<Response> _beneficiaryMe(Request r,Map<String,dynamic> c) async {final rows=db.select('SELECT id,name,phone,address,location,jerba_number,area FROM beneficiaries WHERE id=?',[_bid(c)]);return rows.isEmpty?_json({'error':'المستفيد غير موجود'},status:404):_json(_rows(rows).first);}
  Future<Response> _beneficiaryRequests(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT * FROM booking_requests WHERE beneficiary_id=? ORDER BY created_at DESC',[_bid(c)])));
  Future<Response> _beneficiaryRequestCreate(Request r,Map<String,dynamic> c) async {final b=await _body(r);final now=DateTime.now().toIso8601String();db.execute("INSERT INTO booking_requests(beneficiary_id,created_at,status,notes) VALUES(?,?,\'new\',?)",[_bid(c),now,b['notes']]);return _json({'id':db.lastInsertRowId});}
  Future<Response> _beneficiaryRequestCancel(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);final b=await _body(r);db.execute("UPDATE booking_requests SET status='cancelled',cancel_reason=? WHERE id=? AND beneficiary_id=? AND status IN ('new','under_review')",['${b['reason']??''}',id,_bid(c)]);return _json({'ok':true});}
  Future<Response> _beneficiaryAccount(Request r,Map<String,dynamic> c) async {
    final id=_bid(c);
    final beneficiaryRows=db.select('SELECT station_id FROM beneficiaries WHERE id=?',[_bid(c)]);
    if(beneficiaryRows.isEmpty)return _json({'error':'المستفيد غير موجود'},status:404);
    final station=(beneficiaryRows.first['station_id'] as num).toInt();
    final settings=_settingsForStation(station);
    final includeDiesel=settings['diesel_delivery_financial_credit']=='true';
    final x=_rows(db.select('''SELECT b.opening_balance,b.carried_balance,
      COALESCE((SELECT SUM(total_amount) FROM irrigations WHERE beneficiary_id=b.id AND station_id=? AND status!='cancelled'),0) due,
      COALESCE((SELECT SUM(amount) FROM diesel_movements WHERE beneficiary_id=b.id AND station_id=? AND kind='advance' AND irrigation_id IS NULL),0) advances,
      COALESCE((SELECT SUM(amount) FROM payments WHERE beneficiary_id=b.id AND station_id=? AND status='posted'),0) paid,
      COALESCE((SELECT SUM(amount) FROM diesel_movements WHERE beneficiary_id=b.id AND station_id=? AND kind='delivery'),0) diesel_credit
      FROM beneficiaries b WHERE b.id=? AND b.station_id=?''',[station,station,station,station,id,station])).first;
    final balance=(x['opening_balance'] as num)+(x['carried_balance'] as num)+(x['due'] as num)+(x['advances'] as num)-(x['paid'] as num)-(includeDiesel?(x['diesel_credit'] as num):0);
    return _json({...x,'balance':balance,'label':balance>0?'عليه $balance ريال':balance<0?'له ${-balance} ريال':'متوازن'});
  }
  Future<Response> _beneficiaryNotifications(Request r,Map<String,dynamic> c) async => _json(_rows(db.select('SELECT * FROM notifications WHERE beneficiary_id=? ORDER BY created_at DESC',[_bid(c)])));
  Future<Response> _beneficiaryNotificationRead(Request r,Map<String,dynamic> c) async {final id=int.parse(r.params['id']!);db.execute('UPDATE notifications SET read_at=? WHERE id=? AND beneficiary_id=?',[DateTime.now().toIso8601String(),id,_bid(c)]);return _json({'ok':true});}
}
