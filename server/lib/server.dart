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

  void _journal({required String description, required String referenceType, int? referenceId, required List<Map<String,Object?>> lines, int? userId}) {
    final debit=lines.fold<int>(0,(s,x)=>s+((x['debit'] as num?)?.round()??0));
    final credit=lines.fold<int>(0,(s,x)=>s+((x['credit'] as num?)?.round()??0));
    if(debit<=0 || debit!=credit) throw StateError('القيد غير متوازن');
    final stationId = _stationForUser(userId);
    final now=DateTime.now().toIso8601String();
    db.execute('INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)',[stationId,now,referenceType,referenceId,description,'posted',userId,now]);
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
        final validUuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}
).hasMatch(eventId);
        if (!validUuid || entityType.isEmpty || entityType.length > 64 ||
            entityKey.isEmpty || entityKey.length > 160 ||
            !const {'create','update','delete'}.contains(operation) ||
            payload is! Map || baseVersion == null || baseVersion < 0 ||
            utf8.encode(jsonEncode(payload)).length > 262144) {
          results.add({'event_id':eventId,'status':'rejected','message':'حقول الحدث غير صالحة'});
          continue;
        }
        final duplicate = db.select(
          'SELECT server_sequence,status,server_version FROM sync_event_log WHERE station_id=? AND event_id=? LIMIT 1',
          [station,eventId],
        );
        if (duplicate.isNotEmpty) {
          results.add({'event_id':eventId,'status':duplicate.first['status']=='conflict'?'conflict':'duplicate',
            'server_sequence':duplicate.first['server_sequence'],
            'server_version':duplicate.first['server_version'],
            'current_version':duplicate.first['server_version'],
            'message':duplicate.first['status']=='conflict'?'الحدث مسجل كتعارض سابق':'الحدث مسجل مسبقاً'});
          continue;
        }
        final currentRows = db.select(
          'SELECT version FROM sync_entity_versions WHERE station_id=? AND entity_type=? AND entity_key=? LIMIT 1',
          [station,entityType,entityKey],
        );
        final currentVersion = currentRows.isEmpty ? 0 : (currentRows.first['version'] as num).toInt();
        final conflict = baseVersion != currentVersion;
        final nextVersion = conflict ? currentVersion : currentVersion + 1;
        db.execute('''INSERT INTO sync_event_log
          (station_id,event_id,source_device,entity_type,entity_key,operation,payload_json,base_version,server_version,status,created_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?)''',[
          station,eventId,device,entityType,entityKey,operation,
          jsonEncode(payload),baseVersion,nextVersion,conflict?'conflict':'accepted',now
        ]);
        if (!conflict) {
          db.execute('''INSERT INTO sync_entity_versions(station_id,entity_type,entity_key,version,updated_at)
            VALUES(?,?,?,?,?) ON CONFLICT(station_id,entity_type,entity_key)
            DO UPDATE SET version=excluded.version,updated_at=excluded.updated_at''',
            [station,entityType,entityKey,nextVersion,now]);
        }
        results.add({
          'event_id':eventId,
          'status':conflict?'conflict':'accepted',
          'server_version':nextVersion,
          'current_version':currentVersion,
          if(conflict) 'message':'تعارض إصدار؛ لم يتم اعتماد الحدث تلقائياً',
        });
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
  Future<Response> _beneficiaries(Request r,Map<String,dynamic> c) async => _json(_rows(db.select("SELECT * FROM beneficiaries WHERE status='active' AND station_id=? ORDER BY name",[_stationId(c)])));
  Future<Response> _beneficiaryCreate(Request r,Map<String,dynamic> c) async { final b=await _body(r); if('${b['name']??''}'.trim().isEmpty)return _json({'error':'اسم المستفيد مطلوب'},status:422); final now=DateTime.now().toIso8601String(); final id=db.lastInsertRowId; db.execute('INSERT INTO beneficiaries(station_id,name,phone,address,location,jerba_number,area,is_needy,opening_balance,carried_balance,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,\'active\',?,?)',[_stationId(c),b['name'],b['phone'],b['address'],b['location'],b['jerba_number'],b['area'],b['is_needy']==true?1:0,(b['opening_balance'] as num?)?.round()??0,(b['carried_balance'] as num?)?.round()??0,now,now]); return _json({'id':db.lastInsertRowId}); }
  Future<Response> _beneficiary(Request r,Map<String,dynamic> c) async { final id=int.parse(r.params['id']!); final rows=db.select('SELECT * FROM beneficiaries WHERE id=? AND station_id=?',[id,_stationId(c)]); return rows.isEmpty?_json({'error':'المستفيد غير موجود'},status:404):_json(_rows(rows).first); }
  Future<Response> _beneficiaryUpdate(Request r,Map<String,dynamic> c) async { final id=int.parse(r.params['id']!); final b=await _body(r); const allowed=['name','phone','address','location','jerba_number','area','is_needy','notes']; final sets=<String>[];final args=<Object?>[];for(final k in allowed){if(b.containsKey(k)){sets.add('$k=?');args.add(b[k] is bool?(b[k]?1:0):b[k]);}}if(sets.isEmpty)return _json({'error':'لا توجد حقول قابلة للتعديل'},status:422);args.add(DateTime.now().toIso8601String());args.add(id);args.add(_stationId(c)); db.execute('UPDATE beneficiaries SET ${sets.join(',')},updated_at=? WHERE id=? AND station_id=?',args);return _beneficiary(r,c); }
  Future<Response> _beneficiaryDelete(Request r,Map<String,dynamic> c) async { final id=int.parse(r.params['id']!); final b=await _body(r); if('${b['reason']??''}'.trim().isEmpty)return _json({'error':'سبب الحذف المنطقي مطلوب'},status:422); db.execute("UPDATE beneficiaries SET status='deleted',updated_at=? WHERE id=? AND station_id=?",[DateTime.now().toIso8601String(),id,_stationId(c)]); return _json({'ok':true}); }
  Future<Response> _beneficiaryStatement(Request r,Map<String,dynamic> c) async { final id=int.parse(r.params['id']!); final station=_stationId(c); if(!_owns('beneficiaries',id,station)) return _json({'error':'المستفيد غير موجود'},status:404); return _json(_rows(db.select('SELECT * FROM irrigations WHERE beneficiary_id=? AND station_id=? AND status!=\'cancelled\' ORDER BY start_datetime DESC',[id,station]))); }

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
