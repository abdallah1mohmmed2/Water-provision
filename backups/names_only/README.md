# نسخة أسماء فقط قابلة لإعادة الإنشاء

تحتوي هذه الحزمة على الأسماء فقط، مفصولة حسب الفئة في ثلاثة جداول:

- `beneficiaries`: 50 اسمًا
- `partners`: 5 أسماء
- `workers`: اسم واحد

لكل جدول عمود واحد فقط هو `name`. لا تتضمن الحزمة أرقام الهواتف أو العناوين أو الأرصدة أو المعاملات أو أي بيانات تشغيلية أخرى.

## الملفات

- `names_only_restore.db`: قاعدة SQLite جاهزة للفتح والاستعلام.
- `names_only_restore.sql`: مخطط البيانات والأسماء لإعادة بناء ملف SQLite عند الحاجة.

## إعادة الإنشاء

باستخدام أداة `sqlite3`، شغّل الأمر التالي داخل هذا المجلد لإنشاء ملف جديد:

```sh
sqlite3 names_only_recovered.db < names_only_restore.sql
```

ويُستحسن إنشاء الملف باسم جديد وعدم تمرير ملف قاعدة بيانات قائم حتى لا تتعارض الجداول.

## التحقق

```sh
sqlite3 names_only_recovered.db "PRAGMA integrity_check;"
sqlite3 names_only_recovered.db "SELECT 'beneficiaries', COUNT(*) FROM beneficiaries UNION ALL SELECT 'partners', COUNT(*) FROM partners UNION ALL SELECT 'workers', COUNT(*) FROM workers;"
```

## تنبيه مهم

هذه قاعدة مستقلة مختصرة للأسماء فقط، وليست نسخة كاملة من قاعدة تطبيق ساقية. لا تستخدمها في خيار استعادة النسخة الكاملة داخل التطبيق؛ فذلك الخيار يتطلب جداول وبيانات النظام الأخرى. يمكن استخدامها كنسخة أسماء منفصلة أو مصدر لاستيراد الأسماء يدويًا.
