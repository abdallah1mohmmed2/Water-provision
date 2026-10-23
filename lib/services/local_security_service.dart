import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Local device lock. PIN hashes and settings are stored in Android Keystore-backed storage.
class LocalSecurityService {
  LocalSecurityService._();
  static final LocalSecurityService instance = LocalSecurityService._();

  static const _pinKey = 'local_security_pin_sha256';
  static const _biometricKey = 'local_security_biometric_enabled';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();

  String _hash(String pin) => sha256.convert(utf8.encode(pin)).toString();

  Future<bool> hasPin() async => (await _storage.read(key: _pinKey)) != null;

  Future<bool> verifyPin(String pin) async {
    final saved = await _storage.read(key: _pinKey);
    return saved != null && saved == _hash(pin);
  }

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      throw ArgumentError('رمز التأمين يجب أن يتكون من 4 إلى 8 أرقام');
    }
    await _storage.write(key: _pinKey, value: _hash(pin));
  }

  Future<bool> biometricEnabled() async =>
      (await _storage.read(key: _biometricKey)) == 'true';

  Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.write(key: _biometricKey, value: enabled ? 'true' : 'false');
  }

  Future<bool> biometricAvailable() async {
    try {
      return await _auth.isDeviceSupported() &&
          await _auth.canCheckBiometrics &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometric() async {
    try {
      if (!await biometricAvailable()) return false;
      return await _auth.authenticate(
        localizedReason: 'تحقق من هويتك لفتح تطبيق ساقية',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
