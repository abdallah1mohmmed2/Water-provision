# مرجع API لخادم ساقية

هذا المرجع يصف المسارات المسجلة حاليًا في `lib/server.dart`. هو توثيق للحالة الراهنة وليس ضمانًا لاستقرار العقد أو اكتمال صلاحيات المحطات. راجع [README الخادم](README.md) قبل التشغيل؛ فالخادم غير جاهز للنشر العام، ولا يتصل حاليًا بواجهة Flutter أو Firebase Auth.

هذا الجدول لا يصف Worker الجديد في [`worker-api/`](worker-api/README.md). ذلك Worker يوفّر حاليًا `GET /health` و`GET /api/v1/me` فقط، ويرفض عمدًا كل عمليات `/api/v1/finance/*` بـ`503`؛ لم تُنقل إليه أي عملية مالية ولم يُنشر.

المسارات تبدأ بالبادئة `/api/v1`. يستخدم الخادم JSON للمدخلات والمخرجات. في مسارات الإدارة المحمية، أرسل رمز JWT في ترويسة `Authorization: Bearer <token>`. أسماء الأدوار في هذا المرجع هي القيم البرمجية المستخدمة حاليًا: `manager` و`accountant` و`operations`.

## مسارات عامة

| الطريقة | المسار | الغرض |
|---|---|---|
| `GET` | `/api/v1/time` | إرجاع الوقت الحالي بتوقيت UTC. |
| `POST` | `/api/v1/auth/login` | دخول مستخدم إدارة موجود مسبقًا في قاعدة البيانات؛ يعيد JWT. |
| `POST` | `/api/v1/beneficiary/request-code` | إنشاء رمز مؤقت للمستفيد. لا يرسل الخادم الرمز برسالة نصية أو بريد. |
| `POST` | `/api/v1/beneficiary/session` | إنشاء جلسة مستفيد بعد تقديم الهاتف والرمز. |

مثال جسم طلب دخول الإدارة:

```json
{"username":"اسم المستخدم","password":"كلمة المرور"}
```

مثال بدء طلب رمز المستفيد:

```json
{"phone":"رقم الهاتف المسجل"}
```

لا تستخدم مسار طلب الرمز لتسجيل الدخول الفعلي قبل دمج موفر إرسال حقيقي وحماية نقاط الطلب من الإساءة. خيار `SAQIA_DEV_OTP=true` يكشف الرمز في استجابة JSON للتطوير المحلي فقط؛ التفاصيل في [README الخادم](README.md).

## مسارات الإدارة

المسارات أدناه تتطلب رمز إدارة صالحًا. أسماء الأدوار في عمود الصلاحية هي الأدوار المسموح بها كما قُيدت عند تسجيل المسار.

| الطريقة | المسار | الأدوار المسموح بها |
|---|---|---|
| `GET` | `/api/v1/dashboard` | مدير، محاسب، تشغيل |
| `GET` | `/api/v1/settings` | مدير، محاسب |
| `PUT` | `/api/v1/settings` | مدير |
| `GET` | `/api/v1/beneficiaries` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/beneficiaries` | مدير، محاسب |
| `GET` | `/api/v1/beneficiaries/<id>` | مدير، محاسب، تشغيل |
| `PUT` | `/api/v1/beneficiaries/<id>` | مدير، محاسب |
| `DELETE` | `/api/v1/beneficiaries/<id>` | مدير، محاسب |
| `GET` | `/api/v1/beneficiaries/<id>/statement` | مدير، محاسب، تشغيل |
| `GET` | `/api/v1/irrigations` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/irrigations` | مدير، محاسب |
| `POST` | `/api/v1/irrigations/<id>/cancel` | مدير، محاسب |
| `GET` | `/api/v1/sessions` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/sessions/start` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/sessions/<id>/finish` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/sessions/<id>/postpone` | مدير، محاسب، تشغيل |
| `GET` | `/api/v1/queue` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/queue` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/queue/<id>/postpone` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/queue/<id>/skip` | مدير |
| `GET` | `/api/v1/bookings` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/bookings/<id>/schedule` | مدير، محاسب |
| `POST` | `/api/v1/bookings/<id>/cancel` | مدير، محاسب |
| `GET` | `/api/v1/payments` | مدير، محاسب |
| `POST` | `/api/v1/payments` | مدير، محاسب |
| `GET` | `/api/v1/cashboxes` | مدير، محاسب |
| `POST` | `/api/v1/cashbox-transfers` | مدير، محاسب |
| `GET` | `/api/v1/diesel` | مدير، محاسب، تشغيل |
| `POST` | `/api/v1/diesel/movements` | مدير، محاسب |
| `GET` | `/api/v1/expenses` | مدير، محاسب |
| `POST` | `/api/v1/expenses` | مدير، محاسب |
| `GET` | `/api/v1/workers` | مدير، محاسب |
| `POST` | `/api/v1/workers` | مدير، محاسب |
| `POST` | `/api/v1/workers/<id>/transactions` | مدير، محاسب |
| `GET` | `/api/v1/partners` | مدير، محاسب |
| `POST` | `/api/v1/partners` | مدير، محاسب |
| `POST` | `/api/v1/partners/<id>/transactions` | مدير، محاسب |
| `GET` | `/api/v1/accounting/journal` | مدير، محاسب |
| `GET` | `/api/v1/accounting/ledger` | مدير، محاسب |
| `GET` | `/api/v1/reports/<name>` | مدير، محاسب |
| `POST` | `/api/v1/backup` | مدير |
| `POST` | `/api/v1/restore` | مدير |

## مسارات المستفيد بعد تسجيل الدخول

تتطلب هذه المسارات رمز مستفيد صادرًا من `/api/v1/beneficiary/session`. يتحقق الخادم أيضًا من سجل الجلسة المخزن في SQLite ومن وقت انتهائها.

| الطريقة | المسار | الغرض |
|---|---|---|
| `GET` | `/api/v1/beneficiary/me` | بيانات حساب المستفيد. |
| `GET` | `/api/v1/beneficiary/requests` | قائمة طلباته. |
| `POST` | `/api/v1/beneficiary/requests` | إنشاء طلب حجز/خدمة. |
| `POST` | `/api/v1/beneficiary/requests/<id>/cancel` | إلغاء طلبه وفق الحالات التي يسمح بها التنفيذ. |
| `GET` | `/api/v1/beneficiary/account` | ملخص حساب المستفيد. |
| `GET` | `/api/v1/beneficiary/notifications` | إشعاراته. |
| `POST` | `/api/v1/beneficiary/notifications/<id>/read` | تعليم إشعار كمقروء. |

## حدود هذا المرجع

يوضح الجدول الطريقة والمسار وقيد الدور فقط. لا يحدد مخططًا كاملًا ومستقرًا لكل حقل في أجسام الطلبات، ولا يضمن صحة النتائج المحاسبية أو عزل كل سجل بحسب المحطة. بعض عمليات التحقق موجود داخل معالجات `server.dart`، واختبارات الخادم الحالية لا تغطي جميع المسارات أو الصلاحيات.

لا توجد هنا مسارات لإدارة محطات Firebase أو عضوياتها. ولا توجد مصادقة مستقلة للعامل أو الشريك. قبل ربط أي عميل بهذا API، يلزم تدقيق صلاحية كل عملية واستعلام، وتوثيق مخططات الطلبات والاستجابات، ثم إضافة اختبارات تكافؤ وتكامل مناسبة.
