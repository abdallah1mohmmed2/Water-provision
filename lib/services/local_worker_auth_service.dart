import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../core/app_clock.dart';
import '../data/local/database.dart';
import 'local_beneficiary_auth_service.dart';

abstract interface class WorkerSessionStorage {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

class _SecureWorkerSessionStorage implements WorkerSessionStorage {
  _SecureWorkerSessionStorage(this.storage);
  final FlutterSecureStorage storage;

  @override
  Future<String?> read() => storage.read(key: 'local_worker_session_token_v1');
  @override
  Future<void> write(String token) => storage.write(key: 'local_worker_session_token_v1', value: token);
  @override
  Future<void> delete() => storage.delete(key: 'local_worker_session_token_v1');
}

/// Local worker authentication. It deliberately uses tables and secure-storage
/// keys separate from beneficiary and partner sessions.
class LocalWorkerAuthService {
  LocalWorkerAuthService({
    AppDatabase? database,
    FlutterSecureStorage? secureStorage,
    WorkerSessionStorage? sessionStorage,
    this.stationId = 1,
  }) : db = database ?? AppDatabase.instance,
       _storage = sessionStorage ?? _SecureWorkerSessionStorage(
         secureStorage ?? const FlutterSecureStorage(),
       );

  final AppDatabase db;
  final WorkerSessionStorage _storage;
  final int stationId;

  static const _sessionDuration = Duration(days: 30);
  static const _uuid = Uuid();

  /// These are capability keys, not application roles. Unknown keys are rejected.
  static const allowedPermissions = <String>{
    'view_dashboard',
    'view_irrigations',
    'view_account',
    'view_payments',
    'view_reports',
    'view_assignments',
    'view_profile',
    'edit_profile',
    'view_complaints',
    'submit_complaints',
  };

  String _normalize(String value) => value.trim().toLowerCase();

  void _validateUsername(String value) {
    if (!RegExp(r'^[a-zA-Z0-9._-]{3,40}$').hasMatch(value.trim())) {
      throw ArgumentError('اسم المستخدم يجب أن يكون من 3 إلى 40 حرفًا أو رقمًا');
    }
  }

  void _validatePassword(String value) {
    if (value.length < 10 || value.length > 128) {
      throw ArgumentError('كلمة المرور يجب أن تكون بين 10 و128 حرفًا');
    }
  }

  List<String> _validatePermissions(Iterable<String> values) {
    final selected = values.toSet();
    final unknown = selected.difference(allowedPermissions);
    if (unknown.isNotEmpty) {
      throw ArgumentError('صلاحيات غير معروفة: ${unknown.join('، ')}');
    }
    if (selected.contains('view_reports') && !selected.contains('view_account')) {
      throw ArgumentError('صلاحية التقارير تتطلب صلاحية عرض كشف الحساب');
    }
    if (selected.contains('edit_profile') && !selected.contains('view_profile')) {
      throw ArgumentError('صلاحية تعديل الملف الشخصي تتطلب صلاحية عرضه');
    }
    if (selected.contains('submit_complaints') && !selected.contains('view_complaints')) {
      throw ArgumentError('إرسال البلاغات يتطلب صلاحية عرض ومتابعة البلاغات');
    }
    return selected.toList()..sort();
  }

  Future<void> _requireManager(int managerId) async {
    final rows = await db.rawQuery(
      'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
      [managerId, 'manager'],
    );
    if (rows.isEmpty) throw StateError('هذه العملية متاحة لمدير نشط فقط');
  }

  Future<Map<String, Object?>?> credentials(int workerId) async {
    final rows = await db.rawQuery(
      '''SELECT id, worker_id, username_normalized, permissions_json, active
         FROM worker_credentials WHERE worker_id=? AND station_id=? LIMIT 1''',
      [workerId, stationId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> createCredentials({
    required int workerId,
    required String username,
    required String password,
    required int managerId,
    Iterable<String> permissions = const ['view_dashboard', 'view_irrigations', 'view_account', 'view_payments', 'view_reports'],
  }) async {
    await _requireManager(managerId);
    _validateUsername(username);
    _validatePassword(password);
    final normalized = _normalize(username);
    final selected = _validatePermissions(permissions);
    final hash = await compute(_hashWorkerPassword, password);
    final now = AppClock.now().toIso8601String();

    await db.transaction((tx) async {
      final manager = await tx.rawQuery(
        'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
        [managerId, 'manager'],
      );
      if (manager.isEmpty) throw StateError('هذه العملية متاحة لمدير نشط فقط');
      final workers = await tx.rawQuery(
        'SELECT id, active FROM workers WHERE id=? AND station_id=? LIMIT 1',
        [workerId, stationId],
      );
      if (workers.isEmpty || (workers.first['active'] as num?)?.toInt() != 1) {
        throw StateError('العامل غير موجود أو غير نشط');
      }
      final existing = await tx.rawQuery(
        'SELECT id FROM worker_credentials WHERE station_id=? AND worker_id=? LIMIT 1',
        [stationId, workerId],
      );
      if (existing.isNotEmpty) {
        throw StateError('لدى هذا العامل بيانات دخول بالفعل؛ استخدم تعديل بيانات الدخول');
      }
      final id = await tx.insert('worker_credentials', {
        'station_id': stationId,
        'worker_id': workerId,
        'username_normalized': normalized,
        'password_phc': hash,
        'permissions_json': jsonEncode(selected),
        'active': 1,
        'created_at': now,
        'updated_at': now,
        'created_by': managerId,
        'updated_by': managerId,
      });
      await db.auditTx(
        tx,
        userId: managerId,
        operation: 'worker_login_created',
        table: 'worker_credentials',
        recordId: id,
        newValues: {
          'worker_id': workerId,
          'username': normalized,
          'active': true,
          'permissions': selected,
        },
      );
    });
  }

  Future<void> updateCredentials({
    required int workerId,
    required String username,
    String? newPassword,
    required bool active,
    required int managerId,
    required Iterable<String> permissions,
  }) async {
    await _requireManager(managerId);
    _validateUsername(username);
    if (newPassword != null) _validatePassword(newPassword);
    final normalized = _normalize(username);
    final selected = _validatePermissions(permissions);
    final hash = newPassword == null ? null : await compute(_hashWorkerPassword, newPassword);
    final now = AppClock.now().toIso8601String();

    await db.transaction((tx) async {
      final managers = await tx.rawQuery(
        'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
        [managerId, 'manager'],
      );
      if (managers.isEmpty) throw StateError('هذه العملية متاحة لمدير نشط فقط');
      final rows = await tx.rawQuery(
        'SELECT id, active FROM worker_credentials WHERE worker_id=? AND station_id=? LIMIT 1',
        [workerId, stationId],
      );
      if (rows.isEmpty) throw StateError('لا توجد بيانات دخول لهذا العامل');
      final credentialId = (rows.first['id'] as num).toInt();
      final values = <String, Object?>{
        'username_normalized': normalized,
        'permissions_json': jsonEncode(selected),
        'active': active ? 1 : 0,
        'updated_at': now,
        'updated_by': managerId,
      };
      if (hash != null) values['password_phc'] = hash;
      await tx.update('worker_credentials', values, where: 'id=?', whereArgs: [credentialId]);

      // Any manager-side credential or permission change requires a fresh
      // login so a worker cannot keep using a screen after a permission is removed.
      const revoke = true;
      await tx.update(
        'worker_sessions',
        {'revoked_at': now},
        where: 'worker_id=? AND revoked_at IS NULL',
        whereArgs: [workerId],
      );
      await db.auditTx(
        tx,
        userId: managerId,
        operation: 'worker_login_updated',
        table: 'worker_credentials',
        recordId: credentialId,
        newValues: {
          'worker_id': workerId,
          'username': normalized,
          'active': active,
          'password_changed': hash != null,
          'permissions': selected,
          'sessions_revoked': revoke,
        },
      );
    });
    await currentWorkerId();
  }

  Future<bool> login(String username, String password) async {
    // Match partner-login behavior: a new login attempt closes the previous
    // worker session on this device, including when the new credentials fail.
    await logout();
    final rows = await db.rawQuery(
      '''SELECT c.worker_id, c.password_phc
         FROM worker_credentials c
         JOIN workers w ON w.id=c.worker_id AND w.station_id=c.station_id
         WHERE c.username_normalized=? AND c.station_id=?
           AND c.active=1 AND w.active=1 LIMIT 1''',
      [_normalize(username), stationId],
    );
    if (rows.isEmpty) return false;
    final valid = await compute(
      _verifyWorkerPassword,
      <String>['${rows.first['password_phc']}', password],
    );
    if (!valid) return false;

    final workerId = (rows.first['worker_id'] as num).toInt();
    final token = _uuid.v4();
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final now = AppClock.now();
    await db.transaction((tx) async {
      await tx.update(
        'worker_sessions',
        {'revoked_at': now.toIso8601String()},
        where: 'worker_id=? AND revoked_at IS NULL',
        whereArgs: [workerId],
      );
      await tx.insert('worker_sessions', {
        'worker_id': workerId,
        'token_hash': tokenHash,
        'expires_at': now.add(_sessionDuration).toIso8601String(),
        'created_at': now.toIso8601String(),
      });
    });
    await _storage.write(token);
    return true;
  }

  /// Identity is always resolved from the protected token, never a route argument.
  Future<int?> currentWorkerId() async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) return null;
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final rows = await db.rawQuery(
      '''SELECT s.worker_id FROM worker_sessions s
         JOIN worker_credentials c ON c.worker_id=s.worker_id
         JOIN workers w ON w.id=s.worker_id
         WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
           AND c.active=1 AND w.active=1 AND c.station_id=w.station_id
           AND w.station_id=? LIMIT 1''',
      [tokenHash, AppClock.now().toIso8601String(), stationId],
    );
    if (rows.isEmpty) {
      await _storage.delete();
      return null;
    }
    return (rows.first['worker_id'] as num).toInt();
  }

  Future<Set<String>> currentPermissions() async {
    final workerId = await currentWorkerId();
    if (workerId == null) return <String>{};
    final rows = await db.rawQuery(
      'SELECT permissions_json FROM worker_credentials WHERE worker_id=? AND station_id=? AND active=1 LIMIT 1',
      [workerId, stationId],
    );
    if (rows.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode('${rows.first['permissions_json']}');
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().where(allowedPermissions.contains).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<bool> hasPermission(String permission) async {
    if (!allowedPermissions.contains(permission)) return false;
    return (await currentPermissions()).contains(permission);
  }

  /// يسمح للعامل بتعديل بياناته التعريفية فقط؛ لا يقبل أي حقل وظيفي أو مالي.
  Future<void> updateCurrentProfile({
    required String name,
    required String phone,
  }) async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) throw StateError('انتهت جلسة الدخول.');
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final workerId = await currentWorkerId();
    if (workerId == null) throw StateError('انتهت جلسة الدخول.');
    final cleanName = name.trim();
    final cleanPhone = phone.trim();
    if (cleanName.isEmpty) throw ArgumentError('اسم العامل مطلوب');
    await db.transaction((tx) async {
      final rows = await tx.rawQuery(
        '''SELECT s.worker_id,c.permissions_json FROM worker_sessions s
           JOIN worker_credentials c ON c.worker_id=s.worker_id
           JOIN workers w ON w.id=s.worker_id
           WHERE s.token_hash=? AND s.worker_id=? AND s.revoked_at IS NULL
             AND s.expires_at>? AND c.active=1 AND w.active=1
             AND c.station_id=w.station_id AND w.station_id=? LIMIT 1''',
        [tokenHash, workerId, AppClock.now().toIso8601String(), stationId],
      );
      if (rows.isEmpty) throw StateError('انتهت جلسة الدخول.');
      final decodedPermissions = jsonDecode('${rows.first['permissions_json']}');
      if (decodedPermissions is! List || !decodedPermissions.contains('edit_profile')) {
        throw StateError('لا تملك صلاحية تعديل الملف الشخصي.');
      }
      final old = await tx.query(
        'workers',
        columns: ['id','name','phone'],
        where: 'id=? AND station_id=? AND active=1',
        whereArgs: [workerId, stationId],
        limit: 1,
      );
      if (old.isEmpty) throw StateError('العامل غير موجود أو غير نشط');
      await tx.update('workers', {'name': cleanName, 'phone': cleanPhone},
        where: 'id=? AND station_id=?', whereArgs: [workerId, stationId]);
      await db.auditTx(tx, operation: 'worker_self_profile_updated',
        table: 'workers', recordId: workerId, oldValues: old.first,
        newValues: {'name': cleanName, 'phone': cleanPhone});
    });
  }

  Future<void> changeCurrentPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) throw StateError('انتهت جلسة الدخول. سجّل الدخول مرة أخرى.');
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final workerId = await currentWorkerId();
    if (workerId == null) throw StateError('انتهت جلسة الدخول. سجّل الدخول مرة أخرى.');
    _validatePassword(newPassword);
    final rows = await db.rawQuery(
      'SELECT id, password_phc FROM worker_credentials WHERE worker_id=? AND station_id=? AND active=1 LIMIT 1',
      [workerId, stationId],
    );
    if (rows.isEmpty) throw StateError('حساب الدخول غير نشط');
    final valid = await compute(
      _verifyWorkerPassword,
      <String>['${rows.first['password_phc']}', currentPassword],
    );
    if (!valid) throw StateError('كلمة المرور الحالية غير صحيحة');
    final hash = await compute(_hashWorkerPassword, newPassword);
    await db.transaction((tx) async {
      final stillCurrent = await tx.rawQuery(
        '''SELECT s.worker_id FROM worker_sessions s
           JOIN worker_credentials c ON c.worker_id=s.worker_id
           WHERE s.token_hash=? AND s.worker_id=? AND s.revoked_at IS NULL
             AND s.expires_at>? AND c.active=1 LIMIT 1''',
        [tokenHash, workerId, AppClock.now().toIso8601String()],
      );
      if (stillCurrent.isEmpty) throw StateError('انتهت جلسة الدخول');
      await tx.update(
        'worker_credentials',
        {'password_phc': hash, 'updated_at': AppClock.now().toIso8601String()},
        where: 'id=? AND worker_id=? AND active=1',
        whereArgs: [rows.first['id'], workerId],
      );
      await db.auditTx(
        tx,
        operation: 'worker_self_password_changed',
        table: 'worker_credentials',
        recordId: (rows.first['id'] as num).toInt(),
        newValues: {'worker_id': workerId, 'password_changed': true},
      );
    });
  }

  /// يرسل العامل بلاغًا مرتبطًا بهويته المستخرجة من الجلسة، ولا يقبل workerId من الواجهة.
  Future<int> submitCurrentWorkerReport({
    required String category,
    required String subject,
    required String description,
  }) async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) throw StateError('انتهت جلسة الدخول.');
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final cleanCategory = category.trim();
    final cleanSubject = subject.trim();
    final cleanDescription = description.trim();
    if (cleanCategory.isEmpty || cleanSubject.length < 4 || cleanDescription.length < 10) {
      throw ArgumentError('يرجى تحديد نوع البلاغ وكتابة عنوان ووصف واضحين.');
    }
    if (cleanSubject.length > 120 || cleanDescription.length > 3000) {
      throw ArgumentError('العنوان أو الوصف أطول من الحد المسموح.');
    }
    return db.transaction((tx) async {
      final rows = await tx.rawQuery(
        '''SELECT s.worker_id,c.permissions_json FROM worker_sessions s
           JOIN worker_credentials c ON c.worker_id=s.worker_id
           JOIN workers w ON w.id=s.worker_id
           WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
             AND c.active=1 AND w.active=1 AND c.station_id=w.station_id
             AND w.station_id=? LIMIT 1''',
        [tokenHash, AppClock.now().toIso8601String(), stationId],
      );
      if (rows.isEmpty) throw StateError('انتهت جلسة الدخول.');
      final permissions = jsonDecode('${rows.first['permissions_json']}');
      if (permissions is! List || !permissions.contains('submit_complaints')) {
        throw StateError('لا تملك صلاحية إرسال البلاغات.');
      }
      final workerId = (rows.first['worker_id'] as num).toInt();
      final now = AppClock.now().toIso8601String();
      final id = await tx.insert('worker_reports', {
        'station_id': stationId,
        'worker_id': workerId,
        'category': cleanCategory,
        'subject': cleanSubject,
        'description': cleanDescription,
        'status': 'new',
        'created_at': now,
        'updated_at': now,
      });
      await db.auditTx(tx, operation: 'worker_report_submitted',
        table: 'worker_reports', recordId: id,
        newValues: {'worker_id': workerId, 'category': cleanCategory, 'status': 'new'});
      return id;
    });
  }

  /// العامل يرى بلاغاته فقط؛ يجري التحقق من ملكية الجلسة داخل الاستعلام نفسه.
  Future<List<Map<String, Object?>>> currentWorkerReports() async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) throw StateError('انتهت جلسة الدخول.');
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    return db.transaction((tx) async {
      final rows = await tx.rawQuery(
        '''SELECT s.worker_id,c.permissions_json FROM worker_sessions s
           JOIN worker_credentials c ON c.worker_id=s.worker_id
           JOIN workers w ON w.id=s.worker_id
           WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
             AND c.active=1 AND w.active=1 AND c.station_id=w.station_id
             AND w.station_id=? LIMIT 1''',
        [tokenHash, AppClock.now().toIso8601String(), stationId],
      );
      if (rows.isEmpty) throw StateError('انتهت جلسة الدخول.');
      final permissions = jsonDecode('${rows.first['permissions_json']}');
      if (permissions is! List || !permissions.contains('view_complaints')) {
        throw StateError('لا تملك صلاحية متابعة البلاغات.');
      }
      return tx.rawQuery(
        '''SELECT id,category,subject,description,status,admin_reply,created_at,updated_at,replied_at
           FROM worker_reports WHERE station_id=? AND worker_id=?
           ORDER BY created_at DESC,id DESC LIMIT 100''',
        [stationId, rows.first['worker_id']],
      );
    });
  }

  /// قائمة الإدارة لا تعمل إلا لمدير نشط، ويمكن حصرها بعامل واحد.
  Future<List<Map<String, Object?>>> workerReportsForManager({
    required int managerId,
    int? workerId,
  }) async {
    final managers = await db.rawQuery(
      'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
      [managerId, 'manager'],
    );
    if (managers.isEmpty) throw StateError('عرض بلاغات العمال متاح للمدير النشط فقط.');
    return db.rawQuery(
      '''SELECT r.*,w.name worker_name FROM worker_reports r
         JOIN workers w ON w.id=r.worker_id
         WHERE r.station_id=? AND (? IS NULL OR r.worker_id=?)
         ORDER BY CASE r.status WHEN 'new' THEN 0 WHEN 'under_review' THEN 1 ELSE 2 END,
           r.created_at DESC,r.id DESC LIMIT 300''',
      [stationId, workerId, workerId],
    );
  }

  /// رد الإدارة وتغيير الحالة داخل معاملة واحدة مع إعادة التحقق من المدير.
  Future<void> replyToWorkerReport({
    required int managerId,
    required int reportId,
    required String status,
    required String reply,
  }) async {
    const statuses = {'under_review','accepted','rejected','resolved'};
    if (!statuses.contains(status)) throw ArgumentError('حالة البلاغ غير صحيحة.');
    final cleanReply = reply.trim();
    if (cleanReply.length > 3000) throw ArgumentError('الرد أطول من الحد المسموح.');
    await db.transaction((tx) async {
      final managers = await tx.rawQuery(
        'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
        [managerId, 'manager'],
      );
      if (managers.isEmpty) throw StateError('تحديث البلاغات متاح للمدير النشط فقط.');
      final reports = await tx.query('worker_reports',
        where: 'id=? AND station_id=?', whereArgs: [reportId, stationId], limit: 1);
      if (reports.isEmpty) throw StateError('البلاغ غير موجود في هذه المحطة.');
      final old = reports.first;
      final now = AppClock.now().toIso8601String();
      await tx.update('worker_reports', {
        'status': status,
        'admin_reply': cleanReply.isEmpty ? null : cleanReply,
        'reviewed_by': managerId,
        'updated_at': now,
        'replied_at': cleanReply.isEmpty ? old['replied_at'] : now,
      }, where: 'id=? AND station_id=?', whereArgs: [reportId, stationId]);
      await db.auditTx(tx, userId: managerId,
        operation: 'worker_report_reviewed', table: 'worker_reports',
        recordId: reportId, oldValues: old,
        newValues: {'status': status, 'admin_reply': cleanReply});
    });
  }

  Future<void> logout() async {
    final token = await _storage.read();
    if (token != null && token.isNotEmpty) {
      final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
      await db.update(
        'worker_sessions',
        {'revoked_at': AppClock.now().toIso8601String()},
        'token_hash=? AND revoked_at IS NULL',
        [tokenHash],
      );
    }
    await _storage.delete();
  }
}

String _hashWorkerPassword(String password) =>
    LocalBeneficiaryAuthService.hashPassword(password);
bool _verifyWorkerPassword(List<String> values) =>
    LocalBeneficiaryAuthService.verifyPassword(values[0], values[1]);
