import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'features/app.dart';
import 'firebase/station_firebase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase activation uses only this station build configuration.
  // Missing/failed configuration leaves the Android access gate locked.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final options = StationFirebaseConfig.androidOptions;
    if (options != null) {
      try {
        await Firebase.initializeApp(options: options);
      } catch (_) {
        // Render the locked gate with a recovery message instead of crashing.
      }
    }
  }

  runApp(const SaqiaApp());
}
