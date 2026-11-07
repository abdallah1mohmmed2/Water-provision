# تأسيس Firebase لمحطة «منظومة» — المرحلة التأسيسية

> الفرع: `feature/firebase-station-foundation`
> الفرع الأساسي لطلب المراجعة: `main`
> سياسة التنفيذ: لا دمج إلى `main` دون موافقة صريحة. SQLite تبقى Offline-first ومصدر التشغيل المحلي.

## 1. هوية مشروع المحطة

| البيان | القيمة |
|---|---|
| اسم المحطة | منظومة |
| Firebase Project ID | `manzoma-ststion` |
| Android applicationId | `com.saqia.saqia_station` |
| Firebase Android App ID | `1:1004981299919:android:5bb7d98823849b43e565ba` |
| ملف إعداد Android | `android/app/google-services.json` |

مصدر الملف هو `google-services.json` المرفوع في الفرع `docs/firebase-database-architecture`. تمت قراءة الملف والتحقق من JSON وProject ID وPackage Name، ثم نسخه إلى موضع Android الصحيح في هذا الفرع. لم يتم تعديل `main`.

## 2. ما تم تنفيذه في الكود

- أضيف `lib/firebase/station_firebase_config.dart` لتهيئة Firebase من قيم وقت البناء.
- إذا لم توجد القيم المطلوبة، يبقى Firebase غير مهيأ ويستمر التطبيق محليًا دون fallback إلى مشروع آخر.
- تم تثبيت هذا الفرع التجريبي على Project ID `manzoma-ststion` داخل طبقة الإعداد؛ أي Project ID مختلف يُرفض.
- أضيف Google Services Gradle plugin بإصدار `4.5.0` إلى `android/settings.gradle.kts` وطُبق على تطبيق Android.
- أضيف `tooling/prepare_firebase_dart_defines.py` لاستخراج قيم Firebase العامة من ملف JSON، والتحقق من وجود عميل Android واحد مطابق للحزمة، والتحقق من Project ID الخاص بالفرع. وأضيفت اختبارات Python للسكربت ضمن `tooling/test_prepare_firebase_dart_defines.py`.
- تم تحديث `.github/workflows/buildr.yml` و`.github/workflows/build-apk.yml` لتمرير إعدادات المشروع الصحيح إلى أوامر Flutter build. أضيف فرع المحطة إلى مسار بناء APK ورفع Artifact.
- أضيف اختبار لحالة عدم وجود إعدادات، واختبارات القيم الناقصة، والتهيئة الصحيحة، ورفض مشروع محطة أخرى، وStorage Bucket الاختياري.

## 3. قواعد Firestore والأمان

- أضيف `firebase.json` لربط إعداد Firebase CLI بملف `firestore.rules`.
- القواعد الحالية **deny-all**: تمنع جميع عمليات القراءة والكتابة إلى أن يكتمل نظام الهوية والصلاحيات.
- لم يتم نشر القواعد إلى Firebase Console؛ وجودها في GitHub لا يعني أنها مطبقة على المشروع السحابي.
- لم تتم إضافة Firebase Auth أو Cloud Firestore Flutter packages حتى الآن، ولم يتم تفعيل أي موفر تسجيل دخول أو إنشاء قاعدة Firestore من Console.

## 4. لماذا لم نفعل Firebase Auth بعد؟

التطبيق الحالي لا يستخدم Firebase Auth. تسجيل الدخول الإداري يعتمد جدول `app_users` ورموز JWT يصدرها خادم Shelf، وتسجيل المستفيد له مسار خادمي منفصل. لا يصح استبدال ذلك مباشرةً بـFirebase Auth أو نقل `password_hash` إلى Firestore.

قبل فتح Firestore يجب تنفيذ تصميم موثوق يربط Firebase UID بحساب التطبيق المحلي، ويثبت المحطة والدور من جهة الخادم، ويمنع المستخدم من تغيير `station_id` أو الدور بنفسه. يجب أن تكون Custom Claims أو بيانات الصلاحيات تحت تحكم الخادم فقط، مع اختبارات رفض الوصول بين المحطات والأدوار. تظل العمليات المالية الحساسة على الخادم.

## 5. المزامنة وقاعدة البيانات

- إصدار SQLite الحالي 22، وتبقى قاعدة التشغيل المحلية `saqia_station_v2.db`.
- لم يتم تغيير مخطط SQLite أو ترحيل بيانات.
- تمت مراجعة `SyncService`: يرسل `POST /sync`، بينما `ApiClient` يضيف `/api/v1`، ولم يظهر مسار `/api/v1/sync` في Router الذي تمت مراجعته.
- جدول `sync_queue` يفتقد UUID ثابتًا وIdempotency Key وبيانات إصدار/تعارض.
- لذلك لم يتم تشغيل المزامنة ولم يتم نقل أي بيانات تشغيلية أو مالية. يلزم إصلاح عقد API وتصميم Outbox آمن واختباره على بيانات اصطناعية قبل المزامنة.

## 6. تشغيل إعدادات البناء محليًا

من جذر المستودع، بعد التأكد من أن `android/app/google-services.json` خاص بالمحطة التجريبية:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release $(python3 tooling/prepare_firebase_dart_defines.py)
```

السكربت يتحقق من المشروع والحزمة ويطبع معاملات `--dart-define` المطلوبة. هذه إعدادات Firebase client العامة وليست Service Account أو مفاتيح Admin SDK. لا تُمرر أي مفاتيح خادم أو بيانات اعتماد إدارية إلى التطبيق.

## 7. حالة التحقق وحدودها

- أضيفت تغييرات Gradle وCI والاختبارات إلى الفرع وطلب السحب رقم 35.
- أُطلقت تشغيلات CI جديدة على أحدث commit. عند آخر استعلام كانت مهام Flutter Analyze وSonarCloud وBuild قيد التنفيذ؛ لا نسجل نجاحًا قبل ظهور نتيجة نهائية ناجحة.
- يجب أيضًا التأكد من تشغيل Release APK workflow وظهور Artifact قبل إعلان أن ملف APK جاهز.
- إنشاء Firebase Project وتسجيل Android App تم تأكيدهما من ملف الإعداد، لكن تفعيل Authentication وCloud Firestore ونشر القواعد يتطلبان صلاحية في Firebase Console ولم ندّع تنفيذهما.
- لم يتم تعديل أو دمج أي شيء إلى `main`.


## 8. التصميم المقترح لربط الهوية دون كسر تسجيل الدخول الحالي

النهج المقترح هو **Firebase Custom Authentication** بدل فرض بريد إلكتروني أو نقل كلمات المرور:

1. يبقى تسجيل دخول المدير الحالي (اسم المستخدم/كلمة المرور) والتحقق من رمز المستفيد عبر خادم Shelf كما هو.
2. بعد نجاح التحقق الحالي فقط، ينشئ الخادم Firebase Custom Token لمعرف UID ثابت مرتبط بنوع الحساب ومعرفه المحلي.
3. يضيف الخادم claims موثوقة مثل `stationId` و`role` و`userId`، ولا يسمح للعميل بتعيينها أو تعديلها.
4. يسجل تطبيق Flutter الدخول عبر `signInWithCustomToken`، مع إبقاء جلسة JWT الحالية ومساراتها حتى اكتمال اختبارات التوافق.
5. تبدأ قواعد Firestore بالمنع الكامل، ثم تفتح قراءات محددة فقط بناءً على claims واختبارات الدور والمحطة. لا تفتح قواعد كتابة للأرصدة أو المدفوعات أو القيود المالية.
6. تُحفظ بيانات اعتماد Firebase Admin SDK في Secret Manager/بيئة استضافة الخادم، ولا تُرفع إلى GitHub أو تُضمّن في APK.

هذا تصميم مقترح للمرحلة التالية وليس تنفيذًا قائمًا بعد؛ يتطلب اختيار استضافة الخادم وتوفير اعتماد Admin SDK بطريقة آمنة وتفعيل Firebase Authentication من Console.

