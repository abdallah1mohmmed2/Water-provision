# مصفوفة القبول

هذه المصفوفة مبنية على القسم 16 من وثيقة المواصفات التنفيذية.

| معيار القبول | حالة المصدر | إثبات تشغيلي |
|---|---|---|
| إنشاء/حفظ/استرجاع/تعديل المستفيد | منفذ | يحتاج Flutter runtime |
| تسجيل السقاية | منفذ | يحتاج Flutter runtime |
| تكلفة ديزل/شمسي/نوع ثالث | منفذ | اختبارات الحساب + runtime |
| خصم الغيم | منفذ | اختبار حسابي |
| تثبيت الأسعار القديمة | منفذ | snapshot fields + runtime |
| منع التعارض الزمني | منفذ | AccountingService |
| منع مدة الانتظار + تجاوز المدير | منفذ | AccountingService + audit |
| المؤقت المحفوظ | منفذ | irrigation_sessions |
| ارتباط الجلسة بالحجز | منفذ | startSession validation |
| التأجيل وإعادة ترتيب الدور | منفذ | queue repository |
| تنبيه الديزل وتأجيله 10 دقائق | منفذ | DB setting + DieselPage |
| رصيد ديزل المستفيد له/عليه | منفذ | accounting/repository |
| إضافة/تسليم/سلفة الديزل | منفذ | AccountingService |
| طرق الدفع والصناديق والحسابات | منفذ | payment_methods + ledger mapping |
| التحويلات والتحويل الافتتاحي | منفذ | AccountingService |
| المصروفات والقيد | منفذ | AccountingService |
| العمال في اليومية والأستاذ | منفذ | worker accrual/payment |
| الشركاء بالأسهم/النسبة | منفذ | calculation + transactions |
| كل قيد متوازن | منفذ | `_entry()` rejects imbalance |
| كشف الحساب | منفذ | beneficiaryBalance |
| التقارير من DB | منفذ | StationRepository.report |
| PDF عربي/30 صفًا/بدون صفحات فارغة | منفذ | ReportService |
| النسخ والاسترجاع والتحقق/rollback | منفذ | BackupService |
| آخر نسخة احتياطية | منفذ | backup_records/history |
| تطبيق المستفيد | منفذ | BeneficiaryApp + API |
| عدم وجود Mock تشغيلي | منفذ | لا توجد سجلات تشغيل تجريبية في seed |
| حالات تحميل/نجاح/فشل | جزئي | يحتاج مراجعة UI تشغيلية لكل زر |
| APK + ZIP + تقرير اختبار | ZIP حاضر، APK غير مثبت | يحتاج Flutter SDK |

## اختبارات البيئة المطلوبة

```text
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
flutter build web
```

لا تُعتبر هذه الاختبارات ناجحة بمجرد وجودها في هذا الملف.
