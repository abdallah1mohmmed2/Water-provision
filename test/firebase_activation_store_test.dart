import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/firebase_activation_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('disabled identities survive creating a fresh store instance', () async {
    const store = FirebaseActivationStore();
    expect(await store.readDisabled(), isEmpty);
    await store.writeDisabled({'disabled-a', 'disabled-b'});
    expect(await const FirebaseActivationStore().readDisabled(), {
      'disabled-a',
      'disabled-b',
    });
    await store.writeDisabled({'disabled-b'});
    expect(await const FirebaseActivationStore().readDisabled(), {
      'disabled-b',
    });
  });

  test(
    'malformed revocation storage is not silently treated as enabled',
    () async {
      const storage = FlutterSecureStorage();
      await storage.write(
        key: 'saqia.firebase.disabled_uids.manzoma-ststion',
        value: '{"bad":true}',
      );
      await expectLater(
        const FirebaseActivationStore().readDisabled(),
        throwsFormatException,
      );
    },
  );
}
