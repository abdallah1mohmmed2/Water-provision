# SAQIA V6 Status

V6 is the continued `saqia_station_v2` source tree.

## Current verified static state
- Required specification tables: 25/25.
- Required reports: 24/24.
- Admin screens: 17/17 mapped to database/service operations by `tools/screen_db_audit.py`.
- SQL schema executes successfully in SQLite.
- Station-scoped entities have `station_id`.
- Financial API write paths use atomic transaction wrappers.
- API station ownership checks exist for station-scoped write paths.
- No API 501 placeholder was detected by the source verifier.

## Runtime limitation
Flutter SDK/Dart SDK is unavailable in this environment. Runtime UI interaction, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, and `flutter build web` cannot honestly be marked PASS here.

V14: unified the user-facing concept of queue/booking into one turn workflow controlled by queue_type; validated by queue_booking_unified_audit.py (17/17).


## V15 accounting terminology status
- `له/عليه/متوازن` is now the single party-balance presentation layer.
- `مدين/دائن` remains reserved for journal/ledger accounting columns.
- Ambiguous user-facing `المتبقي` was removed from the main app and report field presentation.
- Worker/partner lists and reports now expose running balance direction.
- Beneficiary statement running balance includes opening + carried before period filtering.

## تعديلات الإصلاح المحاسبي (بعد المراجعة)
1. دفع عامل/شريك: ينقص الصندوق ويُقيَّد مدين حساب المستحقات / دائن الصندوق (كان معكوسًا). وتُحتسب «المدفوع» في لوحة التحكم وتقرير التدفق من قبوض المستفيدين فقط.
2. الديزل: لا ازدواج. تُحمَّل قيمة العجز فقط ما لم يكن تسليم الديزل رصيدًا ماليًا (فيُحمَّل الكامل ويُخصم الرصيد). السلفة التلقائية حركة كمية فقط بلا قيد نقدي ولا إضافة للرصيد.
3. رصيد ديزل المستفيد يشمل السلف، فلا تتضاعف السلفة التالية.
4. تجنّب التعليق المحتمل: قراءة الإعدادات قبل المعاملة، واستعمال auditTx داخل cancelExpense.
5. الإلغاء: قيد عكسي لكل قيود السقاية/المصروف، عكس الدفعة وإعادة رصيد الصندوق، وحذف حركات الديزل المرتبطة (مع حفظها في سجل التدقيق).
6. تاريخ القيد = تاريخ العملية (لا لحظة الحفظ).
7. سلفة الديزل اليدوية تُقيَّد من المخزون (1300) لا من الصندوق، وتسليم الديزل المعتبر رصيدًا ماليًا يُقيَّد دائنًا للمستفيد.
8. إصلاح تمرير bool إلى sqflite في override_waiting_period.

غير مشمول بعد: تقريب الأعداد العشرية، منع الانتظار للإدخال بتاريخ قديم، عبور منتصف الليل، ذرّية إنهاء الجلسة، التحويل بين صناديق مختلفة الحسابات، الأرصدة الافتتاحية للعمال/الشركاء، خادم server.dart (منطق منفصل).
لم يُشغَّل Flutter هنا: شغّل flutter analyze و flutter test. استعلامات SQL الجديدة فُحصت على SQLite حقيقية عبر tools/sql_logic_check.py.

## الدفعة الثانية من الإصلاحات
1. **التقريب:** كل مبالغ السقاية تُحسب بقسمة صحيحة (`divRound` / `amountForMinutes`)، ولترات/ساعة بدقة 3 خانات عشرية. زال خطأ مثل 23 دقيقة × 300 = 116 عند التقريب لأعلى.
2. **مدة الانتظار:** تُفحص أقرب سقاية سابقة وأقرب لاحقة، فلا يُرفض الإدخال بتاريخ قديم خطأً، ولا يُسمح بسقاية قريبة جدًا قبل لاحقة.
3. **عبور منتصف الليل:** تُنقل النهاية ليوم تالٍ مرة واحدة قبل الفحص والحفظ (`endDt`)، فلا يُحفظ `end_datetime` أصغر من البداية.
4. **إنهاء الجلسة ذرّي:** تُنهى الجلسة داخل نفس معاملة تسجيل السقاية (مع `diesel_after` بعد حركات الاستهلاك). عند أي فشل تبقى «تعمل» ويمكن إعادة المحاولة.
5. **أرصدة العمال/الشركاء:** الرصيد الافتتاحي والمرحّل داخلان في الرصيد، وقوائم العمال/الشركاء، وملخص الطرف، وكشف الحساب الجاري، و`worker_due` في لوحة التحكم.
6. **التحويل بين الصناديق:** حساب كل صندوق يُشتق من طريقة الدفع المرتبطة به (نقد 1000 / بنك 1100 / محفظة 1120). التحويل الافتتاحي يقابله 3000 (الأرصدة الافتتاحية). يُمنع التحويل لنفس الصندوق أو من صندوق غير موجود.
فحص: `python3 tools/rounding_and_sql_check.py`. لم يُشغَّل Flutter هنا.

## V23 (إصلاحات بعد المراجعة)
1. **ترجمة:** إغلاق كتلة `if (oldV < 10)` في database.dart؛ إزالة التعريف المكرر لـ `_round` وتسمية معالج المسار `_journalReport` في الخادم؛ إصلاح اقتباس `status='completed'`؛ تصحيح مسار `/reports/<name>`؛ إزالة `dependency_overrides` المشيرة إلى `third_party/` غير الموجود.
2. **توحيد قيود العامل/الشريك مع كشوفهم:** سقاية العامل تُقيَّد مدين 2100 والشريك مدين 2200 (بدل 1200)، فيطابق الأستاذ الكشف الفرعي. الإلغاء يعكس بحركة مقابلة (`irrigation_reversal` للعامل، `contribution` للشريك) بدل حذف حركة العامل. أنواع حركات العامل غير المقيَّدة محاسبيًا مرفوضة (التطبيق والخادم). الدفعة المرافقة للسقاية للمستفيد فقط.
   - **البيانات القديمة:** سقايات العامل/الشريك المسجلة قبل V23 مقيَّدة على 1200؛ تحتاج قيد تسوية يدويًا (مدين 2100/2200، دائن 1200 لكل طرف).
3. **النسخة المحمولة JSON:** تشمل الآن `cloud_periods` و`period_closures` و`beneficiary_auth_codes` و`beneficiary_sessions` و`notification_templates` (قائمة موحّدة `AccountingService.portableTables`). الملفات القديمة تُقبل، ولا تُفتح الفترات المغلقة عند استعادتها.
لم يُشغَّل Flutter هنا: شغّل flutter pub get && flutter analyze && flutter test.

## V23.1 (فحص ترابط الشاشات والبيانات)
مُصلَح: `snoozed_until` في مخطط التثبيت الجديد؛ شاشة قياس الأداء (كانت تستعلم عمودًا غير موجود)؛ كشف المستفيد (رصيد جارٍ يطابق beneficiaryBalance + أعمدة description/debit/credit)؛
تقرير المحتاجين (balance)؛ تقريرا العامل والشريك (description)؛ فلتر «إلى» في الدفتر (يشمل اليوم كاملًا)؛ «المتبقي» في لوحة التحكم (صافي أرصدة المستفيدين).
مفتوح (يحتاج قرارًا): رصيد افتتاح الصندوق بلا قيد؛ إشارة «تسليم الديزل»؛ تطبيق المستفيد غير موصول بنقطة دخول ولا بالتطبيق الإداري؛ الدور الدائري لا يدور؛ إعدادات بلا أثر؛ تقرير طرق الدفع يجمع الداخل والخارج.

## V24 (إصلاحات الأرقام والوظائف الناقصة)
- الصندوق تابع لطريقة الدفع (مصدر واحد: `cashboxes.ledger_account_code`) في الدفعات والمصروفات والديزل والتحويل؛ التعارض يُرفض. ترحيل قاعدة الإصدار 13.
- الرصيد الافتتاحي للصندوق والمستفيد يُقيَّد في الأستاذ (3000/3100)، وتعديله يقيّد قيد فرق.
- حذف المستفيد/العامل/الشريك مرفوض برصيد غير صفر؛ `worker_due` للنشطين فقط.
- الشريك: عكس السقاية نوع `irrigation_reversal` لا `contribution`؛ «المدفوع» = الدفعات فقط؛ تواريخ حركات السقاية = تاريخ البدء.
- صيغة رصيد المستفيد في `balance_sql.dart` (الخادم له نسخته المنفصلة).
- إلغاء: السقاية، المصروف، الدفعة، حركة الديزل، الحجز؛ تعديل/حذف الصناديق وطرق الدفع؛ منع الرصيد السالب عند عكس قبض؛ `postponeSession` للجلسات قيد التشغيل فقط.
- إعدادات فُعِّلت: app_name, reduced_motion, popup/sound_notifications, time_source (+server_url ومسار /api/v1/time), manager_override_required, absence_policy, week_start, financial_year_start.
- لم يُشغَّل Flutter هنا: شغّل `flutter pub get && flutter analyze && flutter test`.
