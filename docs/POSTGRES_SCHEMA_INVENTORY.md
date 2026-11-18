# جرد مخطط البيانات قبل ترحيل PostgreSQL

- الفرع: `feature/firebase-station-foundation`
- تاريخ الجرد: 8 نوفمبر 2026
- مصدر مخطط تطبيق المحطة: `assets/db/001_initial.sql` مع ترقيات `lib/data/local/database.dart` حتى `version: 28`.
- مصدر مخطط الخادم: `server/lib/server.dart`؛ الخادم لا يملك حالياً migrations مستقلة كاملة لمخطط الأعمال.

## نتيجة الجرد التنفيذي

1. قاعدة تطبيق المحطة SQLite بإصدار مخطط 28.
2. نقطة تشغيل الخادم تفتح ملف SQLite عبر `SAQIA_DB`.
3. مُنشئ `SaqiaServer` ينشئ جداول `auth_rate_limits` و`sync_entity_versions` و`sync_event_log`، ويجري بعض ترقيات ملكية المحطة على الجداول الموجودة إذا وجدها.
4. الخادم لا ينشئ كامل مخطط الأعمال بنفسه؛ فهو يفترض وجود جداول مثل `stations` و`app_users` و`beneficiaries` و`irrigations` والحسابات والقيود.
5. لهذا لا يجوز بناء PostgreSQL migration من `001_initial.sql` وحده: فهو لا يتضمن وحده كل تغييرات الإصدارات 2–28 ولا كل جداول المساعدة والمزامنة التي تُنشأ لاحقاً.
6. لا توجد حالياً عملية موثقة ومختبرة تنقل كل بيانات SQLite المحلية إلى قاعدة خادم مركزية كاملة.

## جداول الأعمال الأساسية

### المحطات والهوية
- `stations`
- `app_users`
- `settings`
- `station_settings`

### التشغيل والسقايات
- `pumps`
- `beneficiaries`
- `workers`
- `partners`
- `queue_entries`
- `booking_requests`
- `irrigation_sessions`
- `irrigations`
- `cloud_periods`

### الأموال والحسابات
- `payment_methods`
- `cashboxes`
- `cashbox_transfers`
- `payments`
- `expenses`
- `worker_transactions`
- `partner_transactions`
- `diesel_movements`
- `accounts`
- `journal_entries`
- `journal_lines`
- `general_accounts`
- `general_account_transactions`
- `beneficiary_manual_debts`
- `accountant_reconciliation_months`
- `period_closures`
- `cash_reconciliations`

### المصادقة والإشعارات والتشغيل
- `beneficiary_auth_codes`
- `beneficiary_sessions`
- `notifications`
- `notification_templates`
- `report_runs`
- `performance_metrics`
- `backup_records`
- `audit_logs`
- `auth_rate_limits`

### المزامنة والتدقيق
- `sync_queue`
- `sync_change_log`
- `sync_metadata`
- `sync_inbox`
- `sync_entity_versions`
- `sync_event_log`

> ملاحظة: `irrigations_new` اسم جدول مؤقت مستخدم في ترقية تاريخية لإعادة بناء جدول السقايات، وليس جدول أعمال مطلوباً في المخطط النهائي.

## فروقات SQLite التي يجب حسمها في تحويل PostgreSQL

| استخدام SQLite الحالي | قرار التحويل المطلوب |
|---|---|
| `INTEGER PRIMARY KEY` | هوية PostgreSQL صريحة ومتوافقة مع المراجع |
| `lastInsertRowId` | `INSERT ... RETURNING id` |
| `BEGIN IMMEDIATE` | معاملات PostgreSQL مع أقفال/عزل مناسبين |
| `PRAGMA table_info` و`sqlite_master` | جدول migrations وفحص معلومات المخطط القياسي |
| `INSERT OR IGNORE` | `ON CONFLICT DO NOTHING` |
| `INSERT OR REPLACE` إن وجد | تحديد دلالته ثم تحويله بعناية؛ لا يستبدل آلياً |
| `REAL` للمبالغ/النسب | استخدام `NUMERIC` عند الحاجة إلى دقة مالية وعدم تقريب القيم |
| `CHECK` و`UNIQUE` وForeign Keys | نقلها مع اختبارها على PostgreSQL |
| `station_id` | تضمينه في كل مسارات الملكية والقيود والفهارس، واختبار منع العبور بين المحطات |

## تسلسل العمل بعد هذا الجرد

1. تثبيت نسخة مرجعية موحدة من مخطط SQLite 28، تشمل كل ترقيات التطبيق وجداول المساعدة وTriggers المزامنة.
2. استخراج PostgreSQL schema migrations بإصدارات واضحة، لا بإنشاء جداول ضمن constructor الخادم.
3. بناء طبقة وصول بيانات قابلة للاختبار، وفصل SQL الخاص بـSQLite عن منطق HTTP/المجال.
4. نقل وحدات صغيرة إلى PostgreSQL واختبارها، بدءاً من الهوية والمحطة ثم المزامنة، وبعدها وحدات الأعمال والمالية.
5. تنفيذ أداة ترحيل بيانات ذات dry-run وتقرير counts/checksums ومجاميع مالية، دون تعديل المصدر.
6. اختبار PostgreSQL في CI وعزل محطتين وإعادة المحاولة والتعارضات واستعادة النسخ الاحتياطية.

## حدود هذا الجرد

هذا جرد ساكن من ملفات المصدر، وليس فحصاً لقاعدة بيانات إنتاجية حية. يجب لاحقاً تشغيل فاحص مخطط على نسخة فعلية من قاعدة المحطة ومقارنة الأعمدة والفهارس والقيود والـTriggers قبل ترحيل أي بيانات. لم يتم إنشاء قاعدة PostgreSQL أو نقل أي بيانات في هذه الخطوة.


## أداة فحص قاعدة فعلية قبل الترحيل

أضيفت أداة قراءة فقط: `server/bin/inspect_schema.dart`.

تشغيلها من مجلد `server`:

```bash
dart pub get
dart run bin/inspect_schema.dart /path/to/saqia_station_v2.db
```

تُخرج JSON يحتوي إصدار SQLite، والجداول، وSQL الإنشاء، والأعمدة، والمفاتيح الأجنبية، والفهارس، والمشغلات. لا تقرأ صفوف الأعمال ولا تعدّل ملف القاعدة؛ وتفتح الملف بوضع القراءة فقط. يجب تشغيلها على **نسخة** من قاعدة المحطة، ثم مراجعة الناتج قبل كتابة PostgreSQL migrations. لا ترفع ملف قاعدة المحطة أو ناتجاً يتضمن بيانات حساسة إلى مستودع عام.


## نتائج فحص نسخة قاعدة فعلية — 8 نوفمبر 2026

تم استلام نسخة قاعدة المحطة باسم `نسخة_المنظومة_2026-11-08_08-37-10.db` وفحصها محلياً بوضع SQLite للقراءة فقط. لم تُقرأ صفوف الأعمال ولم يُعدّل الملف ولم يُرفع إلى المستودع.

### نتائج التحقق

- `PRAGMA user_version`: القيمة **28**، مطابقة لإصدار `AppDatabase` الحالي.
- `PRAGMA integrity_check`: النتيجة `ok`.
- `PRAGMA foreign_key_check`: لم يُرجع مخالفات.
- حجم الملف: 401,408 بايت.
- كائنات المخطط: **46 جدولاً** (بما فيها `android_metadata`)، و**17 فهرساً صريحاً**، و**78 Trigger**.
- توجد Triggers تسجيل مزامنة على 26 جدولاً؛ ولا يعني غيابها عن الجداول الأخرى أنها يجب أن تُضاف تلقائياً، بل يلزم تحديد سياسة المزامنة لكل جدول.

### الجداول الموجودة فعلياً

`accountant_reconciliation_months`, `accounts`, `android_metadata`, `app_users`, `audit_logs`, `backup_records`, `beneficiaries`, `beneficiary_auth_codes`, `beneficiary_manual_debts`, `beneficiary_sessions`, `booking_requests`, `cash_reconciliations`, `cashbox_transfers`, `cashboxes`, `cloud_periods`, `diesel_movements`, `expenses`, `general_account_transactions`, `general_accounts`, `irrigation_sessions`, `irrigations`, `journal_entries`, `journal_lines`, `notification_templates`, `notifications`, `partner_transactions`, `partners`, `payment_methods`, `payments`, `performance_metrics`, `period_closures`, `pumps`, `queue_entries`, `report_runs`, `settings`, `station_settings`, `stations`, `sync_change_log`, `sync_entity_versions`, `sync_global_identities`, `sync_global_relations`, `sync_inbox`, `sync_metadata`, `sync_queue`, `worker_transactions`, `workers`.

### فروقات يجب استكمالها قبل PostgreSQL DDL

1. الجدولان `auth_rate_limits` و`sync_event_log` اللذان ينشئهما الخادم غير موجودين في نسخة تطبيق المحطة هذه؛ يجب إدراجهما ضمن مخطط الخادم المركزي من تعريفاتهما الفعلية في كود الخادم، لا افتراض وجودهما في قاعدة التطبيق.
2. النسخة تحتوي جداول هوية عالمية وعلاقات ومزامنة (`sync_global_identities`, `sync_global_relations`, `sync_inbox`, `sync_queue`) لم تكن مفصلة كلها في قائمة الجداول الأولية؛ يجب أن تدخل في المرجع النهائي مع تحديد ما هو محلي وما هو مركزي.
3. يوجد 78 Trigger، ويجب مراجعة SQL لكل واحد وتحديد ما إذا كان منطق مزامنة SQLite سيبقى على الجهاز فقط أم سيعاد تمثيله كقيود/منطق PostgreSQL. لا تُنقل Triggers حرفياً.
4. نتيجة فحص المفاتيح الأجنبية خالية من المخالفات في هذه النسخة، لكن يلزم كذلك فحص القيود المنطقية، وملكية `station_id`، والمراجع المتقاطعة بين المحطات قبل أي استيراد.
5. هذا الفحص يثبت بنية هذه النسخة فقط؛ لا يثبت أنها أحدث نسخة تشغيلية على كل جهاز أو أنها تحتوي كل بيانات المحطة.

### القرار التالي

اعتماد هذه النسخة كمرجع بنيوي أولي لمخطط SQLite v28، ثم إكمال استخراج SQL التفصيلي للجداول والفهارس والقيود وTriggers ومقارنته بمصدر التطبيق والخادم. بعد ذلك فقط تُكتب PostgreSQL migrations إصداريّة مع اختبارات، دون تنفيذ نقل بيانات حقيقي في هذه المرحلة.
