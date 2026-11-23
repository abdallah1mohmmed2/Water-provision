# Android Release Artifact

## الهدف
بناء نسخة Android بنمط Flutter Release ورفعها كـ GitHub Actions Artifact مضغوط قابل للتنزيل، دون إنشاء GitHub Release عام أو نشر تلقائي.

## آلية البناء
- Workflow: `.github/workflows/build-apk.yml`
- Branch: `feature/unified-theme-system`
- Build command: `flutter build apk --release` مع إعدادات Firebase المحضّرة بواسطة `tooling/prepare_firebase_dart_defines.py`.
- الناتج الأصلي: `build/app/outputs/flutter-apk/app-release.apk`.
- الملف المضغوط: `dist/Saqia-App-Release.zip`.
- ملف التحقق: `dist/Saqia-App-Release.zip.sha256`.
- Artifact name: `Saqia-App-Release-ZIP`.

يتحقق الـ workflow من وجود APK غير فارغ، ثم يضغطه، ويفحص سلامة الأرشيف بواسطة `unzip -t`، وينشئ SHA-256 قبل رفع الملفين. فشل أي خطوة يمنع رفع Artifact.

## التوقيع وحدود الاستخدام
حسب `SIGNING_INFO.md` وإعداد `android/app/build.gradle.kts`، يستخدم بناء Release حالياً مفتاح Android Debug الافتراضي. لذلك هذه نسخة Release لأغراض الاختبار والتوزيع التجريبي فقط، وليست توقيع نشر إنتاجي. لا تستخدمها كإصدار Google Play أو كتحديث إنتاجي ثابت قبل إعداد مفتاح Release خاص وآمن خارج المستودع وتحديث إعدادات التوقيع.

## التحقق بعد التشغيل
لا يُعلن نجاح التسليم إلا بعد التأكد من:
1. نجاح Flutter Analyze والاختبارات ضمن الـ workflow.
2. نجاح `flutter build apk --release`.
3. نجاح اختبار ZIP ووجود ملف SHA-256.
4. ظهور Artifact باسم `Saqia-App-Release-ZIP` في تشغيل GitHub Actions المكتمل.
