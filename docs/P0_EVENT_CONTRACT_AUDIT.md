# تدقيق عقد أحداث المزامنة P0 — خط الأساس الفعلي

- المستودع: `abdallah1mohmmed2/Water-provision`
- الفرع: `feature/firebase-station-foundation`
- تاريخ التدقيق: 2026-11-08
- نطاق هذه الوثيقة: تتبع Outbox/Inbox وأوامر الأعمال والآثار التابعة فقط. لا تنفذ P1 أو P2 أو P3.

## 1. الملفات والإصدارات التي تمت مراجعتها

تمت مراجعة النسخ الحالية على الفرع من:
- `lib/data/local/database.dart`
- `lib/services/sync_service.dart`
- `lib/services/sync_inbox_applier.dart`
- `lib/services/sync_coordinator.dart`
- `lib/domain/accounting/accounting_service.dart`
- `server/lib/server.dart`
- `test/sync_inbox_applier_test.dart`
- `test/accounting_integration_test.dart`
- `docs/ARCHITECTURE_DECISION_SHELF_OFFLINE_FIRST.md`
- `docs/SYNC_ACCOUNTING_READINESS_AND_WORK_LEDGER.md`

رأس الفرع الذي تمت مراجعته: `616a14d8074676e7c3bdbda00173bd821d9040fc`.
هذا الرأس يضيف `google-services.json` فقط؛ لم يظهر فيه تنفيذ أحدث لإغلاق P0. كما أن ملف القرار المعماري يحتوي وصفاً تاريخياً قديماً يقول إن مسار المزامنة غير موجود، بينما Router الحالي يحتوي مساري sync الفعليين؛ يلزم تصحيح هذا الوصف ضمن تحديث توثيق المعمارية بعد إغلاق عقد P0، لا تغيير المعمارية المعتمدة.

## 2. تدفق الالتقاط الحالي

1. `AppDatabase._ensureSyncSchema` ينشئ triggers على مجموعة واسعة تشمل:
   `irrigations`, `cloud_periods`, `diesel_movements`, `payments`, `expenses`,
   `worker_transactions`, `partner_transactions`, `journal_entries`, `journal_lines`,
   `queue_entries`, `booking_requests`, `irrigation_sessions`، وغيرها.
2. `AppDatabase.transaction` يقرأ كل صفوف `sync_change_log` ثم ينشئ Outbox لكل صف، إلا إذا استُخدم `captureSyncTables` صراحة.
3. `SyncService.push` يرسل كل صفوف pending/sending كأحداث منفصلة إلى `POST /api/v1/sync/events`.
4. الخادم ينفذ `_applySyncBusinessEvent` لكل نوع، ويستخدم SAVEPOINT لكل حدث. أي نوع بلا معالج فعلي يُرفض مع rollback لذلك الحدث.
5. `GET /api/v1/sync/inbox` يعيد أحداث الأعمال المقبولة المسجلة في `sync_event_log` فقط.
6. `SyncService.applyInbox` يطبق الحدث الأصلي داخل معاملة محلية مع `captureSync: false`، ثم يحدّث النسخة المحلية.

## 3. فجوات مثبتة بالكود

### P0-A — إرسال الآثار المحاسبية التابعة كأوامر مستقلة

- triggers تلتقط `journal_entries` و`journal_lines`، لكن `_applySyncBusinessEvent` لا يحتوي معالج أعمال لهذين النوعين؛ يصلان إلى رفض «معالج المزامنة لهذا المجال غير منفذ بعد».
- القيود والأسطر تُنشأ محلياً داخل عمليات أعمال مثل السقاية والقبض والمصروف والتحويل، كما ينشئها الخادم داخل معالجات الأوامر الأصلية. لذلك لا يجوز أن تكون أوامر مستقلة.
- `SyncInboxApplier` يحتوي منطق تطبيق journal rows الواردة، لكنه لا يجعلها أوامر مقبولة في الخادم ولا ينشئ الخادم أحداث Inbox مستقلة لها.

**القرار المطلوب:** القيد وسطر القيد إسقاطان/آثار مشتقة، لا أوامر Outbox مستقلة. يجب أن ينشئهما معالج أمر الأعمال على الخادم، وأن تصل نسخة الأثر للأجهزة الأخرى عبر آلية إسقاط موثوقة ومحددة، لا عبر إعادة إرسال قيود العميل كأوامر.

### P0-B — السقاية تنتج أحداثاً تابعة زائدة

`AccountingService.recordIrrigation` يكتب داخل معاملة واحدة:
- `irrigations` (أمر الأعمال الأصلي).
- `cloud_periods` (تفاصيل مضمّنة أيضاً في payload السقاية بواسطة `SyncService.push`).
- `journal_entries` و`journal_lines`.
- `worker_transactions` و`partner_transactions` للاستحقاقات/الخصومات.
- `diesel_movements` المرتبطة بـ `irrigation_id`.
- وقد يحدّث `irrigation_sessions` و`queue_entries` و`booking_requests`.
- وقد ينشئ `payments` مستقلاً عندما يكون `paidAmount > 0`.

في المقابل، `server._applySyncIrrigation` يعيد إنشاء فترات الغيم والقيود والحركات التابعة، ويعالج روابط الجلسة/الطابور/الحجز من أمر السقاية. لذلك إرسال هذه الصفوف أيضاً كأحداث منفصلة يسبب رفضاً أو تكراراً أو تعارض ترتيب.

**فجوة إضافية:** صف السقاية المحلي يحمل `paid_amount`، بينما معالج الخادم يرفض أي قيمة غير صفرية ويشترط إرسال القبض كحدث مستقل. يجب أن يظل حدث السقاية بقيمة `paid_amount=0` على الخادم، وأن يرسل قبض المستفيد كحدث `payments` مستقل فقط عندما يوجد قبض فعلي. لا تُضمّن دفعة العامل/الشريك في هذا المسار.

### P0-C — عدم اكتمال إسقاط الآثار إلى Inbox

الخادم يسجل الحدث الأصلي المقبول في `sync_event_log` ثم يعيده إلى الأجهزة الأخرى. `SyncInboxApplier` يطبق صف السقاية/الأمر الأصلي، لكنه لا يعيد تنفيذ المعالجة المحاسبية المركبة التي أجراها الخادم. لذلك يجب أن يحدد عقد P0 كيف تصل إلى الأجهزة الأخرى الآثار التي أنشأها الخادم (القيود، حركات الأطراف، حركات الديزل، الصندوق، وفترات الغيم) مع هويات وروابط عالمية ثابتة، أو أن تُقرأ هذه البيانات من API مركزي بدلاً من افتراض أنها ستظهر محلياً تلقائياً.

**هذه فجوة مانعة لإعلان P0 مكتملاً.** لا يكفي حذف أحداث الآثار التابعة من Outbox؛ يجب إثبات أن الأجهزة الأخرى تحصل على نفس الإسقاط المحاسبي والتشغيلي.

### P0-D — أنواع أخرى لا تملك معالجات أعمال مكتملة

- `worker_transactions` و`partner_transactions` يوجهان إلى `_applySyncPartyOpeningDebt`، وهذا يقبل فقط `type=opening_balance` و`reference_type=previous_debt`. لا يمثل هذا دعماً لدفعات العامل/الشريك أو استحقاقاتهما.
- معالج `payments` الحالي مخصص لقبض المستفيد فقط ويرفض حمولة دفع العامل أو الشريك.
- `general_accounts`, `general_account_transactions`, `accountant_reconciliation_months`, `period_closures`, `cash_reconciliations` موجودة في قائمة الأنواع، لكن لا يظهر لها فرع أعمال فعلي في dispatcher الحالي؛ يجب أن تبقى ضمن P5/P6، ولا تُخلط مع إغلاق P0.
- `cloud_periods` لها معالج مستقل، لكن عند إنشائها كجزء من السقاية يعيد معالج السقاية إنشاءها أيضاً؛ يجب ألا ترسل كأمر مستقل في مسار السقاية.

## 4. مصفوفة أوامر الأعمال والآثار — الوضع الحالي

| أمر العمل | تغييرات العميل المحلية | ما ينشئه الخادم من الأمر الأصلي | السياسة الصحيحة المقترحة |
|---|---|---|---|
| إنشاء سقاية مستفيد | irrigation + cloud periods + journals + worker/partner transactions + irrigation-linked diesel + session/queue/booking updates + optional payment | irrigation + cloud periods + journals + worker/partner accruals + diesel + related operational state | أرسل irrigation فقط، وأرسل payment كأمر مستقل عند وجود قبض؛ لا ترسل الآثار التابعة |
| قبض مستفيد | payment + cashbox balance + journal entry/lines + notification | payment + cashbox balance + journal entry/lines | أرسل payments فقط؛ هذا مطبق بالفعل في `receivePayment` |
| مصروف | expense + cashbox balance + journal entry/lines | expense + cashbox balance + journal entry/lines | أرسل expenses فقط؛ تحقق من مواضع الاستدعاء قبل تعديلها |
| تحويل صندوق | cashbox_transfer + source/destination balances + journal entry/lines | cashbox_transfer + balances + journal entry/lines | أرسل cashbox_transfers فقط؛ تحقق من مواضع الاستدعاء |
| حركة ديزل مستقلة | diesel_movement + أثر مخزون/قيد بحسب النوع | diesel_movement + أثر مخزون/قيد | أرسل diesel_movements المستقلة |
| حركة ديزل ناتجة من سقاية | diesel_movement مع irrigation_id | ينشئها معالج السقاية | لا ترسلها مستقلة |
| مديونية افتتاحية عامل/شريك | worker/partner_transaction + journal rows | transaction + journal rows | أرسل سجل المديونية فقط؛ المعالج الحالي يدعم هذا النوع فقط |

هذه المصفوفة أولية وتحتاج اختبار كل مسار إنشاء فعلي قبل اعتماد السياسات النهائية. لا تعني أن كل العمليات المذكورة مدعومة حالياً.

## 5. شروط الإغلاق قبل P1

- [ ] تحديد allowlist لكل أمر عمل مركب في موضع المعاملة، لا بالاعتماد على قائمة triggers العامة.
- [ ] عدم إرسال journal_entries/journal_lines كأوامر مستقلة.
- [ ] السقاية: عدم إرسال cloud_periods أو diesel_movements المرتبطة بها أو قيودها أو استحقاقاتها التابعة؛ وعدم تكرار تحديث الجلسة/الطابور/الحجز الذي يعالجه معالج السقاية.
- [ ] فصل قبض المستفيد المرافق للسقاية كحدث payments مستقل، مع عدم تمرير paid_amount غير صفري إلى معالج السقاية.
- [ ] وضع آلية صريحة لإسقاط آثار الخادم إلى Inbox الأجهزة الأخرى، بهويات وروابط ثابتة ومنع echo عبر Outbox.
- [ ] الإبقاء على الأحداث المستقلة (مثل حركة ديزل مستقلة ومديونية افتتاحية) وعدم إسقاطها بسبب تشابه الجدول.
- [ ] معالجة/تسوية صفوف Outbox القديمة التابعة التي أنشئت قبل سياسة الالتقاط الجديدة، دون حذف سجل مالي أو إخفاء فشلها.
- [ ] اختبارات Outbox تثبت مجموعة الأحداث المتوقعة لكل عملية.
- [ ] اختبارات خادم تثبت قبول الأمر الأصلي مرة واحدة وعدم إنشاء أثر مزدوج.
- [ ] اختبارات Inbox تثبت وصول الأثر نفسه إلى عميل ثانٍ دون echo أو مضاعفة.
- [ ] اختبار rollback/retry وعزل المحطات.
- [ ] تشغيل Flutter Analyze وFlutter tests وServer tests وCI على HEAD النهائي.

## 6. ما لم يتغير في هذا التدقيق

- لم تُعد كتابة Outbox/Inbox.
- لم تتغير سياسة المعمارية: Shelf API + JWT + SQLite Offline-First.
- لم يتم تنفيذ P1 أو P2 أو P3 أو P4 أو P5 أو P6.
- لم يتم تعديل بيانات مالية أو حذف أي سجل.
- هذا التدقيق قراءة كود فقط؛ لا توجد نتائج تشغيل اختبارات ضمنه.
