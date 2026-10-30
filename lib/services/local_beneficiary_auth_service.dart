import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hashlib/hashlib.dart';
import 'package:uuid/uuid.dart';

import '../core/app_clock.dart';
import '../data/local/database.dart';

/// Local-only beneficiary credentials. Does not use the API/OTP AuthService.
class LocalBeneficiaryAuthService {
  LocalBeneficiaryAuthService({
    AppDatabase? database,
    FlutterSecureStorage? secureStorage,
  }) : db = database ?? AppDatabase.instance,
       _storage = secureStorage ?? const FlutterSecureStorage();

  final AppDatabase db;
  final FlutterSecureStorage _storage;
  static const _sessionKey = 'local_beneficiary_session_token_v1';
  static const _sessionDuration = Duration(days: 30);
  static const _uuid = Uuid();

  String _normalizeUsername(String value) => value.trim().toLowerCase();

  static String hashPassword(String password, {List<int>? salt}) {
    final actualSalt = salt ??
        List<int>.generate(16, (_) => Random.secure().nextInt(256));
    return argon2id(
      utf8.encode(password),
      actualSalt,
      hashLength: 32,
      security: Argon2Security.moderate,
    ).encoded();
  }

  static bool verifyPassword(String encodedHash, String password) {
    try {
      return argon2Verify(encodedHash, utf8.encode(password));
    } catch (_) {
      return false;
    }
  }

  Future<void> _requireManager(int actorId) async {
    final rows = await db.query(
      'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
      args: [actorId, 'manager'],
    );
    if (rows.isEmpty) throw StateError('هذه العملية متاحة لمدير نشط فقط');
  }

  void _validateCredentials(String username, String password) {
    if (!RegExp(r'^[a-zA-Z0-9._-]{3,40}$').hasMatch(username.trim())) {
      throw ArgumentError('اسم المستخدم يجب أن يكون من 3 إلى 40 حرفًا أو رقمًا');
    }
    if (password.length < 10 || password.length > 128) {
      throw ArgumentError('كلمة المرور يجب أن تكون بين 10 و128 حرفًا');
    }
  }

  Future<void> createCredentials({
    required int beneficiaryId,
    required String username,
    required String password,
    required int managerId,
  }) async {
    await _requireManager(managerId);
    _validateCredentials(username, password);
    final normalized = _normalizeUsername(username);
    final now = AppClock.now().toIso8601String();
    final hash = hashPassword(password);

    await db.transaction((tx) async {
      final owners = await tx.query(
        'SELECT id, station_id, status FROM beneficiaries WHERE id=? LIMIT 1',
        [beneficiaryId],
      );
      if (owners.isEmpty || owners.first['status'] != 'active') {
        throw StateError('المستفيد غير موجود أو غير نشط');
      }
      final owner = owners.first;
      final stationId = (owner['station_id'] as num).toInt();
      final existing = await tx.query(
        'SELECT id FROM beneficiary_credentials WHERE station_id=? AND beneficiary_id=? LIMIT 1',
        [stationId, beneficiaryId],
      );
      if (existing.isNotEmpty) {
        throw StateError('لدى هذا المستفيد بيانات دخول بالفعل؛ استخدم إعادة تعيين كلمة المرور');
      }
      await tx.insert('beneficiary_credentials', {
        'station_id': stationId,
        'beneficiary_id': beneficiaryId,
        'username_normalized': normalized,
        'password_phc': hash,
        'active': 1,
        'created_at': now,
        'updated_at': now,
        'created_by': managerId,
        'updated_by': managerId,
      });
      await db.auditTx(
        tx,
        userId: managerId,
        operation: 'beneficiary_login_created',
        table: 'beneficiary_credentials',
        recordId: beneficiaryId,
        newValues: {'username': normalized, 'active': true},
      );
    });
  }

  Future<void> resetPassword({
    required int beneficiaryId,
    required String newPassword,
    required int managerId,
  }) async {
    await _requireManager(managerId);
    if (newPassword.length < 10 || newPassword.length > 128) {
      throw ArgumentError('كلمة المرور يجب أن تكون بين 10 و128 حرفًا');
    }
    final rows = await db.query(
      'SELECT id FROM beneficiary_credentials WHERE beneficiary_id=? LIMIT 1',
      args: [beneficiaryId],
    );
    if (rows.isEmpty) throw StateError('لا توجد بيانات دخول لهذا المستفيد');
    final hash = hashPassword(newPassword);
    final now = AppClock.now().toIso8601String();
    await db.transaction((tx) async {
      await tx.update(
        'beneficiary_credentials',
        {'password_phc': hash, 'updated_at': now, 'updated_by': managerId},
        where: 'id=?',
        whereArgs: [(rows.first['id'] as num).toInt()],
      );
      await tx.update(
        'beneficiary_sessions',
        {'revoked_at': now},
        where: 'beneficiary_id=? AND revoked_at IS NULL',
        whereArgs: [beneficiaryId],
      );
      await db.auditTx(
        tx,
        userId: managerId,
        operation: 'beneficiary_login_password_reset',
        table: 'beneficiary_credentials',
        recordId: beneficiaryId,
        newValues: {'sessions_revoked': true},
      );
    });
    await _storage.delete(key: _sessionKey);
  }

  Future<void> setAccountActive({
    required int beneficiaryId,
    required bool active,
    required int managerId,
  }) async {
    await _requireManager(managerId);
    final now = AppClock.now().toIso8601String();
    await db.transaction((tx) async {
      final rows = await tx.query(
        'SELECT id FROM beneficiary_credentials WHERE beneficiary_id=? LIMIT 1',
        [beneficiaryId],
      );
      if (rows.isEmpty) throw StateError('لا توجد بيانات دخول لهذا المستفيد');
      await tx.update(
        'beneficiary_credentials',
        {'active': active ? 1 : 0, 'updated_at': now, 'updated_by': managerId},
        where: 'id=?',
        whereArgs: [(rows.first['id'] as num).toInt()],
      );
      if (!active) {
        await tx.update(
          'beneficiary_sessions',
          {'revoked_at': now},
          where: 'beneficiary_id=? AND revoked_at IS NULL',
          whereArgs: [beneficiaryId],
        );
      }
      await db.auditTx(
        tx,
        userId: managerId,
        operation: active ? 'beneficiary_login_enabled' : 'beneficiary_login_disabled',
        table: 'beneficiary_credentials',
        recordId: beneficiaryId,
        newValues: {'active': active, 'sessions_revoked': !active},
      );
    });
    if (!active && await currentBeneficiaryId() == beneficiaryId) {
      await _storage.delete(key: _sessionKey);
    }
  }

  Future<bool> login(String username, String password) async {
    final normalized = _normalizeUsername(username);
    final rows = await db.query(
      '''SELECT c.beneficiary_id, c.password_phc
         FROM beneficiary_credentials c
         JOIN beneficiaries b ON b.id=c.beneficiary_id
         WHERE c.username_normalized=? AND c.active=1 AND b.status='active'
         LIMIT 1''',
      args: [normalized],
    );
    if (rows.isEmpty ||
        !verifyPassword('${rows.first['password_phc']}', password)) {
      return false;
    }

    final beneficiaryId = (rows.first['beneficiary_id'] as num).toInt();
    final token = _uuid.v4();
    final tokenHash = sha256.convert(utf8.encode(token)).toString();
    final now = AppClock.now();
    final expires = now.add(_sessionDuration).toIso8601String();
    await db.transaction((tx) async {
      await tx.update(
        'beneficiary_sessions',
        {'revoked_at': now.toIso8601String()},
        where: 'beneficiary_id=? AND revoked_at IS NULL',
        whereArgs: [beneficiaryId],
      );
      await tx.insert('beneficiary_sessions', {
        'beneficiary_id': beneficiaryId,
        'token_hash': tokenHash,
        'expires_at': expires,
        'created_at': now.toIso8601String(),
      });
    });
    await _storage.write(key: _sessionKey, value: token);
    return true;
  }

  Future<int?> currentBeneficiaryId() async {
    final token = await _storage.read(key: _sessionKey);
    if (token == null || token.isEmpty) return null;
    final tokenHash = sha256.convert(utf8.encode(token)).toString();
    final rows = await db.query(
      '''SELECT s.beneficiary_id
         FROM beneficiary_sessions s
         JOIN beneficiary_credentials c ON c.beneficiary_id=s.beneficiary_id
         JOIN beneficiaries b ON b.id=s.beneficiary_id
         WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
           AND c.active=1 AND b.status='active'
         LIMIT 1''',
      args: [tokenHash, AppClock.now().toIso8601String()],
    );
    if (rows.isEmpty) {
      await _storage.delete(key: _sessionKey);
      return null;
    }
    return (rows.first['beneficiary_id'] as num).toInt();
  }

  Future<void> logout() async {
    final token = await _storage.read(key: _sessionKey);
    if (token != null && token.isNotEmpty) {
      final tokenHash = sha256.convert(utf8.encode(token)).toString();
      await db.update(
        'beneficiary_sessions',
        {'revoked_at': AppClock.now().toIso8601String()},
        'token_hash=? AND revoked_at IS NULL',
        [tokenHash],
      );
    }
    await _storage.delete(key: _sessionKey);
  }
}
