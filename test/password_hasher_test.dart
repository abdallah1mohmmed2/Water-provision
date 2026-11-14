import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/core/security/password_hasher.dart';

void main() {
  group('PasswordHasher', () {
    test('creates verifiable Argon2id PHC hashes', () async {
      final encoded = await PasswordHasher.hash('correct-password');

      expect(encoded, startsWith(r'$argon2id$'));
      expect(await PasswordHasher.verify('correct-password', encoded), isTrue);
      expect(await PasswordHasher.verify('wrong-password', encoded), isFalse);
    });

    test('verifies legacy SHA-256 hashes for transparent migration', () async {
      final legacy = sha256.convert('legacy-password'.codeUnits).toString();

      expect(
        await PasswordHasher.verify('legacy-password', legacy),
        isTrue,
      );
      expect(
        await PasswordHasher.verify('wrong-password', legacy),
        isFalse,
      );
      expect(PasswordHasher.isArgon2id(legacy), isFalse);
    });

    test('rejects malformed and unsupported password hashes', () async {
      expect(await PasswordHasher.verify('password', 'not-a-valid-hash'), isFalse);
      expect(await PasswordHasher.verify('password', List.filled(64, 'a').join()), isFalse);
    });
  });
}
