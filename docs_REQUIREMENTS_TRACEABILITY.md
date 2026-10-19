# مصفوفة تتبع المواصفات التنفيذية

المرجع الوحيد للمتطلبات هو: **المواصفات التنفيذية الشاملة لبناء نظام إدارة محطة ومضخة الري**.

هذه المصفوفة تربط كل مجموعة رئيسية بمصدر التنفيذ. وجود المسار هنا يعني أن التنفيذ موجود في المصدر، أما نجاحه التشغيلي النهائي فيتطلب تشغيل Flutter SDK وإجراء اختبارات القبول المذكورة في الوثيقة.

| متطلب الوثيقة | مصدر التنفيذ |
|---|---|
| Flutter/Dart والمنصات | `pubspec.yaml`, `lib/` |
| SQLite محلي + Web adapter | `lib/data/local/database.dart`, `pubspec.yaml` |
| migrations | `lib/data/local/database.dart` versions 2-5 |
| 25 جدولًا أساسيًا | `assets/db/001_initial.sql` |
| المستخدمون والصلاحيات | `lib/core/permissions.dart`, `lib/services/admin_service.dart` |
| سجل التدقيق | `lib/data/local/database.dart` |
| الإعدادات العامة | `lib/data/local/database.dart`, `lib/features/app.dart` |
| أنواع Diesel / Solar / Equivalent | `calculations.dart`, `accounting_service.dart`, `pumps`, `settings` |
| تثبيت الأسعار التاريخية | `irrigations.*_snapshot`, `accounting_service.dart` |
| خصم الغيم | `calculations.dart`, `recordIrrigation()` |
| له / عليه | `calculations.dart`, `beneficiaryBalance()`, الواجهات |
| السقاية | `recordIrrigation()`, `IrrigationsPage` |
| منع التعارض الزمني | `recordIrrigation()` |
| منع مدة الانتظار | `_checkWaiting()` |
| تجاوز المدير مع السبب والتدقيق | `_checkWaiting()`, `auditTx()` |
| جلسة السقي | `StationRepository.startSession/stopSession` |
| المؤقت المحفوظ | `irrigation_sessions.timer_started_at/timer_stopped_at`, `SessionsPage` |
| الطابور الدائري | `queue_entries`, `enqueue/rotateCircularQueue` |
| وضع الحجز | `booking_requests`, `startSession`, `QueueBookingPage` |
| التأجيل بسبب | `postponeQueue`, `postponeSession` |
| الديزل والمخزون | `diesel_movements`, `addDieselMovement()` |
| السلفة التلقائية للديزل | `recordIrrigation()` |
| رصيد ديزل المستفيد | `diesel_movements`, repository queries |
| التحويلات والصناديق | `transferCash()` |
| التحويل الافتتاحي | `transferCash(opening:true)` |
| المدفوعات | `_paymentInTx`, `receivePayment` |
| العامل ثابت/ساعة/نسبة | `workers`, `workerDue`, `workerTransaction` |
| استحقاق العامل وقيده | `createWorkerAccrual()` |
| الشريك أسهم/نسبة | `partners`, `partnerShare`, `createPartnerShare` |
| فصل الشريك عن استخدامه كمستفيد | جداول `partners` و`beneficiaries` المنفصلة |
| دفتر اليومية | `_entry()`, `journal()` |
| الأستاذ العام | `ledger()` |
| منع القيد غير المتوازن | `_entry()` |
| المصروفات وقيدها | `addExpense()` |
| النسخ الاحتياطي | `BackupService.createDatabaseBackup()` |
| فحص ملف الاستعادة | `validateDatabaseFile()` |
| rollback عند فشل الاستعادة | `BackupService.pickAndRestoreDatabase()` |
| سجل النسخ والاستعادة | `backup_records` |
| قوالب الإشعارات | `notification_service.dart`, settings |
| الإشعارات المحلية | `notifications`, `NotificationService` |
| Offline-first / Sync queue | `sync_service.dart`, `sync_queue` |
| تطبيق المستفيد | `features/beneficiary_app.dart` |
| رمز الهاتف السداسي | `api/auth_service.dart`, server auth |
| طلب الحجز من المستفيد | `BeneficiaryApi`, server endpoint |
| كشف حساب المستفيد | `BeneficiaryApi`, repository/server |
| API `/api/v1` | `server/lib/server.dart`, `lib/api/api_client.dart` |
| JWT | `server/lib/server.dart` |
| عزل جلسة المستفيد | `beneficiary_sessions`, JWT beneficiaryId |
| تقارير DB-backed | `StationRepository.report()` |
| تقارير PDF عربية RTL | `ReportService` |
| 30 صفًا افتراضيًا | `ReportService.pageRows` |
| منع الصفحات الفارغة | `ReportService` |
| التدفق النقدي | `report('cash_flow')` |
| المقارنة الزمنية | `report('time_comparison')` |
| المالي الشهري | `report('monthly_financial')` |
| الدخل | `report('income')` |
| طرق الدفع والحسابات | `report('payment_methods')` |
| المصروفات | `report('expenses')` |
| الصناديق والتحويلات | `report('cashboxes')` |
| الطابور والحجز | `report('queue_bookings')` |
| سجل المدفوعات | `report('payment_log')` |
| كشف المستفيد | `report('beneficiary_statement')` |
| كشف مفصل | `report('beneficiary_detailed')` |
| إحصاءات المستفيد | `report('beneficiary_stats')` |
| المساكين | `report('needy')` |
| مخزون الديزل | `report('diesel_inventory')` |
| النشاط | `report('activity_overview')` |
| الزيت | `report('oil_status')` |
| المديونيات | `report('debts')` |
| قائمة الرعية | `report('beneficiary_list')` |
| مقارنة الإيرادات | `report('revenue_comparison')` |
| مقارنة المنظومات | `report('system_comparison')` |
| اليومية | `report('journal')` |
| الأستاذ | `report('ledger')` |
| معاملات العمال | `report('worker_transactions')` |
| حسابات الشركاء | `report('partner_accounts')` |
| فلاتر التاريخ والمنظومة والطرف | `StationRepository.report`, `ReportsPage` |
| تقارير كل الأنواع مع فصل الأنظمة | `system_comparison`, `income`, `activity_overview` |
| الأداء وقياسات التقارير | `report_runs`, `performance_metrics` |
| اختبارات الحسابات | `test/calculations_test.dart` |
| اختبارات الصلاحيات | `test/permissions_test.dart` |
| التحقق من schema | `assets/db/001_initial.sql` + فحص SQLite |

## ما يجب إثباته في بيئة Flutter قبل ختم 100%

1. `flutter pub get`
2. `flutter analyze`
3. `flutter test`
4. `flutter build apk --debug`
5. `flutter build apk --release`
6. `flutter build web`
7. اختبار يدوي لكل معيار قبول في الفصل 16 من الوثيقة.

لا تعتبر هذه الأوامر منفذة لمجرد وجودها في الوثائق. يجب تشغيلها فعليًا على بيئة تحتوي Flutter SDK.
