import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'features/app.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Display Flutter build failures on-screen for phone-only diagnostics.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  ErrorWidget.builder = (details) {
    final stack = details.stack?.toString() ?? 'لا يتوفر StackTrace';
    final report = <String>[
      'BENEFICIARY_APP_DIAGNOSTIC',
      'الاستثناء: ${details.exceptionAsString()}',
      'المكتبة: ${details.library ?? 'غير محددة'}',
      'السياق: ${details.context ?? 'غير محدد'}',
      'StackTrace:',
      stack,
    ].join('\n');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: const Color(0xFFF7F7F7),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.bug_report_outlined, size: 44, color: Colors.red),
                const SizedBox(height: 12),
                const Text('حدث خطأ أثناء عرض الشاشة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('انسخ تقرير التشخيص التالي وأرسله للدعم. لا يحتوي التقرير على كلمة المرور.'),
                const SizedBox(height: 12),
                SelectableText(report, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
          ),
        ),
      ),
    );
  };
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.android);
  }
  runApp(const SaqiaApp());
}
