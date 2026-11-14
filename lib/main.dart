import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'features/app.dart';
import 'firebase/station_firebase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase is opt-in per station build. An unconfigured installation keeps
  // working locally and never falls back to another station's project.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final options = StationFirebaseConfig.androidOptions;
    if (options != null) {
      await Firebase.initializeApp(options: options);
    }
  }

  runApp(const SaqiaApp());
}
