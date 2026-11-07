import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/firebase/station_firebase_config.dart';

void main() {
  group('StationFirebaseConfig.buildAndroidOptions', () {
    test('returns null when a required station value is missing', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: 'api-key',
        appId: 'app-id',
        messagingSenderId: '',
        projectId: 'station-project',
      );

      expect(options, isNull);
    });

    test('builds options for the explicitly supplied station project', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: ' api-key ',
        appId: 'app-id',
        messagingSenderId: 'sender-id',
        projectId: 'station-project',
        storageBucket: 'station-project.firebasestorage.app',
      );

      expect(options, isNotNull);
      expect(options!.apiKey, 'api-key');
      expect(options.appId, 'app-id');
      expect(options.messagingSenderId, 'sender-id');
      expect(options.projectId, 'station-project');
      expect(options.storageBucket, 'station-project.firebasestorage.app');
    });

    test('allows an omitted optional storage bucket', () {
      final options = StationFirebaseConfig.buildAndroidOptions(
        apiKey: 'api-key',
        appId: 'app-id',
        messagingSenderId: 'sender-id',
        projectId: 'station-project',
      );

      expect(options, isNotNull);
      expect(options!.storageBucket, isNull);
    });
  });
}
