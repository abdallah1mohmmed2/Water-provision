import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../core/app_clock.dart';
import '../data/local/database.dart';
import 'local_beneficiary_auth_service.dart';

abstract interface class PartnerSessionStorage {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

class _SecurePartnerSessionStorage implements PartnerSessionStorage {
  _SecurePartnerSessionStorage(this.storage);
  final FlutterSecureStorage storage;
  @override
  Future<String?> read() => storage.read(key: 'local_partner_session_token_v1');
  @override
  Future<void> write(String token) => storage.write(key: 'local_partner_session_token_v1', value: token);
  @override
  Future<void> delete() => storage.delete(key: 'local_partner_session_token_v1');
}

/// Local partner authentication for the same station database.
/// Credentials and sessions are separate from beneficiary credentials.
class LocalPartnerAuthService {
  LocalPartnerAuthService({
    AppDatabase? database,
    FlutterSecureStorage? secureStorage,
    PartnerSessionStorage? sessionStorage,
    this.stationId = 1,
  }) : db = database ?? AppDatabase.instance,
       _storage = sessionStorage ?? _SecurePartnerSessionStorage(secureStorage ?? const FlutterSecureStorage());

  final AppDatabase db;
  final PartnerSessionStorage _storage;
  final int stationId;
  static const _sessionDuration = Duration(days: 30);
  static const _uuid = Uuid();

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

  Future<void> _requireManager(int managerId) async {
    final rows = await db.rawQuery(
      'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
      [managerId, 'manager'],
    );
    if (rows.isEmpty) throw StateError('هذه العملية متاحة لمدير نشط فقط');
  }

  Future<Map<String, Object?>?> credentials(int partnerId) async {
    final rows = await db.rawQuery(
      '''SELECT id, partner_id, username_normalized, active
         FROM partner_credentials WHERE partner_id=? AND station_id=? LIMIT 1''',
      [partnerId, stationId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> createCredentials({
    required int partnerId,
    required String username,
    required String password,
    required int managerId,
  }) async {
    await _requireManager(managerId);
    _validateUsername(username);
    _validatePassword(password);
    final hash = await compute(_hashPartnerPassword, password);
    final now = AppClock.now().toIso8601String();
    await db.transaction((tx) async {
      final manager = await tx.rawQuery(
        'SELECT id FROM app_users WHERE id=? AND role=? AND active=1 LIMIT 1',
        [managerId, 'manager'],
      );
      if (manager.isEmpty) throw StateError('هذه العملية متاحة لمدير نشط فقط');
      final partner = await tx.rawQuery(
        'SELECT id, active FROM partners WHERE id=? AND station_id=? LIMIT 1',
        [partnerId, stationId],
      );
      if (partner.isEmpty || (partner.first['active'] as num?)?.toInt() != 1) {
        throw StateError('الشريك غير موجود أو غير نشط');
      }
      await tx.insert('partner_credentials', {
        'station_id': stationId, 'partner_id': partnerId,
        'username_normalized': _normalize(username), 'password_phc': hash,
        'active': 1, 'created_at': now, 'updated_at': now,
        'created_by': managerId, 'updated_by': managerId,
      });
      await db.auditTx(tx, userId: managerId, operation: 'partner_login_created',
        table: 'partner_credentials',
        newValues: {'partner_id': partnerId, 'username': _normalize(username), 'active': true});
    });
  }

  Future<void> updateCredentials({
    required int partnerId,
    required String username,
    String? newPassword,
    required bool active,
    required int managerId,
  }) async {
    await _requireManager(managerId);
    _validateUsername(username);
    if (newPassword != null) _validatePassword(newPassword);
    final hash = newPassword == null ? null : await compute(_hashPartnerPassword, newPassword);
    final now = AppClock.now().toIso8601String();
    await db.transaction((tx) async {
      final rows = await tx.rawQuery(
        'SELECT id, active FROM partner_credentials WHERE partner_id=? AND station_id=? LIMIT 1',
        [partnerId, stationId],
      );
      if (rows.isEmpty) throw StateError('لا توجد بيانات دخول لهذا الشريك');
      final values = <String, Object?>{
        'username_normalized': _normalize(username), 'active': active ? 1 : 0,
        'updated_at': now, 'updated_by': managerId,
      };
      if (hash != null) values['password_phc'] = hash;
      await tx.update('partner_credentials', values, where: 'id=?', whereArgs: [rows.first['id']]);
      final wasActive = (rows.first['active'] as num?)?.toInt() == 1;
      final revoke = hash != null || (wasActive && !active);
      if (revoke) {
        await tx.update('partner_sessions', {'revoked_at': now},
          where: 'partner_id=? AND revoked_at IS NULL', whereArgs: [partnerId]);
      }
      await db.auditTx(tx, userId: managerId, operation: 'partner_login_updated',
        table: 'partner_credentials', recordId: (rows.first['id'] as num).toInt(),
        newValues: {'partner_id': partnerId, 'username': _normalize(username),
          'active': active, 'password_changed': hash != null, 'sessions_revoked': revoke});
    });
    if (hash != null || !active) await currentPartnerId();
  }

  Future<bool> login(String username, String password) async {
    final rows = await db.rawQuery(
      '''SELECT c.partner_id, c.password_phc FROM partner_credentials c
         JOIN partners p ON p.id=c.partner_id AND p.station_id=c.station_id
         WHERE c.username_normalized=? AND c.station_id=? AND c.active=1 AND p.active=1 LIMIT 1''',
      [_normalize(username), stationId],
    );
    if (rows.isEmpty) return false;
    final valid = await compute(_verifyPartnerPassword, <String>['${rows.first['password_phc']}', password]);
    if (!valid) return false;
    await logout();
    final partnerId = (rows.first['partner_id'] as num).toInt();
    final token = _uuid.v4();
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final now = AppClock.now();
    await db.transaction((tx) async {
      await tx.update('partner_sessions', {'revoked_at': now.toIso8601String()},
        where: 'partner_id=? AND revoked_at IS NULL', whereArgs: [partnerId]);
      await tx.insert('partner_sessions', {
        'partner_id': partnerId, 'token_hash': tokenHash,
        'expires_at': now.add(_sessionDuration).toIso8601String(),
        'created_at': now.toIso8601String(),
      });
    });
    await _storage.write(token);
    return true;
  }

  Future<int?> currentPartnerId() async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) return null;
    final tokenHash = crypto.sha256.convert(utf8.encode(token)).toString();
    final rows = await db.rawQuery(
      '''SELECT s.partner_id FROM partner_sessions s
         JOIN partner_credentials c ON c.partner_id=s.partner_id
         JOIN partners p ON p.id=s.partner_id
         WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
           AND c.active=1 AND p.active=1 AND p.station_id=? LIMIT 1''',
      [tokenHash, AppClock.now().toIso8601String(), stationId],
    );
    if (rows.isEmpty) { await _storage.delete(); return null; }
    return (rows.first['partner_id'] as num).toInt();
  }

  Future<void> changeCurrentPassword({required String currentPassword, required String newPassword}) async {
    final partnerId = await currentPartnerId();
    if (partnerId == null) throw StateError('انتهت جلسة الدخول. سجّل الدخول مرة أخرى.');
    _validatePassword(newPassword);
    final rows = await db.rawQuery(
      'SELECT id, password_phc FROM partner_credentials WHERE partner_id=? AND station_id=? AND active=1 LIMIT 1',
      [partnerId, stationId],
    );
    if (rows.isEmpty) throw StateError('حساب الدخول غير نشط');
    final valid = await compute(_verifyPartnerPassword, <String>['${rows.first['password_phc']}', currentPassword]);
    if (!valid) throw StateError('كلمة المرور الحالية غير صحيحة');
    final hash = await compute(_hashPartnerPassword, newPassword);
    await db.transaction((tx) async {
      await tx.update('partner_credentials', {
        'password_phc': hash, 'updated_at': AppClock.now().toIso8601String(),
      }, where: 'id=? AND partner_id=? AND active=1', whereArgs: [rows.first['id'], partnerId]);
      await db.auditTx(tx, operation: 'partner_self_password_changed',
        table: 'partner_credentials', recordId: (rows.first['id'] as num).toInt(),
        newValues: {'partner_id': partnerId, 'password_changed': true});
    });
  }

  Future<void> logout() async {
    final token = await _storage.read();
    if (token != null && token.isNotEmpty) {
      final hash = crypto.sha256.convert(utf8.encode(token)).toString();
      await db.update('partner_sessions', {'revoked_at': AppClock.now().toIso8601String()},
        'token_hash=? AND revoked_at IS NULL', [hash]);
    }
    await _storage.delete();
  }
}

String _hashPartnerPassword(String password) => LocalBeneficiaryAuthService.hashPassword(password);
bool _verifyPartnerPassword(List<String> values) => LocalBeneficiaryAuthService.verifyPassword(values[0], values[1]);
