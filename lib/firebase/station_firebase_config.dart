import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Build-time Firebase configuration for one station installation.
///
/// Firebase client configuration is not a server credential. Never place
/// service-account keys or Admin SDK secrets in these values.
class StationFirebaseConfig {
  const StationFirebaseConfig._();

  static const String _apiKey = String.fromEnvironment(
    'SAQIA_FIREBASE_API_KEY',
  );
  static const String _appId = String.fromEnvironment(
    'SAQIA_FIREBASE_APP_ID',
  );
  static const String _messagingSenderId = String.fromEnvironment(
    'SAQIA_FIREBASE_MESSAGING_SENDER_ID',
  );
  static const String _projectId = String.fromEnvironment(
    'SAQIA_FIREBASE_PROJECT_ID',
  );
  static const String _storageBucket = String.fromEnvironment(
    'SAQIA_FIREBASE_STORAGE_BUCKET',
  );

  /// Returns null when this build has no station Firebase project configured.
  ///
  /// A missing configuration intentionally leaves the local/offline app
  /// usable and does not silently connect to another station's Firebase.
  static FirebaseOptions? get androidOptions => buildAndroidOptions(
    apiKey: _apiKey,
    appId: _appId,
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    storageBucket: _storageBucket,
  );

  @visibleForTesting
  static FirebaseOptions? buildAndroidOptions({
    required String apiKey,
    required String appId,
    required String messagingSenderId,
    required String projectId,
    String storageBucket = '',
  }) {
    if ([apiKey, appId, messagingSenderId, projectId]
        .any((value) => value.trim().isEmpty)) {
      return null;
    }

    return FirebaseOptions(
      apiKey: apiKey.trim(),
      appId: appId.trim(),
      messagingSenderId: messagingSenderId.trim(),
      projectId: projectId.trim(),
      storageBucket: storageBucket.trim().isEmpty
          ? null
          : storageBucket.trim(),
    );
  }
}
