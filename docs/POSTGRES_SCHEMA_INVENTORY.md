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
