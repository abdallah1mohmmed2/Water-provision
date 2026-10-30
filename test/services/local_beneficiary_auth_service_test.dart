import 'package:flutter_test/flutter_test.dart';
import 'package:hashlib/hashlib.dart';
import 'package:saqia_station/services/local_beneficiary_auth_service.dart';

void main() {
  group('LocalBeneficiaryAuthService password hashing', () {
    test('stores a PHC Argon2id hash and verifies the correct password', () {
      final encoded = LocalBeneficiaryAuthService.hashPassword(
        'a-long-test-password',
        salt: List<int>.filled(16, 7),
        security: Argon2Security.test,
      );

      expect(encoded, startsWith(r'$argon2id$'));
      expect(
        LocalBeneficiaryAuthService.verifyPassword(
          encoded,
          'a-long-test-password',
        ),
        isTrue,
      );
    });

    test('rejects an incorrect password', () {
      final encoded = LocalBeneficiaryAuthService.hashPassword(
        'a-long-test-password',
        salt: List<int>.filled(16, 9),
        security: Argon2Security.test,
      );

      expect(
        LocalBeneficiaryAuthService.verifyPassword(encoded, 'wrong-password'),
        isFalse,
      );
    });

    test('rejects malformed encoded hashes without throwing', () {
      expect(
        LocalBeneficiaryAuthService.verifyPassword('not-an-argon2-hash', 'pw'),
        isFalse,
      );
    });
  });
}
