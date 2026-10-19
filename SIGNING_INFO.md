# معلومات توقيع Android

هذه النسخة هي المصدر الذي بُني منه آخر APK.

## نوع التوقيع الحالي

الإصدار الحالي يستخدم توقيع Android Debug الافتراضي لأن المشروع لا يحتوي على مفتاح Release خاص أو ملف `key.properties`:

```text
signingConfig = signingConfigs.getByName("debug")
```

## بيانات المفتاح المرفق

- الملف: `android/signing/debug.keystore`
- Alias: `androiddebugkey`
- كلمة مخزن المفاتيح: `android`
- نوع الإدخال: `PrivateKeyEntry`
- الخوارزمية: `SHA256withRSA`
- SHA-1: `DB:52:42:08:43:A1:90:5F:14:BA:06:45:94:72:8E:B8:0D:55:80:F0`
- SHA-256: `66:75:7F:99:E2:67:59:82:93:A9:67:63:99:91:12:FB:E9:91:00:F7:DF:20:6D:2A:B3:36:7B:2E:DA:14:5F:EC`

> هذا مفتاح Debug وليس مناسباً للنشر الإنتاجي أو Google Play. للنشر الرسمي يجب إنشاء مفتاح Release خاص وحفظه خارج المستودع، ثم إعداد `key.properties` محلياً وعدم مشاركته علناً.
