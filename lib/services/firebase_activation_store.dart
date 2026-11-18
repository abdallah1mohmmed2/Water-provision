import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../firebase/station_firebase_config.dart';

/// Revocation survives a restart and is separate from restorable SQLite data.
class FirebaseActivationStore {
  const FirebaseActivationStore({this.storage = const FlutterSecureStorage()});

  final FlutterSecureStorage storage;
  static const _key =
      'saqia.firebase.disabled_uids.${StationFirebaseConfig.pilotProjectId}';

  Future<Set<String>> readDisabled() async {
    final raw = await storage.read(key: _key);
    if (raw == null) return <String>{};
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.any((value) => value is! String)) {
      throw const FormatException('Invalid Firebase activation record');
    }
    return decoded.cast<String>().toSet();
  }

  Future<void> writeDisabled(Set<String> uids) =>
      storage.write(key: _key, value: jsonEncode(uids.toList()..sort()));
}
