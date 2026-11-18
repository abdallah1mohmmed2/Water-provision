import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/firebase/station_firebase_config.dart';

void main() {
  group('StationFirebaseConfig.buildAndroidOptions', () {
    test('keeps Firebase disabled when this build has no station defines', () {
      expect(StationFirebaseConfig.androidOptions, isNull);
    });

    test('returns null when a required station value is missing', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: 'api-key',
        appId: 'app-id',
        messagingSenderId: '',
        projectId: 'manzoma-ststion',
      );

      expect(options, isNull);
    });

    test('builds options for the explicitly supplied station project', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: ' api-key ',
        appId: 'app-id',
        messagingSenderId: 'sender-id',
        projectId: 'manzoma-ststion',
        storageBucket: 'manzoma-ststion.firebasestorage.app',
      );

      expect(options, isNotNull);
      expect(options!.apiKey, 'api-key');
      expect(options.appId, 'app-id');
      expect(options.messagingSenderId, 'sender-id');
      expect(options.projectId, 'manzoma-ststion');
      expect(options.storageBucket, 'manzoma-ststion.firebasestorage.app');
    });

    test('rejects a different station Firebase project', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: 'api-key',
        appId: 'app-id',
        messagingSenderId: 'sender-id',
        projectId: 'another-station',
      );

      expect(options, isNull);
    });

    test('allows an omitted optional storage bucket', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: 'api-key',
        appId: 'app-id',
        messagingSenderId: 'sender-id',
        projectId: 'manzoma-ststion',
      );

      expect(options, isNotNull);
      expect(options!.storageBucket, isNull);
    });
  });
}
