import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:serverpod_argon2/serverpod_argon2.dart';

/// Password hashing for local station accounts.
///
/// New hashes use Argon2id PHC strings. Legacy SHA-256 hashes are accepted
/// only to authenticate existing accounts and are upgraded after success.
class PasswordHasher {
  static Future<Argon2>? _argon2Future;

  static Future<Argon2> get _argon2 =>
      _argon2Future ??= Argon2.load();

  static bool isArgon2id(String encoded) =>
      encoded.startsWith(r'$argon2id$');

  static bool isLegacySha256(String encoded) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(encoded);

  static Future<String> hash(String password) async {
    final engine = await _argon2;
    if (kIsWeb) return engine.hash(password);
    return Isolate.run(() => engine.hash(password));
  }

  static Future<bool> verify(String password, String encoded) async {
    if (isArgon2id(encoded)) {
      try {
        final engine = await _argon2;
        if (kIsWeb) return engine.verify(password, encoded);
        return await Isolate.run(() => engine.verify(password, encoded));
      } catch (_) {
        return false;
      }
    }

    if (!isLegacySha256(encoded)) return false;
    final actual = sha256.convert(utf8.encode(password)).toString();
    return _constantTimeEquals(actual, encoded.toLowerCase());
  }

  static bool _constantTimeEquals(String a, String b) {
    var difference = a.length ^ b.length;
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final left = i < a.length ? a.codeUnitAt(i) : 0;
      final right = i < b.length ? b.codeUnitAt(i) : 0;
      difference |= left ^ right;
    }
    return difference == 0;
  }
}
