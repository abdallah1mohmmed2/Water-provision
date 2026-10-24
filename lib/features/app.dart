import 'dart:async';
import '../core/app_clock.dart';
import '../core/app_prefs.dart';
import '../core/period_ranges.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:printing/printing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../core/theme.dart';
import '../core/permissions.dart';
import '../core/system_config.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';
import '../services/admin_service.dart';
import '../services/local_security_service.dart';
import '../services/backup_service.dart';
import '../services/report_service.dart';
import '../services/device_notification_settings.dart';
import '../services/manual_message_service.dart';

const MethodChannel _floatingBubbleChannel = MethodChannel('saqia/floating_bubble');

const _blue = Color(0xff287bff),
    _cyan = Color(0xff00d7ff),
    _purple = Color(0xff7c4dff),
    _green = Color(0xff18e58c);

String money(Object? v) =>
    '${(v is num ? v : num.tryParse('$v') ?? 0).round()} ريال';
String friendlyError(Object e) {
  if (e is ArgumentError && e.message != null) return '${e.message}';
  if (e is StateError) return e.message;
  final x = '$e';
  if (x.contains('carried_diesel_liters')) {
    return 'نسخة قاعدة البيانات قديمة. أعد فتح التطبيق ليتم تحديث قاعدة البيانات تلقائيًا.';
  }
  if (x.contains('UNIQUE')) return 'القيمة موجودة مسبقًا.';
  if (x.contains('FOREIGN KEY')) {
    return 'لا يمكن حفظ العملية لأن البيانات المرتبطة غير صحيحة.';
  }
  return x.replaceAll('DatabaseException', 'خطأ في قاعدة البيانات');
}

/// ينفّذ عملية كتابة ويعرض للمستخدم رسالة مفهومة عند الفشل بدل تمرير الاستثناء.
///هنا الخطا

Future<bool> runGuarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
    return false;
  }
}

/// نافذة تطلب سببًا (إلزاميًا) قبل عملية حساسة كالإلغاء أو الحذف. تعيد النص أو null عند التراجع.
Future<String?> askReason(
  BuildContext context,
  String title, {
  String? message,
  String confirmLabel = 'تأكيد',
}) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (d, s) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(message),
              ),
            TextField(
              controller: c,
              autofocus: true,
              onChanged: (_) => s(() {}),
              decoration: const InputDecoration(labelText: 'السبب *'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: c.text.trim().isEmpty
                ? null
                : () => Navigator.pop(d, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  return ok == true ? c.text.trim() : null;
}

/// الصندوق تابع لطريقة الدفع: إن كان للطريقة صندوق مرتبط فهو المختار دائمًا.
int? cashboxForMethod(
  List<Map<String, Object?>> methods,
  List<Map<String, Object?>> cash,
  int? methodId,
  int? current,
) {
  for (final m in methods) {
    if (m['id'] == methodId && m['cashbox_id'] != null) {
      return (m['cashbox_id'] as num).toInt();
    }
  }
  if (current != null && cash.any((c) => c['id'] == current)) return current;
  return cash.isEmpty ? null : cash.first['id'] as int;
}

/// حقلا «طريقة الدفع» و«الصندوق» كقائمة واحدة متسقة: لا تُعرض قائمة صندوق مستقلة إن كان
/// للطريقة صندوق مرتبط (يظهر اسمه للقراءة فقط)، فلا يتباعد الصندوق عن حساب القيد.
List<Widget> methodCashboxFields({
  required List<Map<String, Object?>> methods,
  required List<Map<String, Object?>> cash,
  required int? method,
  required int? cb,
  required void Function(int? method, int? cashbox) onChanged,
}) {
  Map<String, Object?>? sel;
  for (final m in methods) {
    if (m['id'] == method) sel = m;
  }
  final linked = sel?['cashbox_id'] != null;
  return [
    DropdownButtonFormField<int>(
      initialValue: method,
      items: [
        for (final x in methods)
          DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}')),
      ],
      onChanged: (v) => onChanged(v, cashboxForMethod(methods, cash, v, cb)),
      decoration: const InputDecoration(labelText: 'طريقة الدفع'),
    ),
    if (linked)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'الصندوق (مرتبط بطريقة الدفع)',
          ),
          child: Text('${sel?['cashbox_name'] ?? cb}'),
        ),
      )
    else
      DropdownButtonFormField<int>(
        initialValue: cb,
        items: [
          for (final x in cash)
            DropdownMenuItem(
              value: x['id'] as int,
              child: Text('${x['name']}'),
            ),
        ],
        onChanged: (v) => onChanged(method, v),
        decoration: const InputDecoration(labelText: 'الصندوق'),
      ),
  ];
}

String ledgerAccountName(Object? code) => switch ('$code') {
  '1100' => 'بنك',
  '1120' => 'محفظة إلكترونية',
  _ => 'نقدي',
};

String systemName(String? v) => switch (v) {
  'diesel' => 'ديزل',
  'solar' => 'شمسي',
  'equivalent_hybrid' => 'النوع الثالث',
  _ => 'غير محدد',
};
String statusName(Object? v) => switch ('$v') {
  'waiting' => 'منتظر',
  'postponed' => 'مؤجل',
  'running' => 'قيد التشغيل',
  'completed' => 'مكتمل',
  'new' => 'جديد',
  'under_review' => 'قيد المراجعة',
  'scheduled' => 'مجدول',
  'accepted' => 'مقبول',
  'notified' => 'تم الإبلاغ',
  'cancelled' => 'ملغى',
  'posted' => 'مرحل',
  _ => movementName('$v'),
};
String movementName(String v) =>
    {
      'receipt': 'شراء/إضافة',
      'delivery': 'تسليم',
      'advance': 'سلفة',
      'consumption': 'استهلاك',
      'correction': 'تصحيح جرد',
      'opening_balance': 'رصيد افتتاحي',
    }[v] ??
    v;
String paymentTypeName(String v) =>
    {
      'cash': 'نقدي',
      'check': 'شيك',
      'bank_transfer': 'تحويل بنكي',
      'wallet': 'محفظة',
      'other': 'أخرى',
    }[v] ??
    v;
String settingDisplay(String k, String v) => switch (k) {
  'system_type' => systemName(v),
  'queue_type' =>
    v == 'circular'
        ? 'طابور دائري'
        : v == 'booking'
        ? 'نظام حجز'
        : v,
  'time_source' =>
    v == 'server'
        ? 'وقت الخادم'
        : v == 'device'
        ? 'وقت الجهاز'
        : v,
  'partial_hour' => v == 'true' ? 'نعم' : 'لا',
  'manager_override_required' => v == 'true' ? 'نعم' : 'لا',
  'allow_midnight_crossing' => v == 'true' ? 'نعم' : 'لا',
  'sound_notifications' => v == 'true' ? 'نعم' : 'لا',
  'popup_notifications' => v == 'true' ? 'نعم' : 'لا',
  'reduced_motion' => v == 'true' ? 'نعم' : 'لا',
  'diesel_delivery_financial_credit' => v == 'true' ? 'نعم' : 'لا',
  'absence_policy' => switch (v) {
    'postpone' => 'نقل لآخر الدور',
    'cancel' => 'إزالة من الدور',
    'keep' || 'keep_order' => 'إبقاء الدور',
    _ => v,
  },
  'week_start' =>
    {
          'saturday': 'السبت',
          'sunday': 'الأحد',
          'monday': 'الاثنين',
          'tuesday': 'الثلاثاء',
          'wednesday': 'الأربعاء',
          'thursday': 'الخميس',
          'friday': 'الجمعة',
        }[v] ??
        v,
  _ => v,
};
String categoryName(String v) =>
    {
      'workers': 'عمال',
      'partners': 'شركاء',
      'fuel': 'وقود',
      'oil': 'زيت',
      'grease': 'شحم',
      'maintenance': 'صيانة',
      'parts': 'قطع غيار',
      'transport': 'نقل',
      'admin': 'إدارية',
      'other': 'أخرى',
    }[v] ??
    v;
String payTypeName(String v) =>
    {'fixed': 'راتب ثابت', 'hourly': 'بالساعة', 'percentage': 'نسبة'}[v] ?? v;
String targetName(String v) =>
    {'beneficiary': 'مستفيد', 'worker': 'عامل', 'partner': 'شريك'}[v] ?? v;

class _NoTransitionBuilder extends PageTransitionsBuilder {
  const _NoTransitionBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

ThemeData _withMotion(ThemeData t, bool reduced) => reduced
    ? t.copyWith(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _NoTransitionBuilder(),
            TargetPlatform.iOS: _NoTransitionBuilder(),
            TargetPlatform.linux: _NoTransitionBuilder(),
            TargetPlatform.macOS: _NoTransitionBuilder(),
            TargetPlatform.windows: _NoTransitionBuilder(),
            TargetPlatform.fuchsia: _NoTransitionBuilder(),
          },
        ),
      )
    : t;

class SaqiaApp extends StatefulWidget {
  const SaqiaApp({super.key});
  @override
  State<SaqiaApp> createState() => _SaqiaAppState();
}

class _SaqiaAppState extends State<SaqiaApp> {
  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  /// يقرأ الإعدادات المؤثرة على الواجهة (اسم التطبيق، تقليل الحركة، التنبيهات، مصدر الوقت).
  Future<void> _loadPrefs() async {
    try {
      await AppPrefs.apply(await StationRepository().settings());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppPrefsData>(
    valueListenable: AppPrefs.notifier,
    builder: (_, p, __) => MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: p.appName,
      theme: _withMotion(SaqiaTheme.light(themeKey: p.themeKey), p.reducedMotion),
      darkTheme: _withMotion(SaqiaTheme.dark(themeKey: p.themeKey), p.reducedMotion),
      themeMode: switch (p.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(disableAnimations: p.reducedMotion),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const AdminLoginPage(),
    ),
  );
}

/// شاشة القفل المحلية: لا تطلب كلمة مرور الحساب، بل رمز الجهاز أو البصمة.
class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});
  @override
  State<AdminLoginPage> createState() => _LocalSecurityGateState();
}

class _LocalSecurityGateState extends State<AdminLoginPage> {
  final pin = TextEditingController();
  bool loading = true;
  bool busy = false;
  bool needsSetup = false;
  bool biometric = false;
  bool biometricAvailable = false;
  String? error;
  Map<String, Object?>? user;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final security = LocalSecurityService.instance;
      final configured = await security.hasPin();
      final bio = await security.biometricEnabled();
      final bioAvailable = await security.biometricAvailable();
      final allUsers = await AdminService().users();
      final activeUsers = allUsers.where((x) => (x['active'] as num?)?.toInt() == 1).toList();
      activeUsers.sort((a, b) {
        final aManager = a['role'] == 'manager' ? 0 : 1;
        final bManager = b['role'] == 'manager' ? 0 : 1;
        return aManager.compareTo(bManager);
      });
      if (!mounted) return;
      setState(() {
        needsSetup = !configured;
        biometric = bio && bioAvailable;
        biometricAvailable = bioAvailable;
        user = activeUsers.isEmpty ? null : activeUsers.first;
        loading = false;
        if (activeUsers.isEmpty) error = 'لا يوجد مستخدم نشط. فعّل حسابًا من قاعدة بيانات المحطة أولاً.';
      });
    } catch (e) {
      if (mounted) setState(() { loading = false; error = friendlyError(e); });
    }
  }

  Future<void> _unlocked() async {
    if (user == null) {
      setState(() => error = 'تعذر تحديد مستخدم نشط لفتح المحطة.');
      return;
    }
    setState(() => busy = true);
    try {
      final settings = await StationRepository().settings();
      final destination = settings['initial_setup_completed'] == 'true'
          ? AdminShell(role: '${user!['role']}', userName: '${user!['name']}', userId: (user!['id'] as num).toInt())
          : InitialSetupPage(role: '${user!['role']}', userName: '${user!['name']}', userId: (user!['id'] as num).toInt());
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => destination));
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _verifyPin() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      if (await LocalSecurityService.instance.verifyPin(pin.text)) {
        await _unlocked();
      } else if (mounted) {
        setState(() => error = 'رمز التأمين غير صحيح');
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _verifyBiometric() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    final ok = await LocalSecurityService.instance.authenticateBiometric();
    if (!mounted) return;
    if (ok) {
      await _unlocked();
    } else {
      setState(() => error = 'لم يتم التحقق بالبصمة. استخدم رمز التأمين.');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (needsSetup) {
      return SecuritySettingsPage(firstTime: true, onSaved: _load);
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 82, height: 82,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(26),
                          gradient: LinearGradient(colors: [SaqiaTheme.accent(AppPrefs.current.themeKey), SaqiaTheme.accent(AppPrefs.current.themeKey).withValues(alpha: .72)]),
                        ),
                        child: const Icon(Icons.shield_rounded, size: 44, color: Colors.white),
                      ),
                      const SizedBox(height: 18),
                      Text(AppPrefs.current.appName, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      const Text('تأمين محلي للجهاز', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 22),
                      TextField(
                        controller: pin,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 8,
                        onSubmitted: (_) => _verifyPin(),
                        decoration: const InputDecoration(
                          labelText: 'رمز التأمين الرقمي',
                          prefixIcon: Icon(Icons.pin_outlined),
                          border: OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
                        ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: busy ? null : _verifyPin,
                          icon: const Icon(Icons.lock_open_rounded),
                          label: Text(busy ? 'جارٍ التحقق…' : 'فتح التطبيق'),
                        ),
                      ),
                      if (biometric && biometricAvailable) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : _verifyBiometric,
                            icon: const Icon(Icons.fingerprint_rounded),
                            label: const Text('فتح بالبصمة'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => Navigator.push(c, MaterialPageRoute(
                          builder: (_) => const SecuritySettingsPage(firstTime: false),
                        )).then((_) => _load()),
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('إعدادات التأمين'),
                      ),
                      const SizedBox(height: 4),
                      Text('يُحفظ رمز التأمين محليًا على هذا الجهاز ولا يُرسل إلى الخادم.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: Theme.of(c).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// إعداد رمز PIN والبصمة محليًا. يتطلب رمز PIN كوسيلة احتياطية حتى عند تفعيل البصمة.
class SecuritySettingsPage extends StatefulWidget {
  final bool firstTime;
  final Future<void> Function()? onSaved;
  const SecuritySettingsPage({super.key, required this.firstTime, this.onSaved});
  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  final currentPin = TextEditingController();
  final newPin = TextEditingController();
  final confirmPin = TextEditingController();
  bool bioAvailable = false;
  bool bioEnabled = false;
  bool loading = true;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    currentPin.dispose();
    newPin.dispose();
    confirmPin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = LocalSecurityService.instance;
    final available = await service.biometricAvailable();
    final enabled = await service.biometricEnabled();
    if (mounted) setState(() { bioAvailable = available; bioEnabled = enabled && available; loading = false; });
  }

  Future<void> _save() async {
    if (saving) return;
    final changingPin = newPin.text.isNotEmpty || confirmPin.text.isNotEmpty;
    if (widget.firstTime && newPin.text.isEmpty) {
      setState(() => error = 'أنشئ رمز تأمين رقميًا أولاً، ويمكنك تفعيل البصمة كخيار إضافي.');
      return;
    }
    if (changingPin) {
      if (!RegExp(r'^\d{4,8}$').hasMatch(newPin.text)) {
        setState(() => error = 'رمز التأمين يجب أن يتكون من 4 إلى 8 أرقام.');
        return;
      }
      if (newPin.text != confirmPin.text) {
        setState(() => error = 'رمزا التأمين غير متطابقين.');
        return;
      }
    }
    setState(() { saving = true; error = null; });
    try {
      final service = LocalSecurityService.instance;
      if (!widget.firstTime) {
        if (currentPin.text.isEmpty || !await service.verifyPin(currentPin.text)) {
          setState(() => error = 'أدخل رمز التأمين الحالي الصحيح لإجراء التغييرات.');
          return;
        }
      }
      if (changingPin) await service.setPin(newPin.text);
      if (bioEnabled && !bioAvailable) {
        throw StateError('البصمة غير متاحة على هذا الجهاز. استخدم رمز التأمين.');
      }
      await service.setBiometricEnabled(bioEnabled);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ إعدادات التأمين محليًا على الجهاز.')),
      );
      if (widget.onSaved != null) {
        await widget.onSaved!();
      } else {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('شاشة تأمين التطبيق')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.security_rounded, size: 48),
                      const SizedBox(height: 10),
                      Text(widget.firstTime ? 'إنشاء تأمين محلي' : 'إدارة التأمين المحلي',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      const Text('كلمة مرور الحساب لم تعد مطلوبة. أنشئ رمزًا رقميًا من 4 إلى 8 أرقام، ويمكنك استخدام البصمة بدلًا منه عند توفرها.',
                        textAlign: TextAlign.center),
                      if (!widget.firstTime) ...[
                        const SizedBox(height: 20),
                        TextField(
                          controller: currentPin,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'رمز التأمين الحالي', prefixIcon: Icon(Icons.lock_outline), border: OutlineInputBorder()),
                        ),
                      ],
                      const SizedBox(height: 14),
                      TextField(
                        controller: newPin,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 8,
                        decoration: InputDecoration(
                          labelText: widget.firstTime ? 'رمز التأمين الجديد (4–8 أرقام)' : 'رمز جديد (اتركه فارغًا للإبقاء على الحالي)',
                          prefixIcon: const Icon(Icons.pin_outlined),
                          border: const OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: confirmPin,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 8,
                        decoration: const InputDecoration(labelText: 'تأكيد الرمز الجديد', prefixIcon: Icon(Icons.check_circle_outline), border: OutlineInputBorder(), counterText: ''),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: bioEnabled && bioAvailable,
                        onChanged: bioAvailable ? (v) => setState(() => bioEnabled = v) : null,
                        secondary: const Icon(Icons.fingerprint_rounded),
                        title: const Text('السماح بفتح التطبيق بالبصمة'),
                        subtitle: Text(bioAvailable
                          ? 'ستبقى أرقام PIN متاحة كوسيلة احتياطية.'
                          : 'لا تتوفر بصمة مدعومة أو لم تُسجّل بصمة في إعدادات الجهاز.'),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 10),
                        Text(error!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: saving ? null : _save,
                        icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                        label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ إعدادات التأمين'),
                      ),
                      const SizedBox(height: 8),
                      Text('التأمين محلي على هذا الجهاز. لا يحمي نسخة قاعدة البيانات إذا نُسخت خارج الجهاز، ولا يغني عن قفل الهاتف.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InitialSetupPage extends StatefulWidget {
  final String role,userName; final int userId;
  const InitialSetupPage({required this.role,required this.userName,required this.userId,super.key});
  @override State<InitialSetupPage> createState()=>_InitialSetupState();
}
class _InitialSetupState extends State<InitialSetupPage>{
  final repo=StationRepository();late final TextEditingController stationName,currency;List<Map<String,Object?>> pumps=[];String type='diesel',timeSource='device';int? pumpId;bool loading=true,saving=false;String? error;
  @override void initState(){super.initState();stationName=TextEditingController();currency=TextEditingController(text:'YER');_load();}
  @override void dispose(){stationName.dispose();currency.dispose();super.dispose();}
  Future<void> _load()async{try{final set=await repo.settings();final ps=await repo.db.query('pumps',where:'active=1',orderBy:'id');if(mounted)setState((){stationName.text=set['station_name']??'';currency.text=set['currency']??'YER';type=set['system_type']??'diesel';timeSource=set['time_source']??'device';pumps=ps;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  List<Map<String,Object?>> get compatiblePumps=>pumps.where((p)=>'${p['system_type']}'==type).toList();
  Future<void> _finish()async{if(stationName.text.trim().isEmpty){setState(()=>error='اكتب اسم المحطة أولاً');return;}if(currency.text.trim().isEmpty){setState(()=>error='حدد العملة المستخدمة');return;}if(compatiblePumps.isNotEmpty&&pumpId==null){setState(()=>error='اختر المضخة الأساسية للمنظومة');return;}setState(()=>saving=true);try{await repo.setSetting('station_name',stationName.text.trim());await repo.setSetting('currency',currency.text.trim().toUpperCase());await repo.setSetting('time_source',timeSource);await repo.setSystemType(type);if(pumpId!=null)await repo.selectPump(pumpId!);await repo.setSetting('initial_setup_completed','true');await AppPrefs.apply(await repo.settings());if(!mounted)return;Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>AdminShell(role:widget.role,userName:widget.userName,userId:widget.userId)));}catch(e){if(mounted)setState((){error=friendlyError(e);saving=false;});}}
  Widget _typeCard(String value,String title,String subtitle,IconData icon,Color color){final selected=type==value;return InkWell(onTap:(){setState((){type=value;pumpId=null;});},borderRadius:BorderRadius.circular(20),child:AnimatedContainer(duration:const Duration(milliseconds:180),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:selected?color.withValues(alpha: .1):Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:selected?color:_reportLine,width:selected?2:1)),child:Row(children:[Container(width:45,height:45,decoration:BoxDecoration(color:selected?color:color.withValues(alpha: .1),borderRadius:BorderRadius.circular(14)),child:Icon(icon,color:selected?Colors.white:color)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:15)),const SizedBox(height:4),Text(subtitle,style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:10))]),),Icon(selected?Icons.radio_button_checked_rounded:Icons.radio_button_unchecked_rounded,color:selected?color:_reportInk.withValues(alpha: .28))])));}
  Widget _sectionTitle(String title,String sub,IconData icon)=>Padding(padding:const EdgeInsets.only(bottom:10),child:Row(children:[Container(width:36,height:36,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(11)),child:Icon(icon,color:_reportOliveDark,size:19)),const SizedBox(width:9),Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),Text(sub,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10))]) ]));
  @override Widget build(BuildContext context){final ps=compatiblePumps;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,body:loading?const Center(child:CircularProgressIndicator()):SafeArea(child:ListView(padding:const EdgeInsets.fromLTRB(20,18,20,28),children:[Container(padding:const EdgeInsets.all(22),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(29),boxShadow:[BoxShadow(color:_reportOlive.withValues(alpha: .18),blurRadius:18,offset:const Offset(0,8))]),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('مرحباً ${widget.userName}',style:TextStyle(color:Colors.white.withValues(alpha: .75),fontSize:12)),const SizedBox(height:7),const Text('لنجهّز محطتك معاً',style:TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.w900)),const SizedBox(height:8),Text('اختر المنظومة والإعدادات الأساسية مرة واحدة، وسنخصّص لك التطبيق تلقائياً.',style:TextStyle(color:Colors.white.withValues(alpha: .84),fontSize:11,height:1.5))]),),Container(width:62,height:62,decoration:BoxDecoration(color:Colors.white.withValues(alpha: .14),borderRadius:BorderRadius.circular(21)),child:const Icon(Icons.water_drop_rounded,color:Colors.white,size:34))])),const SizedBox(height:18),Container(padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(23),border:Border.all(color:_reportLine)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_sectionTitle('اختر منظومة المحطة','ستظهر لك الواجهات والتقارير المناسبة فقط',Icons.tune_rounded),_typeCard('diesel','منظومة الديزل','خزان ووقود وتنبيهات استهلاك',Icons.local_gas_station_rounded,_reportOrange),const SizedBox(height:9),_typeCard('solar','المنظومة الشمسية','سقي شمسي وتسعير وتشغيل',Icons.wb_sunny_rounded,_reportGreen),const SizedBox(height:9),_typeCard('equivalent_hybrid','النوع الثالث','منظومة مخصصة بإعداداتها الخاصة',Icons.bolt_rounded,_reportOliveDark)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(23),border:Border.all(color:_reportLine)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_sectionTitle('بيانات المحطة','معلومات تظهر في الواجهات والتقارير',Icons.storefront_rounded),TextField(controller:stationName,decoration:const InputDecoration(labelText:'اسم المحطة',prefixIcon:Icon(Icons.storefront_outlined),border:OutlineInputBorder())),const SizedBox(height:10),TextField(controller:currency,decoration:const InputDecoration(labelText:'العملة',prefixIcon:Icon(Icons.currency_exchange_rounded),border:OutlineInputBorder()),textCapitalization:TextCapitalization.characters),const SizedBox(height:10),DropdownButtonFormField<String>(initialValue:timeSource,items:const[DropdownMenuItem(value:'device',child:Text('وقت الجهاز')) ,DropdownMenuItem(value:'server',child:Text('وقت الخادم'))],onChanged:(v)=>setState(()=>timeSource=v??'device'),decoration:const InputDecoration(labelText:'مصدر الوقت',prefixIcon:Icon(Icons.access_time_rounded),border:OutlineInputBorder()))])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(23),border:Border.all(color:_reportLine)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_sectionTitle('المضخة الأساسية','تطابق نوع المنظومة المختار',Icons.settings_input_component_rounded),if(ps.isEmpty)Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(13)),child:const Row(children:[Icon(Icons.info_outline_rounded,color:_reportOliveDark),SizedBox(width:8),Expanded(child:Text('لا توجد مضخات متوافقة حالياً. يمكنك إكمال الإعداد وإضافتها لاحقاً من إدارة المضخات.',style:TextStyle(fontSize:11,fontWeight:FontWeight.w700))) ]))else DropdownButtonFormField<int>(initialValue:pumpId,items:[for(final p in ps)DropdownMenuItem(value:p['id'] as int,child:Text('${p['name']}'))],onChanged:(v)=>setState(()=>pumpId=v),decoration:const InputDecoration(labelText:'اختر المضخة',prefixIcon:Icon(Icons.water_rounded),border:OutlineInputBorder()))])),if(error!=null)Padding(padding:const EdgeInsets.only(top:14),child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:_reportOrange.withValues(alpha: .1),borderRadius:BorderRadius.circular(12)),child:Row(children:[const Icon(Icons.warning_amber_rounded,color:_reportOrange),const SizedBox(width:8),Expanded(child:Text(error!,style:const TextStyle(color:_reportOrange,fontWeight:FontWeight.w800,fontSize:11)))]))),const SizedBox(height:18),FilledButton.icon(onPressed:saving?null:_finish,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,padding:const EdgeInsets.symmetric(vertical:16),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16))),icon:saving?const SizedBox(width:19,height:19,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white)):const Icon(Icons.check_circle_outline_rounded),label:Text(saving?'جارٍ حفظ الإعدادات…':'حفظ وفتح لوحة التحكم',style:const TextStyle(fontWeight:FontWeight.w900))),const SizedBox(height:10),Text('يمكن للمدير تعديل هذه الإعدادات لاحقاً من صفحة الإعدادات.',textAlign:TextAlign.center,style:TextStyle(color:_reportInk.withValues(alpha: .52),fontSize:10))]))));}
}

class AdminShell extends StatefulWidget {
  final String role, userName;
  final int userId;
  const AdminShell({
    required this.role,
    required this.userName,
    required this.userId,
    super.key,
  });
  @override
  State<AdminShell> createState() => _ShellState();
}

class _ShellState extends State<AdminShell> {
  final repo = StationRepository();
  final GlobalKey<ScaffoldState> _shellScaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<_BeneficiariesState> _beneficiariesKey =
      GlobalKey<_BeneficiariesState>();
  final GlobalKey<_NewIrrigationState> _newIrrigationKey =
      GlobalKey<_NewIrrigationState>();
  final GlobalKey<_ExpensesState> _expensesKey = GlobalKey<_ExpensesState>();
  int index = 0;
  bool collapsed = false;
  Map<String, Object?> counts = {};
  String systemType = 'diesel';
  final menuSearch = TextEditingController();
  final pages = const [
    'لوحة التحكم',
    'المستفيدون',
    'سقاية جديدة',
    'السقايات',
    'جلسات السقي',
    'الطابور والحجوزات',
    'الديزل',
    'المدفوعات',
    'الصناديق والتحويلات',
    'المصروفات',
    'العمال',
    'الشركاء',
    'دفتر اليومية',
    'الأستاذ العام',
    'التقارير',
    'الإشعارات',
    'الإعدادات',
    'النسخ الاحتياطي',
    'قياس الأداء',
  ];
  AppRole get role => AppRole.values.firstWhere(
    (x) => x.name == widget.role,
    orElse: () => AppRole.operations,
  );
  Set<int> get visible {
    final s = <int>{0, 2, 4, 5, 15};
    if (systemType == 'diesel') s.add(6);
    if (role == AppRole.manager || role == AppRole.accountant) {
      s.addAll({1, 3, 7, 8, 9, 10, 11, 12, 13, 14});
    }
    if (role == AppRole.manager) {
      s.addAll({16, 17, 18});
    }
    return s;
  }

  StreamSubscription<AppAlert>? _alertSub;

  @override
  void initState() {
    super.initState();
    _floatingBubbleChannel.setMethodCallHandler((call) async {
      if (call.method == 'quickAction' && call.arguments is String) {
        _handleFloatingAction(call.arguments as String);
        return true;
      }
      return null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingFloatingAction();
    });
    refreshCounts();
    // النافذة المنبثقة (إن كان إعدادها مفعّلًا؛ الصوت يُشغَّل داخل AppAlerts نفسه).
    _alertSub = AppAlerts.stream.listen((a) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('${a.title}: ${a.body}'),
        ),
      );
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _floatingBubbleChannel.setMethodCallHandler(null);
    menuSearch.dispose();
    super.dispose();
  }

  Future<void> _consumePendingFloatingAction() async {
    try {
      final action = await _floatingBubbleChannel.invokeMethod<String>('consumePendingQuickAction');
      if (action != null && mounted) _handleFloatingAction(action);
    } on PlatformException {
      // The native bridge is available only on Android.
    } catch (_) {}
  }

  void _handleFloatingAction(String action) {
    if (!mounted) return;
    switch (action) {
      case 'irrigation':
        go(2);
        break;
      case 'cash':
        go(7);
        break;
      case 'queue':
        go(5);
        break;
      case 'beneficiary':
        if (!visible.contains(1)) return;
        go(1);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _beneficiariesKey.currentState?.add();
        });
        break;
      case 'expense':
        if (!visible.contains(9)) return;
        go(9);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _expensesKey.currentState?.add();
        });
        break;
    }
  }

  Future<void> refreshCounts() async {
    try {
      final x = await repo.dashboard();
      final cfg = await SystemConfig.load(repo);
      if (mounted) {
        setState(() {
          counts = x;
          systemType = cfg.type;
        });
      }
    } catch (_) {}
  }

  void go(int i) {
    if (visible.contains(i)) {
      setState(() => index = i);
      refreshCounts();
    }
  }

  @override
  Widget build(BuildContext c) {
    if (!visible.contains(index)) index = visible.first;
    final filter = menuSearch.text.trim();
    final menu = visible.where((i) => pages[i].contains(filter)).toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        key: _shellScaffoldKey,
        appBar: AppBar(
          backgroundColor: index == 0 ? SaqiaTheme.accent(AppPrefs.current.themeKey) : null,
          foregroundColor: index == 0 ? Colors.white : null,
          elevation: index == 0 ? 0 : null,
          title: Text(
            pages[index],
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            if (role == AppRole.manager)
              IconButton(
                tooltip: 'تأمين التطبيق',
                onPressed: () => Navigator.push(
                  c,
                  MaterialPageRoute(builder: (_) => const SecuritySettingsPage(firstTime: false)),
                ),
                icon: const Icon(Icons.security_rounded),
              ),
            IconButton(
              tooltip: 'تحديث',
              onPressed: refreshCounts,
              icon: const Icon(Icons.refresh),
            ),
            Builder(
              builder: (bc) => IconButton(
                tooltip: 'القائمة',
                onPressed: () => Scaffold.of(bc).openDrawer(),
                icon: const Icon(Icons.menu_open),
              ),
            ),
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(17),
                          gradient: LinearGradient(
                            colors: [SaqiaTheme.accent(AppPrefs.current.themeKey), SaqiaTheme.accent(AppPrefs.current.themeKey).withValues(alpha: .72)],
                          ),
                        ),
                        child: const Icon(
                          Icons.water_drop,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppPrefs.current.appName.split(' ').first,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              widget.userName,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: TextField(
                    controller: menuSearch,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'بحث سريع في القائمة',
                      isDense: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      _badge('الطابور', '${counts['queue'] ?? 0}', _purple),
                      _badge(
                        'التنبيهات',
                        '${counts['unread_notifications'] ?? 0}',
                        _cyan,
                      ),
                      _badge(
                        'حالة الرصيد',
                        AccountingCalculations.balanceLabel(
                          (counts['remaining'] as num?)?.round() ?? 0,
                        ),
                        _green,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final i in menu)
                        ListTile(
                          selected: i == index,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          leading: Icon(_icon(i)),
                          title: Text(pages[i]),
                          trailing: i == 5
                              ? Text('${counts['queue'] ?? 0}')
                              : i == 15
                              ? Text('${counts['unread_notifications'] ?? 0}')
                              : null,
                          onTap: () {
                            Navigator.pop(c);
                            go(i);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: _NeonBottomBar(
          currentIndex: index,
          isManager: role == AppRole.manager,
          canFinance: visible.contains(8),
          onSelect: (target) {
            if (target == -1) {
              _shellScaffoldKey.currentState?.openDrawer();
            } else {
              go(target);
            }
          },
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _page(index, key: ValueKey(index)),
              ),
            ),
            QuickActionOrb(
              onIrrigation: () {
                go(2);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _newIrrigationKey.currentState?.openQuickForm();
                });
              },
              onCash: () => go(7),
              onQueue: () => go(5),
              onAddBeneficiary: () {
                if (!visible.contains(1)) return;
                go(1);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _beneficiariesKey.currentState?.add();
                });
              },
              onAddExpense: () {
                if (!visible.contains(9)) return;
                go(9);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _expensesKey.currentState?.add();
                });
              },
              canCash: visible.contains(7),
              canAddBeneficiary: visible.contains(1),
              canAddExpense: visible.contains(9),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String a, String b, Color color) => Chip(
    avatar: CircleAvatar(
      backgroundColor: color,
      child: const SizedBox.shrink(),
    ),
    label: Text('$a: $b'),
  );
  IconData _icon(int i) => [
    Icons.dashboard_rounded,
    Icons.people_alt_rounded,
    Icons.add_circle_rounded,
    Icons.water_drop_rounded,
    Icons.timer_rounded,
    Icons.format_list_numbered_rounded,
    Icons.local_gas_station_rounded,
    Icons.payments_rounded,
    Icons.account_balance_rounded,
    Icons.receipt_long_rounded,
    Icons.engineering_rounded,
    Icons.groups_rounded,
    Icons.menu_book_rounded,
    Icons.account_tree_rounded,
    Icons.picture_as_pdf_rounded,
    Icons.notifications_rounded,
    Icons.settings_rounded,
    Icons.backup_rounded,
    Icons.speed_rounded,
  ][i];
  Widget _page(int i, {Key? key}) {
    final w = switch (i) {
      0 => DashboardPage(repo, onOpen: go, availableMenu: visible.toList()),
      1 => BeneficiariesPage(
        repo,
        key: _beneficiariesKey,
        userId: widget.userId,
        manager: role == AppRole.manager,
      ),
      2 => NewIrrigationPage(repo, key: _newIrrigationKey, manager: role == AppRole.manager),
      3 => IrrigationsPage(
        repo,
        manager: role == AppRole.manager,
        userId: widget.userId,
      ),
      4 => SessionsPage(repo, userId: widget.userId),
      5 => QueueBookingPage(
        repo,
        userId: widget.userId,
        manager: role == AppRole.manager,
      ),
      6 => DieselPage(repo, userId: widget.userId),
      7 => PaymentsPage(repo, userId: widget.userId),
      8 => CashboxesPage(repo, userId: widget.userId),
      9 => ExpensesPage(repo, key: _expensesKey, userId: widget.userId),
      10 => WorkersPage(
        repo,
        userId: widget.userId,
        manager: role == AppRole.manager,
      ),
      11 => PartnersPage(
        repo,
        userId: widget.userId,
        manager: role == AppRole.manager,
      ),
      12 => JournalPage(repo),
      13 => LedgerPage(repo),
      14 => ReportsPage(repo),
      15 => NotificationsPage(repo),
      16 => SettingsPage(
        repo,
        userId: widget.userId,
        manager: role == AppRole.manager,
        onSystemTypeChanged: (v) => refreshCounts(),
      ),
      17 => BackupPage(repo),
      18 => PerformancePage(repo),
      _ => DashboardPage(repo, onOpen: go, availableMenu: visible.toList()),
    };
    return KeyedSubtree(key: key, child: w);
  }
}

class _DashboardCircularMenu extends StatefulWidget {
  final List<int> availableMenu;
  final ValueChanged<int> onOpen;
  const _DashboardCircularMenu({required this.availableMenu, required this.onOpen});

  @override
  State<_DashboardCircularMenu> createState() => _DashboardCircularMenuState();
}

class _DashboardCircularMenuState extends State<_DashboardCircularMenu>
    with SingleTickerProviderStateMixin {
  double rotation = -math.pi / 2;
  late final AnimationController controller = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 450),
  );
  late final Animation<double> scale = CurvedAnimation(parent: controller, curve: Curves.easeOutBack);

  @override
  void initState() {
    super.initState();
    controller.forward();
  }

  void _rotateFromDrag(DragUpdateDetails details) {
    const center = Offset(143, 143);
    final previous = details.localPosition - details.delta - center;
    final current = details.localPosition - center;
    if (previous.distance < 1 || current.distance < 1) return;
    final before = math.atan2(previous.dy, previous.dx);
    final after = math.atan2(current.dy, current.dx);
    var delta = after - before;
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    setState(() => rotation += delta);
  }
  // لا نكرر اختصارات الزر العائم (السقاية، حجز الدور، إضافة المصروف،
  // والصرف/القبض) داخل العجلة؛ نعرض بدلاً منها أقساماً مختلفة ومهمة.
  static const _items = <(int, String, IconData, Color)>[
    (1, 'المستفيدون', Icons.people_alt_rounded, Color(0xFF39FFB6)),
    (10, 'العمال', Icons.engineering_rounded, Color(0xFF00E5FF)),
    (11, 'الشركاء', Icons.handshake_rounded, Color(0xFF39FFB6)),
    (7, 'المدفوعات', Icons.payments_rounded, Color(0xFF00E5FF)),
    (8, 'الصناديق', Icons.account_balance_rounded, Color(0xFF39FFB6)),
    (14, 'التقارير', Icons.analytics_rounded, Color(0xFF00E5FF)),
    (17, 'النسخ الاحتياطي', Icons.backup_rounded, Color(0xFF39FFB6)),
  ];

  @override
  void dispose() { controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final items = _items.where((item) => widget.availableMenu.contains(item.$1)).toList();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF08111F),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: .30)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF00E5FF).withValues(alpha: .08), blurRadius: 26, spreadRadius: 1),
          BoxShadow(color: const Color(0xFF39FFB6).withValues(alpha: .05), blurRadius: 38),
        ],
      ),
      child: Column(
        children: [
          Row(children: [
            const Icon(Icons.bolt_rounded, color: Color(0xFF39FFB6)),
            const SizedBox(width: 8),
            const Expanded(child: Text('العمليات السريعة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 17))),
            Text('اسحب لتدويرها', style: TextStyle(color: Colors.white.withValues(alpha: .55), fontSize: 10)),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 286,
            child: GestureDetector(
              onPanUpdate: _rotateFromDrag,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 222, height: 222,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0D1B2B),
                      border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: .55), width: 1.4),
                      boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withValues(alpha: .12), blurRadius: 24, spreadRadius: 2)],
                    ),
                  ),
                  ...List.generate(items.length, (i) {
                    final item = items[i];
                    final angle = rotation + 2 * math.pi * i / items.length;
                    final dx = 104 * math.cos(angle);
                    final dy = 104 * math.sin(angle);
                    return Transform.translate(
                      offset: Offset(dx, dy),
                      child: ScaleTransition(
                        scale: scale,
                        child: Transform.rotate(
                          angle: -rotation,
                          child: SizedBox(
                            width: 78, height: 78,
                            child: Material(
                              color: const Color(0xFF111F30),
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => widget.onOpen(item.$1),
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: item.$4.withValues(alpha: .78)),
                                    boxShadow: [BoxShadow(color: item.$4.withValues(alpha: .14), blurRadius: 14)],
                                  ),
                                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    Icon(item.$3, color: item.$4, size: 24),
                                    const SizedBox(height: 4),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 3),
                                      child: Text(item.$2, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                  Container(
                    width: 66, height: 66,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(colors: [Color(0xFF123047), Color(0xFF10251F)]),
                      border: Border.all(color: const Color(0xFF39FFB6), width: 1.7),
                      boxShadow: [BoxShadow(color: const Color(0xFF39FFB6).withValues(alpha: .2), blurRadius: 18)],
                    ),
                    child: const Icon(Icons.hub_rounded, color: Color(0xFF39FFB6), size: 30),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NeonBottomBar extends StatelessWidget {
  final int currentIndex;
  final bool isManager, canFinance;
  final ValueChanged<int> onSelect;
  const _NeonBottomBar({required this.currentIndex, required this.isManager, required this.canFinance, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final destinations = <(int, String, IconData)>[
      (0, 'الرئيسية', Icons.home_rounded),
      if (isManager || canFinance) (14, 'التقارير', Icons.analytics_rounded),
      if (canFinance) (8, 'المالية', Icons.account_balance_wallet_rounded),
      if (isManager) (16, 'الإعدادات', Icons.settings_rounded),
      (-1, 'المزيد', Icons.menu_rounded),
    ];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF08111F),
        border: Border(top: BorderSide(color: const Color(0xFF00E5FF).withValues(alpha: .25))),
        boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withValues(alpha: .07), blurRadius: 18, offset: const Offset(0, -4))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (final item in destinations)
              Expanded(
                child: InkWell(
                  onTap: () => onSelect(item.$1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(item.$3, color: currentIndex == item.$1 ? const Color(0xFF39FFB6) : const Color(0xFF8296AA), size: 22),
                      const SizedBox(height: 3),
                      Text(item.$2, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: currentIndex == item.$1 ? const Color(0xFF39FFB6) : const Color(0xFFB5C3D1), fontSize: 10, fontWeight: currentIndex == item.$1 ? FontWeight.w900 : FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// زر إجراءات سريع قابل للسحب، مع قائمة دائرية وحركة متدرجة حول الزر.
class QuickActionOrb extends StatefulWidget {
  final VoidCallback onIrrigation, onCash, onQueue;
  final VoidCallback onAddBeneficiary, onAddExpense;
  final bool canCash, canAddBeneficiary, canAddExpense;
  const QuickActionOrb({
    required this.onIrrigation,
    required this.onCash,
    required this.onQueue,
    required this.onAddBeneficiary,
    required this.onAddExpense,
    required this.canCash,
    required this.canAddBeneficiary,
    required this.canAddExpense,
    super.key,
  });

  @override
  State<QuickActionOrb> createState() => _QuickActionOrbState();
}

class _QuickActionOrbState extends State<QuickActionOrb>
    with SingleTickerProviderStateMixin {
  Offset position = const Offset(18, 110);
  bool expanded = false;
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final Animation<double> progress = CurvedAnimation(
    parent: controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void toggle() {
    setState(() => expanded = !expanded);
    if (expanded) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final maxX = (constraints.maxWidth - 66).clamp(0.0, double.infinity).toDouble();
      final maxY = (constraints.maxHeight - 66).clamp(0.0, double.infinity).toDouble();
      final menuMaxX = (constraints.maxWidth - 158).clamp(8.0, double.infinity).toDouble();
      final menuMaxY = (constraints.maxHeight - 56).clamp(8.0, double.infinity).toDouble();
      position = Offset(position.dx.clamp(8.0, maxX).toDouble(), position.dy.clamp(8.0, maxY).toDouble());
      final actions = <({IconData icon, String label, Color color, VoidCallback run})>[
        (icon: Icons.water_drop_rounded, label: 'سقاية جديدة', color: const Color(0xff10b981), run: widget.onIrrigation),
        if (widget.canCash) (icon: Icons.account_balance_wallet_rounded, label: 'صرف وقبض', color: const Color(0xff0ea5e9), run: widget.onCash),
        (icon: Icons.format_list_numbered_rounded, label: 'حجز دور', color: const Color(0xff8b5cf6), run: widget.onQueue),
        if (widget.canAddBeneficiary) (icon: Icons.person_add_alt_1_rounded, label: 'إضافة مستفيد', color: const Color(0xfff59e0b), run: widget.onAddBeneficiary),
        if (widget.canAddExpense) (icon: Icons.receipt_long_rounded, label: 'إضافة مصروف', color: const Color(0xffef4444), run: widget.onAddExpense),
      ];
      final menuLeft = position.dx > constraints.maxWidth / 2
          ? (position.dx - 158).clamp(8.0, menuMaxX).toDouble()
          : (position.dx + 68).clamp(8.0, menuMaxX).toDouble();
      final menuAbove = position.dy + actions.length * 56 > constraints.maxHeight - 8;
      return AnimatedBuilder(
        animation: progress,
        builder: (context, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            if (expanded)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: toggle,
                  child: const SizedBox.expand(),
                ),
              ),
            for (var i = 0; i < actions.length; i++)
              Positioned(
                left: menuLeft,
                top: ((menuAbove
                            ? position.dy - actions.length * 56 + 54
                            : position.dy + 7) +
                        i * 56)
                    .clamp(8.0, menuMaxY)
                    .toDouble(),
                child: IgnorePointer(
                  ignoring: !expanded || progress.value < 0.75,
                  child: Opacity(
                    opacity: progress.value.clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(expanded ? 0 : (position.dx > constraints.maxWidth / 2 ? 18 : -18), 0),
                      child: SizedBox(
                        width: 150,
                        height: 48,
                        child: Material(
                          color: actions[i].color,
                          elevation: 8,
                          borderRadius: BorderRadius.circular(24),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () {
                              toggle();
                              actions[i].run();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                children: [
                                  Icon(actions[i].icon, color: Colors.white, size: 22),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      actions[i].label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: position.dx,
              top: position.dy,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    position = Offset(
                      (position.dx + details.delta.dx).clamp(8.0, maxX).toDouble(),
                      (position.dy + details.delta.dy).clamp(8.0, maxY).toDouble(),
                    );
                  });
                },
                child: Material(
                  color: const Color(0xff172554),
                  elevation: 12,
                  shadowColor: const Color(0x6610b981),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: toggle,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: expanded
                              ? const [Color(0xff0ea5e9), Color(0xff6366f1)]
                              : const [Color(0xff10b981), Color(0xff0ea5e9)],
                        ),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2),
                      ),
                      child: AnimatedRotation(
                        turns: expanded ? 0.125 : 0,
                        duration: const Duration(milliseconds: 260),
                        child: Icon(
                          expanded ? Icons.close_rounded : Icons.add_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class PageFrame extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> actions;
  final Widget child;
  const PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
    super.key,
  });
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(c).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(child: child),
      ],
    ),
  );
}

class EmptyView extends StatelessWidget {
  final String text;
  const EmptyView(this.text, {super.key});
  @override
  Widget build(BuildContext c) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.inbox_outlined,
          size: 52,
          color: Theme.of(c).colorScheme.outline,
        ),
        const SizedBox(height: 8),
        Text(text),
      ],
    ),
  );
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext c) =>
      const Center(child: CircularProgressIndicator());
}

class ErrorBox extends StatelessWidget {
  final String text;
  const ErrorBox(this.text, {super.key});
  @override
  Widget build(BuildContext c) => Center(
    child: Card(
      child: Padding(padding: const EdgeInsets.all(22), child: Text(text)),
    ),
  );
}

class DashboardPage extends StatefulWidget {
  final StationRepository r;
  final void Function(int) onOpen;
  final List<int> availableMenu;
  const DashboardPage(this.r, {required this.onOpen, this.availableMenu = const [1, 2, 3, 5, 7, 9, 10, 11, 8, 14, 16, 17], super.key});
  @override
  State<DashboardPage> createState() => _DashboardState();
}

class _DashboardState extends State<DashboardPage> {
  Map<String, Object?>? d;
  Map<String, Object?> session = {};
  double diesel = 0;
  Map<String, Object?>? warning;
  String systemType = 'diesel';
  bool loading = true;
  late final PageController _statsController = PageController(viewportFraction: .78);
  Future<void> load() async {
    try {
      final a = await widget.r.dashboard(),
          c = await widget.r.currentSession(),
          cfg = await SystemConfig.load(widget.r);
      final b = cfg.isDiesel ? await widget.r.dieselStock() : 0.0;
      final w = cfg.isDiesel
          ? await widget.r.dieselWarning()
          : <String, Object?>{};
      if (mounted) {
        setState(() {
          d = a;
          diesel = b;
          session = c;
          warning = w;
          systemType = cfg.type;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _statsController.dispose();
    super.dispose();
  }

  Widget card(String title, String value, IconData icon, Color color) =>
      Container(
        width: 205,
        height: 116,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: [color.withValues(alpha: .16), color.withValues(alpha: .04)],
          ),
          border: Border.all(color: color.withValues(alpha: .18)),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const Spacer(),
            Text(title),
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      );
  @override
  Widget build(BuildContext c) {
    if (loading) {
      return const ColoredBox(
        color: Color(0xFF080F1B),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF39FFB6))),
      );
    }
    final remaining = (d?['remaining'] as num?)?.round() ?? 0;
    const bg = Color(0xFF080F1B);
    const panel = Color(0xFF101E2E);
    const cyan = Color(0xFF00E5FF);
    const neon = Color(0xFF39FFB6);
    const muted = Color(0xFF8CA3B8);

    Widget statCard(String title, String value, IconData icon, Color color) {
      return Container(
        width: 190,
        height: 116,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: .32)),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: .07), blurRadius: 18, spreadRadius: 1),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 23),
            const Spacer(),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted, fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900)),
          ],
        ),
      );
    }

    Widget statusPanel({required IconData icon, required Color color, required String title,
      required String subtitle, Widget? trailing}) {
      return Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: color.withValues(alpha: .22)),
          boxShadow: [BoxShadow(color: color.withValues(alpha: .045), blurRadius: 16)],
        ),
        child: Row(children: [
          Container(width: 43, height: 43,
            decoration: BoxDecoration(color: color.withValues(alpha: .11), borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: .25))),
            child: Icon(icon, color: color)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
            const SizedBox(height: 5),
            Text(subtitle, style: const TextStyle(color: muted, fontSize: 11, height: 1.45)),
          ])),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ]),
      );
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ColoredBox(
        color: bg,
        child: SafeArea(
          child: RefreshIndicator(
            color: neon,
            backgroundColor: panel,
            onRefresh: load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(19),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [Color(0xFF123047), Color(0xFF10251F), Color(0xFF101E2E)],
                    ),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: cyan.withValues(alpha: .38)),
                    boxShadow: [
                      BoxShadow(color: cyan.withValues(alpha: .09), blurRadius: 25, spreadRadius: 1),
                      BoxShadow(color: neon.withValues(alpha: .05), blurRadius: 35),
                    ],
                  ),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('لوحة التحكم', style: TextStyle(color: neon, fontSize: 12, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 7),
                      const Text('مرحباً بك في ساقية', style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 7),
                      Text('ملخص التشغيل والعمليات اليومية في مكان واحد',
                        style: TextStyle(color: Colors.white.withValues(alpha: .72), fontSize: 11, height: 1.5)),
                    ])),
                    Container(width: 57, height: 57,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                        color: cyan.withValues(alpha: .08),
                        border: Border.all(color: neon.withValues(alpha: .7)),
                        boxShadow: [BoxShadow(color: neon.withValues(alpha: .12), blurRadius: 18)]),
                      child: const Icon(Icons.water_drop_rounded, color: neon, size: 30)),
                  ]),
                ),
                const SizedBox(height: 20),
                const Row(children: [
                  Expanded(child: Text('ملخص التشغيل', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900))),
                  Icon(Icons.swipe_rounded, color: cyan, size: 18),
                  SizedBox(width: 5),
                  Text('اسحب', style: TextStyle(color: muted, fontSize: 10)),
                ]),
                const SizedBox(height: 11),
                SizedBox(
                  height: 120,
                  child: PageView(
                    controller: _statsController,
                    scrollDirection: Axis.horizontal,
                    physics: const PageScrollPhysics(),
                    children: [
                      statCard('المستفيدون', '${d?['beneficiaries'] ?? 0}', Icons.people_alt_rounded, cyan),
                      statCard('المنتظرون', '${d?['queue'] ?? 0}', Icons.format_list_numbered_rounded, neon),
                      statCard('طلبات جديدة', '${d?['bookings'] ?? 0}', Icons.event_note_rounded, cyan),
                      statCard('جلسات فعالة', '${d?['running_sessions'] ?? 0}', Icons.timer_rounded, neon),
                      statCard('المستحق', money(d?['due']), Icons.request_quote_rounded, cyan),
                      statCard('المدفوع', money(d?['paid']), Icons.payments_rounded, neon),
                      statCard('حالة الأرصدة', AccountingCalculations.balanceLabel(remaining), Icons.account_balance_wallet_rounded, cyan),
                      statCard('المصروفات', money(d?['expenses']), Icons.receipt_long_rounded, neon),
                      if (systemType == 'diesel')
                        statCard('رصيد الديزل', '${diesel.toStringAsFixed(2)} لتر', Icons.local_gas_station_rounded, cyan),
                      if (systemType != 'diesel')
                        statCard('تشغيل المنظومة', '${d?['running_sessions'] ?? 0} جلسة',
                          systemType == 'solar' ? Icons.wb_sunny_rounded : Icons.bolt_rounded, neon),
                    ].map((item) => Padding(
                      padding: const EdgeInsetsDirectional.only(end: 10),
                      child: item,
                    )).toList(),
                  ),
                ),
                const SizedBox(height: 23),
                _DashboardCircularMenu(
                  availableMenu: widget.availableMenu,
                  onOpen: widget.onOpen,
                ),
                const SizedBox(height: 22),
                Row(children: [
                  Container(width: 4, height: 22, decoration: BoxDecoration(color: neon, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(width: 9),
                  const Text('حالة التشغيل', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 11),
                statusPanel(
                  icon: session.isNotEmpty ? Icons.timer_rounded : Icons.timer_off_rounded,
                  color: session.isNotEmpty ? neon : cyan,
                  title: session.isEmpty ? 'لا توجد جلسة سقي حالية' : 'جلسة السقي الحالية: ${session['beneficiary_name']}',
                  subtitle: session.isEmpty ? 'المضخة متاحة لبدء عملية جديدة' : '${session['pump_name']} • بدأت ${session['actual_start']}',
                  trailing: session.isEmpty ? null : FilledButton(
                    onPressed: () => widget.onOpen(4),
                    style: FilledButton.styleFrom(backgroundColor: neon, foregroundColor: bg),
                    child: const Text('فتح الجلسة'),
                  ),
                ),
                if (systemType == 'diesel') ...[
                  const SizedBox(height: 10),
                  statusPanel(
                    icon: warning?['warning'] == true ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
                    color: warning?['warning'] == true ? const Color(0xFFFFB454) : neon,
                    title: 'تنبيه الديزل',
                    subtitle: '${diesel.toStringAsFixed(2)} لتر متاح من ${warning?['capacity'] ?? 0} لتر',
                    trailing: Text(warning?['warning'] == true ? 'قريب من الحد' : 'طبيعي',
                      style: TextStyle(color: warning?['warning'] == true ? const Color(0xFFFFB454) : neon, fontSize: 10, fontWeight: FontWeight.w900)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class QuickButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const QuickButton(this.text, this.icon, this.color, this.onTap, {super.key});
  @override
  Widget build(BuildContext c) => SizedBox(
    width: 190,
    child: FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon, color: color),
      label: Text(text),
    ),
  );
}

class RecordDetailsPage extends StatefulWidget {
  final StationRepository r;
  final String kind;
  final int id;
  final String title;
  const RecordDetailsPage(
    this.r, {
    required this.kind,
    required this.id,
    required this.title,
    super.key,
  });
  @override
  State<RecordDetailsPage> createState() => _RecordDetailsState();
}

class _RecordDetailsState extends State<RecordDetailsPage> {
  Map<String, Object?> data = {};
  List<Map<String, Object?>> history = [];
  List<Map<String, Object?>> irrigations = [];
  Map<String, Object?> financial = {};
  bool loading = true;
  String? loadError;
  DateTime? filterFrom, filterTo;
  String paymentMovementFilter = 'all';
  DateTime? paymentFrom, paymentTo;
  List<Map<String, Object?>> paymentReceipts = [], paymentDisbursements = [];
  final PageController _financialSummaryController = PageController(viewportFraction: .84);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _financialSummaryController.dispose();
    super.dispose();
  }

  List<Map<String, Object?>> _paymentRows() {
    final all = [
      ...paymentReceipts.map((x) => {...x}),
      ...paymentDisbursements.map((x) => {...x}),
    ];
    return all.where((x) {
      final group = '${x['movement_group']}';
      if (paymentMovementFilter != 'all' && group != paymentMovementFilter) {
        return false;
      }
      final d = DateTime.tryParse('${x['date'] ?? ''}');
      if (paymentFrom != null &&
          (d == null ||
              d.isBefore(
                DateTime(
                  paymentFrom!.year,
                  paymentFrom!.month,
                  paymentFrom!.day,
                ),
              ))) {
        return false;
      }
      if (paymentTo != null &&
          (d == null ||
              d.isAfter(
                DateTime(
                  paymentTo!.year,
                  paymentTo!.month,
                  paymentTo!.day,
                  23,
                  59,
                  59,
                ),
              ))) {
        return false;
      }
      return true;
    }).toList()..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
  }

  Future<void> pickPaymentDate(bool fromDate) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: fromDate
          ? (paymentFrom ?? AppClock.now())
          : (paymentTo ?? AppClock.now()),
      locale: const Locale('ar'),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (fromDate) {
        paymentFrom = picked;
      } else {
        paymentTo = picked;
      }
    });
  }

  Widget paymentMethodMovements(BuildContext c) {
    if (widget.kind != 'payment_method') return const SizedBox.shrink();
    final rows = _paymentRows();
    final receipts = rows
        .where((x) => x['movement_group'] == 'مقبوضات')
        .toList();
    final disb = rows.where((x) => x['movement_group'] == 'مسلّمات').toList();
    final received = receipts.fold<int>(
      0,
      (s, x) => s + ((x['amount'] as num?)?.round() ?? 0),
    );
    final delivered = disb.fold<int>(
      0,
      (s, x) => s + ((x['amount'] as num?)?.round() ?? 0),
    );
    final scheme = Theme.of(c).colorScheme;
    Widget movementCard(Map<String, Object?> x) {
      final incoming = x['movement_group'] == 'مقبوضات';
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: .38),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: (incoming ? _green : _purple).withValues(alpha: .16),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (incoming ? _green : _purple).withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
                color: incoming ? _green : _purple,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${x['party_name'] ?? x['description'] ?? 'حركة'}',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${x['date'] ?? '-'} • ${x['notes'] ?? ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  money(x['amount']),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  incoming ? 'مقبوضات' : 'مسلّمات',
                  style: TextStyle(
                    fontSize: 12,
                    color: incoming ? _green : _purple,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_vert_rounded, color: scheme.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'المسلّمات والمقبوضات',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                '${rows.length} حركة',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              metric(
                c,
                'إجمالي المقبوضات',
                money(received),
                Icons.south_west_rounded,
                _green,
              ),
              metric(
                c,
                'إجمالي المسلّمات',
                money(delivered),
                Icons.north_east_rounded,
                _purple,
              ),
              metric(
                c,
                'الصافي',
                money(received - delivered),
                Icons.account_balance_wallet_rounded,
                _blue,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('الكل'),
                selected: paymentMovementFilter == 'all',
                onSelected: (_) =>
                    setState(() => paymentMovementFilter = 'all'),
              ),
              ChoiceChip(
                label: const Text('المقبوضات'),
                selected: paymentMovementFilter == 'مقبوضات',
                onSelected: (_) =>
                    setState(() => paymentMovementFilter = 'مقبوضات'),
              ),
              ChoiceChip(
                label: const Text('المسلّمات'),
                selected: paymentMovementFilter == 'مسلّمات',
                onSelected: (_) =>
                    setState(() => paymentMovementFilter = 'مسلّمات'),
              ),
              OutlinedButton.icon(
                onPressed: () => pickPaymentDate(true),
                icon: const Icon(Icons.date_range),
                label: Text(
                  paymentFrom == null
                      ? 'من تاريخ'
                      : 'من ${DateFormat('yyyy/MM/dd').format(paymentFrom!)}',
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => pickPaymentDate(false),
                icon: const Icon(Icons.event),
                label: Text(
                  paymentTo == null
                      ? 'إلى تاريخ'
                      : 'إلى ${DateFormat('yyyy/MM/dd').format(paymentTo!)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const EmptyView('لا توجد حركة مطابقة للفلاتر')
          else
            Column(children: [for (final x in rows.take(200)) movementCard(x)]),
        ],
      ),
    );
  }

  Future<void> load() async {
    if (loadError != null && mounted) setState(() => loadError = null);
    try {
      late Map<String, Object?> d;
      List<Map<String, Object?>> h = [];
      switch (widget.kind) {
        case 'beneficiary':
          d = await widget.r.beneficiaryDetails(widget.id);
          // الكشف تصاعدي لحساب الرصيد الجاري؛ نعرضه الأحدث أولًا.
          h = (await widget.r.beneficiaryStatement(widget.id)).reversed.toList();
          financial = await widget.r.partyFinancialSummary(
            'beneficiary',
            widget.id,
          );
          irrigations = await widget.r.partyIrrigations(
            'beneficiary',
            widget.id,
          );
          break;
        case 'worker':
          d = (await widget.r.db.query(
            'workers',
            where: 'id=?',
            whereArgs: [widget.id],
            limit: 1,
          )).first;
          h = await widget.r.workerTransactions(widget.id);
          financial = await widget.r.partyFinancialSummary('worker', widget.id);
          irrigations = await widget.r.partyIrrigations('worker', widget.id);
          break;
        case 'partner':
          d = (await widget.r.db.query(
            'partners',
            where: 'id=?',
            whereArgs: [widget.id],
            limit: 1,
          )).first;
          h = await widget.r.partnerTransactions(widget.id);
          financial = await widget.r.partyFinancialSummary(
            'partner',
            widget.id,
          );
          irrigations = await widget.r.partyIrrigations('partner', widget.id);
          break;
        case 'cashbox':
          d = (await widget.r.db.query(
            'cashboxes',
            where: 'id=?',
            whereArgs: [widget.id],
            limit: 1,
          )).first;
          h = await widget.r.db.query(
            'cashbox_transfers',
            where: 'from_cashbox_id=? OR to_cashbox_id=?',
            whereArgs: [widget.id, widget.id],
            orderBy: 'date DESC',
          );
          break;
        case 'payment_method':
          d = (await widget.r.db.query(
            'payment_methods',
            where: 'id=?',
            whereArgs: [widget.id],
            limit: 1,
          )).first;
          final receipts = await widget.r.db.rawQuery(
            '''SELECT p.id,p.date,p.amount,p.reference_number,p.notes,
                      COALESCE(b.name,w.name,pt.name,'غير محدد') party_name,
                      CASE
                        WHEN p.beneficiary_id IS NOT NULL THEN 'مقبوضات'
                        WHEN p.worker_id IS NOT NULL OR p.partner_id IS NOT NULL THEN 'مسلّمات'
                        ELSE 'مقبوضات'
                      END movement_group
               FROM payments p
               LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id
               LEFT JOIN workers w ON w.id=p.worker_id
               LEFT JOIN partners pt ON pt.id=p.partner_id
               WHERE p.payment_method_id=? AND p.status='posted'
               ORDER BY p.date DESC,p.id DESC''',
            [widget.id],
          );
          final disbursements = await widget.r.db.rawQuery(
            '''SELECT e.id,e.date,e.amount,e.title description,e.notes,
                      COALESCE(e.title,'مصروف') party_name,
                      'مسلّمات' movement_group
               FROM expenses e
               WHERE e.payment_method_id=? AND e.status='posted'
               ORDER BY e.date DESC,e.id DESC''',
            [widget.id],
          );
          paymentReceipts = receipts;
          paymentDisbursements = disbursements;
          h = [
            ...receipts.map((x) => <String, Object?>{...x}),
            ...disbursements.map((x) => <String, Object?>{...x}),
          ]..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
          break;
        case 'queue':
          d = (await widget.r.db.query(
            "SELECT q.*, b.name beneficiary_name FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE q.id=?",
            args: [widget.id],
          )).first;
          h = await widget.r.db.query(
            'audit_logs',
            where: "record_id=? AND table_name='queue_entries'",
            whereArgs: [widget.id],
            orderBy: 'created_at DESC',
          );
          break;
        case 'booking':
          d = (await widget.r.db.query(
            "SELECT b.*, x.name beneficiary_name FROM booking_requests b JOIN beneficiaries x ON x.id=b.beneficiary_id WHERE b.id=?",
            args: [widget.id],
          )).first;
          h = await widget.r.db.query(
            'audit_logs',
            where: "record_id=? AND table_name='booking_requests'",
            whereArgs: [widget.id],
            orderBy: 'created_at DESC',
          );
          break;
        case 'journal':
          d = (await widget.r.db.query(
            'journal_entries',
            where: 'id=?',
            whereArgs: [widget.id],
            limit: 1,
          )).first;
          d = {
            ...d,
            'reference_number': _refLabel(d['reference_type'], d['reference_id']),
          };
          h = await widget.r.db.query(
            "SELECT jl.*,a.name description,"
            "CASE WHEN jl.debit>0 THEN 'عليه' ELSE 'له' END"
            "||COALESCE(' • '||COALESCE(b.name,w.name,p.name),'')"
            "||COALESCE(' • '||jl.memo,'') notes "
            'FROM journal_lines jl JOIN accounts a ON a.id=jl.account_id '
            'LEFT JOIN beneficiaries b ON b.id=jl.beneficiary_id '
            'LEFT JOIN workers w ON w.id=jl.worker_id '
            'LEFT JOIN partners p ON p.id=jl.partner_id '
            'WHERE jl.journal_entry_id=? ORDER BY jl.id',
            args: [widget.id],
          );
          break;
        default:
          d = {};
      }
      if (mounted) {
        setState(() {
          data = d;
          history = h;
          if (financial.isEmpty) financial = {};
          irrigations = irrigations;
          loadError = null;
          loading = false;
        });
      }
    } catch (e, st) {
      debugPrint('RecordDetailsPage.load(${widget.kind}#${widget.id}) failed: $e\n$st');
      if (mounted) {
        setState(() {
          loadError = '$e';
          loading = false;
        });
      }
    }
  }

  String label(String k) =>
      {
        'name': 'الاسم',
        'phone': 'الهاتف',
        'jerba_number': 'رقم الجربة',
        'address': 'العنوان',
        'location': 'الموقع',
        'opening_balance': 'الرصيد الافتتاحي',
        'carried_balance': 'الرصيد المرحل',
        'pay_type': 'طريقة الاستحقاق',
        'fixed_salary': 'الراتب الثابت',
        'hourly_rate': 'أجر الساعة',
        'percentage_rate': 'النسبة',
        'ownership_mode': 'طريقة الملكية',
        'ownership_percentage': 'نسبة الملكية',
        'shares_count': 'عدد الحصص',
        'current_balance': 'الرصيد الحالي',
        'account_number': 'رقم الحساب',
        'bank_name': 'اسم البنك',
        'type': 'النوع',
        'position': 'الترتيب',
        'status': 'الحالة',
        'created_at': 'تاريخ الإنشاء',
        'date': 'التاريخ',
        'amount': 'المبلغ',
        'notes': 'الملاحظات',
        'description': 'البيان',
        'reference_number': 'المرجع',
        'debit': 'عليه',
        'credit': 'له',
        'memo': 'المذكرة',
        'beneficiary_name': 'المستفيد',
        'scheduled_start': 'بداية الموعد',
        'scheduled_end': 'نهاية الموعد',
        'cancel_reason': 'سبب الإلغاء',
        'postponed_count': 'مرات التأجيل',
        'created_by': 'أنشأ بواسطة',
      }[k] ??
      k.replaceAll('_', ' ');

  String displayValue(String k, Object? v) {
    if (v == null || v.toString().trim().isEmpty) return '-';
    if (k == 'ownership_percentage' || k == 'percentage_rate') return '$v%';
    if (k == 'shares_count' || k == 'position' || k == 'postponed_count') {
      return '$v';
    }
    if ([
      'opening_balance',
      'carried_balance',
      'fixed_salary',
      'hourly_rate',
      'current_balance',
      'amount',
      'debit',
      'credit',
    ].contains(k)) {
      return money(v);
    }
    if (k == 'pay_type') return payTypeName('$v');
    if (k == 'ownership_mode') {
      return '$v' == 'percentage' ? 'نسبة ملكية' : 'عدد حصص';
    }
    if (k == 'type') return statusName(v);
    if (k == 'status') return statusName(v);
    return '$v';
  }

  String primaryName() =>
      '${data['name'] ?? data['beneficiary_name'] ?? data['description'] ?? widget.title}';

  String kindCaption() =>
      {
        'beneficiary': 'ملف المستفيد وكشف الحساب',
        'worker': 'ملف العامل وحركات الاستحقاق والدفع',
        'partner': 'ملف الشريك وحركات حصته',
        'cashbox': 'الرصيد وحركة التحويلات',
        'payment_method': 'بيانات طريقة الدفع وحركاتها',
        'queue': 'حالة الدور وسجل الإجراءات',
        'booking': 'تفاصيل الطلب وسجل المراجعة',
        'journal': 'القيد المحاسبي وقيوده التفصيلية',
      }[widget.kind] ??
      'تفاصيل السجل';

  IconData kindIcon() =>
      {
        'beneficiary': Icons.agriculture_rounded,
        'worker': Icons.engineering_rounded,
        'partner': Icons.handshake_rounded,
        'cashbox': Icons.account_balance_wallet_rounded,
        'payment_method': Icons.payments_rounded,
        'queue': Icons.format_list_numbered_rounded,
        'booking': Icons.event_available_rounded,
        'journal': Icons.receipt_long_rounded,
      }[widget.kind] ??
      Icons.description_rounded;

  List<MapEntry<String, Object?>> fieldsFor(List<String> keys) => keys
      .where((k) => data[k] != null && data[k].toString().trim().isNotEmpty)
      .map((k) => MapEntry(k, data[k]))
      .toList();

  Widget fieldTile(BuildContext c, String k, Object? v) {
    final scheme = Theme.of(c).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .48),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label(k),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            displayValue(k, v),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  Widget section(
    BuildContext c,
    String title,
    IconData icon,
    List<MapEntry<String, Object?>> fields,
  ) {
    if (fields.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(c).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(c).colorScheme.outlineVariant.withValues(alpha: .35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .045),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Theme.of(c).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: Theme.of(c).colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (_, box) {
              final columns = box.maxWidth >= 1050
                  ? 4
                  : box.maxWidth >= 700
                  ? 3
                  : box.maxWidth >= 430
                  ? 2
                  : 1;
              const gap = 10.0;
              final width = (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final f in fields)
                    SizedBox(width: width, child: fieldTile(c, f.key, f.value)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget metric(
    BuildContext c,
    String title,
    String value,
    IconData icon,
    Color color,
  ) => Container(
    constraints: const BoxConstraints(minWidth: 170),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [color.withValues(alpha: .18), color.withValues(alpha: .055)],
      ),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: color.withValues(alpha: .18)),
    ),
    child: Row(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Theme.of(c).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget historyView(BuildContext c) {
    if (history.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Theme.of(c).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Column(
          children: [
            Icon(Icons.timeline_rounded, size: 42),
            SizedBox(height: 8),
            Text('لا توجد حركات مرتبطة بهذا السجل'),
          ],
        ),
      );
    }
    const maxItems = 100;
    final shown = history.length < maxItems ? history.length : maxItems;
    return Column(
      children: [
        for (int i = 0; i < shown; i++)
          _TimelineItem(
            first: i == 0,
            last: i == shown - 1,
            title: _historyTitle(history[i]),
            subtitle: _historySub(history[i]),
            amount: _historyAmount(history[i]),
          ),
        if (history.length > maxItems)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'عرض أحدث $maxItems حركة من ${history.length}. استخدم «تصدير التقرير» لكامل الحركات.',
              style: TextStyle(
                color: Theme.of(c).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  /// المستفيد: الموجب = عليه. العامل/الشريك: الموجب = له (مستحق على المحطة).
  String balanceText(Object? v) {
    final n = (v as num?)?.round() ?? 0;
    return widget.kind == 'beneficiary'
        ? AccountingCalculations.balanceLabel(n)
        : AccountingCalculations.partyDueLabel(n);
  }

  Color balanceColor(int b) => widget.kind == 'beneficiary'
      ? (b > 0 ? Colors.red : _green)
      : (b > 0 ? Colors.orange : (b < 0 ? Colors.red : _green));

  Future<void> pickDetailDate(bool fromDate) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: fromDate
          ? (filterFrom ?? AppClock.now())
          : (filterTo ?? AppClock.now()),
      locale: const Locale('ar'),
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (fromDate) {
        filterFrom = picked;
      } else {
        filterTo = picked;
      }
    });
  }

  List<Map<String, Object?>> filteredIrrigations() => irrigations.where((x) {
    final d = DateTime.tryParse('${x['date'] ?? x['start_datetime'] ?? ''}');
    if (d == null) return true;
    if (filterFrom != null &&
        d.isBefore(
          DateTime(filterFrom!.year, filterFrom!.month, filterFrom!.day),
        )) {
      return false;
    }
    if (filterTo != null &&
        d.isAfter(
          DateTime(filterTo!.year, filterTo!.month, filterTo!.day, 23, 59, 59),
        )) {
      return false;
    }
    return true;
  }).toList();

  Future<void> printPersonReport() async {
    final key = widget.kind == 'worker'
        ? 'worker_transactions'
        : widget.kind == 'partner'
        ? 'partner_accounts'
        : 'beneficiary_detailed';
    try {
      // For beneficiary details, print the same statement rows already loaded
      // for this screen, keeping opening/carried balances visible with date filters.
      final sourceRows = widget.kind == 'beneficiary'
          ? history.reversed.where((row) {
              if (const ['opening_balance', 'carried_balance'].contains(row['type'])) {
                return true;
              }
              final rawDate = DateTime.tryParse('${row['date'] ?? ''}');
              if (rawDate == null) return filterFrom == null && filterTo == null;
              if (filterFrom != null &&
                  rawDate.isBefore(DateTime(filterFrom!.year, filterFrom!.month, filterFrom!.day))) {
                return false;
              }
              if (filterTo != null &&
                  rawDate.isAfter(DateTime(filterTo!.year, filterTo!.month, filterTo!.day, 23, 59, 59))) {
                return false;
              }
              return true;
            }).toList()
          : null;
      await ReportService(widget.r).printPdf(
        key,
        from: filterFrom,
        to: filterTo,
        beneficiaryId: widget.kind == 'beneficiary' ? widget.id : null,
        workerId: widget.kind == 'worker' ? widget.id : null,
        partnerId: widget.kind == 'partner' ? widget.id : null,
        sourceRows: sourceRows,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر تصدير التقرير: $e')));
      }
    }
  }

  Widget financialPanel(BuildContext c) {
    if (!['beneficiary', 'worker', 'partner'].contains(widget.kind)) {
      return const SizedBox.shrink();
    }
    final minutes = (financial['irrigation_minutes'] as num?)?.round() ?? 0;
    final total = (financial['irrigation_total'] as num?)?.round() ?? 0;
    final earnings = (financial['earnings'] as num?)?.round() ?? 0;
    final paid = (financial['paid'] as num?)?.round() ?? 0;
    final balance = (financial['balance'] as num?)?.round() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Theme.of(c).colorScheme.primaryContainer.withValues(alpha: .7),
            Theme.of(c).colorScheme.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: Theme.of(c).colorScheme.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.insights_rounded,
                color: Theme.of(c).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              const Text(
                'الملخص المالي والإحصائي',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Builder(
            builder: (context) {
              final items = <Widget>[
                metric(
                  c,
                  'استهلاك السقايات',
                  '$minutes دقيقة',
                  Icons.timer_outlined,
                  _cyan,
                ),
                metric(
                  c,
                  'إجمالي السقايات',
                  money(total),
                  Icons.water_drop_outlined,
                  _blue,
                ),
                if (widget.kind != 'beneficiary')
                  metric(
                    c,
                    'الاستحقاقات/الأرباح',
                    money(earnings),
                    Icons.trending_up_rounded,
                    _purple,
                  ),
                metric(
                  c,
                  'الدفعات المسددة',
                  money(paid),
                  Icons.payments_outlined,
                  _green,
                ),
                metric(
                  c,
                  'حالة الرصيد',
                  balanceText(balance),
                  Icons.account_balance_wallet_outlined,
                  balanceColor(balance),
                ),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 126,
                    child: PageView.builder(
                      scrollDirection: Axis.horizontal,
                      physics: const PageScrollPhysics(),
                      padEnds: false,
                      itemCount: items.length,
                      controller: _financialSummaryController,
                      itemBuilder: (_, index) => Padding(
                        padding: const EdgeInsetsDirectional.only(end: 10),
                        child: items[index],
                      ),
                    ),
                  ),
                  if (items.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Center(
                        child: Text(
                          'اسحب أفقيًا لاستعراض بطاقات الملخص • ${items.length} بطاقات',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget irrigationTable(BuildContext c) {
    final rows = filteredIrrigations();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(c).colorScheme.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: Theme.of(c).colorScheme.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.water_drop_rounded, color: _cyan),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'السقايات المرتبطة',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => pickDetailDate(true),
                icon: const Icon(Icons.date_range),
                label: Text(
                  filterFrom == null
                      ? 'من تاريخ'
                      : '${filterFrom!.day}/${filterFrom!.month}/${filterFrom!.year}',
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => pickDetailDate(false),
                icon: const Icon(Icons.event),
                label: Text(
                  filterTo == null
                      ? 'إلى تاريخ'
                      : '${filterTo!.day}/${filterTo!.month}/${filterTo!.year}',
                ),
              ),
              if (filterFrom != null || filterTo != null)
                TextButton(
                  onPressed: () => setState(() {
                    filterFrom = null;
                    filterTo = null;
                  }),
                  child: const Text('مسح الفلاتر'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: Text('لا توجد سقايات ضمن الفلتر الحالي')),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('اليوم')),
                  DataColumn(label: Text('التاريخ')),
                  DataColumn(label: Text('التفاصيل')),
                  DataColumn(label: Text('المدة')),
                  DataColumn(label: Text('المستحق')),
                  DataColumn(label: Text('المدفوع')),
                ],
                rows: [
                  for (final x in rows)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            DateFormat('EEEE', 'ar').format(
                              DateTime.tryParse('${x['date']}') ??
                                  AppClock.now(),
                            ),
                          ),
                        ),
                        DataCell(Text('${x['date'] ?? '-'}'.split('T').first)),
                        DataCell(
                          Text(
                            '${systemName('${x['system_type']}')} • ${x['notes'] ?? 'جلسة سقي'}',
                          ),
                        ),
                        DataCell(Text('${x['minutes'] ?? 0} دقيقة')),
                        DataCell(Text(money(x['total_amount']))),
                        DataCell(Text(money(x['paid_amount']))),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    if (loading) return const LoadingView();
    if (loadError != null) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ErrorBox('تعذر تحميل بيانات هذا السجل:\n$loadError'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    setState(() => loading = true);
                    load();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (data.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const ErrorBox('تعذر العثور على السجل'),
      );
    }

    final name = primaryName();
    final balance = (data['balance'] is Map)
        ? ((data['balance'] as Map)['balance'] as num?)?.round()
        : null;
    final current = (data['current_balance'] as num?)?.round();
    final debit = (data['debit'] as num?)?.round();
    final credit = (data['credit'] as num?)?.round();

    final basic = fieldsFor([
      'name',
      'phone',
      'jerba_number',
      'address',
      'location',
      'beneficiary_name',
      'account_number',
      'bank_name',
      'type',
      'status',
    ]);
    final accounting = fieldsFor([
      'opening_balance',
      'carried_balance',
      'fixed_salary',
      'hourly_rate',
      'percentage_rate',
      'ownership_mode',
      'ownership_percentage',
      'shares_count',
      'current_balance',
      'position',
      'postponed_count',
    ]);
    final meta = fieldsFor([
      'date',
      'created_at',
      'scheduled_start',
      'scheduled_end',
      'reference_number',
      'description',
      'memo',
      'notes',
      'cancel_reason',
    ]);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(c).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            widget.kind == 'beneficiary'
                ? '$name • ${statusName(data['status'] ?? 'active')} • ${data['phone'] ?? 'لا يوجد هاتف'}'
                : widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          actions: [
            if (['beneficiary', 'worker', 'partner'].contains(widget.kind))
              IconButton(
                onPressed: printPersonReport,
                tooltip: 'تصدير التقرير',
                icon: const Icon(Icons.picture_as_pdf_rounded),
              ),
            IconButton(
              onPressed: load,
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 32),
          children: [
            financialPanel(c),
            if (['beneficiary', 'worker', 'partner'].contains(widget.kind))
              irrigationTable(c),
            const SizedBox(height: 14),
            if (balance != null ||
                current != null ||
                debit != null ||
                credit != null)
              LayoutBuilder(
                builder: (_, box) {
                  final items = <Widget>[];
                  if (balance != null) {
                    items.add(
                      metric(
                        c,
                        'الرصيد',
                        AccountingCalculations.balanceLabel(balance),
                        Icons.account_balance_rounded,
                        balance > 0 ? Colors.redAccent : _green,
                      ),
                    );
                  }
                  if (current != null) {
                    items.add(
                      metric(
                        c,
                        'الرصيد الحالي',
                        money(current),
                        Icons.account_balance_wallet_rounded,
                        _blue,
                      ),
                    );
                  }
                  if (debit != null) {
                    items.add(
                      metric(
                        c,
                        'عليه',
                        money(debit),
                        Icons.arrow_downward_rounded,
                        _purple,
                      ),
                    );
                  }
                  if (credit != null) {
                    items.add(
                      metric(
                        c,
                        'له',
                        money(credit),
                        Icons.arrow_upward_rounded,
                        _green,
                      ),
                    );
                  }
                  if (items.isEmpty) return const SizedBox.shrink();
                  if (box.maxWidth < 700) {
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: items
                          .map((x) => SizedBox(width: box.maxWidth, child: x))
                          .toList(),
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int i = 0; i < items.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(child: items[i]),
                      ],
                    ],
                  );
                },
              ),
            const SizedBox(height: 16),
            if (widget.kind != 'beneficiary') ...[
              section(c, 'البيانات الأساسية', Icons.badge_rounded, basic),
              section(c, 'الأرصدة والاستحقاقات', Icons.account_balance_rounded, accounting),
              section(c, 'معلومات السجل', Icons.info_outline_rounded, meta),
            ],
            paymentMethodMovements(c),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(c).colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Theme.of(
                    c,
                  ).colorScheme.outlineVariant.withValues(alpha: .35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(c).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Icons.timeline_rounded,
                          color: Theme.of(c).colorScheme.secondary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'السجل الزمني',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  historyView(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _historyTitle(Map<String, Object?> x) =>
      '${x['description'] ?? x['type'] ?? x['title'] ?? 'حركة'}';
  String _historyDate(Object? raw) {
    final text = '${raw ?? ''}';
    final d = DateTime.tryParse(text);
    if (d == null) return text.isEmpty ? '-' : text;
    return text.length > 10
        ? DateFormat('yyyy/MM/dd HH:mm').format(d)
        : DateFormat('yyyy/MM/dd').format(d);
  }

  bool get _hasRunningBalance =>
      const ['beneficiary', 'worker', 'partner'].contains(widget.kind);

  String _historySub(Map<String, Object?> x) {
    final note = '${x['notes'] ?? x['memo'] ?? x['status'] ?? ''}'.trim();
    final rawDate = x['date'] ?? x['created_at'];
    final parts = <String>[
      if (rawDate != null && '$rawDate'.isNotEmpty) _historyDate(rawDate),
      if (note.isNotEmpty) note,
      if (_hasRunningBalance && x['balance'] is num)
        'الرصيد بعدها: ${balanceText(x['balance'])}',
    ];
    return parts.join(' • ');
  }

  String _historyAmount(Map<String, Object?> x) {
    // عامل/شريك: مبلغ موقّع (+ يزيد المستحق له، − ينقصه).
    final signed = x['signed_amount'];
    if (signed is num) {
      return '${signed >= 0 ? '+' : '−'} ${money(signed.abs())}';
    }
    // كشف المستفيد: مدين يزيد ما عليه، دائن ينقصه.
    if (x.containsKey('debit') && x.containsKey('credit') && x.containsKey('balance')) {
      final d = (x['debit'] as num?)?.round() ?? 0;
      final cr = (x['credit'] as num?)?.round() ?? 0;
      if (d > 0) return '+ ${money(d)}';
      if (cr > 0) return '− ${money(cr)}';
      return money(0);
    }
    if (x['amount'] != null) return money(x['amount']);
    final d = (x['debit'] as num?)?.round();
    final cr = (x['credit'] as num?)?.round();
    if (d == null && cr == null) return '';
    return money((d ?? 0) > 0 ? d : (cr ?? 0));
  }
}

class _TimelineItem extends StatelessWidget {
  final bool first, last;
  final String title, subtitle, amount;
  const _TimelineItem({
    required this.first,
    required this.last,
    required this.title,
    required this.subtitle,
    required this.amount,
  });
  @override
  Widget build(BuildContext c) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 30,
          child: Column(
            children: [
              if (!first)
                Expanded(
                  child: Container(
                    width: 2,
                    color: Theme.of(c).colorScheme.outlineVariant,
                  ),
                ),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Theme.of(c).colorScheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(c).colorScheme.primary.withValues(alpha: .25),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    color: Theme.of(c).colorScheme.outlineVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(
                c,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: .38),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(c).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (amount.isNotEmpty)
                  Text(
                    amount,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class BeneficiariesPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  const BeneficiariesPage(
    this.r, {
    required this.userId,
    required this.manager,
    super.key,
  });
  @override
  State<BeneficiariesPage> createState() => _BeneficiariesState();
}

class _BeneficiariesState extends State<BeneficiariesPage> {
  final q = TextEditingController();
  List<Map<String, Object?>> rows = [];
  bool loading = true;
  Timer? _debounce;
  int _seq = 0;
  Future<void> load() async {
    // رقم تسلسلي: نتيجة استعلام أقدم لا تكتب فوق نتيجة أحدث.
    final seq = ++_seq;
    setState(() => loading = true);
    try {
      final x = await widget.r.beneficiaries(q.text.trim());
      if (mounted && seq == _seq) setState(() => rows = x);
    } finally {
      if (mounted && seq == _seq) setState(() => loading = false);
    }
  }

  /// تأخير البحث حتى يتوقف المستخدم عن الكتابة بدل استعلام لكل حرف.
  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), load);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    q.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final n = TextEditingController(),
        p = TextEditingController(),
        j = TextEditingController(),
        a = TextEditingController(),
        l = TextEditingController(),
        o = TextEditingController(text: '0'),
        c = TextEditingController(text: '0');
    bool needy = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'إضافة مستفيد',
        children: [
          TextField(
            controller: n,
            decoration: const InputDecoration(
              labelText: 'اسم المستفيد *',
              hintText: 'الاسم الكامل',
            ),
          ),
          TextField(
            controller: p,
            decoration: const InputDecoration(
              labelText: 'رقم الهاتف',
              hintText: 'رقم التواصل',
            ),
          ),
          TextField(
            controller: j,
            decoration: const InputDecoration(labelText: 'رقم الجربة'),
          ),
          TextField(
            controller: a,
            decoration: const InputDecoration(labelText: 'العنوان'),
          ),
          TextField(
            controller: l,
            decoration: const InputDecoration(labelText: 'الموقع'),
          ),
          TextField(
            controller: o,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
          ),
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد المرحل'),
          ),
          StatefulBuilder(
            builder: (c, s) => CheckboxListTile(
              value: needy,
              onChanged: (v) => s(() => needy = v ?? false),
              title: const Text('مستفيد من فئة المحتاجين'),
            ),
          ),
        ],
        onSave: () => Navigator.pop(context, n.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.createBeneficiary(
          name: n.text,
          phone: p.text,
          jerba: j.text,
          address: a.text,
          location: l.text,
          needy: needy,
          opening: int.tryParse(o.text) ?? 0,
          carried: int.tryParse(c.text) ?? 0,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> edit(Map<String, Object?> x) async {
    final n = TextEditingController(text: '${x['name']}'),
        p = TextEditingController(text: '${x['phone'] ?? ''}'),
        j = TextEditingController(text: '${x['jerba_number'] ?? ''}'),
        a = TextEditingController(text: '${x['address'] ?? ''}'),
        l = TextEditingController(text: '${x['location'] ?? ''}'),
        o = TextEditingController(text: '${x['opening_balance'] ?? 0}'),
        c = TextEditingController(text: '${x['carried_balance'] ?? 0}');
    bool needy = (x['is_needy'] as num?)?.toInt() == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تعديل بيانات المستفيد',
        children: [
          TextField(
            controller: n,
            decoration: const InputDecoration(labelText: 'الاسم'),
          ),
          TextField(
            controller: p,
            decoration: const InputDecoration(labelText: 'الهاتف'),
          ),
          TextField(
            controller: j,
            decoration: const InputDecoration(labelText: 'رقم الجربة'),
          ),
          TextField(
            controller: a,
            decoration: const InputDecoration(labelText: 'العنوان'),
          ),
          TextField(
            controller: l,
            decoration: const InputDecoration(labelText: 'الموقع'),
          ),
          TextField(
            controller: o,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
          ),
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد المرحل'),
          ),
          StatefulBuilder(
            builder: (c, s) => CheckboxListTile(
              value: needy,
              onChanged: (v) => s(() => needy = v ?? false),
              title: const Text('مستفيد من فئة المحتاجين'),
            ),
          ),
        ],
        onSave: () => Navigator.pop(context, n.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.updateBeneficiary(x['id'] as int, {
          'name': n.text.trim(),
          'phone': p.text,
          'jerba_number': j.text,
          'address': a.text,
          'location': l.text,
          'is_needy': needy ? 1 : 0,
          'opening_balance': int.tryParse(o.text) ?? 0,
          'carried_balance': int.tryParse(c.text) ?? 0,
        }, widget.userId),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> remove(Map<String, Object?> x) async {
    if (!widget.manager) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حذف السجلات متاح للمدير فقط')),
      );
      return;
    }
    final r = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'حذف منطقي للمستفيد',
        children: [
          const Text(
            'لن تُحذف السجلات المحاسبية، وسيتم إخفاء المستفيد من القوائم النشطة.',
          ),
          TextField(
            controller: r,
            decoration: const InputDecoration(labelText: 'سبب الحذف *'),
          ),
        ],
        onSave: () => Navigator.pop(context, r.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.deleteBeneficiary(x['id'] as int, widget.userId, r.text),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> details(Map<String, Object?> x) async {
    final loaded = await widget.r.beneficiaryDetails(x['id'] as int);
    if (loaded.isEmpty || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecordDetailsPage(
          widget.r,
          kind: 'beneficiary',
          id: x['id'] as int,
          title: 'تفاصيل المستفيد',
        ),
      ),
    );
  }

  Future<void> sendAccountSummary(Map<String, Object?> x) async {
    try {
      final id = x['id'] as int;
      final balanceData = await widget.r.accounting.beneficiaryBalance(id);
      if (!mounted) return;
      final recipientName = x['name']?.toString() ?? 'المستفيد';
      final balance = balanceData['balance'] ?? 0;
      final asOf = AppClock.now();
      await ManualMessageService.offerChoices(
        context,
        title: 'إرسال كشف حساب مختصر',
        recipientName: recipientName,
        phone: x['phone']?.toString() ?? '',
        message: ManualMessageService.accountSummaryMessage(
          recipientName: recipientName,
          partyLabel: 'المستفيد',
          balanceLabel: AccountingCalculations.balanceLabel(balance),
          asOf: asOf,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e))),
        );
      }
    }
  }

  @override
  Widget build(c) => PageFrame(
    title: 'المستفيدون',
    subtitle: 'بحث سريع وإدارة البيانات والأرصدة وكشف الحساب',
    actions: [
      OutlinedButton.icon(
        onPressed: () => ReportService(widget.r).printPdf('beneficiary_list'),
        icon: const Icon(Icons.picture_as_pdf_rounded),
        label: const Text('تقرير المستفيدين'),
      ),
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.person_add),
        label: const Text('إضافة مستفيد'),
      ),
    ],
    child: Column(
      children: [
        TextField(
          controller: q,
          onChanged: _onSearchChanged,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث بالاسم أو الهاتف أو رقم الجربة أو الموقع',
            hintText: 'اكتب جزءًا من الاسم أو الرقم',
          ),
        ),
        const SizedBox(height: 10),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: rows.isEmpty && !loading
              ? const EmptyView('لا توجد بيانات مطابقة')
              : LayoutBuilder(
                  builder: (_, box) {
                    final cols = box.maxWidth >= 1100
                        ? 3
                        : box.maxWidth >= 720
                        ? 2
                        : 1;
                    const gap = 12.0;
                    final w = (box.maxWidth - gap * (cols - 1)) / cols;
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: rows.map((x) {
                          final b = (x['balance'] as num?)?.round() ?? 0;
                          return SizedBox(
                            width: w,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(24),
                              onTap: () => details(x),
                              onLongPress: () => showModalBottomSheet(
                                context: context,
                                showDragHandle: true,
                                builder: (bc) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: const Icon(
                                          Icons.edit_outlined,
                                        ),
                                        title: const Text(
                                          'تعديل بيانات المستفيد',
                                        ),
                                        onTap: () {
                                          Navigator.pop(bc);
                                          edit(x);
                                        },
                                      ),
                                      if (widget.manager)
                                        ListTile(
                                          leading: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.red,
                                          ),
                                          title: const Text('حذف'),
                                          onTap: () {
                                            Navigator.pop(bc);
                                            remove(x);
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              child: Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const CircleAvatar(
                                            child: Icon(
                                              Icons.agriculture_rounded,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              '${x['name']}',
                                              style: const TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            onSelected: (v) {
                                              if (v == 'edit') edit(x);
                                              if (v == 'delete' &&
                                                  widget.manager) {
                                                remove(x);
                                              }
                                            },
                                            itemBuilder: (_) => [
  const PopupMenuItem(value: 'edit', child: Text('تعديل بيانات المستفيد')),
  if (widget.manager)
    const PopupMenuItem(value: 'delete', child: Text('حذف')),
],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        '${x['phone'] ?? 'بدون هاتف'} • ${x['jerba_number'] ?? 'بدون رقم جربة'}',
                                        style: TextStyle(
                                          color: Theme.of(
                                            c,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        AccountingCalculations.balanceLabel(b),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: b > 0 ? Colors.red : _green,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: () => details(x),
                                              icon: const Icon(Icons.open_in_new),
                                              label: const Text('التفاصيل'),
                                            ),
                                            OutlinedButton.icon(
                                              onPressed: () => sendAccountSummary(x),
                                              icon: const Icon(Icons.send_rounded),
                                              label: const Text('إرسال الحساب'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class NewIrrigationPage extends StatefulWidget {
  final StationRepository r;
  final bool manager;
  const NewIrrigationPage(this.r, {required this.manager, super.key});
  @override
  State<NewIrrigationPage> createState() => _NewIrrigationState();
}

class _NewIrrigationState extends State<NewIrrigationPage> {
  List<Map<String, Object?>> beneficiaries = [],
      workers = [],
      partners = [],
      pumps = [],
      queue = [],
      bookings = [],
      sessions = [],
      history = [];
  int? bid, workerId, operatorWorkerId, partnerId, pumpId, queueId, bookingId, sessionId;
  String partyType = 'beneficiary',
      type = 'diesel',
      queueType = 'circular',
      search = '';
  DateTime start = AppClock.now(),
      end = AppClock.now().add(const Duration(hours: 1));
  // يحتفظ بنهاية آخر سقاية ناجحة أثناء البقاء في شاشة السقاية فقط.
  DateTime? nextStartFromPreviousEnd;
  final paid = TextEditingController(text: '0'),
      reason = TextEditingController();
  final searchController = TextEditingController();
  final searchFocusNode = FocusNode();
  final quickFormSearchFocusNode = FocusNode();
  final startTimeController = TextEditingController();
  final endTimeController = TextEditingController();
  final List<Map<String, DateTime>> cloudPeriods = [];
  final cloudQuickController = TextEditingController();
  bool quickCloudMode = false;
  DateTime selectedDate = DateTime(AppClock.now().year, AppClock.now().month, AppClock.now().day);
  String? startPeriod;
  String? endPeriod;
  // لا يُحدَّد زر فترة البداية عند فتح الشاشة؛ يبقى الاختيار محفوظاً حتى dispose.
  bool isStartSelected = false;
  int timeStep = 0;
  bool managerOverride = false,
      loading = true,
      saved = false,
      useSession = false;
  double beneficiaryDiesel = 0;
  // رصيد صاحب الحساب الحالي (مستفيد: الموجب عليه، عامل/شريك: الموجب له).
  int partyBalance = 0;
  Map<String, String> settings = {};

  /// إعداد «اشتراط تجاوز المدير»: مفعّل = المدير وحده يتجاوز مدة الانتظار.
  bool get overrideManagerOnly =>
      (settings['manager_override_required'] ?? 'true') == 'true';
  List<Map<String, Object?>> methods = [];
  int? payMethod;
  @override
  void initState() {
    super.initState();
    final now = AppClock.now();
    selectedDate = DateTime(now.year, now.month, now.day);
    start = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, now.hour, now.minute);
    end = start.add(const Duration(hours: 1));
    startTimeController.text = _hm12(start);
    endTimeController.text = _hm12(end);
    load();
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocusNode.dispose();
    quickFormSearchFocusNode.dispose();
    startTimeController.dispose();
    endTimeController.dispose();
    paid.dispose();
    reason.dispose();
    cloudQuickController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final b = await widget.r.beneficiaries(),
        w = await widget.r.workers(),
        pt = await widget.r.partners(),
        p = await widget.r.db.query('pumps', where: 'active=1', orderBy: 'id'),
        q = await widget.r.queue(),
        bk = await widget.r.bookings(),
        ss = await widget.r.sessions(),
        st = await widget.r.settings(),
        pm = await widget.r.paymentMethods();
    if (mounted) {
      setState(() {
        methods = pm;
        // «تحديث» لا يكتب فوق اختيار المستخدم: الافتراضي فقط إن لم يوجد اختيار صالح.
        if (payMethod == null || !pm.any((x) => x['id'] == payMethod)) {
          final cashM = pm.where((x) => x['type'] == 'cash').toList();
          payMethod =
              (cashM.isNotEmpty
                      ? cashM.first
                      : (pm.isNotEmpty ? pm.first : null))?['id']
                  as int?;
        }
        beneficiaries = b;
        workers = w;
        partners = pt;
        pumps = p;
        queue = q;
        bookings = bk;
        sessions = ss;
        settings = st;
        queueType = st['queue_type'] ?? 'circular';
        if (bid != null && !b.any((x) => x['id'] == bid)) {
          bid = null;
        }
        final configured = int.tryParse(st['selected_pump_id'] ?? '');
        final chosen = p.where((x) => x['id'] == configured).toList();
        if (chosen.isNotEmpty) pumpId = chosen.first['id'] as int;
        type = st['system_type'] ?? 'diesel';
        _dropStaleLinks();
        loading = false;
      });
    }
    await _reloadParty();
  }

  /// يعيد تحميل بيانات صاحب الحساب المختار (سجل، ديزل، رصيد) دون تغيير اختياره.
  Future<void> _reloadParty() async {
    if (partyType == 'beneficiary' && bid != null) {
      await selectBeneficiary(bid!);
      return;
    }
    await _loadPartyBalance();
  }

  Future<void> _loadPartyBalance() async {
    var v = 0;
    if (partyType == 'beneficiary' && bid != null) {
      v = (await widget.r.accounting.beneficiaryBalance(bid!))['balance'] ?? 0;
    } else if (partyType == 'worker' && workerId != null) {
      v = (await widget.r.accounting.workerBalance(workerId!))['balance'] ?? 0;
    } else if (partyType == 'partner' && partnerId != null) {
      v = (await widget.r.accounting.partnerBalance(partnerId!))['balance'] ?? 0;
    }
    if (mounted) setState(() => partyBalance = v);
  }

  Future<void> selectBeneficiary(int id) async {
    final h = await widget.r.irrigations(beneficiaryId: id);
    final d = await widget.r.db.query(
      "SELECT COALESCE(b.opening_diesel_liters, 0)+COALESCE(b.carried_diesel_liters,0)+COALESCE((SELECT SUM(liters) FROM diesel_movements WHERE beneficiary_id=? AND kind IN ('delivery','advance')),0)-COALESCE((SELECT SUM(liters) FROM diesel_movements WHERE beneficiary_id=? AND kind='consumption'),0) stock FROM beneficiaries b WHERE b.id=?",
      args: [id, id, id],
    );
    final bal = await widget.r.accounting.beneficiaryBalance(id);
    if (!mounted) return;
    setState(() {
      partyType = 'beneficiary';
      bid = id;
      workerId = null;
      partnerId = null;
      partyBalance = bal['balance'] ?? 0;
      history = h;
      beneficiaryDiesel = d.isEmpty
          ? 0
          : (d.first['stock'] as num?)?.toDouble() ?? 0;
      _dropStaleLinks();
    });
  }

  /// اختيار صاحب الحساب من نتائج البحث الموحد دون مطالبة المستخدم بتحديد الفئة.
  Future<void> selectParty(String selectedType, int id) async {
    if (selectedType == 'beneficiary') {
      await selectBeneficiary(id);
      return;
    }
    if (selectedType == 'worker') {
      setState(() {
        partyType = 'worker';
        bid = null;
        workerId = id;
        partnerId = null;
        history = [];
        beneficiaryDiesel = 0;
        _dropStaleLinks();
      });
    } else if (selectedType == 'partner') {
      setState(() {
        partyType = 'partner';
        bid = null;
        workerId = null;
        partnerId = id;
        history = [];
        beneficiaryDiesel = 0;
        _dropStaleLinks();
      });
    } else {
      return;
    }
    await _loadPartyBalance();
  }

  // ---- الدور/الحجز/الجلسة: تخص المستفيد المختار فقط ----
  bool get canLink => partyType == 'beneficiary' && bid != null;
  static const _openBookingStatuses = ['scheduled', 'accepted', 'notified'];
  List<Map<String, Object?>> get linkQueue => !canLink
      ? const []
      : queue.where((x) => x['beneficiary_id'] == bid).toList();
  List<Map<String, Object?>> get linkBookings => !canLink
      ? const []
      : bookings
            .where(
              (x) =>
                  x['beneficiary_id'] == bid &&
                  _openBookingStatuses.contains('${x['status']}'),
            )
            .toList();
  List<Map<String, Object?>> get linkSessions => !canLink
      ? const []
      : sessions
            .where((x) => x['beneficiary_id'] == bid && x['status'] == 'running')
            .toList();

  /// يصفّر أي رابط (دور/حجز/جلسة) لم يعد ضمن القوائم المتاحة للطرف الحالي،
  /// فلا يبقى معرّف مختار خارج عناصر القائمة المنسدلة ولا يُرسَل لمستفيد آخر.
  void _dropStaleLinks() {
    if (queueId != null && !linkQueue.any((x) => x['id'] == queueId)) {
      queueId = null;
    }
    if (bookingId != null && !linkBookings.any((x) => x['id'] == bookingId)) {
      bookingId = null;
    }
    if (sessionId != null && !linkSessions.any((x) => x['id'] == sessionId)) {
      sessionId = null;
    }
    if (sessionId == null && !canLink) useSession = false;
  }

  /// إعادة تحميل الأدوار والحجوزات والجلسات والسجل بعد الحفظ كي لا تبقى عناصر مستهلكة.
  Future<void> _refreshAfterSave() async {
    final q = await widget.r.queue(),
        bk = await widget.r.bookings(),
        ss = await widget.r.sessions();
    if (!mounted) return;
    setState(() {
      queue = q;
      bookings = bk;
      sessions = ss;
      _dropStaleLinks();
    });
    await _reloadParty();
  }

  int get minutes => end.difference(start).inMinutes;
  int get cloudMin => quickCloudMode
      ? (int.tryParse(cloudQuickController.text.trim()) ?? 0)
      : cloudPeriods.fold<int>(
          0,
          (sum, p) => sum + p['end']!.difference(p['start']!).inMinutes,
        );
  int get waterRate =>
      int.tryParse(settings['diesel_hourly_water_rate'] ?? '0') ?? 0;
  double get liters =>
      double.tryParse(settings['diesel_liters_per_hour'] ?? '0') ?? 0;
  int get dieselPrice =>
      int.tryParse(settings['diesel_price_per_liter'] ?? '0') ?? 0;
  int get solarRate => int.tryParse(settings['solar_hourly_rate'] ?? '0') ?? 0;
  int get thirdRate =>
      int.tryParse(settings['third_type_hourly_rate'] ?? '0') ?? 0;
  String _balLabel(int v) => partyType == 'beneficiary'
      ? AccountingCalculations.balanceLabel(v)
      : AccountingCalculations.partyDueLabel(v);

  /// هل رصيد ما بعد العملية في غير صالح المحطة/الطرف (مدين للمحطة)؟
  bool _balanceOwed(int v) => partyType == 'beneficiary' ? v > 0 : v < 0;

  Map<String, num> preview() {
    if (minutes <= 0) {
      return {
        'الإجمالي': 0,
        'المياه': 0,
        'الديزل': 0,
        'القابل للمحاسبة': 0,
        'المدفوع': 0,
        'الرصيد الحالي': partyBalance,
        'حالة الرصيد': partyBalance,
      };
    }
    final c = type == 'diesel'
        ? AccountingCalculations.diesel(
            start: start,
            end: end,
            hourlyWaterRate: waterRate,
            litersPerHour: liters,
            dieselPrice: dieselPrice,
            cloudMinutes: 0,
            allowMidnightCrossing:
                settings['allow_midnight_crossing'] == 'true',
            rounding: settings['rounding'] ?? 'nearest',
            partialHour: settings['partial_hour'] != 'false',
          )
        : type == 'solar'
        ? AccountingCalculations.solar(
            start: start,
            end: end,
            hourlyRate: solarRate,
            cloudMinutes: cloudMin,
            allowMidnightCrossing:
                settings['allow_midnight_crossing'] == 'true',
            rounding: settings['rounding'] ?? 'nearest',
            partialHour: settings['partial_hour'] != 'false',
          )
        : AccountingCalculations.equivalent(
            start: start,
            end: end,
            hourlyRate: thirdRate,
            allowMidnightCrossing:
                settings['allow_midnight_crossing'] == 'true',
            rounding: settings['rounding'] ?? 'nearest',
            partialHour: settings['partial_hour'] != 'false',
          );
    final isBeneficiary = partyType == 'beneficiary';
    // نفس سياسة recordIrrigation: يُحمَّل ثمن العجز فقط ما لم يكن تسليم الديزل رصيدًا ماليًا.
    var diesel = c.dieselAmount;
    if (isBeneficiary &&
        type == 'diesel' &&
        c.dieselLiters > 0 &&
        (settings['diesel_delivery_financial_credit'] ?? '').toLowerCase() !=
            'true') {
      final shortage = c.dieselLiters > beneficiaryDiesel
          ? c.dieselLiters - beneficiaryDiesel
          : 0.0;
      diesel = AccountingCalculations.roundAmount(
        shortage * dieselPrice,
        settings['rounding'] ?? 'nearest',
      );
    }
    final total = c.waterAmount + diesel;
    // الدفعة المرافقة للمستفيد فقط (الخدمة ترفضها لغيره).
    final paidValue = isBeneficiary ? (int.tryParse(paid.text) ?? 0) : 0;
    // المستفيد: رصيده + المستحق − المدفوع (الموجب عليه).
    // العامل/الشريك: رصيده − قيمة السقاية (الموجب له).
    final after = isBeneficiary
        ? partyBalance + total - paidValue
        : partyBalance - total;
    return {
      'الإجمالي': total,
      'المياه': c.waterAmount,
      'الديزل': diesel,
      'القابل للمحاسبة': c.chargeableMinutes,
      'المدفوع': paidValue,
      'الرصيد الحالي': partyBalance,
      'حالة الرصيد': after,
    };
  }

  bool _cloudPeriodValid(
    DateTime cloudStart,
    DateTime cloudEnd, {
    int? editingIndex,
  }) {
    if (!cloudEnd.isAfter(cloudStart)) {
      msg('وقت نهاية الغيم يجب أن يكون بعد وقت بدايته');
      return false;
    }
    if (cloudStart.isBefore(start) || cloudEnd.isAfter(end)) {
      msg('فترة الغيم يجب أن تكون داخل وقت السقاية');
      return false;
    }
    for (var i = 0; i < cloudPeriods.length; i++) {
      if (editingIndex != null && i == editingIndex) continue;
      final a = cloudPeriods[i]['start']!;
      final b = cloudPeriods[i]['end']!;
      if (cloudStart.isBefore(b) && cloudEnd.isAfter(a)) {
        msg('فترة الغيم تتداخل مع فترة غيم أخرى');
        return false;
      }
    }
    final existingTotal = cloudPeriods.fold<int>(
      0,
      (sum, period) =>
          sum + period['end']!.difference(period['start']!).inMinutes,
    );
    final replacedTotal = editingIndex == null
        ? 0
        : cloudPeriods[editingIndex]['end']!
            .difference(cloudPeriods[editingIndex]['start']!)
            .inMinutes;
    final total = existingTotal - replacedTotal +
        cloudEnd.difference(cloudStart).inMinutes;
    if (total > minutes) {
      msg('إجمالي خصم الغيم لا يمكن أن يتجاوز مدة السقاية');
      return false;
    }
    return true;
  }

  Future<void> addCloudPeriod({int? editingIndex}) async {
    if (type != 'solar') return;
    final existing = editingIndex == null ? null : cloudPeriods[editingIndex];
    final initialStart = existing?['start'] ?? start;
    final initialEnd =
        existing?['end'] ?? start.add(const Duration(minutes: 15));
    final startController = TextEditingController(text: _hm(initialStart));
    final endController = TextEditingController(text: _hm(initialEnd));
    final quickController = TextEditingController(
      text: quickCloudMode ? cloudQuickController.text : '',
    );
    var dialogQuickMode = quickCloudMode;
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: const Text('إضافة غيم / حساب وقت التوقف'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'اختر طريقة واحدة فقط لحساب خصم الغيم.',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('من البداية إلى النهاية'),
                        selected: !dialogQuickMode,
                        onSelected: (selected) {
                          if (!selected) return;
                          dialogSetState(() => dialogQuickMode = false);
                        },
                      ),
                      ChoiceChip(
                        label: const Text('الغيم السريع'),
                        selected: dialogQuickMode,
                        onSelected: (selected) {
                          if (!selected) return;
                          dialogSetState(() => dialogQuickMode = true);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (dialogQuickMode)
                    TextField(
                      controller: quickController,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: false,
                        signed: false,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'الغيم السريع (بالدقائق)',
                        hintText: 'مثال: 10',
                        suffixText: 'دقيقة',
                      ),
                    )
                  else ...[
                    Row(children: [
                      Expanded(child: TextField(controller: startController, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'بداية الغيم (ساعة:دقيقة)', hintText: '13:10'))),
                      IconButton(tooltip: 'لاقط وقت هجين لبداية الغيم', icon: const Icon(Icons.schedule), onPressed: () async {
                        final initial = _parseCloudClock(startController.text) ?? start;
                        final selected = await _showHybridTimePicker(initial: initial, title: 'اختيار بداية الغيم', use24Hour: true);
                        if (selected != null) { startController.text = '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'; dialogSetState(() {}); }
                      }),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: TextField(controller: endController, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'نهاية الغيم (ساعة:دقيقة)', hintText: '13:20'))),
                      IconButton(tooltip: 'لاقط وقت هجين لنهاية الغيم', icon: const Icon(Icons.schedule), onPressed: () async {
                        final initial = _parseCloudClock(endController.text) ?? start.add(const Duration(minutes: 15));
                        final selected = await _showHybridTimePicker(initial: initial, title: 'اختيار نهاية الغيم', use24Hour: true);
                        if (selected != null) { endController.text = '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'; dialogSetState(() {}); }
                      }),
                    ]),
                    const SizedBox(height: 6),
                    const Text(
                      'استخدم صيغة 24 ساعة، مثل 13:10 إلى 13:20.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () {
                if (dialogQuickMode) {
                  final raw = quickController.text.trim();
                  final value = int.tryParse(raw);
                  if (raw.isEmpty || value == null || value < 0 || value > minutes) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(
                        content: Text('أدخل دقائق صحيحة من 0 إلى $minutes'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, {
                    'mode': 'quick',
                    'minutes': value,
                  });
                  return;
                }
int? parseClock(String raw) {
                  final match = RegExp(
                    r'^\s*(\d{1,2})\s*:\s*(\d{1,2})\s*$',
                  ).firstMatch(raw.trim());
                  if (match == null) return null;
                  final hour = int.tryParse(match.group(1)!);
                  final minute = int.tryParse(match.group(2)!);
                  if (hour == null || hour < 0 || hour > 23 ||
                      minute == null || minute < 0 || minute > 59) {
                    return null;
                  }
                  return hour * 60 + minute;
                }
                final a = parseClock(startController.text);
                final b = parseClock(endController.text);
                if (a == null || b == null || a == b) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text('أدخل وقتي بداية ونهاية صحيحين ومختلفين'),
                    ),
                  );
                  return;
                }
                final cs = DateTime(
                  start.year, start.month, start.day, a ~/ 60, a % 60,
                );
                final ce = DateTime(
                  start.year,
                  start.month,
                  start.day + (b <= a ? 1 : 0),
                  b ~/ 60,
                  b % 60,
                );
                final duration = ce.difference(cs).inMinutes;
                if (duration <= 0 || duration > minutes) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(
                      content: Text('مدة الغيم يجب ألا تتجاوز $minutes دقيقة'),
                    ),
                  );
                  return;
                }
                Navigator.pop(dialogContext, {
                  'mode': 'range',
                  'start': cs,
                  'end': ce,
                });
              },
              icon: const Icon(Icons.check),
              label: const Text('احتساب الغيم'),
            ),
          ],
        ),
      ),
    );
    startController.dispose();
    endController.dispose();
    quickController.dispose();
    if (!mounted || result == null) return;

    if (result['mode'] == 'quick') {
      final value = result['minutes'] as int;
      if (value > minutes) {
        msg('دقائق الغيم لا يمكن أن تتجاوز مدة السقاية');
        return;
      }
      setState(() {
        quickCloudMode = true;
        cloudPeriods.clear();
        cloudQuickController.text = '$value';
      });
      return;
    }

    final cs = result['start'] as DateTime;
    final ce = result['end'] as DateTime;
    if (!_cloudPeriodValid(cs, ce, editingIndex: editingIndex)) return;
    setState(() {
      quickCloudMode = false;
      cloudQuickController.clear();
      final item = {'start': cs, 'end': ce};
      if (editingIndex == null) {
        cloudPeriods.add(item);
      } else {
        cloudPeriods[editingIndex] = item;
      }
      cloudPeriods.sort((a, b) => a['start']!.compareTo(b['start']!));
    });
  }

  Future<TimeOfDay?> _showHybridTimePicker({required DateTime initial, required String title, bool use24Hour = false, bool confirmPeriod = false, String? initialPeriod}) async {
    var hour = use24Hour ? initial.hour : (initial.hour % 12 == 0 ? 12 : initial.hour % 12);
    var minute = initial.minute;
    String? period = confirmPeriod ? initialPeriod : (initial.hour < 12 ? 'am' : 'pm');
    var inputMode = false;
    final hc = TextEditingController(text: hour.toString().padLeft(2, '0'));
    final mc = TextEditingController(text: minute.toString().padLeft(2, '0'));
    final hw = FixedExtentScrollController(initialItem: hour - (use24Hour ? 0 : 1));
    final mw = FixedExtentScrollController(initialItem: minute);
    final result = await showDialog<TimeOfDay>(context: context, builder: (dc) =>
      StatefulBuilder(builder: (context, ds) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('التدوير'), icon: Icon(Icons.swap_vert)),
              ButtonSegment(value: true, label: Text('الكتابة'), icon: Icon(Icons.keyboard)),
            ],
            selected: {inputMode},
            onSelectionChanged: (s) => ds(() {
              inputMode = s.first;
              hc.text = hour.toString().padLeft(2, '0');
              mc.text = minute.toString().padLeft(2, '0');
            }),
          ),
          const SizedBox(height: 12),
          if (inputMode)
            Row(children: [
              Expanded(child: TextField(controller: hc, keyboardType: TextInputType.number, textAlign: TextAlign.center, maxLength: 2, decoration: const InputDecoration(labelText: 'الساعة', counterText: ''))),
              const Text(':', style: TextStyle(fontSize: 24)),
              Expanded(child: TextField(controller: mc, keyboardType: TextInputType.number, textAlign: TextAlign.center, maxLength: 2, decoration: const InputDecoration(labelText: 'الدقيقة', counterText: ''))),
            ])
          else
            SizedBox(height: 145, child: Row(children: [
              Expanded(child: Column(children: [
                const Text('الساعة'),
                Expanded(child: ListWheelScrollView.useDelegate(controller: hw, itemExtent: 40, physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: (i) => ds(() {
                    final previousHour = hour;
                    final nextHour = i + (use24Hour ? 0 : 1);
                    // في نظام 12 ساعة، عبور الحد بين 11 و12 يبدّل الفترة تلقائياً.
                    // بقية تغييرات الساعة لا تغيّر صباحاً/مساءً.
                    if (confirmPeriod && !use24Hour &&
                        ((previousHour == 11 && nextHour == 12) ||
                         (previousHour == 12 && nextHour == 11))) {
                      // إذا لم تُحدد الفترة بعد، اخترها تلقائياً عند عبور حد 12.
                      // بعد تحديدها، اعكسها عند كل عبور تالٍ بين 11 و12.
                      period = period == null
                          ? (nextHour == 12 ? 'pm' : 'am')
                          : (period == 'pm' ? 'am' : 'pm');
                    }
                    hour = nextHour;
                    hc.text = hour.toString().padLeft(2, '0');
                  }),
                  childDelegate: ListWheelChildBuilderDelegate(childCount: use24Hour ? 24 : 12,
                    builder: (context, i) { final v = i + (use24Hour ? 0 : 1); return Center(child: Text(v.toString().padLeft(2, '0'), style: TextStyle(fontSize: v == hour ? 24 : 18, fontWeight: v == hour ? FontWeight.bold : FontWeight.normal))); }),
                )),
              ])),
              const Text(':', style: TextStyle(fontSize: 24)),
              Expanded(child: Column(children: [
                const Text('الدقيقة'),
                Expanded(child: ListWheelScrollView.useDelegate(controller: mw, itemExtent: 40, physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: (v) => ds(() { minute = v; mc.text = minute.toString().padLeft(2, '0'); }),
                  childDelegate: ListWheelChildBuilderDelegate(childCount: 60,
                    builder: (context, v) => Center(child: Text(v.toString().padLeft(2, '0'), style: TextStyle(fontSize: v == minute ? 24 : 18, fontWeight: v == minute ? FontWeight.bold : FontWeight.normal))),
                ))),
              ])),
            ])),
          if (!use24Hour && confirmPeriod) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('صباحاً'), selected: period == 'am', onSelected: (_) => ds(() => period = 'am')),
              ChoiceChip(label: const Text('مساءً'), selected: period == 'pm', onSelected: (_) => ds(() => period = 'pm')),
            ]),
            const Text('يجب اختيار صباحاً أو مساءً قبل التأكيد.', style: TextStyle(fontSize: 12)),
          ],
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('إلغاء')),
          FilledButton.icon(onPressed: () {
            if (confirmPeriod && period == null) {
              ScaffoldMessenger.of(dc).showSnackBar(const SnackBar(content: Text('اختر صباحاً أو مساءً أولاً')));
              return;
            }
            if (inputMode) {
              final ih = int.tryParse(hc.text.trim()), im = int.tryParse(mc.text.trim());
              if (ih == null || ih < (use24Hour ? 0 : 1) || ih > (use24Hour ? 23 : 12) || im == null || im < 0 || im > 59) {
                ScaffoldMessenger.of(dc).showSnackBar(SnackBar(content: Text(use24Hour ? 'أدخل ساعة 00–23 ودقيقة 00–59' : 'أدخل ساعة 01–12 ودقيقة 00–59')));
                return;
              }
              hour = ih; minute = im;
            }
            Navigator.pop(dc, TimeOfDay(hour: use24Hour ? hour : (hour % 12) + (period == 'pm' ? 12 : 0), minute: minute));
          }, icon: const Icon(Icons.check), label: const Text('تأكيد الوقت')),
        ],
      )),
    );
    hc.dispose(); mc.dispose(); hw.dispose(); mw.dispose();
    return result;
  }

  DateTime? _parseCloudClock(String raw) {
    final match = RegExp(r'^\s*(\d{1,2})\s*:\s*(\d{1,2})\s*$').firstMatch(raw.trim());
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || hour < 0 || hour > 23 || minute == null || minute < 0 || minute > 59) return null;
    return DateTime(start.year, start.month, start.day, hour, minute);
  }

  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _hm12(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${h.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  int? _parseTimeMinutes(String raw) {
    final match = RegExp(r'^\s*(\d{1,2})\s*[:.]\s*(\d{1,2})\s*$').firstMatch(raw);
    if (match == null) return null;
    final h = int.tryParse(match.group(1)!);
    final m = int.tryParse(match.group(2)!);
    if (h == null || h < 1 || h > 12 || m == null || m < 0 || m > 59) return null;
    return h * 60 + m;
  }

  int _to24Hour(int minutes, String period) => ((minutes ~/ 60) % 12) + (period == 'pm' ? 12 : 0);
  String _oppositePeriod(String period) => period == 'am' ? 'pm' : 'am';

  void _ensureStartPeriodSelected() {
    // يختار الفترة تلقائياً عند أول تفاعل فقط، ولا يُصفّرها setState أو build.
    startPeriod ??= start.hour < 12 ? 'am' : 'pm';
    isStartSelected = true;
  }

  /// يختار وقت البداية ثم يفتح لاقط وقت النهاية مباشرةً دون الرجوع للشاشة.
  Future<void> pickStartAndThenEnd() async {
    final previousEnd = nextStartFromPreviousEnd;
    final initialStart = previousEnd ?? start;
    final pickedStart = await _showHybridTimePicker(
      initial: initialStart,
      title: 'اختيار وقت البداية',
      confirmPeriod: true,
      initialPeriod: startPeriod ?? (initialStart.hour < 12 ? 'am' : 'pm'),
    );
    if (!mounted || pickedStart == null) return;

    final chosenStart = DateTime(
      selectedDate.year, selectedDate.month, selectedDate.day,
      pickedStart.hour, pickedStart.minute,
    );
    final defaultEnd = chosenStart.add(const Duration(hours: 1));
    setState(() {
      start = chosenStart;
      startTimeController.text = _hm12(chosenStart);
      startPeriod = chosenStart.hour < 12 ? 'am' : 'pm';
      isStartSelected = true;
      end = defaultEnd;
      endTimeController.text = _hm12(defaultEnd);
      endPeriod = defaultEnd.hour < 12 ? 'am' : 'pm';
      timeStep = 1;
    });

    final pickedEnd = await _showHybridTimePicker(
      initial: defaultEnd,
      title: 'اختيار وقت النهاية',
      confirmPeriod: true,
      initialPeriod: endPeriod,
    );
    if (!mounted || pickedEnd == null) return;

    setState(() {
      end = DateTime(
        start.year, start.month, start.day,
        pickedEnd.hour, pickedEnd.minute,
      );
      if (!end.isAfter(start)) {
        end = DateTime(
          start.year, start.month, start.day + 1,
          pickedEnd.hour, pickedEnd.minute,
        );
      }
      endTimeController.text = _hm12(end);
      endPeriod = end.hour < 12 ? 'am' : 'pm';
      cloudPeriods.removeWhere(
        (p) => p['start']!.isBefore(start) || p['end']!.isAfter(end),
      );
    });
  }

  void _updateEndPeriodFromTime() {
    final a = _parseTimeMinutes(startTimeController.text);
    final b = _parseTimeMinutes(endTimeController.text);
    if (a == null || b == null || startPeriod == null) return;
    final startHour = (a ~/ 60) % 12;
    final endHour = (b ~/ 60) % 12;
    final crossesTwelve = (endHour == 0 && startHour != 0) || b < a;
    endPeriod = crossesTwelve ? _oppositePeriod(startPeriod!) : startPeriod;
  }

  void _applyManualEndTime() {
    final value = _parseTimeMinutes(endTimeController.text);
    if (value == null || endPeriod == null) {
      msg('أدخل وقت نهاية صحيحاً');
      return;
    }
    _updateEndPeriodFromTime();
    final hour = _to24Hour(value, endPeriod!);
    final endClock = hour * 60 + value % 60;
    final startClock = start.hour * 60 + start.minute;
    final dayOffset = endClock <= startClock ? 1 : 0;
    end = DateTime(selectedDate.year, selectedDate.month, selectedDate.day + dayOffset, hour, value % 60);
    cloudPeriods.removeWhere((p) => p['start']!.isBefore(start) || p['end']!.isAfter(end));
  }

  Future<void> nextTimeStep() async {
    if (timeStep == 0) {
      setState(_ensureStartPeriodSelected);
      final value = _parseTimeMinutes(startTimeController.text);
      if (value == null) {
        msg('أدخل وقت بداية صحيحاً مثل 08:30');
        return;
      }

      final hour = _to24Hour(value, startPeriod!);
      final chosenStart = DateTime(
        selectedDate.year, selectedDate.month, selectedDate.day, hour, value % 60,
      );
      final defaultEnd = chosenStart.add(const Duration(hours: 1));
      setState(() {
        start = chosenStart;
        // التالي ينقل مباشرةً إلى لاقط الساعة الدوارة لوقت النهاية.
        end = defaultEnd;
        endTimeController.text = _hm12(defaultEnd);
        endPeriod = defaultEnd.hour < 12 ? 'am' : 'pm';
        timeStep = 1;
      });

      final picked = await _showHybridTimePicker(
        initial: end,
        title: 'اختيار وقت النهاية',
        confirmPeriod: true,
        // يبدأ صباحاً/مساءً بما يتوافق مع نهاية الساعة الافتراضية،
        // ويتبدل تلقائياً عند تدوير الساعة عبر 11 ↔ 12.
        initialPeriod: endPeriod,
      );
      if (picked != null && mounted) {
        setState(() {
          end = DateTime(
            start.year, start.month, start.day, picked.hour, picked.minute,
          );
          if (!end.isAfter(start)) {
            end = DateTime(
              start.year, start.month, start.day + 1, picked.hour, picked.minute,
            );
          }
          endTimeController.text = _hm12(end);
          endPeriod = end.hour < 12 ? 'am' : 'pm';
          cloudPeriods.removeWhere(
            (p) => p['start']!.isBefore(start) || p['end']!.isAfter(end),
          );
        });
      }
    } else if (timeStep == 1) {
      final value = _parseTimeMinutes(endTimeController.text);
      if (value == null) {
        msg('أدخل وقت نهاية صحيحاً مثل 09:30');
        return;
      }
      setState(() {
        _applyManualEndTime();
        if (minutes > 0) timeStep = 2;
      });
      if (minutes <= 0) msg('وقت النهاية يجب أن يكون بعد وقت البداية');
    } else {
      setState(() => timeStep = 0);
    }
  }

  Future<void> pickDate(bool isStart) async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: selectedDate,
      locale: const Locale('ar'),
      helpText: 'اختيار تاريخ السقاية',
    );
    if (d == null) return;
    setState(() {
      selectedDate = DateTime(d.year, d.month, d.day);
      start = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, start.hour, start.minute);
      final startClock = start.hour * 60 + start.minute;
      final endClock = end.hour * 60 + end.minute;
      final dayOffset = endClock <= startClock ? 1 : 0;
      end = DateTime(selectedDate.year, selectedDate.month, selectedDate.day + dayOffset, end.hour, end.minute);
      cloudPeriods.clear();
    });
  }

  /// يفتح نموذجاً مختصراً من الفقاعة العائمة داخل نفس حالة السقاية؛
  /// الحفظ يستدعي save() نفسها حتى تبقى قاعدة البيانات والقيود المحاسبية موحدة.
  Future<void> openQuickForm() async {
    if (!mounted || loading || saved) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) {
          final q = search.trim().toLowerCase();
          final matches = beneficiaries.where((x) =>
            '${x['name'] ?? ''}'.toLowerCase().contains(q)).take(8).toList();
          Future<void> chooseTime(bool isStart) async {
            final picked = await _showHybridTimePicker(
              initial: isStart ? start : end,
              title: isStart ? 'ساعة دورة وقت البداية' : 'ساعة دوارة وقت النهاية',
              confirmPeriod: true,
              initialPeriod: (isStart ? start.hour : end.hour) < 12 ? 'am' : 'pm',
            );
            if (picked == null || !mounted) return;
            setState(() {
              if (isStart) {
                start = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, picked.hour, picked.minute);
                startTimeController.text = _hm12(start);
                if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
              } else {
                end = DateTime(start.year, start.month, start.day, picked.hour, picked.minute);
                if (!end.isAfter(start)) end = DateTime(start.year, start.month, start.day + 1, picked.hour, picked.minute);
                endTimeController.text = _hm12(end);
              }
              timeStep = 2;
              cloudPeriods.removeWhere((p) => p['start']!.isBefore(start) || p['end']!.isAfter(end));
            });
            dialogSetState(() {});
          }
          return AlertDialog(
            title: const Text('سقاية جديدة'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('بطاقة وقت التشغيل', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                    const SizedBox(height: 10),
                    TextField(
                      controller: searchController,
                      focusNode: quickFormSearchFocusNode,
                      autofocus: true,
                      onChanged: (v) => setState(() => search = v),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'بحث عن المستفيد',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (matches.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 150),
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: matches.length,
                          itemBuilder: (context, i) {
                            final item = matches[i];
                            final id = item['id'] as int?;
                            return ListTile(
                              dense: true,
                              title: Text('${item['name'] ?? 'غير معروف'}'),
                              selected: bid == id,
                              onTap: () {
                                setState(() { partyType = 'beneficiary'; bid = id; workerId = null; partnerId = null; });
                                dialogSetState(() {});
                              },
                            );
                          },
                        ),
                      ),
                    if (bid != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('المستفيد المحدد: ${beneficiaries.firstWhere((x) => x['id'] == bid, orElse: () => <String, Object?>{})['name'] ?? 'محدد'}'),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => chooseTime(true),
                      icon: const Icon(Icons.access_time),
                      label: Text('بداية التشغيل: ${_hm12(start)}'),
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: () => chooseTime(false),
                      icon: const Icon(Icons.av_timer),
                      label: Text('نهاية التشغيل: ${_hm12(end)}'),
                    ),
                    if (type == 'solar') ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          timeStep = 2;
                          await addCloudPeriod();
                          if (mounted) dialogSetState(() {});
                        },
                        icon: const Icon(Icons.cloud_outlined),
                        label: Text(quickCloudMode ? 'تعديل الغيم' : 'إضافة غيم'),
                      ),
                      if (quickCloudMode)
                        Text('الغيم: ${cloudQuickController.text} دقيقة'),
                      if (!quickCloudMode && cloudPeriods.isNotEmpty)
                        ...cloudPeriods.map((p) => Text('الغيم: ${_hm12(p['start']!)} – ${_hm12(p['end']!)}')),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton.icon(
                onPressed: loading ? null : () async {
                  if (bid == null) {
                    msg('اختر مستفيداً من مربع البحث أولاً');
                    return;
                  }
                  if (!end.isAfter(start)) {
                    msg('وقت النهاية يجب أن يكون بعد وقت البداية');
                    return;
                  }
                  setState(() => timeStep = 2);
                  await save();
                  if (!mounted || !saved || !dialogContext.mounted) return;
                  // بعد نجاح الحفظ نجهز الفورم لسقاية تالية، ونبدأ من نهاية
                  // السقاية المحفوظة دون إغلاق الفورم.
                  final previousEnd = end;
                  setState(() {
                    selectedDate = DateTime(previousEnd.year, previousEnd.month, previousEnd.day);
                    start = previousEnd;
                    end = start.add(const Duration(hours: 1));
                    startTimeController.text = _hm12(start);
                    endTimeController.text = _hm12(end);
                    bid = null;
                    workerId = null;
                    operatorWorkerId = null;
                    partnerId = null;
                    queueId = null;
                    bookingId = null;
                    sessionId = null;
                    partyType = 'beneficiary';
                    search = '';
                    searchController.clear();
                    paid.text = '0';
                    reason.clear();
                    cloudPeriods.clear();
                    cloudQuickController.clear();
                    quickCloudMode = false;
                    managerOverride = false;
                    useSession = false;
                    timeStep = 0;
                    startPeriod = start.hour < 12 ? 'am' : 'pm';
                    endPeriod = end.hour < 12 ? 'am' : 'pm';
                    isStartSelected = false;
                    saved = false;
                  });
                  dialogSetState(() {});
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && dialogContext.mounted) {
                      quickFormSearchFocusNode.requestFocus();
                    }
                  });
                },
                icon: const Icon(Icons.save_rounded),
                label: const Text('حفظ سقاية'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> save() async {
    if (timeStep != 2) {
      msg('أكمل تحديد وقت البداية والنهاية بالضغط على التالي أولاً');
      return;
    }
    if ((partyType == 'beneficiary' && bid == null) ||
        (partyType == 'worker' && workerId == null) ||
        (partyType == 'partner' && partnerId == null) ||
        pumpId == null) {
      msg('يجب اختيار صاحب الحساب والمضخة');
      return;
    }
    if (minutes <= 0) {
      msg('وقت النهاية يجب أن يكون بعد وقت البداية');
      return;
    }
    if (type == 'solar' &&
        (cloudMin < 0 || cloudMin > minutes ||
            (quickCloudMode && cloudQuickController.text.trim().isEmpty))) {
      msg('أدخل دقائق غيم صحيحة لا تتجاوز مدة السقاية');
      return;
    }
    if (useSession && sessionId == null) {
      msg('اختر جلسة سقي عند تفعيل استخدام وقت الجلسة');
      return;
    }
    _dropStaleLinks();
    if (managerOverride && overrideManagerOnly && !widget.manager) {
      msg('تجاوز مدة الانتظار متاح للمدير فقط');
      return;
    }
    if (managerOverride && reason.text.trim().isEmpty) {
      msg('أدخل سبب تجاوز مدة الانتظار');
      return;
    }
    final currentSettings = await widget.r.settings();
    type = currentSettings['system_type'] ?? type;
    if (type == 'solar') cloudPeriods.removeWhere((p) => p['end']!.isAfter(end));
    setState(() => loading = true);
    try {
      // المحطة = محطة المضخة المختارة (لا رقم ثابت).
      final pumpRow = pumps.where((x) => x['id'] == pumpId).toList();
      final stationId =
          (pumpRow.isEmpty ? null : (pumpRow.first['station_id'] as num?))
              ?.toInt() ??
          await widget.r.accounting.currentStationId();
      final recipientId = partyType == 'beneficiary'
          ? bid
          : partyType == 'worker'
          ? workerId
          : partnerId;
      final recipientRows = partyType == 'beneficiary'
          ? beneficiaries
          : partyType == 'worker'
          ? workers
          : partners;
      Map<String, Object?>? recipient;
      for (final row in recipientRows) {
        if (row['id'] == recipientId) {
          recipient = row;
          break;
        }
      }
      final previousBalance = partyType == 'beneficiary'
          ? (await widget.r.accounting.beneficiaryBalance(bid!))['balance'] ?? 0
          : 0;
      final irrigationId = await widget.r.accounting.recordIrrigation(
        stationId: stationId,
        pumpId: pumpId!,
        beneficiaryId: partyType == 'beneficiary' ? bid : null,
        workerId: partyType == 'worker' ? workerId : null,
        operatorWorkerId: partyType == 'beneficiary' ? operatorWorkerId : null,
        partnerId: partyType == 'partner' ? partnerId : null,
        partyType: partyType,
        start: start,
        end: end,
        systemType: type,
        waterRate: waterRate,
        litersPerHour: liters,
        dieselPrice: dieselPrice,
        solarRate: solarRate,
        thirdRate: thirdRate,
        cloudMinutes: cloudMin,
        cloudPeriods: cloudPeriods
            .map(
              (p) => {
                'start': p['start']!.toIso8601String(),
                'end': p['end']!.toIso8601String(),
              },
            )
            .toList(),
        paidAmount: partyType == 'beneficiary'
            ? (int.tryParse(paid.text) ?? 0)
            : 0,
        paymentMethodId: payMethod,
        bookingId: canLink ? bookingId : null,
        queueId: canLink ? queueId : null,
        sessionId: canLink ? sessionId : null,
        overrideWaitingPeriod: managerOverride,
        overrideReason: reason.text,
      );
      // لا ننقل الوقت إلا بعد نجاح حفظ السقاية والقيد المحاسبي.
      nextStartFromPreviousEnd = end;
      if (mounted) setState(() => saved = true);
      msg('تم حفظ السقاية والقيد المحاسبي بنجاح');
      await _refreshAfterSave();
      if (partyType == 'beneficiary') {
        try {
          final irrigationRows = await widget.r.db.rawQuery(
            'SELECT i.*,b.name beneficiary_name,p.name pump_name FROM irrigations i '
            'LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id '
            'LEFT JOIN pumps p ON p.id=i.pump_id WHERE i.id=?',
            [irrigationId],
          );
          final row = irrigationRows.isEmpty ? <String, Object?>{} : irrigationRows.first;
          final currentBalance = (await widget.r.accounting.beneficiaryBalance(bid!))['balance'] ?? 0;
          String balanceText(int value) => value > 0
              ? 'عليه $value ريال'
              : value < 0
                  ? 'له ${value.abs()} ريال'
                  : 'متوازن (0 ريال)';
          final systemName = switch ('${row['system_type'] ?? type}') {
            'diesel' => 'ديزل',
            'solar' => 'شمسي',
            'equivalent_hybrid' => 'النوع الثالث',
            _ => 'غير محدد',
          };
          final total = (row['total_amount'] as num?)?.round() ?? 0;
          final water = (row['water_amount'] as num?)?.round() ?? 0;
          final diesel = (row['diesel_amount'] as num?)?.round() ?? 0;
          final paidAmount = (row['paid_amount'] as num?)?.round() ?? 0;
          final cloud = (row['cloud_minutes'] as num?)?.round() ?? 0;
          await widget.r.notify(
            beneficiaryId: bid,
            type: 'irrigation',
            title: 'تفاصيل السقاية والرصيد',
            body: [
              'المستفيد: ${row['beneficiary_name'] ?? recipient?['name'] ?? 'غير محدد'}',
              'المضخة: ${row['pump_name'] ?? 'غير محددة'}',
              'نوع المنظومة: $systemName',
              'وقت السقاية: ${DateFormat('yyyy/MM/dd HH:mm').format(start)} إلى ${DateFormat('yyyy/MM/dd HH:mm').format(end)}',
              'مدة السقاية: $minutes دقيقة (خصم الغيم: $cloud دقيقة)',
              'قيمة المياه: $water ريال',
              if (systemName == 'ديزل') 'قيمة الديزل المحتسبة: $diesel ريال',
              'الرصيد السابق: ${balanceText(previousBalance)}',
              'قيمة السقاية الحالية: $total ريال',
              'المدفوع: $paidAmount ريال',
              'الرصيد بعد السقاية: ${balanceText(currentBalance)}',
            ].join('\n'),
          );
        } catch (_) {
          // لا نعتبر حفظ السقاية فاشلًا إذا تعذر تسجيل الإشعار.
        }
      }
      if (mounted) {
        final recipientName = recipient?['name']?.toString() ?? 'الطرف';
        final eventVerb = partyType == 'beneficiary'
            ? 'تم تسجيل السقاية لكم'
            : 'تم تسجيل السقاية المرتبطة بحسابكم';
        String message;
        if (partyType == 'beneficiary') {
          final rows = await widget.r.db.rawQuery(
            'SELECT i.*, b.name beneficiary_name, p.name pump_name '
            'FROM irrigations i '
            'LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id '
            'LEFT JOIN pumps p ON p.id=i.pump_id WHERE i.id=?',
            [irrigationId],
          );
          final row = rows.isEmpty ? <String, Object?>{} : rows.first;
          final currentBalance =
              (await widget.r.accounting.beneficiaryBalance(bid!))['balance'] ?? 0;
          String balanceLabel(int value) => value > 0
              ? 'عليه $value ريال'
              : value < 0
                  ? 'له ${value.abs()} ريال'
                  : 'متوازن (0 ريال)';
          final total = (row['total_amount'] as num?)?.round() ?? 0;
          final water = (row['water_amount'] as num?)?.round() ?? 0;
          final diesel = (row['diesel_amount'] as num?)?.round() ?? 0;
          final paidAmount = (row['paid_amount'] as num?)?.round() ?? 0;
          final cloud = (row['cloud_minutes'] as num?)?.round() ?? 0;
          final chargeableMinutes =
              (row['chargeable_minutes'] as num?)?.round() ?? minutes - cloud;
          final hourlyRate =
              (row['water_hourly_rate_snapshot'] as num?)?.toDouble() ?? waterRate.toDouble();
          final minuteRate = hourlyRate / 60;
          final systemName = switch ('${row['system_type'] ?? type}') {
            'diesel' => 'ديزل',
            'solar' => 'شمسي',
            'equivalent_hybrid' => 'النوع الثالث',
            _ => 'غير محدد',
          };
          message = [
            'السلام عليكم $recipientName،',
            'تم تسجيل السقاية لكم بنجاح.',
            'المستفيد: ${row['beneficiary_name'] ?? recipientName}',
            'المضخة: ${row['pump_name'] ?? 'غير محددة'}',
            'نوع المنظومة: $systemName',
            'من: ${DateFormat('yyyy/MM/dd HH:mm').format(start)}',
            'إلى: ${DateFormat('yyyy/MM/dd HH:mm').format(end)}',
            'إجمالي الدقائق: $minutes دقيقة',
            if (cloud > 0) 'دقائق الغيم المخصومة: $cloud دقيقة',
            'الدقائق المحتسبة: $chargeableMinutes دقيقة',
            'سعر الدقيقة: ${minuteRate.toStringAsFixed(2)} ريال',
            'قيمة المياه: $water ريال',
            if (systemName == 'ديزل') 'قيمة الديزل: $diesel ريال',
            'إجمالي السقاية الحالية: $total ريال',
            'المدفوع: $paidAmount ريال',
            'الرصيد السابق: ${balanceLabel(previousBalance)}',
            'الرصيد بعد السقاية: ${balanceLabel((currentBalance as num).round())}',
            'رقم العملية: $irrigationId',
          ].join('\n');
        } else {
          message = [
            'السلام عليكم $recipientName،',
            eventVerb,
            'التاريخ: ${DateFormat('yyyy/MM/dd').format(start)} من ${DateFormat('HH:mm').format(start)} إلى ${DateFormat('HH:mm').format(end)}',
            'المدة: $minutes دقيقة.',
            'رقم العملية: $irrigationId.',
          ].join('\n');
        }
        if (!mounted) return;
        await ManualMessageService.offerChoices(
          context,
          title: 'تم تسجيل السقاية',
          recipientName: recipientName,
          phone: recipient?['phone']?.toString() ?? '',
          message: message,
        );
      }
      // جهّز النموذج تلقائياً للسقاية التالية وأعد المؤشر إلى البحث.
      if (mounted) await newOperation();
    } catch (e) {
      msg(friendlyError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> newOperation() async {
    searchController.clear();
    setState(() {
      search = '';
      saved = false;
      // تبدأ السقاية التالية من نهاية السقاية السابقة، بالتاريخ والوقت نفسيهما.
      // إن لم توجد سقاية سابقة محفوظة، استخدم الوقت الحالي.
      final clock = nextStartFromPreviousEnd ?? AppClock.now();
      selectedDate = DateTime(clock.year, clock.month, clock.day);
      start = DateTime(clock.year, clock.month, clock.day, clock.hour, clock.minute);
      end = start.add(const Duration(hours: 1));
      startTimeController.text = _hm12(start);
      endTimeController.text = _hm12(end);
      // لا تُصفّر isStartSelected أو startPeriod أثناء عمر الشاشة.
      // تُهيّأ فترة النهاية فقط، ويظل زر البداية على حالته السابقة حتى dispose.
      endPeriod = end.hour < 12 ? 'am' : 'pm';
      timeStep = 0;
      paid.text = '0';
      cloudPeriods.clear();
      quickCloudMode = false;
      cloudQuickController.clear();
      reason.clear();
      managerOverride = false;
      queueId = null;
      bookingId = null;
      sessionId = null;
    });
    // أعد تحميل رصيد الديزل والسجل والأدوار والجلسات والرصيد بدل عرض بيانات ما قبل الحفظ.
    await load();
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          searchFocusNode.requestFocus();
        }
      });
    }
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  @override
  Widget build(c) {
    if (loading && beneficiaries.isEmpty) return const LoadingView();
    final p = preview();
    bool keepSelected(Map<String, Object?> x, int? selected) =>
        x['id'] == selected;
    final query = search.trim().toLowerCase();
    final matchingParties = <Map<String, Object?>>[
      ...beneficiaries
          .where((x) => keepSelected(x, bid) || (query.isNotEmpty && '${x['name'] ?? ''}'.toLowerCase().contains(query)))
          .map((x) => <String, Object?>{'type': 'beneficiary', 'row': x}),
      ...workers
          .where((x) => keepSelected(x, workerId) || (query.isNotEmpty && '${x['name'] ?? ''}'.toLowerCase().contains(query)))
          .map((x) => <String, Object?>{'type': 'worker', 'row': x}),
      ...partners
          .where((x) => keepSelected(x, partnerId) || (query.isNotEmpty && '${x['name'] ?? ''}'.toLowerCase().contains(query)))
          .map((x) => <String, Object?>{'type': 'partner', 'row': x}),
    ];
    return PageFrame(
      title: 'سقاية جديدة • ${systemName(type)}',
      subtitle: 'عملية مخصصة للمنظومة الحالية مرتبطة بالحساب والقيد المحاسبي',
      actions: [
        if (saved)
          OutlinedButton.icon(
            onPressed: newOperation,
            icon: const Icon(Icons.add),
            label: const Text('عملية جديدة'),
          ),
      ],
      child: ListView(
        children: [
          SectionCard(
            title: '3. الدور وطريقة الوقت',
            icon: Icons.alt_route_rounded,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (!canLink)
                  const Chip(
                    avatar: Icon(Icons.info_outline),
                    label: Text(
                      'الربط بالدور والحجز والجلسة متاح عند اختيار مستفيد فقط',
                    ),
                  ),
                Container(
                  constraints: const BoxConstraints(
                    minWidth: 280,
                    maxWidth: 520,
                  ),
                  child: fieldSelect<int>(
                    queueType == 'booking' ? 'الدور المحجوز' : 'الدور الحالي',
                    queueType == 'booking' ? bookingId : queueId,
                    [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('بدون ربط بالدور'),
                      ),
                      if (queueType == 'booking')
                        for (final x in linkBookings)
                          DropdownMenuItem(
                            value: x['id'] as int,
                            child: Text(
                              'الدور • ${x['beneficiary_name']} • ${x['scheduled_start'] ?? 'الموعد غير محدد'}',
                            ),
                          )
                      else
                        for (final x in linkQueue)
                          DropdownMenuItem(
                            value: x['id'] as int,
                            child: Text(
                              'الدور ${x['position']} • ${x['beneficiary_name']}',
                            ),
                          ),
                    ],
                    (v) => setState(() {
                      queueId = queueType == 'circular' ? v : null;
                      bookingId = queueType == 'booking' ? v : null;
                    }),
                  ),
                ),
                fieldSelect<int>('جلسة سقي محفوظة', sessionId, [
                  const DropdownMenuItem(value: null, child: Text('بدون جلسة')),
                  for (final x in linkSessions)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text(
                        '${statusName(x['status'])} • ${x['actual_start'] ?? x['planned_start'] ?? ''}',
                      ),
                    ),
                ], (v) => setState(() => sessionId = v)),
                SizedBox(
                  width: 220,
                  child: SwitchListTile(
                    value: useSession,
                    onChanged: canLink
                        ? (v) => setState(() => useSession = v)
                        : null,
                    title: const Text('استخدام وقت جلسة السقي'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'بيانات التشغيل',
            icon: Icons.settings_input_component,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Align(alignment: AlignmentDirectional.centerStart, child: Text('البحث واختيار صاحب الحساب', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
                const SizedBox(height: 10),
                TextField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  onChanged: (v) => setState(() => search = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'ابحث بالاسم بين المستفيدين والعمال والشركاء',
                    hintText: 'اكتب أي جزء من الاسم',
                  ),
                ),
                const SizedBox(height: 10),
                if (partyType == 'beneficiary' && bid != null)
                  Chip(
                    avatar: const Icon(Icons.person),
                    label: Text('المحدد: ${beneficiaries.firstWhere((x) => x['id'] == bid, orElse: () => <String, Object?>{})['name'] ?? '-'} • مستفيد'),
                  )
                else if (partyType == 'worker' && workerId != null)
                  Chip(
                    avatar: const Icon(Icons.engineering),
                    label: Text('المحدد: ${workers.firstWhere((x) => x['id'] == workerId, orElse: () => <String, Object?>{})['name'] ?? '-'} • عامل'),
                  )
                else if (partyType == 'partner' && partnerId != null)
                  Chip(
                    avatar: const Icon(Icons.handshake),
                    label: Text('المحدد: ${partners.firstWhere((x) => x['id'] == partnerId, orElse: () => <String, Object?>{})['name'] ?? '-'} • شريك'),
                  ),
                if (query.isNotEmpty)
                  ...matchingParties.take(12).map((entry) {
                    final x = entry['row'] as Map<String, Object?>;
                    final selectedType = entry['type'] as String;
                    final category = selectedType == 'beneficiary'
                        ? 'مستفيد'
                        : selectedType == 'worker'
                            ? 'عامل'
                            : 'شريك';
                    return ListTile(
                      dense: true,
                      leading: Icon(selectedType == 'beneficiary'
                          ? Icons.person
                          : selectedType == 'worker'
                              ? Icons.engineering
                              : Icons.handshake),
                      title: Text('${x['name'] ?? '-'}'),
                      subtitle: Text(category),
                      trailing: const Icon(Icons.north_west, size: 18),
                      onTap: () async {
                        final id = (x['id'] as num?)?.toInt();
                        if (id == null) return;
                        searchController.clear();
                        setState(() => search = '');
                        await selectParty(selectedType, id);
                      },
                    );
                  }),
                const SizedBox(height: 18),
                const Align(alignment: AlignmentDirectional.centerStart, child: Text('وقت السقاية وفترات الغيم', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
                const SizedBox(height: 10),

                OutlinedButton.icon(
                  onPressed: () => pickDate(true),
                  icon: const Icon(Icons.event),
                  label: Text('تاريخ جديد: ${selectedDate.year}/${selectedDate.month.toString().padLeft(2, '0')}/${selectedDate.day.toString().padLeft(2, '0')}'),
                ),
                const SizedBox(height: 8),
                if (timeStep == 0) ...[
                  const Align(alignment: AlignmentDirectional.centerStart, child: Text('وقت البداية', style: TextStyle(fontWeight: FontWeight.w800))),
                  Row(children: [
                    SizedBox(width: 240, child: TextField(controller: startTimeController, keyboardType: TextInputType.datetime, onTap: () { if (startPeriod == null) setState(_ensureStartPeriodSelected); }, onChanged: (_) { if (startPeriod == null) setState(_ensureStartPeriodSelected); }, decoration: const InputDecoration(labelText: 'الساعة والدقيقة', hintText: '08:30'))),
                    IconButton(tooltip: 'لاقط وقت هجين للبداية', icon: const Icon(Icons.schedule), onPressed: () async {
                      await pickStartAndThenEnd();
                    }),
                  ]),
                  Wrap(spacing: 8, children: [
                    ChoiceChip(label: const Text('صباحاً'), selected: isStartSelected && startPeriod == 'am', onSelected: (_) => setState(() { isStartSelected = true; startPeriod = 'am'; _updateEndPeriodFromTime(); })),
                    ChoiceChip(label: const Text('مساءً'), selected: isStartSelected && startPeriod == 'pm', onSelected: (_) => setState(() { isStartSelected = true; startPeriod = 'pm'; _updateEndPeriodFromTime(); })),
                  ]),
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.icon(
                      onPressed: nextTimeStep,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('التالي'),
                    ),
                  ),
                ] else if (timeStep == 1) ...[
                  const Align(alignment: AlignmentDirectional.centerStart, child: Text('وقت النهاية', style: TextStyle(fontWeight: FontWeight.w800))),
                  Row(children: [
                    SizedBox(width: 240, child: TextField(controller: endTimeController, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'الساعة والدقيقة', hintText: '09:30'), onChanged: (_) => setState(_updateEndPeriodFromTime))),
                    IconButton(tooltip: 'لاقط وقت هجين للنهاية', icon: const Icon(Icons.schedule), onPressed: () async {
                      final value = _parseTimeMinutes(endTimeController.text);
                      final hour24 = value == null ? end.hour : _to24Hour(value, endPeriod ?? (end.hour < 12 ? 'am' : 'pm'));
                      final picked = await _showHybridTimePicker(initial: DateTime(selectedDate.year, selectedDate.month, selectedDate.day, hour24, value == null ? end.minute : value % 60), title: 'اختيار وقت النهاية');
                      if (picked != null) {
                        setState(() {
                        endTimeController.text = '${(picked.hour % 12 == 0 ? 12 : picked.hour % 12).toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                        _updateEndPeriodFromTime();
                      });
                      }
                    }),
                  ]),
                  Chip(avatar: const Icon(Icons.schedule), label: Text('الفترة تلقائياً: ${endPeriod == 'am' ? 'صباحاً' : 'مساءً'}')),
                  TextButton.icon(onPressed: () => setState(() => timeStep = 0), icon: const Icon(Icons.arrow_back), label: const Text('تعديل وقت البداية')),
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.icon(
                      onPressed: nextTimeStep,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('تأكيد وقت النهاية'),
                    ),
                  ),
                ] else ...[
                  Text('البداية: ${_hm12(start)} ${start.hour < 12 ? 'صباحاً' : 'مساءً'}'),
                  Text('النهاية: ${_hm12(end)} ${end.hour < 12 ? 'صباحاً' : 'مساءً'}'),
                  TextButton.icon(onPressed: () => setState(() => timeStep = 0), icon: const Icon(Icons.edit), label: const Text('تعديل الوقت')),
                ],
                if (end.year != start.year || end.month != start.month || end.day != start.day)
                  const Chip(avatar: Icon(Icons.nights_stay_outlined), label: Text('وقت النهاية في اليوم التالي')),
                Chip(label: Text('المدة: $minutes دقيقة'), avatar: const Icon(Icons.timelapse)),
                if (type == 'solar') ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: minutes > 0 ? () => addCloudPeriod() : null,
                    icon: const Icon(Icons.cloud_outlined),
                    label: Text(quickCloudMode ? 'تعديل الغيم السريع' : 'إضافة غيم'),
                  ),
                  if (quickCloudMode)
                    Chip(
                      avatar: const Icon(Icons.bolt, size: 18),
                      label: Text('الغيم السريع: $cloudMin دقيقة'),
                    ),
                  if (!quickCloudMode && cloudPeriods.isNotEmpty)
                    ...cloudPeriods.asMap().entries.map((entry) {
                      final i = entry.key;
                      final p = entry.value;
                      final m = p['end']!.difference(p['start']!).inMinutes;
                      return InputChip(
                        avatar: const Icon(Icons.cloud, size: 18),
                        label: Text(
                          'غيم ${i + 1}: ${_hm(p['start']!)} → ${_hm(p['end']!)} • $m دقيقة',
                        ),
                        onPressed: () => addCloudPeriod(editingIndex: i),
                        onDeleted: () =>
                            setState(() => cloudPeriods.removeAt(i)),
                      );
                    }),
                  if (cloudMin > 0)
                    Chip(
                      avatar: const Icon(Icons.remove_circle_outline),
                      label: Text(
                        'خصم الغيم: $cloudMin دقيقة • المحاسبة: ${minutes - cloudMin} دقيقة',
                      ),
                    ),
                ],





              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: loading || saved ? null : save,
                icon: const Icon(Icons.save_rounded),
                label: const Text('حفظ سقاية جديدة'),
              ),
            ),
          ),
          SectionCard(
            title: '5. المعاينة قبل الحفظ',
            icon: Icons.receipt_long,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                Metric(
                  'القابل للمحاسبة',
                  '${p['القابل للمحاسبة']} دقيقة',
                  _cyan,
                ),
                Metric(type == 'diesel' ? 'قيمة المياه' : 'قيمة السقي', money(p['المياه']), _blue),
                if (type == 'diesel') Metric('قيمة الديزل', money(p['الديزل']), _purple),
                if (type == 'solar' && cloudMin > 0) Metric('خصم الغيم', '$cloudMin دقيقة', _cyan),
                Metric('الإجمالي المستحق', money(p['الإجمالي']), _green),
                if (partyType == 'beneficiary')
                  Metric('المدفوع', money(p['المدفوع']), _blue),
                Metric(
                  'الرصيد الحالي',
                  _balLabel(p['الرصيد الحالي']!.round()),
                  _purple,
                ),
                Metric(
                  'حالة الرصيد بعد العملية',
                  _balLabel(p['حالة الرصيد']!.round()),
                  _balanceOwed(p['حالة الرصيد']!.round())
                      ? Colors.orange
                      : _green,
                ),
                ],
              ),
            ),
          ),
          if (saved)
            Card(
              color: _green.withValues(alpha: .08),
              child: const ListTile(
                leading: Icon(Icons.check_circle, color: _green),
                title: Text('تم الحفظ بنجاح'),
                subtitle: Text(
                  'تم إنشاء السقاية والقيد المحاسبي وتحديث الرصيد. يمكنك بدء عملية جديدة.',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget fieldSelect<T>(
    String label,
    T? value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> f,
  ) => SizedBox(
    width: 270,
    child: DropdownButtonFormField<T>(
      // Flutter يرمي assertion إن لم تطابق القيمة عنصرًا واحدًا بالضبط.
      initialValue: items.where((i) => i.value == value).length == 1 ? value : null,
      items: items,
      onChanged: f,
      decoration: InputDecoration(labelText: label, hintText: 'اختر $label'),
    ),
  );
}

class DateButton extends StatelessWidget {
  final String label;
  final DateTime value;
  final VoidCallback onTap;
  const DateButton(this.label, this.value, this.onTap, {super.key});
  @override
  Widget build(BuildContext c) => OutlinedButton.icon(
    onPressed: onTap,
    icon: const Icon(Icons.event),
    label: Text(
      '$label: ${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}',
    ),
  );
}

class Metric extends StatelessWidget {
  final String a, b;
  final Color color;
  const Metric(this.a, this.b, this.color, {super.key});
  @override
  Widget build(BuildContext c) => Container(
    width: 190,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      color: color.withValues(alpha: .08),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(a),
        Text(
          b,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      ],
    ),
  );
}

class SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    super.key,
  });
  @override
  Widget build(BuildContext c) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(c).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}

class FormDialog extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final VoidCallback onSave;
  const FormDialog({
    required this.title,
    required this.children,
    required this.onSave,
    super.key,
  });
  @override
  Widget build(BuildContext c) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(child: Column(children: children)),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
      FilledButton(onPressed: onSave, child: const Text('حفظ')),
    ],
  );
}

class IrrigationsPage extends StatefulWidget {
  final StationRepository r;
  final bool manager;
  final int userId;
  const IrrigationsPage(
    this.r, {
    required this.manager,
    required this.userId,
    super.key,
  });
  @override
  State<IrrigationsPage> createState() => _IrrigationsState();
}

class _IrrigationsState extends State<IrrigationsPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> bs = [];
  String q = '';
  String? type;
  int? bid;
  bool loading = true;
  final TextEditingController reportPeriodController =
      TextEditingController(text: 'كل الفترة');

  @override
  void dispose() {
    reportPeriodController.dispose();
    super.dispose();
  }

  DateTime? _reportStart(String raw, DateTime now) {
    final value = raw.trim().toLowerCase();
    final today = DateTime(now.year, now.month, now.day);
    if (const {'كل الفترة', 'كل السجلات', 'الكل', 'تاريخ كامل'}.contains(value)) return null;
    if (const {'يوم', 'اليوم', '1 يوم', 'يوم واحد'}.contains(value)) return today;
    if (const {'يومان', 'يومين', 'آخر يومين', '2 يوم', '2 أيام'}.contains(value)) {
      return today.subtract(const Duration(days: 1));
    }
    if (const {'أسبوع', 'اسبوع', 'أسبوع واحد', 'آخر أسبوع', '7 أيام'}.contains(value)) {
      return today.subtract(const Duration(days: 6));
    }
    if (const {'شهر', 'شهر واحد', 'آخر شهر', '30 يوم', '30 أيام'}.contains(value)) {
      return today.subtract(const Duration(days: 29));
    }
    final match = RegExp(r'^(\d{1,3})\s*(?:يوم|أيام|ايام|يومان|يومين)$').firstMatch(value);
    if (match != null) {
      final count = int.tryParse(match.group(1) ?? '');
      if (count != null && count >= 1 && count <= 365) {
        return today.subtract(Duration(days: count - 1));
      }
    }
    return null;
  }

  Future<void> printIrrigationsReport() async {
    final now = AppClock.now();
    final allPeriod = const {'كل الفترة', 'كل السجلات', 'الكل', 'تاريخ كامل'}
        .contains(reportPeriodController.text.trim().toLowerCase());
    final from = allPeriod ? null : _reportStart(reportPeriodController.text, now);
    if (!allPeriod && from == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'اختر يومًا أو يومين أو أسبوعًا أو شهرًا، أو اكتب مدة مثل 3 أيام (حتى 365 يومًا).',
          ),
        ),
      );
      return;
    }

    try {
      // اجلب بيانات التقرير من قاعدة البيانات مباشرة، لا من القائمة المعروضة
      // التي قد تكون محدودة بفلتر الشاشة أو لم تُحمّل بعد.
      final reportRows = await widget.r.report(
        'irrigations',
        from: from,
        to: DateTime(now.year, now.month, now.day),
        systemType: type ?? 'all',
        beneficiaryId: bid,
      );

      // أظهر عدد الصفوف الراجعة من SQLite قبل دخول مرحلة بناء PDF.
      // لا نغيّر البيانات ولا نحاول إعادة الاستعلام بفلاتر مختلفة تلقائيًا.
      if (reportRows.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 6),
            content: Text(
              'استعلام تقرير السقايات أعاد 0 سجلًا قبل إنشاء PDF. راجع الفترة وفلتر المنظومة والمستفيد؛ لم يتم حذف أو تعديل أي بيانات.',
            ),
          ),
        );
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            content: Text(
              'تم جلب ${reportRows.length} سجلًا من قاعدة البيانات. جارٍ إنشاء PDF…',
            ),
          ),
        );
      }

      await ReportService(widget.r).printPdf(
        'irrigations',
        from: from,
        to: DateTime(now.year, now.month, now.day),
        systemType: type ?? 'all',
        beneficiaryId: bid,
        sourceRows: reportRows,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تعذر إنشاء تقرير السقايات: ${friendlyError(e)}'),
        ),
      );
    }
  }

  Future<void> createIrrigationsPdf() async {
    final now = AppClock.now();
    final allPeriod = const {'كل الفترة', 'كل السجلات', 'الكل', 'تاريخ كامل'}
        .contains(reportPeriodController.text.trim().toLowerCase());
    final from = allPeriod ? null : _reportStart(reportPeriodController.text, now);
    if (!allPeriod && from == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حدد فترة صحيحة قبل إنشاء ملف PDF.')),
      );
      return;
    }
    try {
      final to = DateTime(now.year, now.month, now.day);
      final reportRows = await widget.r.report(
        'irrigations',
        from: from,
        to: to,
        systemType: type ?? 'all',
        beneficiaryId: bid,
      );
      if (reportRows.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد بيانات مطابقة للفلاتر لإنشاء PDF.')),
        );
        return;
      }
      final bytes = await ReportService(widget.r).pdf(
        'irrigations',
        from: from,
        to: to,
        systemType: type ?? 'all',
        beneficiaryId: bid,
        sourceRows: reportRows,
      );
      if (bytes.isEmpty) throw StateError('ملف PDF الناتج فارغ.');
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'تقرير_السقايات_${DateFormat('yyyyMMdd_HHmm').format(now)}.pdf',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم تجهيز PDF من ${reportRows.length} سجلًا وفق الفلاتر المحددة.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء/مشاركة PDF السقايات: ${friendlyError(e)}')),
      );
    }
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final x = await widget.r.irrigations(systemType: type ?? 'all', beneficiaryId: bid);
      if (mounted) setState(() { rows = x; loading = false; });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }
  @override
  void initState() {
    super.initState();
    widget.r.beneficiaries().then((x) {
      if (mounted) setState(() => bs = x);
    });
    load();
  }

  String _timeOf(Object? value) {
    final d = DateTime.tryParse('$value');
    return d == null ? '-' : DateFormat('HH:mm').format(d);
  }

  Future<void> cancelIrrigationRow(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'إلغاء السقاية',
      message:
          'سيُعكس القيد المحاسبي وتُلغى الدفعة المرافقة (إن وُجدت) ويُعاد أثرها على الصندوق. المبلغ: ${money(x['total_amount'])}',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.accounting.cancelIrrigation(
        x['id'] as int,
        widget.userId,
        reason,
      ),
    )) {
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إلغاء السقاية وعكس أثرها')),
      );
    }
    await load();
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['beneficiary_name']}'.contains(q))
        .toList();
    return PageFrame(
      title: 'السقايات',
      subtitle: 'سجل السقايات مع البحث والتصفية ومراجعة الحالة',
      actions: [
        FilledButton.icon(
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) =>
                  NewIrrigationPage(widget.r, manager: widget.manager),
            ),
          ).then((_) => load()),
          icon: const Icon(Icons.add),
          label: const Text('سقاية جديدة'),
        ),
      ],
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  onChanged: (v) => setState(() => q = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'بحث باسم المستفيد',
                  ),
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  initialValue: type,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('كل المنظومات')),
                    DropdownMenuItem(value: 'diesel', child: Text('ديزل')),
                    DropdownMenuItem(value: 'solar', child: Text('شمسي')),
                    DropdownMenuItem(
                      value: 'equivalent_hybrid',
                      child: Text('النوع الثالث'),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => type = v);
                    load();
                  },
                  decoration: const InputDecoration(labelText: 'المنظومة'),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<int>(
                  initialValue: bid,
                  items: [
                    const DropdownMenuItem<int>(
                      value: null,
                      child: Text('كل المستفيدين'),
                    ),
                    for (final b in bs)
                      DropdownMenuItem(
                        value: b['id'] as int,
                        child: Text('${b['name']}'),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => bid = v);
                    load();
                  },
                  decoration: const InputDecoration(labelText: 'المستفيد'),
                ),
              ),
              SizedBox(
                width: 250,
                child: DropdownMenu<String>(
                  controller: reportPeriodController,
                  label: const Text('فترة تقرير الطباعة'),
                  enableFilter: true,
                  enableSearch: true,
                  expandedInsets: EdgeInsets.zero,
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: 'كل الفترة', label: 'كل الفترة'),
                    DropdownMenuEntry(value: 'يوم', label: 'اليوم'),
                    DropdownMenuEntry(value: 'يومان', label: 'آخر يومين'),
                    DropdownMenuEntry(value: 'أسبوع', label: 'آخر أسبوع'),
                    DropdownMenuEntry(value: 'شهر', label: 'آخر شهر'),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: loading ? null : printIrrigationsReport,
                icon: const Icon(Icons.print_rounded),
                label: const Text('طباعة تقرير السقايات'),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : createIrrigationsPdf,
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('إنشاء PDF'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (loading) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty && !loading
                ? const EmptyView('لا توجد سقايات مطابقة')
                : Card(
                    margin: EdgeInsets.zero,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: DataTable(
                          headingRowHeight: 52,
                          dataRowMinHeight: 62,
                          columns: const [
                            DataColumn(label: Text('الجهة')),
                            DataColumn(label: Text('من')),
                            DataColumn(label: Text('إلى')),
                            DataColumn(label: Text('المدة')),
                            DataColumn(label: Text('المدفوع')),
                            DataColumn(label: Text('المبلغ')),
                            DataColumn(label: Text('الغيم')),
                            DataColumn(label: Text('حالة الخصم')),
                            DataColumn(label: Text('إجراء')),
                          ],
                          rows: [
                            for (final x in filtered)
                              DataRow(
                                cells: [
                                  DataCell(
                                    Text(
                                      '${x['beneficiary_name'] ?? '-'}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  DataCell(Text(_timeOf(x['start_datetime']))),
                                  DataCell(Text(_timeOf(x['end_datetime']))),
                                  DataCell(Text('${x['minutes'] ?? 0} دقيقة')),
                                  DataCell(Text(money(x['paid_amount']))),
                                  DataCell(Text(money(x['total_amount']))),
                                  DataCell(
                                    Text('${x['cloud_minutes'] ?? 0} دقيقة'),
                                  ),
                                  DataCell(
                                    Chip(
                                      avatar: Icon(
                                        ((x['cloud_minutes'] as num?)
                                                        ?.round() ??
                                                    0) >
                                                0
                                            ? Icons.cloud
                                            : Icons.cloud_off,
                                        size: 16,
                                      ),
                                      label: Text(
                                        ((x['cloud_minutes'] as num?)
                                                        ?.round() ??
                                                    0) >
                                                0
                                            ? 'تم الخصم'
                                            : 'لا يوجد خصم',
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    IconButton(
                                      tooltip: 'إلغاء السقاية',
                                      onPressed: () => cancelIrrigationRow(x),
                                      icon: const Icon(
                                        Icons.cancel_outlined,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class SessionsPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const SessionsPage(this.r, {required this.userId, super.key});
  @override
  State<SessionsPage> createState() => _SessionsState();
}

class _SessionsState extends State<SessionsPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> bs = [], qs = [], ps = [], bookings = [], ws = [];
  String q = '';
  String queueType = 'circular';
  Timer? ticker;
  DateTime now = AppClock.now();

  Future<void> load() async {
    try {
      final a = await widget.r.sessions();
      final b = await widget.r.beneficiaries();
      final workers = await widget.r.workers();
      final st = await widget.r.settings();
      final queueTypeValue = st['queue_type'] ?? 'circular';
      final queue = queueTypeValue == 'booking'
          ? <Map<String, Object?>>[]
          : await widget.r.queue();
      final bookingsValue = queueTypeValue == 'booking'
          ? await widget.r.bookings('scheduled')
          : <Map<String, Object?>>[];
      final selectedId = int.tryParse(st['selected_pump_id'] ?? '');
      final pumps = selectedId == null
          ? <Map<String, Object?>>[]
          : await widget.r.db.query(
              'pumps',
              where: 'id=? AND active=1',
              whereArgs: [selectedId],
            );
      if (mounted) {
        setState(() {
          rows = a;
          bs = b;
          ws = workers;
          qs = queue;
          bookings = bookingsValue;
          queueType = queueTypeValue;
          ps = pumps;
        });
      }
    } catch (e) {
      msg(friendlyError(e));
    }
  }

  @override
  void initState() {
    super.initState();
    load();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => now = AppClock.now());
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> start() async {
    int? b = bs.isEmpty ? null : bs.first['id'] as int;
    int? p = ps.isEmpty ? null : ps.first['id'] as int;
    int? queueId;
    int? bookId;
    final bookings = await widget.r.bookings('scheduled');
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('بدء جلسة سقي'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: b,
                  items: [
                    for (final x in bs)
                      DropdownMenuItem(
                        value: x['id'] as int,
                        child: Text('${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => b = v),
                  decoration: const InputDecoration(labelText: 'المستفيد'),
                ),
                DropdownButtonFormField<int>(
                  initialValue: queueType == 'booking' ? bookId : queueId,
                  items: [
                    const DropdownMenuItem<int>(
                      value: null,
                      child: Text('بدون ربط بالدور'),
                    ),
                    if (queueType == 'booking')
                      for (final x in bookings.where(
                        (x) => b == null || x['beneficiary_id'] == b,
                      ))
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text(
                            'الدور • ${x['beneficiary_name']} • ${x['scheduled_start'] ?? 'الموعد غير محدد'}',
                          ),
                        )
                    else
                      for (final x in qs.where(
                        (x) => b == null || x['beneficiary_id'] == b,
                      ))
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text(
                            'الدور ${x['position']} • ${x['beneficiary_name']}',
                          ),
                        ),
                  ],
                  onChanged: (v) => s(() {
                    queueId = queueType == 'circular' ? v : null;
                    bookId = queueType == 'booking' ? v : null;
                  }),
                  decoration: InputDecoration(
                    labelText: queueType == 'booking'
                        ? 'الدور المحجوز'
                        : 'الدور الحالي',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, b != null && p != null),
              child: const Text('بدء'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      try {
        await widget.r.startSession(
          beneficiaryId: b!,
          pumpId: p!,
          queueId: queueId,
          bookingId: bookId,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> stop(int id) async {
    int? operatorWorkerId;
    final selected = await showDialog<int?>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('إنهاء جلسة السقي'),
          content: DropdownButtonFormField<int>(
            initialValue: operatorWorkerId,
            items: [
              const DropdownMenuItem<int>(value: null, child: Text('بدون عامل منفذ')),
              ...ws.map((w) => DropdownMenuItem<int>(
                value: w['id'] as int,
                child: Text('${w['name']} • ${w['pay_type'] == 'hourly' ? 'بالساعة' : w['pay_type'] == 'percentage' ? 'نسبة' : 'راتب شهري'}'),
              )),
            ],
            onChanged: (v) => setDialogState(() => operatorWorkerId = v),
            decoration: const InputDecoration(labelText: 'العامل المنفذ (اختياري)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(context, operatorWorkerId), child: const Text('إنهاء وترحيل')),
          ],
        ),
      ),
    );
    if (!mounted) return;
    // القيمة null قد تعني «بدون عامل» أو إلغاء الحوار؛ نتحقق من الإغلاق عبر زر
    // مستقل حتى لا نوقف الجلسة عند الضغط خارج النافذة.
    if (selected == null && ws.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('إنهاء بدون عامل؟'),
          content: const Text('سيتم ترحيل كامل قيمة السقاية دون خصم استحقاق عامل.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('متابعة')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await widget.r.stopSession(id, operatorWorkerId: selected, userId: widget.userId);
      await load();
      msg('تم إنهاء الجلسة وإنشاء السقاية المحاسبية');
    } catch (e) {
      msg(friendlyError(e));
    }
  }

  Future<void> postpone(int id) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تأجيل جلسة',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(
              labelText: 'سبب التأجيل *',
              hintText: 'سيظهر في سجل التدقيق',
            ),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.postponeSession(id, c.text, userId: widget.userId),
      )) {
        return;
      }
      await load();
    }
  }

  String elapsed(Object? start) {
    if (start == null) return '00:00:00';
    final d = now.difference(DateTime.tryParse('$start') ?? now);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec';
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['beneficiary_name']} ${x['pump_name']}'.contains(q))
        .toList();
    return PageFrame(
      title: 'جلسات السقي',
      subtitle: 'مؤقت حقيقي محفوظ في قاعدة البيانات مع بدء وإيقاف وتأجيل',
      actions: [
        FilledButton.icon(
          onPressed: start,
          icon: const Icon(Icons.play_arrow),
          label: const Text('بدء جلسة'),
        ),
      ],
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث باسم المستفيد أو المضخة',
              hintText: 'ابحث داخل الجلسات',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyView('لا توجد جلسات مطابقة')
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 7),
                    itemBuilder: (_, i) {
                      final x = filtered[i];
                      final running = x['status'] == 'running';
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            running ? Icons.timer : Icons.check_circle,
                            color: running ? _green : _blue,
                          ),
                          title: Text(
                            '${x['beneficiary_name']} • ${x['pump_name']}',
                          ),
                          subtitle: Text(
                            '${statusName(x['status'])} • البداية: ${x['actual_start'] ?? x['planned_start'] ?? '-'}',
                          ),
                          trailing: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (running)
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    elapsed(x['actual_start']),
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      color: _cyan,
                                    ),
                                  ),
                                ),
                              if (running)
                                IconButton(
                                  tooltip: 'إنهاء الجلسة',
                                  onPressed: () => stop(x['id'] as int),
                                  icon: const Icon(
                                    Icons.stop_circle,
                                    color: Colors.red,
                                  ),
                                ),
                              if (running)
                                IconButton(
                                  tooltip: 'تأجيل',
                                  onPressed: () => postpone(x['id'] as int),
                                  icon: const Icon(Icons.pause_circle),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class QueueBookingPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  const QueueBookingPage(
    this.r, {
    required this.userId,
    required this.manager,
    super.key,
  });
  @override
  State<QueueBookingPage> createState() => _QueueState();
}

class _QueueState extends State<QueueBookingPage> {
  List<Map<String, Object?>> q = [], b = [], bs = [];
  String? status;
  String queueType = 'circular';

  bool get isBookingMode => queueType == 'booking';

  Future<void> load() async {
    final settings = await widget.r.settings();
    final mode = settings['queue_type'] ?? 'circular';
    final allBeneficiaries = await widget.r.beneficiaries();
    final queue = mode == 'booking'
        ? <Map<String, Object?>>[]
        : await widget.r.queue();
    final bookings = mode == 'booking'
        ? await widget.r.bookings(status)
        : <Map<String, Object?>>[];
    if (mounted) {
      setState(() {
        queueType = mode;
        q = queue;
        b = bookings;
        bs = allBeneficiaries;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> addQueue() async {
    int? id = bs.isEmpty ? null : bs.first['id'] as int;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة إلى الدور'),
          content: DropdownButtonFormField<int>(
            initialValue: id,
            items: [
              for (final x in bs)
                DropdownMenuItem(
                  value: x['id'] as int,
                  child: Text('${x['name']}'),
                ),
            ],
            onChanged: (v) => s(() => id = v),
            decoration: const InputDecoration(labelText: 'المستفيد'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, id != null),
              child: const Text('إضافة'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && id != null) {
      await widget.r.enqueue(id!, userId: widget.userId);
      await load();
    }
  }

  Future<void> book() async {
    int? id = bs.isEmpty ? null : bs.first['id'] as int;
    final n = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة طلب إلى الدور'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: id,
                items: [
                  for (final x in bs)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => id = v),
                decoration: const InputDecoration(labelText: 'المستفيد'),
              ),
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, id != null),
              child: const Text('إرسال الطلب'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && id != null) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.createBooking(id!, n.text, userId: widget.userId),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> review(Map<String, Object?> x) async {
    String st = 'scheduled';
    final reason = TextEditingController();
    DateTime? start;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: Text('إدارة دور ${x['beneficiary_name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: st,
                items: const [
                  DropdownMenuItem(
                    value: 'scheduled',
                    child: Text('محدد الموعد'),
                  ),
                  DropdownMenuItem(value: 'accepted', child: Text('مقبول')),
                  DropdownMenuItem(value: 'cancelled', child: Text('ملغى')),
                ],
                onChanged: (v) => s(() => st = v!),
                decoration: const InputDecoration(labelText: 'الحالة'),
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(
                  labelText: 'السبب أو الملاحظة',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (st == 'scheduled' || st == 'accepted') {
      if (!mounted) return;
      final d = await showDatePicker(
        context: context,
        firstDate: AppClock.now(),
        lastDate: DateTime(2100),
        initialDate: AppClock.now(),
        locale: const Locale('ar'),
      );
      if (d != null) {
        if (!mounted) return;
        final t = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
          helpText: 'اختيار وقت الموعد',
        );
        if (t != null) {
          start = DateTime(d.year, d.month, d.day, t.hour, t.minute);
        }
      }
    }
    if (st == 'cancelled' && reason.text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('سبب الإلغاء مطلوب')));
      }
      return;
    }
    if (!mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.reviewBooking(
        x['id'] as int,
        status: st,
        reviewer: widget.userId,
        reason: reason.text,
        start: start,
        end: start?.add(const Duration(hours: 1)),
      ),
    )) {
      return;
    }
    await load();
  }

  Future<void> cancelBooking(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'إلغاء حجز ${x['beneficiary_name']}',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.reviewBooking(
        x['id'] as int,
        status: 'cancelled',
        reviewer: widget.userId,
        reason: reason,
      ),
    )) {
      return;
    }
    await load();
  }

  Future<void> editBookingNotes(Map<String, Object?> x) async {
    final c = TextEditingController(text: '${x['notes'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => FormDialog(
        title: 'تعديل ملاحظات الحجز',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'ملاحظات'),
          ),
        ],
        onSave: () => Navigator.pop(d, true),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.updateBookingNotes(
          x['id'] as int,
          c.text,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> postpone(int id) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تأجيل الدور',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'سبب التأجيل *'),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.postponeQueue(id, c.text, userId: widget.userId),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> completeEntry(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('تمت الخدمة'),
        content: const Text(
          'تسجيل أن هذا المستفيد خُدم دون سقاية في النظام؟ في الطابور الدائري يعود إلى آخر الدور.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.completeQueue(id, userId: widget.userId),
    )) {
      return;
    }
    await load();
  }

  Future<void> overrideQ(int id) async {
    if (!widget.manager) return;
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تجاوز الدور',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'سبب التجاوز *'),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.serveSpecific(id, widget.userId, c.text),
      )) {
        return;
      }
      await load();
    }
  }

  @override
  Widget build(BuildContext c) {
    final modeTitle = isBookingMode ? 'حجز' : 'دور دائري';
    final entries = isBookingMode ? b : q;
    return PageFrame(
      title: 'إدارة الدور',
      subtitle: 'مسار واحد للدور، يتغير أسلوبه حسب إعداد المحطة: $modeTitle',
      actions: [
        OutlinedButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('تحديث'),
        ),
        if (isBookingMode)
          FilledButton.icon(
            onPressed: book,
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة طلب للدور'),
          )
        else
          FilledButton.icon(
            onPressed: addQueue,
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة إلى الدور'),
          ),
      ],
      child: ListView(
        children: [
          if (isBookingMode) ...[
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _statusChip('كل الطلبات', null),
                _statusChip('جديد', 'new'),
                _statusChip('قيد المراجعة', 'under_review'),
                _statusChip('محدد الموعد', 'scheduled'),
                _statusChip('مكتمل', 'completed'),
                _statusChip('ملغى', 'cancelled'),
              ],
            ),
            const SizedBox(height: 14),
          ],
          SectionCard(
            title: isBookingMode ? 'الدور الحالي' : 'ترتيب الدور الحالي',
            icon: Icons.format_list_numbered_rounded,
            child: entries.isEmpty
                ? EmptyView(
                    isBookingMode ? 'لا توجد طلبات في الدور' : 'الدور فارغ',
                  )
                : Column(
                    children: [
                      for (var i = 0; i < entries.length; i++)
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      child: Text(
                                        isBookingMode
                                            ? '${i + 1}'
                                            : '${entries[i]['position']}',
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: Text(
                                              '${entries[i]['beneficiary_name']}',
                                              style: Theme.of(c).textTheme.titleMedium,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            flex: 3,
                                            child: Text(
                                              isBookingMode
                                                  ? '${statusName(entries[i]['status'])} • ${entries[i]['created_at']} • ${entries[i]['scheduled_start'] ?? 'الموعد غير محدد'}'
                                                  : '${statusName(entries[i]['status'])} • مرات التأجيل: ${entries[i]['postponed_count'] ?? 0}',
                                              style: Theme.of(c).textTheme.bodySmall,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      IconButton(
                                        tooltip: 'التفاصيل',
                                        onPressed: () => Navigator.push(
                                          c,
                                          MaterialPageRoute(
                                            builder: (_) => RecordDetailsPage(
                                              widget.r,
                                              kind: isBookingMode ? 'booking' : 'queue',
                                              id: entries[i]['id'] as int,
                                              title: 'تفاصيل الدور',
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(Icons.info_outline_rounded),
                                      ),
                                      if (isBookingMode) ...[
                                        if (!const {'completed', 'cancelled'}
                                            .contains('${entries[i]['status']}')) ...[
                                          IconButton(
                                            tooltip: 'إدارة الدور',
                                            onPressed: () => review(entries[i]),
                                            icon: const Icon(Icons.edit_calendar_rounded),
                                          ),
                                          IconButton(
                                            tooltip: 'تعديل الملاحظات',
                                            onPressed: () => editBookingNotes(entries[i]),
                                            icon: const Icon(Icons.edit_note_rounded),
                                          ),
                                          IconButton(
                                            tooltip: 'إلغاء الحجز',
                                            onPressed: () => cancelBooking(entries[i]),
                                            icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                                          ),
                                        ],
                                      ] else ...[
                                        IconButton(
                                          tooltip: 'غياب / تأجيل (حسب سياسة الغياب)',
                                          onPressed: () => postpone(entries[i]['id'] as int),
                                          icon: const Icon(Icons.pause_rounded),
                                        ),
                                        IconButton(
                                          tooltip: 'تمت الخدمة',
                                          onPressed: () => completeEntry(entries[i]['id'] as int),
                                          icon: const Icon(Icons.check_circle_outline_rounded),
                                        ),
                                        if (widget.manager)
                                          IconButton(
                                            tooltip: 'تجاوز',
                                            onPressed: () => overrideQ(entries[i]['id'] as int),
                                            icon: const Icon(Icons.flash_on_rounded),
                                          ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          if (isBookingMode)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'طلبات الحجز هنا هي مرحلة طلب الدور نفسها، وعند قبولها/تحديد موعدها تبقى في نفس المسار دون إنشاء قائمة طابور ثانية للمستخدم.',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusChip(String label, String? value) => ChoiceChip(
    label: Text(label),
    selected: status == value,
    onSelected: (_) {
      setState(() => status = value);
      load();
    },
  );
}

class DieselPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const DieselPage(this.r, {required this.userId, super.key});
  @override
  State<DieselPage> createState() => _DieselState();
}

class _DieselState extends State<DieselPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> bs = [], cs = [];
  double stock = 0;
  Map<String, Object?>? warning;
  String q = '';
  Future<void> load() async {
    final cfg = await SystemConfig.load(widget.r);
    if (!cfg.isDiesel) {
      if (mounted) setState(() => enabled = false);
      return;
    }
    final a = await widget.r.diesel(),
        b = await widget.r.beneficiaries(),
        c = await widget.r.cashboxes(),
        s = await widget.r.dieselStock(),
        w = await widget.r.dieselWarning();
    if (mounted) {
      setState(() {
        rows = a;
        bs = b;
        cs = c;
        stock = s;
        warning = w;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    String kind = 'receipt';
    int? bid, cb = cs.isEmpty ? null : cs.first['id'] as int;
    final liters = TextEditingController(),
        price = TextEditingController(text: '0'),
        notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('حركة ديزل'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  items: const [
                    DropdownMenuItem(
                      value: 'receipt',
                      child: Text('شراء وإضافة للمخزون'),
                    ),
                    DropdownMenuItem(
                      value: 'delivery',
                      child: Text('تسليم لمستفيد'),
                    ),
                    DropdownMenuItem(
                      value: 'advance',
                      child: Text('سلفة ديزل'),
                    ),
                    DropdownMenuItem(
                      value: 'correction',
                      child: Text('تصحيح مخزون'),
                    ),
                  ],
                  onChanged: (v) => s(() => kind = v!),
                  decoration: const InputDecoration(labelText: 'نوع الحركة'),
                ),
                if (kind == 'delivery' || kind == 'advance')
                  DropdownButtonFormField<int>(
                    initialValue: bid,
                    items: [
                      for (final x in bs)
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text('${x['name']}'),
                        ),
                    ],
                    onChanged: (v) => s(() => bid = v),
                    decoration: const InputDecoration(labelText: 'المستفيد'),
                  ),
                if (kind == 'receipt')
                  DropdownButtonFormField<int>(
                    initialValue: cb,
                    items: [
                      for (final x in cs)
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text('${x['name']}'),
                        ),
                    ],
                    onChanged: (v) => s(() => cb = v),
                    decoration: const InputDecoration(labelText: 'الصندوق'),
                  ),
                TextField(
                  controller: liters,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الكمية باللتر'),
                ),
                TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'سعر اللتر'),
                ),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'ملاحظات'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.addDieselMovement(
          beneficiaryId: bid,
          kind: kind,
          liters: double.tryParse(liters.text) ?? 0,
          unitPrice: int.tryParse(price.text) ?? 0,
          date: AppClock.now(),
          cashboxId: cb,
          userId: widget.userId,
          notes: notes.text,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  Future<void> cancelMove(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'إلغاء حركة الديزل',
      message:
          'ستُعكس قيودها ويُردّ أثرها على المخزون والصندوق. ${statusName(x['kind'])} — ${x['liters']} لتر',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.accounting.cancelDieselMovement(
        x['id'] as int,
        widget.userId,
        reason,
      ),
    )) {
      return;
    }
    await load();
  }

  Future<void> editMoveNotes(Map<String, Object?> x) async {
    final c = TextEditingController(text: '${x['notes'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => FormDialog(
        title: 'تعديل ملاحظات الحركة',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'ملاحظات'),
          ),
          const Text(
            'الكمية والسعر والنوع تُصحَّح بإلغاء الحركة وإعادة إدخالها.',
          ),
        ],
        onSave: () => Navigator.pop(d, true),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.accounting.updateDieselNotes(
          x['id'] as int,
          c.text,
          widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  bool enabled = true;

  @override
  Widget build(c) => enabled
      ? PageFrame(
          title: 'الديزل',
          subtitle: 'المخزون والحركات والتنبيه والسلف والتسليم',
          actions: [
            if (warning?['warning'] == true)
              OutlinedButton.icon(
                onPressed: () async {
                  final m =
                      double.tryParse(
                        (await widget.r.settings())['diesel_snooze_minutes'] ??
                            '10',
                      ) ??
                      10;
                  if (!mounted) return;
                  if (!await runGuarded(
                    context,
                    () => widget.r.setSetting(
                      'diesel_warning_snoozed_until',
                      AppClock.now()
                          .add(Duration(minutes: m.round()))
                          .toIso8601String(),
                    ),
                  )) {
                    return;
                  }
                  await load();
                },
                icon: const Icon(Icons.snooze),
                label: const Text('تأجيل التنبيه 10 دقائق'),
              ),
            FilledButton.icon(
              onPressed: add,
              icon: const Icon(Icons.local_gas_station),
              label: const Text('حركة ديزل'),
            ),
          ],
          child: Column(
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.oil_barrel, color: _cyan),
                  title: const Text('المخزون الحالي'),
                  subtitle: Text('${stock.toStringAsFixed(2)} لتر'),
                  trailing: warning?['warning'] == true
                      ? const Icon(Icons.warning_amber, color: Colors.orange)
                      : const Icon(Icons.check_circle, color: _green),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                onChanged: (v) => setState(() => q = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'بحث في حركات الديزل',
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    for (final x in rows.where(
                      (x) =>
                          '${x['beneficiary_name'] ?? ''} ${x['kind']} ${x['notes'] ?? ''}'
                              .contains(q),
                    ))
                      Card(
                        child: ListTile(
                          title: Text(
                            '${x['beneficiary_name'] ?? 'المخزون'} • ${statusName(x['kind'])}',
                          ),
                          subtitle: Text(
                            '${x['liters']} لتر • ${x['date']}${(x['notes'] ?? '').toString().isEmpty ? '' : ' • ${x['notes']}'}',
                          ),
                          trailing: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(money(x['amount'])),
                              if (x['irrigation_id'] == null) ...[
                                IconButton(
                                  tooltip: 'تعديل الملاحظات',
                                  onPressed: () => editMoveNotes(x),
                                  icon: const Icon(Icons.edit_note_rounded),
                                ),
                                IconButton(
                                  tooltip: 'إلغاء الحركة',
                                  onPressed: () => cancelMove(x),
                                  icon: const Icon(
                                    Icons.cancel_outlined,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        )
      : const Center(child: Text('عناصر الديزل غير متاحة لأن المنظومة شمسية.'));
}

class PaymentsPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const PaymentsPage(this.r, {required this.userId, super.key});
  @override
  State<PaymentsPage> createState() => _PaymentsState();
}

class _PaymentsState extends State<PaymentsPage> {
  List<Map<String, Object?>> rows = [],
      bs = [],
      ws = [],
      ps = [],
      methods = [],
      cash = [];
  String target = 'beneficiary', q = '';
  Future<void> load() async {
    final a = await widget.r.payments(),
        b = await widget.r.beneficiaries(),
        w = await widget.r.workers(),
        p = await widget.r.partners(),
        m = await widget.r.paymentMethods(),
        c = await widget.r.cashboxes();
    if (mounted) {
      setState(() {
        rows = a;
        bs = b;
        ws = w;
        ps = p;
        methods = m;
        cash = c;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final list = target == 'beneficiary'
        ? bs
        : target == 'worker'
        ? ws
        : ps;
    int? party = list.isEmpty ? null : list.first['id'] as int;
    int? method = methods.isEmpty ? null : methods.first['id'] as int;
    int? cb = cashboxForMethod(methods, cash, method, null);
    final amount = TextEditingController(),
        note = TextEditingController(),
        reference = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('تسجيل دفعة'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: target,
                  items: const [
                    DropdownMenuItem(
                      value: 'beneficiary',
                      child: Text('مستفيد'),
                    ),
                    DropdownMenuItem(value: 'worker', child: Text('عامل')),
                    DropdownMenuItem(value: 'partner', child: Text('شريك')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      s(() {
                        target = v;
                        final l = target == 'beneficiary'
                            ? bs
                            : target == 'worker'
                            ? ws
                            : ps;
                        party = l.isEmpty ? null : l.first['id'] as int;
                      });
                    }
                  },
                  decoration: const InputDecoration(labelText: 'الطرف'),
                ),
                DropdownButtonFormField<int>(
                  initialValue: party,
                  items: [
                    for (final x
                        in (target == 'beneficiary'
                            ? bs
                            : target == 'worker'
                            ? ws
                            : ps))
                      DropdownMenuItem(
                        value: x['id'] as int,
                        child: Text('${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => party = v),
                  decoration: InputDecoration(
                    labelText: targetName(target),
                  ),
                ),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'المبلغ'),
                ),
                ...methodCashboxFields(
                  methods: methods,
                  cash: cash,
                  method: method,
                  cb: cb,
                  onChanged: (m, b) => s(() {
                    method = m;
                    cb = b;
                  }),
                ),
                TextField(
                  controller: reference,
                  decoration: const InputDecoration(labelText: 'رقم مرجعي'),
                ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'ملاحظات'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                party != null &&
                    method != null &&
                    cb != null &&
                    int.tryParse(amount.text) != null,
              ),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        final a = int.parse(amount.text);
        final recipientRows = target == 'beneficiary'
            ? bs
            : target == 'worker'
            ? ws
            : ps;
        Map<String, Object?>? recipient;
        for (final row in recipientRows) {
          if (row['id'] == party) {
            recipient = row;
            break;
          }
        }
        int paymentId;
        if (target == 'beneficiary') {
          paymentId = await widget.r.accounting.receivePayment(
            beneficiaryId: party!,
            amount: a,
            paymentMethodId: method!,
            cashboxId: cb!,
            userId: widget.userId,
            referenceNumber: reference.text,
            notes: note.text,
          );
        } else if (target == 'worker') {
          paymentId = await widget.r.accounting.payWorker(
            workerId: party!,
            amount: a,
            paymentMethodId: method!,
            cashboxId: cb!,
            userId: widget.userId,
            referenceNumber: reference.text,
            notes: note.text,
          );
        } else {
          paymentId = await widget.r.accounting.payPartner(
            partnerId: party!,
            amount: a,
            paymentMethodId: method!,
            cashboxId: cb!,
            userId: widget.userId,
            referenceNumber: reference.text,
            notes: note.text,
          );
        }
        await load();
        if (!mounted) return;
        final recipientName =
            recipient?['name']?.toString() ?? targetName(target);
        final action = target == 'beneficiary'
            ? 'تم استلام دفعة من حسابكم'
            : 'تم صرف دفعة لكم';
        final message = [
          'السلام عليكم $recipientName،',
          '$action بمبلغ ${money(a)} بتاريخ ${DateFormat('yyyy/MM/dd HH:mm').format(AppClock.now())}.',
          'رقم العملية: $paymentId.',
        ].join('\n');
        await ManualMessageService.offerChoices(
          context,
          title: 'تمت العملية',
          recipientName: recipientName,
          phone: recipient?['phone']?.toString() ?? '',
          message: message,
        );
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  Future<void> cancelPay(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'إلغاء الدفعة',
      message:
          'سيُعكس القيد المحاسبي ويُعدَّل رصيد الصندوق. ${x['party_name']} — ${money(x['amount'])}',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.accounting.cancelPayment(
        x['id'] as int,
        widget.userId,
        reason,
      ),
    )) {
      return;
    }
    msg('تم إلغاء الدفعة وعكس أثرها');
    await load();
  }

  @override
  Widget build(c) => PageFrame(
    title: 'المدفوعات',
    subtitle: 'قبض المستفيدين ودفع مستحقات العمال والشركاء',
    actions: [
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.add_card),
        label: const Text('تسجيل دفعة'),
      ),
    ],
    child: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final x in const [
              ('beneficiary', 'المستفيدون'),
              ('worker', 'العمال'),
              ('partner', 'الشركاء'),
            ])
              ChoiceChip(
                selected: target == x.$1,
                label: Text(x.$2),
                onSelected: (_) => setState(() => target = x.$1),
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث بالطرف أو المرجع أو المبلغ أو التاريخ أو الملاحظات',
            hintText: 'اكتب الاسم أو رقم المرجع أو المبلغ أو جزءاً من التاريخ',
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final x in rows.where((x) {
                final partyId = x[switch (target) {
                  'worker' => 'worker_id',
                  'partner' => 'partner_id',
                  _ => 'beneficiary_id',
                }];
                final searchText = [
                  x['party_name'],
                  x['method_name'],
                  x['cashbox_name'],
                  x['reference_number'],
                  x['amount'],
                  money(x['amount']),
                  x['date'],
                  x['notes'],
                  statusName(x['status']),
                ].map((value) => value?.toString() ?? '').join(' ').toLowerCase();
                return partyId != null &&
                    searchText.contains(q.trim().toLowerCase());
              }))
                Card(
                  child: ListTile(
                    title: Text('${x['party_name']}'),
                    subtitle: Text(
                      '${x['date']} • ${x['method_name']} • ${x['cashbox_name']} • ${statusName(x['status'])}',
                    ),
                    trailing: Wrap(
                      children: [
                        Text(
                          money(x['amount']),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            decoration: x['status'] == 'cancelled'
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (x['status'] == 'posted')
                          IconButton(
                            tooltip: 'إلغاء الدفعة',
                            onPressed: () => cancelPay(x),
                            icon: const Icon(
                              Icons.cancel_outlined,
                              color: Colors.red,
                            ),
                          ),
                        IconButton(
                          tooltip: 'إيصال',
                          onPressed: () async {
                            try {
                              await ReportService(
                                widget.r,
                              ).printPaymentReceipt(x['id'] as int);
                            } catch (e) {
                              msg(friendlyError(e));
                            }
                          },
                          icon: const Icon(Icons.receipt_long),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class CashboxesPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const CashboxesPage(this.r, {required this.userId, super.key});
  @override
  State<CashboxesPage> createState() => _CashboxesState();
}

class _CashboxesState extends State<CashboxesPage> {
  List<Map<String, Object?>> boxes = [], methods = [], transfers = [];

  Future<void> load() async {
    final a = await widget.r.cashboxes();
    final b = await widget.r.paymentMethods();
    final t = await widget.r.transfers();
    if (mounted) {
      setState(() {
        boxes = a;
        methods = b;
        transfers = t;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> addBox() async {
    final n = TextEditingController();
    final o = TextEditingController(text: '0');
    String ledger = 'cash';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, st) => FormDialog(
          title: 'إضافة صندوق',
          children: [
            TextField(
              controller: n,
              decoration: const InputDecoration(labelText: 'اسم الصندوق *'),
            ),
            DropdownButtonFormField<String>(
              initialValue: ledger,
              items: const [
                DropdownMenuItem(
                  value: 'cash',
                  child: Text('نقدي (حساب الصندوق 1000)'),
                ),
                DropdownMenuItem(value: 'bank', child: Text('بنك (حساب 1100)')),
                DropdownMenuItem(
                  value: 'wallet',
                  child: Text('محفظة إلكترونية (حساب 1120)'),
                ),
              ],
              onChanged: (v) => st(() => ledger = v!),
              decoration: const InputDecoration(labelText: 'نوع الصندوق'),
            ),
            TextField(
              controller: o,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'الرصيد الافتتاحي',
                helperText:
                    'يُقيَّد تلقائيًا في الأستاذ مقابل الأرصدة الافتتاحية',
              ),
            ),
          ],
          onSave: () => Navigator.pop(c, n.text.trim().isNotEmpty),
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.createCashbox(
          name: n.text.trim(),
          openingBalance: int.tryParse(o.text) ?? 0,
          currency: 'YER',
          ledgerAccountCode: switch (ledger) {
            'bank' => '1100',
            'wallet' => '1120',
            _ => '1000',
          },
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> editBox(Map<String, Object?> x) async {
    final n = TextEditingController(text: '${x['name']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => FormDialog(
        title: 'تعديل الصندوق',
        children: [
          TextField(
            controller: n,
            decoration: const InputDecoration(labelText: 'اسم الصندوق *'),
          ),
          const Text(
            'الرصيد الافتتاحي وحساب الصندوق لا يُعدَّلان بعد الإنشاء؛ يُصحَّح الرصيد بتحويل.',
          ),
        ],
        onSave: () => Navigator.pop(d, n.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.updateCashbox(
          x['id'] as int,
          name: n.text,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> deleteBox(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'حذف الصندوق «${x['name']}»',
      message: 'يُرفض الحذف إن كان رصيده غير صفر أو مرتبطًا بطرق دفع مفعّلة.',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.deleteCashbox(x['id'] as int, widget.userId, reason),
    )) {
      return;
    }
    await load();
  }

  Future<void> editMethod(Map<String, Object?> x) async {
    final n = TextEditingController(text: '${x['name']}'),
        a = TextEditingController(text: '${x['account_number'] ?? ''}'),
        b = TextEditingController(text: '${x['bank_name'] ?? ''}');
    String type = '${x['type']}';
    int? cb = (x['cashbox_id'] as num?)?.toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, st) => FormDialog(
          title: 'تعديل طريقة الدفع',
          children: [
            TextField(
              controller: n,
              decoration: const InputDecoration(labelText: 'اسم طريقة الدفع *'),
            ),
            DropdownButtonFormField<String>(
              initialValue: type,
              items: [
                for (final t in [
                  'cash',
                  'check',
                  'bank_transfer',
                  'wallet',
                  'other',
                ])
                  DropdownMenuItem(value: t, child: Text(paymentTypeName(t))),
              ],
              onChanged: (v) => st(() => type = v!),
              decoration: const InputDecoration(labelText: 'نوع الطريقة'),
            ),
            TextField(
              controller: a,
              decoration: const InputDecoration(labelText: 'رقم الحساب'),
            ),
            TextField(
              controller: b,
              decoration: const InputDecoration(labelText: 'اسم البنك'),
            ),
            DropdownButtonFormField<int>(
              initialValue: boxes.any((e) => e['id'] == cb) ? cb : null,
              items: [
                for (final e in boxes)
                  DropdownMenuItem(
                    value: e['id'] as int,
                    child: Text('${e['name']}'),
                  ),
              ],
              onChanged: (v) => st(() => cb = v),
              decoration: const InputDecoration(labelText: 'الصندوق المرتبط'),
            ),
          ],
          onSave: () => Navigator.pop(c, n.text.trim().isNotEmpty),
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.updatePaymentMethod(
          x['id'] as int,
          name: n.text,
          type: type,
          cashboxId: cb,
          accountNumber: a.text,
          bankName: b.text,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> deleteMethod(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'حذف طريقة الدفع «${x['name']}»',
      message:
          'تبقى الدفعات السابقة مرتبطة بها، ولا تظهر في الاختيارات الجديدة.',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.deletePaymentMethod(x['id'] as int, widget.userId, reason),
    )) {
      return;
    }
    await load();
  }

  Future<void> addMethod() async {
    final n = TextEditingController(),
        a = TextEditingController(),
        b = TextEditingController();
    String type = 'cash';
    int? cb = boxes.isEmpty ? null : boxes.first['id'] as int;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => FormDialog(
          title: 'إضافة طريقة دفع',
          children: [
            TextField(
              controller: n,
              decoration: const InputDecoration(labelText: 'اسم طريقة الدفع *'),
            ),
            DropdownButtonFormField<String>(
              initialValue: type,
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('نقدي')),
                DropdownMenuItem(value: 'check', child: Text('شيك')),
                DropdownMenuItem(
                  value: 'bank_transfer',
                  child: Text('تحويل بنكي'),
                ),
                DropdownMenuItem(value: 'wallet', child: Text('محفظة')),
                DropdownMenuItem(value: 'other', child: Text('أخرى')),
              ],
              onChanged: (v) => s(() => type = v!),
              decoration: const InputDecoration(labelText: 'نوع الطريقة'),
            ),
            TextField(
              controller: a,
              decoration: const InputDecoration(labelText: 'رقم الحساب'),
            ),
            TextField(
              controller: b,
              decoration: const InputDecoration(labelText: 'اسم البنك'),
            ),
            DropdownButtonFormField<int>(
              initialValue: cb,
              items: [
                for (final x in boxes)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ],
              onChanged: (v) => s(() => cb = v),
              decoration: const InputDecoration(labelText: 'الصندوق المرتبط'),
            ),
          ],
          onSave: () => Navigator.pop(c, n.text.trim().isNotEmpty),
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.createPaymentMethod(
          name: n.text.trim(),
          type: type,
          cashboxId: cb,
          accountNumber: a.text,
          bankName: b.text,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> transfer() async {
    if (boxes.length < 2) {
      msg('يجب إنشاء صندوقين على الأقل');
      return;
    }
    int f = boxes.first['id'] as int;
    int t = boxes[1]['id'] as int;
    final a = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('تحويل بين الصناديق'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: f,
                items: [
                  for (final x in boxes)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => f = v!),
                decoration: const InputDecoration(labelText: 'من صندوق'),
              ),
              DropdownButtonFormField<int>(
                initialValue: t,
                items: [
                  for (final x in boxes)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => t = v!),
                decoration: const InputDecoration(labelText: 'إلى صندوق'),
              ),
              TextField(
                controller: a,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(c, f != t && int.tryParse(a.text) != null),
              child: const Text('تحويل'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.transferCash(
          from: f,
          to: t,
          amount: int.parse(a.text),
          date: AppClock.now(),
          userId: widget.userId,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      title: 'الصناديق والتحويلات',
      subtitle: 'الأرصدة والتحويلات بين الصناديق وطرق الدفع',
      actions: [
        OutlinedButton.icon(
          onPressed: transfer,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('تحويل'),
        ),
        OutlinedButton.icon(
          onPressed: addMethod,
          icon: const Icon(Icons.payments),
          label: const Text('طريقة دفع'),
        ),
        FilledButton.icon(
          onPressed: addBox,
          icon: const Icon(Icons.account_balance),
          label: const Text('صندوق جديد'),
        ),
      ],
      child: ListView(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final x in boxes)
                Metric('${x['name']}', money(x['current_balance']), _blue),
            ],
          ),
          const SizedBox(height: 8),
          for (final x in boxes)
            ListTile(
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => RecordDetailsPage(
                    widget.r,
                    kind: 'cashbox',
                    id: x['id'] as int,
                    title: 'تفاصيل الصندوق',
                  ),
                ),
              ),
              title: Text('${x['name']}'),
              subtitle: Text(
                'الرصيد الحالي: ${money(x['current_balance'])} • ${ledgerAccountName(x['ledger_account_code'])}',
              ),
              trailing: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'تعديل',
                    onPressed: () => editBox(x),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'حذف',
                    onPressed: () => deleteBox(x),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                  ),
                  const Icon(Icons.open_in_new),
                ],
              ),
            ),
          const SizedBox(height: 15),
          const Text(
            'طرق الدفع',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          for (final x in methods)
            ListTile(
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => RecordDetailsPage(
                    widget.r,
                    kind: 'payment_method',
                    id: x['id'] as int,
                    title: 'تفاصيل طريقة الدفع',
                  ),
                ),
              ),
              title: Text('${x['name']}'),
              subtitle: Text(
                '${paymentTypeName('${x['type']}')} • ${x['account_number'] ?? ''} • الصندوق: ${x['cashbox_name'] ?? 'غير مرتبط'}',
              ),
              trailing: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'تعديل',
                    onPressed: () => editMethod(x),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'حذف',
                    onPressed: () => deleteMethod(x),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                  ),
                  const Icon(Icons.open_in_new),
                ],
              ),
            ),
          const Divider(),
          const Text(
            'التحويلات',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          for (final x in transfers)
            ListTile(
              title: Text('${x['from_cashbox']} ← ${x['to_cashbox']}'),
              subtitle: Text('${x['date']}'),
              trailing: Text(money(x['amount'])),
            ),
        ],
      ),
    );
  }
}

class ExpensesPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const ExpensesPage(this.r, {required this.userId, super.key});
  @override
  State<ExpensesPage> createState() => _ExpensesState();
}

class _ExpensesState extends State<ExpensesPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> cash = [], methods = [], partners = [];
  String q = '';
  Future<void> load() async {
    final a = await widget.r.expenses(),
        b = await widget.r.cashboxes(),
        m = await widget.r.paymentMethods(),
        p = await widget.r.partners();
    if (mounted) {
      setState(() {
        rows = a;
        cash = b;
        methods = m;
        partners = p;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    String cat = 'other';
    String scope = 'general';
    int? selectedPartnerId;
    int? pm = methods.isEmpty ? null : methods.first['id'] as int;
    int? cb = cashboxForMethod(methods, cash, pm, null);
    final title = TextEditingController(),
        amount = TextEditingController(),
        note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          scrollable: true,
          title: const Text('إضافة مصروف'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: scope,
                decoration: const InputDecoration(labelText: 'نوع المصروف'),
                items: const [
                  DropdownMenuItem(value: 'general', child: Text('مصروف عام — يُخصم قبل توزيع الأرباح')),
                  DropdownMenuItem(value: 'partner', child: Text('مصروف خاص بشريك — يُخصم من حصته')),
                ],
                onChanged: (v) => s(() {
                  scope = v ?? 'general';
                  if (scope == 'general') {
                    selectedPartnerId = null;
                    if (cat == 'workers') cat = 'other';
                  }
                }),
              ),
              if (scope == 'partner')
                DropdownButtonFormField<int>(
                  // ignore: deprecated_member_use
                  value: selectedPartnerId,
                  decoration: const InputDecoration(labelText: 'الشريك الذي يتحمل المصروف'),
                  items: [
                    for (final p in partners)
                      DropdownMenuItem<int>(
                        value: (p['id'] as num).toInt(),
                        child: Text('${p['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => selectedPartnerId = v),
                ),
              DropdownButtonFormField<String>(
                initialValue: cat,
                items: [
                  for (final x in [
                    if (scope == 'partner') 'workers',
                    'partners',
                    'fuel',
                    'oil',
                    'grease',
                    'maintenance',
                    'parts',
                    'transport',
                    'admin',
                    'other',
                  ])
                    DropdownMenuItem(value: x, child: Text(categoryName(x))),
                ],
                onChanged: (v) => s(() => cat = v!),
                decoration: const InputDecoration(labelText: 'التصنيف'),
              ),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'بيان المصروف'),
              ),
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              ...methodCashboxFields(
                methods: methods,
                cash: cash,
                method: pm,
                cb: cb,
                onChanged: (m, b) => s(() {
                  pm = m;
                  cb = b;
                }),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                title.text.trim().isNotEmpty &&
                    int.tryParse(amount.text) != null &&
                    pm != null &&
                    cb != null &&
                    (scope == 'general' || selectedPartnerId != null),
              ),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.addExpense(
          category: cat,
          title: title.text,
          amount: int.parse(amount.text),
          date: AppClock.now(),
          paymentMethodId: pm!,
          cashboxId: cb!,
          partnerId: scope == 'partner' ? selectedPartnerId : null,
          userId: widget.userId,
          notes: note.text,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  Future<void> cancelExp(Map<String, Object?> x) async {
    final reason = await askReason(
      context,
      'إلغاء المصروف',
      message:
          'سيُعكس القيد ويُعاد المبلغ إلى الصندوق. ${x['title']} — ${money(x['amount'])}',
    );
    if (reason == null || !mounted) return;
    if (!await runGuarded(
      context,
      () => widget.r.accounting.cancelExpense(
        x['id'] as int,
        widget.userId,
        reason,
      ),
    )) {
      return;
    }
    msg('تم إلغاء المصروف وعكس أثره');
    await load();
  }

  @override
  Widget build(c) => PageFrame(
    title: 'المصروفات',
    subtitle: 'تسجيل المصروفات مع التصنيف والصندوق والقيد المحاسبي',
    actions: [
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.add),
        label: const Text('مصروف جديد'),
      ),
    ],
    child: Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث ببيان المصروف أو التصنيف',
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final x in rows.where(
                (x) => '${x['title']} ${x['category']}'.contains(q),
              ))
                Card(
                  child: ListTile(
                    title: Text('${x['title']}'),
                    subtitle: Text(
                      '${categoryName('${x['category']}')} • ${x['date']} • '
                      '${x['partner_id'] == null ? 'مصروف عام' : 'خاص بالشريك: ${partners.firstWhere((p) => (p['id'] as num).toInt() == (x['partner_id'] as num).toInt(), orElse: () => <String, Object?>{})['name'] ?? 'غير معروف'}'} • '
                      '${statusName(x['status'])}',
                    ),
                    trailing: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          money(x['amount']),
                          style: TextStyle(
                            decoration: x['status'] == 'cancelled'
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (x['status'] == 'posted')
                          IconButton(
                            tooltip: 'إلغاء المصروف',
                            onPressed: () => cancelExp(x),
                            icon: const Icon(
                              Icons.cancel_outlined,
                              color: Colors.red,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class WorkersPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  const WorkersPage(
    this.r, {
    required this.userId,
    required this.manager,
    super.key,
  });
  @override
  State<WorkersPage> createState() => _WorkersState();
}

class _WorkersState extends State<WorkersPage> {
  List<Map<String, Object?>> rows = [];
  String q = '';

  Future<void> load() async {
    final x = await widget.r.workers();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final n = TextEditingController(), phone = TextEditingController();
    final open = TextEditingController(text: '0');
    final rate = TextEditingController(),
        salary = TextEditingController(),
        percent = TextEditingController();
    String type = 'hourly';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          scrollable: true,
          title: const Text('إضافة عامل'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'اسم العامل'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'الهاتف'),
              ),
              TextField(
                controller: open,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'الرصيد الافتتاحي',
                  helperText: 'موجب = له على المحطة، سالب = عليه. يُقيَّد في الأستاذ.',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: type,
                items: const [
                  DropdownMenuItem(value: 'fixed', child: Text('راتب ثابت')),
                  DropdownMenuItem(value: 'hourly', child: Text('بالساعة')),
                  DropdownMenuItem(value: 'percentage', child: Text('نسبة')),
                ],
                onChanged: (v) => s(() => type = v!),
                decoration: const InputDecoration(labelText: 'طريقة الاستحقاق'),
              ),
              if (type == 'fixed')
                TextField(
                  controller: salary,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الراتب'),
                ),
              if (type == 'hourly')
                TextField(
                  controller: rate,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'أجر الساعة'),
                ),
              if (type == 'percentage')
                TextField(
                  controller: percent,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'النسبة %'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final openingOk = open.text.trim().isEmpty || int.tryParse(open.text.trim()) != null;
                final percentage = double.tryParse(percent.text.trim()) ?? -1;
                final methodOk = type == 'percentage'
                    ? percentage >= 0 && percentage <= 100
                    : type == 'fixed'
                        ? (int.tryParse(salary.text.trim()) ?? 0) > 0
                        : (double.tryParse(rate.text.trim()) ?? 0) > 0;
                Navigator.pop(c, n.text.trim().isNotEmpty && openingOk && methodOk);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.createWorker(
          name: n.text,
          phone: phone.text,
          opening: int.tryParse(open.text.trim()) ?? 0,
          payType: type,
          fixedSalary: int.tryParse(salary.text) ?? 0,
          hourlyRate: int.tryParse(rate.text) ?? 0,
          percentageRate: double.tryParse(percent.text) ?? 0,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> transaction(Map<String, Object?> x) async {
    final a = TextEditingController(), h = TextEditingController();
    String type = 'accrual';
    final methods = await widget.r.paymentMethods();
    if (!mounted) return;
    final cashM = methods.where((m) => m['type'] == 'cash').toList();
    int? pm =
        (cashM.isNotEmpty
                ? cashM.first
                : (methods.isNotEmpty ? methods.first : null))?['id']
            as int?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: Text('حركة العامل: ${x['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: type,
                items: const [
                  DropdownMenuItem(
                    value: 'accrual',
                    child: Text('إضافة استحقاق'),
                  ),
                  DropdownMenuItem(value: 'payment', child: Text('دفع مستحق')),
                ],
                onChanged: (v) => s(() => type = v!),
                decoration: const InputDecoration(labelText: 'نوع الحركة'),
              ),
              if (type == 'payment' && methods.isNotEmpty)
                DropdownButtonFormField<int>(
                  initialValue: pm,
                  items: [
                    for (final m in methods)
                      DropdownMenuItem(
                        value: m['id'] as int,
                        child: Text('${m['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => pm = v),
                  decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                ),
              TextField(
                controller: a,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              if (type == 'accrual')
                TextField(
                  controller: h,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'عدد الساعات'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, int.tryParse(a.text) != null),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      int? paymentId;
      if (!await runGuarded(
        context,
        () async {
          paymentId = await widget.r.workerTransaction(
            workerId: x['id'] as int,
            type: type,
            amount: int.parse(a.text),
            hours: type == 'accrual' ? (double.tryParse(h.text) ?? 0) : 0,
            paymentMethodId: type == 'payment' ? pm : null,
            userId: widget.userId,
          );
        },
      )) {
        return;
      }
      await load();
      if (type != 'payment' || !mounted) return;
      final recipientName = x['name']?.toString() ?? 'العامل';
      final amountValue = int.parse(a.text);
      final operationNumber = paymentId == null
          ? ''
          : ' رقم العملية: $paymentId.';
      final message = [
        'السلام عليكم $recipientName،',
        'تم صرف مبلغ ${money(amountValue)} لكم بتاريخ ${DateFormat('yyyy/MM/dd HH:mm').format(AppClock.now())}.',
        operationNumber,
      ].where((line) => line.isNotEmpty).join('\n');
      await ManualMessageService.offerChoices(
        context,
        title: 'تم دفع مستحق العامل',
        recipientName: recipientName,
        phone: x['phone']?.toString() ?? '',
        message: message,
      );
    }
  }

  Future<void> editWorker(Map<String, Object?> x) async {
    final n = TextEditingController(text: '${x['name'] ?? ''}'),
        phone = TextEditingController(text: '${x['phone'] ?? ''}');
    String type = '${x['pay_type'] ?? 'hourly'}';
    final rate = TextEditingController(text: '${x['hourly_rate'] ?? 0}'),
        salary = TextEditingController(text: '${x['fixed_salary'] ?? 0}'),
        pct = TextEditingController(text: '${x['percentage_rate'] ?? 0}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('تعديل معلومات العامل'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'الاسم'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'الهاتف'),
              ),
              DropdownButtonFormField<String>(
                initialValue: type,
                items: const [
                  DropdownMenuItem(value: 'fixed', child: Text('راتب ثابت')),
                  DropdownMenuItem(value: 'hourly', child: Text('بالساعة')),
                  DropdownMenuItem(value: 'percentage', child: Text('نسبة')),
                ],
                onChanged: (v) => s(() => type = v!),
                decoration: const InputDecoration(labelText: 'طريقة الاستحقاق'),
              ),
              if (type == 'fixed')
                TextField(
                  controller: salary,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الراتب الثابت'),
                ),
              if (type == 'hourly')
                TextField(
                  controller: rate,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'أجر الساعة'),
                ),
              if (type == 'percentage')
                TextField(
                  controller: pct,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'النسبة %'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final percentage = double.tryParse(pct.text.trim()) ?? -1;
                final methodOk = type == 'percentage'
                    ? percentage >= 0 && percentage <= 100
                    : type == 'fixed'
                        ? (int.tryParse(salary.text.trim()) ?? 0) > 0
                        : (double.tryParse(rate.text.trim()) ?? 0) > 0;
                Navigator.pop(c, n.text.trim().isNotEmpty && methodOk);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(context, () => widget.r.updateWorker(x['id'] as int, {
        'name': n.text.trim(),
        'phone': phone.text,
        'pay_type': type,
        'fixed_salary': int.tryParse(salary.text) ?? 0,
        'hourly_rate': int.tryParse(rate.text) ?? 0,
        'percentage_rate': double.tryParse(pct.text) ?? 0,
      }, widget.userId))) {
        return;
      }
      await load();
    }
  }

  Future<void> deleteWorker(Map<String, Object?> x) async {
    if (!widget.manager) {
      msg('حذف السجلات متاح للمدير فقط');
      return;
    }
    final r = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'حذف العامل',
        children: [
          const Text('سيتم إخفاؤه من القوائم دون حذف حركاته المحاسبية.'),
          TextField(
            controller: r,
            decoration: const InputDecoration(labelText: 'سبب الحذف *'),
          ),
        ],
        onSave: () => Navigator.pop(context, r.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.deleteWorker(x['id'] as int, widget.userId, r.text),
      )) {
        return;
      }
      await load();
    }
  }

  void workerActions(Map<String, Object?> x) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('تعديل معلومات العامل'),
              onTap: () {
                Navigator.pop(c);
                editWorker(x);
              },
            ),
            if (widget.manager)
              ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('حذف'),
              onTap: () {
                Navigator.pop(c);
                deleteWorker(x);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> accrueMonthlySalary() async {
    if (!widget.manager) { msg('ترحيل الرواتب متاح للمدير فقط'); return; }
    final now = AppClock.now();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: const Text('ترحيل رواتب الشهر'),
      content: Text('سيتم ترحيل رواتب العمال ذوي الراتب الشهري لشهر ${now.year}/${now.month.toString().padLeft(2, '0')} إلى دفتر الأستاذ. إذا تم ترحيل الشهر سابقاً لن يتكرر.'),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('ترحيل الآن'))],
    )) ?? false;
    if (!ok) return;
    try {
      final count = await widget.r.accounting.accrueMonthlySalaries(month: now, userId: widget.userId);
      msg('تم ترحيل مستحقات $count عامل شهري');
      await load();
    } catch (e) { msg(friendlyError(e)); }
  }
  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  Future<void> sendAccountSummary(Map<String, Object?> x) async {
    try {
      final id = x['id'] as int;
      final balanceData = await widget.r.accounting.workerBalance(id);
      if (!mounted) return;
      final recipientName = x['name']?.toString() ?? 'العامل';
      final balance = balanceData['balance'] ?? 0;
      final asOf = AppClock.now();
      await ManualMessageService.offerChoices(
        context,
        title: 'إرسال كشف حساب مختصر',
        recipientName: recipientName,
        phone: x['phone']?.toString() ?? '',
        message: ManualMessageService.accountSummaryMessage(
          recipientName: recipientName,
          partyLabel: 'العامل',
          balanceLabel: AccountingCalculations.partyDueLabel(balance),
          asOf: asOf,
        ),
      );
    } catch (e) {
      msg(friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['name']} ${x['phone'] ?? ''}'.contains(q))
        .toList();
    return PageFrame(
      title: 'العمال',
      subtitle: 'الأجر بالساعة أو النسبة أو الراتب الثابت مع الاستحقاق والدفع',
      actions: [
        OutlinedButton.icon(
          onPressed: () =>
              ReportService(widget.r).printPdf('worker_transactions'),
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: const Text('تقرير العمال'),
        ),
        if (widget.manager)
          OutlinedButton.icon(
            onPressed: accrueMonthlySalary,
            icon: const Icon(Icons.event_available_rounded),
            label: const Text('ترحيل راتب الشهر'),
          ),
        FilledButton.icon(
          onPressed: add,
          icon: const Icon(Icons.person_add_alt),
          label: const Text('عامل جديد'),
        ),
      ],
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث باسم العامل أو الهاتف',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyView('لا يوجد عمال مطابقون')
                : LayoutBuilder(
                    builder: (_, box) {
                      final cols = box.maxWidth >= 1100
                          ? 3
                          : box.maxWidth >= 720
                          ? 2
                          : 1;
                      const gap = 12.0;
                      final w = (box.maxWidth - gap * (cols - 1)) / cols;
                      return SingleChildScrollView(
                        child: Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final x in filtered)
                              SizedBox(
                                width: w,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(24),
                                  onTap: () => Navigator.push(
                                    c,
                                    MaterialPageRoute(
                                      builder: (_) => RecordDetailsPage(
                                        widget.r,
                                        kind: 'worker',
                                        id: x['id'] as int,
                                        title: 'تفاصيل العامل',
                                      ),
                                    ),
                                  ),
                                  onLongPress: () => workerActions(x),
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const CircleAvatar(
                                                child: Icon(
                                                  Icons.engineering_rounded,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  '${x['name']}',
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                                ),
                                              ),
                                              PopupMenuButton<String>(
                                                onSelected: (v) {
                                                  if (v == 'edit') {
                                                    editWorker(x);
                                                  }
                                                  if (v == 'delete') {
                                                    deleteWorker(x);
                                                  }
                                                },
                                                itemBuilder: (_) => [
  const PopupMenuItem(value: 'edit', child: Text('تعديل بيانات العامل')),
  if (widget.manager)
    const PopupMenuItem(value: 'delete', child: Text('حذف')),
],
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            payTypeName('${x['pay_type']}'),
                                            style: TextStyle(
                                              color: Theme.of(
                                                c,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            AccountingCalculations.partyDueLabel(
  ((x['balance'] as num?)?.round() ?? 0),
),
style: TextStyle(
  fontWeight: FontWeight.w900,
  color: ((x['balance'] as num?)?.round() ?? 0) < 0
      ? Colors.red
      : _green,
),
                                          ),
                                          const SizedBox(height: 12),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                OutlinedButton.icon(
                                                  onPressed: () => transaction(x),
                                                  icon: const Icon(
                                                    Icons.account_balance_wallet_outlined,
                                                  ),
                                                  label: const Text('حركة العامل'),
                                                ),
                                                OutlinedButton.icon(
                                                  onPressed: () => sendAccountSummary(x),
                                                  icon: const Icon(Icons.send_rounded),
                                                  label: const Text('إرسال الحساب'),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class PartnersPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  const PartnersPage(
    this.r, {
    required this.userId,
    required this.manager,
    super.key,
  });
  @override
  State<PartnersPage> createState() => _PartnersState();
}

class _PartnersState extends State<PartnersPage> {
  List<Map<String, Object?>> rows = [];
  String q = '';

  Future<void> load() async {
    final x = await widget.r.partners();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final n = TextEditingController(), phone = TextEditingController();
    final open = TextEditingController(text: '0');
    final sh = TextEditingController(), pc = TextEditingController();
    String mode = 'percentage';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          scrollable: true,
          title: const Text('إضافة شريك'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'اسم الشريك'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'الهاتف'),
              ),
              TextField(
                controller: open,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'الرصيد الافتتاحي',
                  helperText: 'موجب = له على المحطة، سالب = عليه. يُقيَّد في الأستاذ.',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: mode,
                items: const [
                  DropdownMenuItem(
                    value: 'percentage',
                    child: Text('نسبة ملكية'),
                  ),
                  DropdownMenuItem(value: 'shares', child: Text('عدد حصص')),
                ],
                onChanged: (v) => s(() { mode = v!; if (mode == 'shares') {
                  pc.clear();
                } else {
                  sh.clear();
                } }),
                decoration: const InputDecoration(labelText: 'طريقة التوزيع'),
              ),
              if (mode == 'percentage')
                TextField(
                  controller: pc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'النسبة %'),
                ),
              if (mode == 'shares')
                TextField(
                  controller: sh,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'عدد الحصص (يمكن إدخال 1.5 أو 4.5)'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                n.text.trim().isNotEmpty &&
                    (open.text.trim().isEmpty ||
                        int.tryParse(open.text.trim()) != null),
              ),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.createPartner(
          name: n.text,
          mode: mode,
          shares: double.tryParse(sh.text.trim().replaceAll(',', '.')) ?? 0,
          percentage: double.tryParse(pc.text) ?? 0,
          phone: phone.text,
          opening: int.tryParse(open.text.trim()) ?? 0,
          userId: widget.userId,
        ),
      )) {
        return;
      }
      await load();
    }
  }

  Future<void> share(Map<String, Object?> x) async {
    final amount = TextEditingController();
    final isPercentage = '${x['ownership_mode']}' == 'percentage';
    final pct = TextEditingController(
      text: '${x['ownership_percentage'] ?? 0}',
    );
    final basis = isPercentage
        ? 'نسبة ملكية مثبتة: ${x['ownership_percentage'] ?? 0}%'
        : 'توزيع بالحِصص: ${x['shares_count'] ?? 0} حصص';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'توزيع أرباح الشريك',
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _reportCream,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(isPercentage ? Icons.percent_rounded : Icons.pie_chart_rounded, color: _reportOliveDark),
                const SizedBox(width: 8),
                Expanded(child: Text(basis, style: const TextStyle(fontWeight: FontWeight.w800))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'قيمة الاستحقاق'),
          ),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'أساس التوزيع', border: OutlineInputBorder()),
            child: Text(basis),
          ),
        ],
        onSave: () => Navigator.pop(
          context,
          int.tryParse(amount.text) != null && int.parse(amount.text) > 0,
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.createPartnerShare(
          partnerId: x['id'] as int,
          amount: int.parse(amount.text),
          date: AppClock.now(),
          percentage: double.tryParse(pct.text),
          userId: widget.userId,
        );
        await load();
        msg('تم تسجيل استحقاق الشريك والقيد المحاسبي');
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> pay(Map<String, Object?> x) async {
    final methods = await widget.r.paymentMethods();
    final cash = await widget.r.cashboxes();
    if (!mounted) return;
    if (methods.isEmpty || cash.isEmpty) {
      msg('أضف طريقة دفع وصندوقًا أولًا');
      return;
    }
    int? pm = methods.first['id'] as int;
    int? cb = cashboxForMethod(methods, cash, pm, null);
    final amount = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: Text('دفع مستحق: ${x['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              ...methodCashboxFields(
                methods: methods,
                cash: cash,
                method: pm,
                cb: cb,
                onChanged: (m, b) => s(() {
                  pm = m;
                  cb = b;
                }),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                int.tryParse(amount.text) != null && int.parse(amount.text) > 0,
              ),
              child: const Text('دفع'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        final amountValue = int.parse(amount.text);
        final paymentId = await widget.r.accounting.payPartner(
          partnerId: x['id'] as int,
          amount: amountValue,
          paymentMethodId: pm!,
          cashboxId: cb!,
          userId: widget.userId,
        );
        await load();
        if (!mounted) return;
        final recipientName = x['name']?.toString() ?? 'الشريك';
        final message = [
          'السلام عليكم $recipientName،',
          'تم صرف مبلغ ${money(amountValue)} لكم بتاريخ ${DateFormat('yyyy/MM/dd HH:mm').format(AppClock.now())}.',
          'رقم العملية: $paymentId.',
        ].join('\n');
        await ManualMessageService.offerChoices(
          context,
          title: 'تم دفع مستحق الشريك',
          recipientName: recipientName,
          phone: x['phone']?.toString() ?? '',
          message: message,
        );
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> editPartner(Map<String, Object?> x) async {
    final n = TextEditingController(text: '${x['name'] ?? ''}'),
        phone = TextEditingController(text: '${x['phone'] ?? ''}'),
        pct = TextEditingController(text: '${x['ownership_percentage'] ?? 0}'),
        sh = TextEditingController(text: '${x['shares_count'] ?? 0}');
    String mode = '${x['ownership_mode'] ?? 'percentage'}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('تعديل معلومات الشريك'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'الاسم'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'الهاتف'),
              ),
              DropdownButtonFormField<String>(
                initialValue: mode,
                items: const [
                  DropdownMenuItem(
                    value: 'percentage',
                    child: Text('نسبة ملكية'),
                  ),
                  DropdownMenuItem(value: 'shares', child: Text('عدد حصص')),
                ],
                onChanged: (v) => s(() { mode = v!; if (mode == 'shares') {
                  pct.clear();
                } else {
                  sh.clear();
                } }),
                decoration: const InputDecoration(labelText: 'طريقة التوزيع'),
              ),
              if (mode == 'percentage')
                TextField(
                  controller: pct,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'نسبة الملكية %',
                  ),
                ),
              if (mode == 'shares')
                TextField(
                  controller: sh,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'عدد الحصص (يمكن إدخال 1.5 أو 4.5)'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, n.text.trim().isNotEmpty),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(context, () => widget.r.updatePartner(x['id'] as int, {
        'name': n.text.trim(),
        'phone': phone.text,
        'ownership_mode': mode,
        'ownership_percentage': mode == 'percentage' ? (double.tryParse(pct.text) ?? 0) : 0,
        'shares_count': mode == 'shares' ? (double.tryParse(sh.text.trim().replaceAll(',', '.')) ?? 0) : 0,
      }, widget.userId))) {
        return;
      }
      await load();
    }
  }

  Future<void> deletePartner(Map<String, Object?> x) async {
    if (!widget.manager) {
      msg('حذف السجلات متاح للمدير فقط');
      return;
    }
    final r = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'حذف الشريك',
        children: [
          const Text('سيتم إخفاؤه من القوائم دون حذف حركاته المحاسبية.'),
          TextField(
            controller: r,
            decoration: const InputDecoration(labelText: 'سبب الحذف *'),
          ),
        ],
        onSave: () => Navigator.pop(context, r.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      if (!await runGuarded(
        context,
        () => widget.r.deletePartner(x['id'] as int, widget.userId, r.text),
      )) {
        return;
      }
      await load();
    }
  }

  void partnerActions(Map<String, Object?> x) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('تعديل معلومات الشريك'),
              onTap: () {
                Navigator.pop(c);
                editPartner(x);
              },
            ),
            if (widget.manager)
              ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('حذف'),
              onTap: () {
                Navigator.pop(c);
                deletePartner(x);
              },
            ),
          ],
        ),
      ),
    );
  }

  void msg(String x) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
    }
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['name']} ${x['phone'] ?? ''}'.contains(q))
        .toList();
    return PageFrame(
      title: 'الشركاء',
      subtitle: 'ملكية الشركاء وحصصهم واستحقاقاتهم ومدفوعاتهم',
      actions: [
        OutlinedButton.icon(
          onPressed: () => ReportService(widget.r).printPdf('partner_accounts'),
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: const Text('تقرير الشركاء'),
        ),
        FilledButton.icon(
          onPressed: add,
          icon: const Icon(Icons.group_add),
          label: const Text('شريك جديد'),
        ),
      ],
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث باسم الشريك أو الهاتف',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyView('لا يوجد شركاء مطابقون')
                : LayoutBuilder(
                    builder: (_, box) {
                      final cols = box.maxWidth >= 1100
                          ? 3
                          : box.maxWidth >= 720
                          ? 2
                          : 1;
                      const gap = 12.0;
                      final w = (box.maxWidth - gap * (cols - 1)) / cols;
                      return SingleChildScrollView(
                        child: Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final x in filtered)
                              SizedBox(
                                width: w,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(24),
                                  onTap: () => Navigator.push(
                                    c,
                                    MaterialPageRoute(
                                      builder: (_) => RecordDetailsPage(
                                        widget.r,
                                        kind: 'partner',
                                        id: x['id'] as int,
                                        title: 'تفاصيل الشريك',
                                      ),
                                    ),
                                  ),
                                  onLongPress: () => partnerActions(x),
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const CircleAvatar(
                                                child: Icon(
                                                  Icons.handshake_rounded,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  '${x['name']}',
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                                ),
                                              ),
                                              PopupMenuButton<String>(
                                                onSelected: (v) {
                                                  if (v == 'edit') {
                                                    editPartner(x);
                                                  }
                                                  if (v == 'delete') {
                                                    deletePartner(x);
                                                  }
                                                },
                                                itemBuilder: (_) => [
  const PopupMenuItem(value: 'edit', child: Text('تعديل بيانات الشريك')),
  if (widget.manager)
    const PopupMenuItem(value: 'delete', child: Text('حذف')),
],
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            x['ownership_mode'] == 'percentage'
                                                ? 'نسبة ملكية ${x['ownership_percentage'] ?? 0}%'
                                                : 'عدد حصص ${x['shares_count'] ?? 0}',
                                            style: TextStyle(
                                              color: Theme.of(
                                                c,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            AccountingCalculations.partyDueLabel(
  ((x['balance'] as num?)?.round() ?? 0),
),
style: TextStyle(
  fontWeight: FontWeight.w900,
  color: ((x['balance'] as num?)?.round() ?? 0) < 0
      ? Colors.red
      : _green,
),
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: OutlinedButton.icon(
                                                  onPressed: () => share(x),
                                                  icon: const Icon(
                                                    Icons.add_chart,
                                                  ),
                                                  label: const Text('استحقاق'),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: OutlinedButton.icon(
                                                  onPressed: () => pay(x),
                                                  icon: const Icon(
                                                    Icons.payments,
                                                  ),
                                                  label: const Text('دفع'),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── دفتر اليومية والأستاذ العام ─────────────────────────

/// تاريخ للعرض: «yyyy/MM/dd HH:mm» إن وُجد وقت، وإلا «yyyy/MM/dd».
String _fmtLedgerDate(Object? raw) {
  final text = '${raw ?? ''}';
  final d = DateTime.tryParse(text);
  if (d == null) return text.isEmpty ? '-' : text;
  return text.length > 10
      ? DateFormat('yyyy/MM/dd HH:mm').format(d)
      : DateFormat('yyyy/MM/dd').format(d);
}

/// رصيد الأستاذ الداخلي: الموجب عليه والسالب له.
String _drLabel(int n) => n > 0
    ? 'عليه ${money(n)}'
    : n < 0
    ? 'له ${money(n.abs())}'
    : money(0);

/// اسم عربي لمرجع القيد (نوع العملية الأصلية ورقمها).
String _refLabel(Object? type, Object? id) {
  final t = '${type ?? ''}';
  if (t.isEmpty) return '';
  final name = switch (t) {
    'irrigation' => 'سقاية',
    'irrigation_cancel' => 'إلغاء سقاية',
    'payment' => 'دفعة',
    'payment_cancel' => 'إلغاء دفعة',
    'expense' => 'مصروف',
    'cashbox_opening' => 'رصيد افتتاحي لصندوق',
    'cashbox_transfer' => 'تحويل بين الصناديق',
    'diesel' => 'تسليم ديزل',
    'diesel_advance' => 'سلفة ديزل',
    'diesel_consumption' => 'استهلاك ديزل',
    'diesel_receipt' => 'شراء ديزل',
    'worker' => 'استحقاق عامل',
    'partner' => 'حصة شريك',
    'beneficiary_opening' => 'رصيد افتتاحي لمستفيد',
    'beneficiary_carried' => 'رصيد مرحّل لمستفيد',
    'worker_opening' => 'رصيد افتتاحي لعامل',
    'partner_opening' => 'رصيد افتتاحي لشريك',
    'reversal' => 'قيد عكسي',
    _ => t,
  };
  return id == null ? name : '$name #$id';
}

void _openJournalEntry(BuildContext c, StationRepository r, Map<String, Object?> x) {
  final id = x['journal_id'] ?? x['id'];
  if (id is! int) return;
  Navigator.push(
    c,
    MaterialPageRoute(
      builder: (_) => RecordDetailsPage(
        r,
        kind: 'journal',
        id: id,
        title: 'تفاصيل القيد المحاسبي',
      ),
    ),
  );
}

/// يفتح صفحة الطرف (مستفيد/عامل/شريك) المرتبط بسطر القيد.
void _openLedgerParty(BuildContext c, StationRepository r, Map<String, Object?> x) {
  final (kind, id) = x['beneficiary_id'] is int
      ? ('beneficiary', x['beneficiary_id'] as int)
      : x['worker_id'] is int
      ? ('worker', x['worker_id'] as int)
      : x['partner_id'] is int
      ? ('partner', x['partner_id'] as int)
      : ('', 0);
  if (kind.isEmpty) return;
  Navigator.push(
    c,
    MaterialPageRoute(
      builder: (_) => RecordDetailsPage(
        r,
        kind: kind,
        id: id,
        title: '${x['party_name'] ?? ''}',
      ),
    ),
  );
}

class _DateRangeBar extends StatelessWidget {
  final DateTime? from, to;
  final ValueChanged<DateTime> onFrom, onTo;
  final VoidCallback onClear;
  const _DateRangeBar({
    required this.from,
    required this.to,
    required this.onFrom,
    required this.onTo,
    required this.onClear,
  });

  Future<void> _pick(BuildContext c, DateTime? cur, ValueChanged<DateTime> cb) async {
    final d = await showDatePicker(
      context: c,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: cur ?? AppClock.now(),
      locale: const Locale('ar'),
    );
    if (d != null) cb(d);
  }

  @override
  Widget build(BuildContext c) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      OutlinedButton.icon(
        onPressed: () => _pick(c, from, onFrom),
        icon: const Icon(Icons.date_range),
        label: Text(
          from == null ? 'من تاريخ' : 'من ${DateFormat('yyyy/MM/dd').format(from!)}',
        ),
      ),
      OutlinedButton.icon(
        onPressed: () => _pick(c, to, onTo),
        icon: const Icon(Icons.event),
        label: Text(
          to == null ? 'إلى تاريخ' : 'إلى ${DateFormat('yyyy/MM/dd').format(to!)}',
        ),
      ),
      if (from != null || to != null)
        TextButton.icon(
          onPressed: onClear,
          icon: const Icon(Icons.clear),
          label: const Text('مسح التواريخ'),
        ),
    ],
  );
}

class JournalPage extends StatefulWidget {
  final StationRepository r;
  const JournalPage(this.r, {super.key});
  @override
  State<JournalPage> createState() => _JournalState();
}

class _JournalState extends State<JournalPage> {
  List<Map<String, Object?>> lines = [];
  DateTime? from, to;
  String search = '';
  bool loading = true;
  String? error;
  int _seq = 0;

  Future<void> load() async {
    final seq = ++_seq;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final x = await widget.r.journal(from: from, to: to);
      if (!mounted || seq != _seq) return;
      setState(() {
        lines = x;
        loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        error = friendlyError(e);
        loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  /// يجمع أسطر القيد الواحد في بطاقة واحدة (الأحدث أولًا).
  List<List<Map<String, Object?>>> get entries {
    final byId = <Object?, List<Map<String, Object?>>>{};
    for (final l in lines) {
      byId.putIfAbsent(l['journal_id'], () => []).add(l);
    }
    final q = search.trim();
    final out = byId.values.where((g) {
      if (q.isEmpty) return true;
      return g.any(
        (l) =>
            '${l['description']} ${l['account_code']} ${l['account_name']} ${l['party_name'] ?? ''} ${l['memo'] ?? ''} ${_refLabel(l['reference_type'], l['reference_id'])}'
                .contains(q),
      );
    }).toList();
    return out.reversed.toList();
  }

  Widget entryCard(BuildContext c, List<Map<String, Object?>> g) {
    final head = g.first;
    final totalDebit = g.fold<int>(0, (s, l) => s + ((l['debit'] as num?)?.round() ?? 0));
    final ref = _refLabel(head['reference_type'], head['reference_id']);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openJournalEntry(c, widget.r, head),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${head['description']}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  Text(
                    _fmtLedgerDate(head['date']),
                    style: TextStyle(
                      color: Theme.of(c).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (ref.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'المرجع: $ref',
                    style: TextStyle(
                      color: Theme.of(c).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              const Divider(height: 18),
              const Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Text('الحساب', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'عليه',
                      textAlign: TextAlign.end,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'له',
                      textAlign: TextAlign.end,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              for (final l in g)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Text(
                          '${l['account_name']}'
                          '${l['party_name'] != null ? ' • ${l['party_name']}' : ''}',
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          ((l['debit'] as num?)?.round() ?? 0) > 0 ? money(l['debit']) : '',
                          textAlign: TextAlign.end,
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          ((l['credit'] as num?)?.round() ?? 0) > 0 ? money(l['credit']) : '',
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                    'إجمالي الحركة: ${money(totalDebit)}',
                style: TextStyle(
                  color: Theme.of(c).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final list = loading || error != null ? <List<Map<String, Object?>>>[] : entries;
    return PageFrame(
      title: 'دفتر اليومية',
      subtitle: 'كل القيود المحاسبية المتوازنة المرتبطة بالعمليات',
      actions: [
        OutlinedButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DateRangeBar(
            from: from,
            to: to,
            onFrom: (d) {
              from = d;
              if (to != null && d.isAfter(to!)) to = null;
              load();
            },
            onTo: (d) {
              to = d;
              if (from != null && d.isBefore(from!)) from = null;
              load();
            },
            onClear: () {
              from = null;
              to = null;
              load();
            },
          ),
          const SizedBox(height: 8),
          TextField(
            onChanged: (v) => setState(() => search = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث بالبيان أو الحساب أو الطرف أو المرجع',
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: loading
                ? const LoadingView()
                : error != null
                ? ErrorBox('تعذر تحميل القيود:\n$error')
                : list.isEmpty
                ? const EmptyView('لا توجد قيود مطابقة')
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) => entryCard(c, list[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class LedgerPage extends StatefulWidget {
  final StationRepository r;
  const LedgerPage(this.r, {super.key});
  @override
  State<LedgerPage> createState() => _LedgerState();
}

class _LedgerState extends State<LedgerPage> {
  String code = '1000';
  List<Map<String, Object?>> accounts = [];
  List<Map<String, Object?>> rows = [];
  List<String> accountIssues = [];
  int opening = 0, totalDebit = 0, totalCredit = 0, closing = 0;
  DateTime? from, to;
  bool loading = true;
  String? error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// قائمة الحسابات من جدول accounts (لا قائمة ثابتة في الكود).
  Future<void> _init() async {
    try {
      final a = await widget.r.accounts();
      final issues = await widget.r.accountTreeIssues();
      if (!mounted) return;
      setState(() {
        accounts = a;
        accountIssues = issues;
        if (a.isNotEmpty && !a.any((x) => x['code'] == code)) {
          code = '${a.first['code']}';
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
    await load();
  }

  String _accountIndent(Map<String, Object?> account) {
    final byId = <int, Map<String, Object?>>{
      for (final item in accounts)
        if (item['id'] is num) (item['id'] as num).toInt(): item,
    };
    final visited = <int>{};
    var parent = account['parent_id'] is num
        ? (account['parent_id'] as num).toInt()
        : null;
    var depth = 0;
    while (parent != null && byId.containsKey(parent) && visited.add(parent)) {
      depth++;
      final next = byId[parent]!['parent_id'];
      parent = next is num ? next.toInt() : null;
    }
    return depth == 0 ? '' : '${List.filled(depth, '  ').join()}↳ ';
  }

  Future<void> load() async {
    // رقم الطلب يتجاهل أي استجابة قديمة عند التبديل السريع بين الحسابات/التواريخ.
    final seq = ++_seq;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final st = await widget.r.ledgerStatement(code, from: from, to: to);
      if (!mounted || seq != _seq) return;
      setState(() {
        rows = (st['rows'] as List).cast<Map<String, Object?>>();
        opening = st['opening'] as int;
        totalDebit = st['total_debit'] as int;
        totalCredit = st['total_credit'] as int;
        closing = st['closing'] as int;
        loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        error = friendlyError(e);
        rows = [];
        loading = false;
      });
    }
  }

  Widget rowCard(BuildContext c, Map<String, Object?> x) {
    final ref = _refLabel(x['reference_type'], x['reference_id']);
    final memo = '${x['memo'] ?? ''}'.trim();
    final muted = TextStyle(
      color: Theme.of(c).colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    final d = (x['debit'] as num?)?.round() ?? 0;
    final cr = (x['credit'] as num?)?.round() ?? 0;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openJournalEntry(c, widget.r, x),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${x['description'] ?? x['memo'] ?? 'حركة محاسبية'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        height: 1.25,
                        color: Theme.of(c).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _fmtLedgerDate(x['date']),
                    style: TextStyle(
                      color: Theme.of(c).colorScheme.onSurface,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (x['party_name'] != null)
                    ActionChip(
                      avatar: const Icon(Icons.person_outline, size: 16),
                      label: Text('${x['party_name']}'),
                      onPressed: () => _openLedgerParty(c, widget.r, x),
                    ),
                  if (ref.isNotEmpty) Text('المرجع: $ref', style: muted),
                  if (memo.isNotEmpty) Text(memo, style: muted),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 18,
                runSpacing: 4,
                children: [
                  Text(
                    'عليه: ${d > 0 ? money(d) : '—'}',
                    style: const TextStyle(color: _reportOrange, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                  Text(
                    'له: ${cr > 0 ? money(cr) : '—'}',
                    style: const TextStyle(color: _reportGreen, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                  Text(
                    'الرصيد الجاري: ${_drLabel((x['balance'] as num?)?.round() ?? 0)}',
                    style: TextStyle(color: Theme.of(c).colorScheme.onSurface, fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final hasCode = accounts.any((x) => x['code'] == code);
    return PageFrame(
      title: 'الأستاذ العام',
      subtitle: 'حساب مستقل لكل رمز مع له وعليه والرصيد الجاري',
      actions: [
        OutlinedButton.icon(
          onPressed: loading ? null : _printLedger,
          icon: const Icon(Icons.print_rounded),
          label: const Text('طباعة كشف الحساب'),
        ),
        OutlinedButton.icon(
          onPressed: loading ? null : _init,
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: hasCode ? code : null,
            isExpanded: true,
            items: [
              for (final a in accounts)
                DropdownMenuItem(
                  value: '${a['code']}',
                  child: Text('${_accountIndent(a)}${a['code']} • ${a['name']}'),
                ),
            ],
            onChanged: (v) {
              if (v == null || v == code) return;
              setState(() => code = v);
              load();
            },
            decoration: const InputDecoration(labelText: 'الحساب'),
          ),
          if (accountIssues.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('تنبيه: توجد مشكلات في شجرة الحسابات', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    for (final issue in accountIssues.take(8))
                      Text('• $issue'),
                    if (accountIssues.length > 8)
                      Text('ومشكلات أخرى: ${accountIssues.length - 8}'),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          _DateRangeBar(
            from: from,
            to: to,
            onFrom: (d) {
              from = d;
              if (to != null && d.isAfter(to!)) to = null;
              load();
            },
            onTo: (d) {
              to = d;
              if (from != null && d.isBefore(from!)) from = null;
              load();
            },
            onClear: () {
              from = null;
              to = null;
              load();
            },
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 112,
            child: PageView(
              controller: PageController(viewportFraction: .78),
              children: [
                _ledgerMetric('رصيد أول المدة', _drLabel(opening), Icons.account_balance_wallet_rounded, _blue),
                _ledgerMetric('إجمالي عليه', money(totalDebit), Icons.south_west_rounded, _purple),
                _ledgerMetric('إجمالي له', money(totalCredit), Icons.north_east_rounded, _cyan),
                _ledgerMetric('الرصيد الختامي', _drLabel(closing), Icons.balance_rounded, _green),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: loading
                ? const LoadingView()
                : error != null
                ? ErrorBox('تعذر تحميل الأستاذ:\n$error')
                : rows.isEmpty
                ? const EmptyView('لا توجد حركات لهذا الحساب في الفترة المحددة')
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 18),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => rowCard(c, rows[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _ledgerMetric(String label, String value, IconData icon, Color color) =>
      Container(
        margin: const EdgeInsetsDirectional.only(end: 10, top: 3, bottom: 5),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: .45), width: 1.2),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: .09), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(children: [
              Icon(icon, color: color, size: 21),
              const SizedBox(width: 8),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w700, fontSize: 12))),
            ]),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(value, style: TextStyle(color: color, fontSize: 19, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 2),
            Text('اسحب لمشاهدة البطاقة التالية', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 9)),
          ],
        ),
      );

  Future<void> _printLedger() async {
    try {
      final account = accounts.where((x) => '${x['code']}' == code).toList();
      final accountName = account.isEmpty ? code : '${account.first['name'] ?? code}';
      final reportRows = <Map<String, Object?>>[
        for (final x in rows)
          <String, Object?>{
            'date': x['date'],
            'account_name': '$code • $accountName',
            'journal_entry_id': x['journal_entry_id'] ?? x['entry_id'] ?? x['id'],
            'description': x['description'] ?? x['memo'] ?? '',
            'alayh': x['debit'] ?? 0,
            'lah': x['credit'] ?? 0,
            'balance': x['balance'] ?? 0,
          },
      ];
      await ReportService(widget.r).printPdf(
        'ledger',
        from: from,
        to: to,
        sourceRows: reportRows,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e))),
        );
      }
    }
  }
}

const _reportOlive = Color(0xff777648);
const _reportOliveDark = Color(0xff575633);
const _reportCream = Color(0xffF4F3E9);
const _reportInk = Color(0xff263027);
const _reportGreen = Color(0xff169B58);
const _reportOrange = Color(0xffDE7732);
const _reportLine = Color(0xffDDE1D5);

class ReportsPage extends StatefulWidget {
  final StationRepository r;
  const ReportsPage(this.r, {super.key});
  static const keys = [
    'invoices','irrigations','time_comparison','monthly_financial','income',
    'payment_methods','expenses','cashboxes','queue_bookings',
    'beneficiary_statement','beneficiary_detailed','beneficiary_stats','needy',
    'diesel_inventory','activity_overview','oil_status','debts','beneficiary_list',
    'revenue_comparison','system_comparison','journal','ledger',
    'worker_transactions','partner_accounts','partner_profit_distribution',
  ];
  @override State<ReportsPage> createState() => _ReportsState();
}

class _ReportsState extends State<ReportsPage> {
  List<Map<String,Object?>> bs=[],ws=[],ps=[],cs=[],ms=[];
  DateTime? from,to;
  String? type,category,status;
  int? bid,wid,pid,cid,mid;
  String currentType='diesel'; Map<String,String> _cfg={};
  final Map<String, PageController> _reportControllers = {};
  @override void dispose(){for(final controller in _reportControllers.values){controller.dispose();}super.dispose();}
  List<(String,DateTime,DateTime)> _quickRanges(){
    final now=AppClock.now(),today=DateTime(now.year,now.month,now.day);
    return [('اليوم',today,today),('هذا الأسبوع',PeriodRanges.weekStart(today,_cfg['week_start']??'saturday'),today),('هذا الشهر',DateTime(now.year,now.month,1),today),('السنة المالية',PeriodRanges.financialYearStart(today,_cfg['financial_year_start']??'01-01'),today)];
  }
  Future<void> load() async { final a=await widget.r.beneficiaries(),b=await widget.r.workers(),p=await widget.r.partners(),c=await widget.r.cashboxes(),m=await widget.r.paymentMethods(),cfg=await widget.r.settings(); if(mounted)setState((){_cfg=cfg;bs=a;ws=b;ps=p;cs=c;ms=m;bid=bid??(a.isEmpty?null:a.first['id'] as int?);wid=wid??(b.isEmpty?null:b.first['id'] as int?);pid=pid??(p.isEmpty?null:p.first['id'] as int?);cid=cid??(c.isEmpty?null:c.first['id'] as int?);mid=mid??(m.isEmpty?null:m.first['id'] as int?);currentType=cfg['system_type']??'diesel';type = currentType;}); }
  @override void initState(){super.initState();load();}
  Future<List<Map<String,Object?>>> _rows(String k)=>widget.r.report(k,from:from,to:to,beneficiaryId:bid,workerId:wid,partnerId:pid,systemType:type,cashboxId:cid,paymentMethodId:mid,category:category,status:status);
  Future<void> previewR(String k) async {
    if (currentType == 'solar' && k == 'diesel_inventory') return;
    if (k == 'time_comparison') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => RevenueComparisonsPage(widget.r, initialFrom: from, initialTo: to)));
      return;
    }
    if (k == 'monthly_financial') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => MonthlyFinancialReportPage(widget.r, initialFrom: from, initialTo: to)));
      return;
    }
    if (k == 'cashboxes') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => CashboxesTransfersReportPage(widget.r, initialFrom: from, initialTo: to)));
      return;
    }
    if (k == 'debts') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => DebtsReportPage(widget.r)));
      return;
    }
    if (k == 'income') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => RevenueCollectionsReportPage(widget.r, initialFrom: from, initialTo: to, initialSystemType: type)));
      return;
    }
    if (k == 'diesel_inventory') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => InventoryMovementReportPage(widget.r, initialFrom: from, initialTo: to)));
      return;
    }
    if (k == 'expenses') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ExpensesDetailedReportPage(widget.r, initialFrom: from, initialTo: to, initialCategory: category, initialStatus: status)));
      return;
    }
    if (k == 'invoices') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicesReportPage(widget.r, initialFrom: from, initialTo: to)));
      return;
    }
    if (k == 'irrigations') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => IrrigationDetailedReportPage(widget.r, initialBeneficiaryId: bid, initialFrom: from, initialTo: to, initialSystemType: type)));
      return;
    }
    if (k == 'partner_accounts') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => PartnerAccountsReportPage(
        widget.r,
        initialPartnerId: pid,
        initialFrom: from,
        initialTo: to,
        userId: null,
      )));
      return;
    }
    if (k == 'worker_transactions') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => WorkerTransactionsOverviewPage(
        widget.r,
        initialWorkerId: wid,
        initialFrom: from,
        initialTo: to,
      )));
      return;
    }
    if (k == 'partner_profit_distribution') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => PartnerProfitDistributionPage(widget.r, initialFrom: from, initialTo: to)));
      return;
    }
    if (k == 'ledger') {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => LedgerStatementsPage(
        widget.r,
        initialFrom: from,
        initialTo: to,
      )));
      return;
    }
    try {
      final rows = await _rows(k);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReportPreviewPage(widget.r, keyName: k, rows: rows, filters: '${from ?? ''} ${to ?? ''}', from: from, to: to, beneficiaryId: bid, workerId: wid, partnerId: pid, cashboxId: cid, paymentMethodId: mid, systemType: type, category: category, status: status)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إنشاء التقرير: $e')));
    }
  }
  Future<void> printR(String k) async {try{final rows = await _rows(k);if(!mounted)return;if(k=='invoices'){await ReportService(widget.r).printInvoicesPdf(rows:rows,from:from,to:to);return;}await ReportService(widget.r).printPdf(k,from:from,to:to,beneficiaryId:bid,workerId:wid,partnerId:pid,systemType:type,cashboxId:cid,paymentMethodId:mid,category:category,status:status,sourceRows:rows);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}}
  Widget sel<T>(String label,T? v,List<DropdownMenuItem<T>> items,ValueChanged<T?> f)=>SizedBox(width:205,child:DropdownButtonFormField<T>(initialValue:v,items:items,onChanged:f,decoration:InputDecoration(labelText:label,filled:true,fillColor:Colors.white,border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none))));
  IconData _icon(String k)=>switch(k){'invoices'=>Icons.receipt_long_rounded,'irrigations'=>Icons.water_drop_rounded,'expenses'=>Icons.receipt_long_rounded,'journal'=>Icons.menu_book_rounded,'ledger'=>Icons.account_balance_rounded,'worker_transactions'=>Icons.engineering_rounded,'partner_accounts'=>Icons.groups_rounded,'beneficiary_statement'=>Icons.person_pin_rounded,'monthly_financial'=>Icons.insights_rounded,'cashboxes'=>Icons.account_balance_wallet_rounded,_=>Icons.analytics_rounded};
  String _group(String k)=>switch(k){
    'invoices'||'irrigations'||'time_comparison'||'income'||'monthly_financial'||'revenue_comparison'||'system_comparison'=>'السقايات والإيرادات',
    'expenses'||'cashboxes'||'payment_methods'||'oil_status'||'diesel_inventory'=>'المالية والحركة',
    'beneficiary_statement'||'beneficiary_detailed'||'beneficiary_stats'||'beneficiary_list'||'needy'||'debts'=>'كشوف الحساب',
    'journal'||'ledger'=>'دفتر الأستاذ',
    'worker_transactions'||'partner_accounts'||'partner_profit_distribution'||'queue_bookings'||'activity_overview'=>'التشغيل والمتابعة',
    _=>'التشغيل والمتابعة',
  };
  String _description(String k)=>switch(k){
    'invoices'=>'فواتير السقايات بجدول مرتب وملخص إجمالي ومعاينة وطباعة ومشاركة PDF',
    'irrigations'=>'تفاصيل كل سقاية ومدتها ومبلغها والمدفوع منها',
    'time_comparison'=>'مقارنة الدقائق والعمليات بين الأشهر والمنظومات',
    'monthly_financial'=>'الدخل والمصروفات شهرياً بصورة مختصرة',
    'income'=>'مصادر الدخل حسب نوع المنظومة',
    'payment_methods'=>'إجمالي الاستخدام لكل طريقة دفع',
    'expenses'=>'توزيع المصروفات حسب التصنيف',
    'cashboxes'=>'الوارد والمنصرف والرصيد الحالي لكل صندوق',
    'queue_bookings'=>'حالة الطابور وطلبات الحجز',
    'beneficiary_statement'=>'كشف له وعليه للمستفيد مع الرصيد الجاري',
    'beneficiary_detailed'=>'تفاصيل حركات المستفيد والسقايات والدفعات',
    'beneficiary_stats'=>'عدد السقايات والدقائق والإجمالي لكل مستفيد',
    'needy'=>'المستفيدون المحتاجون وأرصدتهم الحالية',
    'diesel_inventory'=>'حركة مخزون الديزل والكميات والتكلفة',
    'activity_overview'=>'ملخص العمليات والدقائق والإيرادات',
    'oil_status'=>'إجمالي استهلاك الزيت والشحم',
    'debts'=>'ترتيب أرصدة المستفيدين من الأعلى إلى الأقل',
    'beneficiary_list'=>'قائمة المستفيدين وبيانات التواصل',
    'revenue_comparison'=>'مقارنة الإيرادات بين الأشهر والمنظومات',
    'system_comparison'=>'مقارنة أداء منظومات الري وتكلفة الديزل',
    'journal'=>'قيود اليومية مع الحسابات والمرجع',
    'ledger'=>'دفتر الأستاذ وحركة الرصيد لكل قيد',
    'worker_transactions'=>'كشف العامل من دفتر الأستاذ: له وعليه',
    'partner_accounts'=>'كشف الشريك من دفتر الأستاذ: له وعليه',
    'partner_profit_distribution'=>'صافي الربح بعد المصروفات والعمال وتوزيعه على الشركاء',
    _=>'معاينة البيانات والفلاتر والطباعة',
  };
  bool _allowedReport(String k) => currentType == 'diesel' || (k != 'diesel_inventory' && k != 'oil_status');
  Widget _reportCard(String k){final title=ReportService.titles[k]??'تقرير';return Container(padding:const EdgeInsets.all(18),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(22),border:Border.all(color:_reportLine),boxShadow:[BoxShadow(color:_reportOlive.withValues(alpha: .08),blurRadius:18,offset:const Offset(0,7))]),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Container(width:44,height:44,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(14)),child:Icon(_icon(k),color:_reportOliveDark)),const SizedBox(width:12),Expanded(child:Text(title,softWrap:true,style:const TextStyle(fontWeight:FontWeight.w900,fontSize:16,color:_reportInk))),const Icon(Icons.swipe_rounded,size:20,color:_reportOlive)]),const SizedBox(height:14),Expanded(child:Align(alignment:Alignment.topRight,child:Text(_description(k),softWrap:true,style:TextStyle(color:_reportInk.withValues(alpha: .72),fontSize:13,height:1.5)))),const SizedBox(height:10),Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>previewR(k),style:OutlinedButton.styleFrom(foregroundColor:_reportOliveDark,side:const BorderSide(color:_reportLine),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),icon:const Icon(Icons.visibility_outlined,size:18),label:const Text('معاينة كاملة'))),const SizedBox(width:10),FilledButton.tonalIcon(onPressed:()=>printR(k),style:FilledButton.styleFrom(foregroundColor:_reportOliveDark,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),icon:const Icon(Icons.print_rounded,size:18),label:const Text('PDF'))])]));}
  @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('مركز التقارير',style:TextStyle(fontWeight:FontWeight.w900)),actions:[Padding(padding:const EdgeInsetsDirectional.only(end:16),child:IconButton(onPressed:load,icon:const Icon(Icons.refresh_rounded)))]),body:ListView(padding:const EdgeInsets.fromLTRB(18,4,18,32),children:[Container(padding:const EdgeInsets.all(22),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(28)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('تقاريرك المالية والتشغيلية',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:13)),const SizedBox(height:7),const Text('كل الأرقام في نظرة واضحة',style:TextStyle(color:Colors.white,fontWeight:FontWeight.w900,fontSize:23)),const SizedBox(height:10),Text('اختر فترة ثم افتح التقرير أو اطبعه PDF',style:TextStyle(color:Colors.white.withValues(alpha: .78),fontSize:12))]),),Container(width:68,height:68,decoration:BoxDecoration(color:Colors.white.withValues(alpha: .15),shape:BoxShape.circle),child:const Icon(Icons.insights_rounded,color:Colors.white,size:35))])),const SizedBox(height:16),Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(22),border:Border.all(color:_reportLine)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[const Icon(Icons.tune_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('نطاق التقرير',style:TextStyle(fontWeight:FontWeight.w900,fontSize:16)),const Spacer(),TextButton(onPressed:()=>setState((){from=null;to=null;bid=wid=pid=cid=mid=null;category=status=null;type = currentType;}),child:const Text('مسح الكل'))]),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[for(final qr in _quickRanges())ChoiceChip(label:Text(qr.$1),selected:from==qr.$2&&to==qr.$3,onSelected:(_)=>setState((){from=qr.$2;to=qr.$3;}),selectedColor:_reportOliveDark, labelStyle:TextStyle(color:from==qr.$2&&to==qr.$3?Colors.white:_reportInk)),OutlinedButton.icon(onPressed:()async{from=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:from??AppClock.now(),locale:const Locale('ar'));setState((){});},icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${from!.year}/${from!.month}/${from!.day}')),OutlinedButton.icon(onPressed:()async{to=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:to??AppClock.now(),locale:const Locale('ar'));setState((){});},icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${to!.year}/${to!.month}/${to!.day}'))]),const SizedBox(height:12),Wrap(spacing:8,runSpacing:8,children:[sel<String>('نوع المنظومة',type,[DropdownMenuItem(value: currentType, child: Text(systemName(currentType)))],(v)=>setState(()=>type=v)),sel<int>('المستفيد',bid,[const DropdownMenuItem(value:null,child:Text('كل المستفيدين')),for(final x in bs)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],(v)=>setState(()=>bid=v)),sel<int>('العامل',wid,[const DropdownMenuItem(value:null,child:Text('كل العمال')),for(final x in ws)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],(v)=>setState(()=>wid=v)),sel<int>('الشريك',pid,[const DropdownMenuItem(value:null,child:Text('كل الشركاء')),for(final x in ps)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],(v)=>setState(()=>pid=v)),sel<int>('الصندوق',cid,[const DropdownMenuItem(value:null,child:Text('كل الصناديق')),for(final x in cs)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],(v)=>setState(()=>cid=v)),sel<int>('طريقة الدفع',mid,[const DropdownMenuItem(value:null,child:Text('كل طرق الدفع')),for(final x in ms)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],(v)=>setState(()=>mid=v)),sel<String>('تصنيف المصروف',category,[const DropdownMenuItem(value:null,child:Text('كل التصنيفات')),for(final x in ['workers','partners','fuel','oil','grease','maintenance','parts','transport','admin','other'])DropdownMenuItem(value:x,child:Text(categoryName(x)))],(v)=>setState(()=>category=v)),sel<String>('الحالة',status,[const DropdownMenuItem(value:null,child:Text('كل الحالات')),for(final x in ['posted','cancelled','new','scheduled'])DropdownMenuItem(value:x,child:Text(statusName(x)))],(v)=>setState(()=>status=v))])])),const SizedBox(height:22),for(final group in ['السقايات والإيرادات','المالية والحركة','كشوف الحساب','دفتر الأستاذ','التشغيل والمتابعة']) _reportGroup(group)])));
  Widget _reportGroup(String group){final items=ReportsPage.keys.where((k)=>_group(k)==group&&_allowedReport(k)).toList();return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Container(width:6,height:24,decoration:BoxDecoration(color:_reportOliveDark,borderRadius:BorderRadius.circular(5))),const SizedBox(width:9),Expanded(child:Text(group,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w900,color:_reportInk))),Text('${items.length} تقارير',style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:12))]),const SizedBox(height:11),if(items.isNotEmpty)SizedBox(height:228,child:PageView.builder(scrollDirection:Axis.horizontal,physics:const PageScrollPhysics(),padEnds:true,itemCount:items.length,controller:(_reportControllers[group]??=PageController(viewportFraction:.91)),itemBuilder:(context,index)=>Padding(padding:const EdgeInsetsDirectional.only(end:10,bottom:4),child:_reportCard(items[index])))),if(items.length>1)Padding(padding:const EdgeInsets.only(top:7),child:Center(child:Text('اسحب أفقيًا لاستعراض البطاقات • ${items.length} تقارير',style:TextStyle(color:_reportInk.withValues(alpha:.55),fontSize:11)))),const SizedBox(height:25)]);}
}

String? reportFieldArabic(String key) => {
  'id': 'الرقم',
  'date': 'التاريخ',
  'start_datetime': 'بداية السقي',
  'end_datetime': 'نهاية السقي',
  'minutes': 'المدة بالدقائق',
  'system_type': 'نوع المنظومة',
  'total_amount': 'الإجمالي',
  'paid_amount': 'المدفوع',
  'remaining': 'حالة الرصيد',
  'beneficiary_name': 'المستفيد',
  'party_name': 'الجهة',
  'cloud_status': 'حالة خصم الغيم',
  'worker_name': 'العامل',
  'partner_name': 'الشريك',
  'cashbox_name': 'الصندوق',
  'method_name': 'طريقة الدفع',
  'account_name': 'الحساب',
  'account_code': null,
  'debit': 'عليه',
  'credit': 'له',
  'lah': 'له',
  'alayh': 'عليه',
  'amount': 'المبلغ',
  'liters': 'اللترات',
  'kind': 'نوع الحركة',
  'status': 'الحالة',
  'notes': 'ملاحظات',
  'description': 'البيان',
  'ownership_percentage': 'نسبة الملكية',
  'shares_count': 'عدد الحصص',
  'opening_balance': 'الرصيد الافتتاحي',
  'carried_balance': 'الرصيد المرحل',
  'balance': 'حالة الرصيد',
  'water_amount': 'قيمة المياه',
  'diesel_amount': 'قيمة الديزل',
  'cloud_minutes': 'دقائق الغيم',
  'chargeable_minutes': 'الدقائق المحاسبية',
  'category': 'التصنيف',
  'title': 'العنوان',
  'phone': 'الهاتف',
  'name': 'الاسم',
  'reference_number': 'رقم المرجع',
  'created_at': 'تاريخ الإنشاء',
  'updated_at': 'تاريخ التحديث',
  'position': 'الدور',
  'scheduled_start': 'بداية الموعد',
  'scheduled_end': 'نهاية الموعد',
  'payment_method_id': 'طريقة الدفع',
  'cashbox_id': 'الصندوق',
  'beneficiary_id': 'المستفيد',
  'worker_id': 'العامل',
  'partner_id': 'الشريك',
  'journal_id': 'رقم القيد',
  'journal_entry_id': 'رقم القيد',
  'ownership_mode': 'طريقة الملكية',
}[key];
String reportValueArabic(String key, Object? value) {
  if (value == null) return '-';
  if (key == 'system_type') return systemName('$value');
  if (key == 'status') return statusName(value);
  if (key == 'kind') return movementName('$value');
  if (key == 'ownership_mode') {
    return value == 'percentage' ? 'نسبة ملكية' : 'عدد حصص';
  }
  return '$value';
}

class ReportPreviewPage extends StatelessWidget {
  final StationRepository r; final String keyName; final List<Map<String,Object?>> rows; final String filters;
  final DateTime? from,to; final int? beneficiaryId,workerId,partnerId,cashboxId,paymentMethodId; final String? systemType,category,status;
  const ReportPreviewPage(this.r,{required this.keyName,required this.rows,required this.filters,this.from,this.to,this.beneficiaryId,this.workerId,this.partnerId,this.cashboxId,this.paymentMethodId,this.systemType,this.category,this.status,super.key});
  String _title()=>ReportService.titles[keyName]??'تقرير';
  Color _valueColor(String k,Object? v){if(k=='lah'||k=='credit')return _reportGreen;if(k=='alayh'||k=='debit')return _reportOrange;return _reportInk;}
  String _value(String k,Object? v){if(v==null)return '-';if(k=='date'||k.endsWith('_datetime')){final d=DateTime.tryParse('$v');if(d!=null)return '${d.day}/${d.month}/${d.year}';}if(k=='system_type')return systemName('$v');if(k=='status')return statusName(v);if(k=='kind')return movementName('$v');if(k=='ownership_mode')return v=='percentage'?'نسبة ملكية':'عدد حصص';return '$v';}
  List<MapEntry<String,Object?>> _visible(Map<String,Object?> row)=>row.entries.where((e)=>reportFieldArabic(e.key)!=null&&e.key!='id'&&e.key!='created_at'&&e.key!='updated_at'&&e.key!='journal_entry_id').toList();
  Widget _metric(String label, String value, IconData icon, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _reportLine),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(color: _reportInk.withValues(alpha: .55), fontSize: 11)),
                    const SizedBox(height: 3),
                    Text(value, style: const TextStyle(fontWeight: FontWeight.w900, color: _reportInk, fontSize: 16)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
  Widget _rowCard(Map<String,Object?> row,int index){
    final entries=_visible(row);
    return Container(
      margin:const EdgeInsetsDirectional.only(start:5,end:5,bottom:8),
      padding:const EdgeInsets.all(15),
      decoration:BoxDecoration(
        color:Colors.white,
        borderRadius:BorderRadius.circular(20),
        border:Border.all(color:_reportLine),
        boxShadow:[BoxShadow(color:_reportOlive.withValues(alpha:.05),blurRadius:12,offset:const Offset(0,4))],
      ),
      child:SingleChildScrollView(
        child:Column(
          crossAxisAlignment:CrossAxisAlignment.stretch,
          children:[
            Row(children:[
              Container(width:30,height:30,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(10)),child:Center(child:Text('${index+1}',style:const TextStyle(color:_reportOliveDark,fontWeight:FontWeight.w900)))),
              const SizedBox(width:10),
              Expanded(child:Text(_value(entries.isNotEmpty?entries.first.key:'description',entries.isNotEmpty?entries.first.value:null),softWrap:true,style:const TextStyle(fontWeight:FontWeight.w800,color:_reportInk))),
              if(row['lah']!=null&&((row['lah'] as num?)?.abs()??0)>0)_badge('له','${row['lah']}',_reportGreen),
              if(row['alayh']!=null&&((row['alayh'] as num?)?.abs()??0)>0)_badge('عليه','${row['alayh']}',_reportOrange),
            ]),
            const SizedBox(height:12),
            Wrap(
              spacing:14,
              runSpacing:12,
              children:[
                for(final e in entries.skip(1))
                  SizedBox(
                    width:145,
                    child:Column(
                      crossAxisAlignment:CrossAxisAlignment.start,
                      mainAxisSize:MainAxisSize.min,
                      children:[
                        Text(reportFieldArabic(e.key)??e.key,softWrap:true,style:TextStyle(color:_reportInk.withValues(alpha:.55),fontSize:10)),
                        const SizedBox(height:3),
                        Text(_value(e.key,e.value),softWrap:true,style:TextStyle(color:_valueColor(e.key,e.value),fontWeight:FontWeight.w700,fontSize:12,height:1.35)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  Widget _badge(String label,String value,Color color)=>Container(margin:const EdgeInsetsDirectional.only(start:5),padding:const EdgeInsets.symmetric(horizontal:9,vertical:5),decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(9)),child:Text('$label $value',style:TextStyle(color:color,fontSize:11,fontWeight:FontWeight.w900)));
  @override Widget build(BuildContext context){final net=rows.isEmpty?'-':'${rows.last['balance']??'-'}';return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:Text(_title(),style:const TextStyle(fontWeight:FontWeight.w900)),actions:[Padding(padding:const EdgeInsetsDirectional.only(end:12),child:FilledButton.icon(style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14))),onPressed:()async{await ReportService(r).printPdf(keyName,from:from,to:to,beneficiaryId:beneficiaryId,workerId:workerId,partnerId:partnerId,cashboxId:cashboxId,paymentMethodId:paymentMethodId,systemType:systemType,category:category,status:status,sourceRows:rows);},icon:const Icon(Icons.print_rounded),label:const Text('PDF')))]),body:ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(26)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة التقرير',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),Text(_title(),style:const TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:6),Text(filters.trim().isEmpty?'كل الفترات':filters,style:TextStyle(color:Colors.white.withValues(alpha: .8),fontSize:11))]),),const Icon(Icons.assessment_rounded,color:Colors.white,size:48)])),const SizedBox(height:14),Row(children:[_metric('عدد السجلات','${rows.length}',Icons.view_list_rounded,_reportOliveDark),const SizedBox(width:10),_metric('آخر رصيد',net,Icons.account_balance_wallet_rounded,net.startsWith('-')?_reportOrange:_reportGreen)]),const SizedBox(height:16),if(rows.isEmpty)Container(padding:const EdgeInsets.all(35),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(22)),child:const Column(children:[Icon(Icons.inbox_rounded,size:44,color:_reportOlive),SizedBox(height:10),Text('لا توجد بيانات مطابقة للفلاتر المحددة',style:TextStyle(fontWeight:FontWeight.w700))]))else ...[SizedBox(height:390,child:PageView.builder(scrollDirection:Axis.horizontal,physics:const PageScrollPhysics(),padEnds:true,itemCount:rows.take(200).length,itemBuilder:(context,index)=>_rowCard(rows[index],index))),if(rows.length>200)Center(child:Text('يتم عرض أول 200 سجل',style:TextStyle(color:_reportInk.withValues(alpha:.55)))),if(rows.length>1)Padding(padding:const EdgeInsets.only(top:8),child:Center(child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[const Icon(Icons.swipe_rounded,size:17,color:_reportOliveDark),const SizedBox(width:6),Text('اسحب يمينًا أو يسارًا للتنقل بين السجلات • ${rows.take(200).length} سجل',style:TextStyle(color:_reportInk.withValues(alpha:.65),fontSize:11))])))]])));}
}

class RevenueComparisonsPage extends StatefulWidget {
  final StationRepository r;final DateTime? initialFrom,initialTo;
  const RevenueComparisonsPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<RevenueComparisonsPage> createState()=>_RevenueComparisonsState();
}
class _RevenueComparisonsState extends State<RevenueComparisonsPage>{
  List<Map<String,Object?>> rows=[];DateTime? from,to;bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.report('time_comparison',from:from,to:to,systemType:'all');if(mounted)setState((){rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});_load();}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('time_comparison',from:from,to:to,systemType:'all');}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _month(Object? v){final s='$v';final p=s.split('-');const n=['','يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];final m=int.tryParse(p.length>1?p[1]:'')??0;return m>0&&m<13?'${n[m]} ${p.first}':s;}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Icon(icon,color:color,size:21),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:15))]))])));
  Widget _monthCard(String m,Map<String,int> a,Map<String,int>? previous,int maxMonth,int index){final old=previous?['total']??0;final change=old<=0?0:((a['total']!-old)*100/old);final color=change>=0?_reportGreen:_reportOrange;return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[const Icon(Icons.calendar_today_rounded,color:_reportOliveDark,size:20),const SizedBox(width:8),Expanded(child:Text(_month(m),style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk,fontSize:15))),Text(money(a['total']??0),style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:16))]),const SizedBox(height:10),ClipRRect(borderRadius:BorderRadius.circular(5),child:LinearProgressIndicator(value:maxMonth<=0?0:(a['total']??0)/maxMonth,minHeight:9,backgroundColor:_reportCream,color:_reportGreen)),const SizedBox(height:8),Row(children:[Text('${a['operations']} عملية • ${a['minutes']} دقيقة',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:10)),const Spacer(),Text(index==0?'بداية المقارنة':'${change>=0?'+':''}${change.toStringAsFixed(1)}% عن الشهر السابق',style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:10))])]));}
  @override Widget build(BuildContext context){final total=rows.fold<int>(0,(s,x)=>s+_n(x['total']));final ops=rows.fold<int>(0,(s,x)=>s+_n(x['operations']));final minutes=rows.fold<int>(0,(s,x)=>s+_n(x['minutes']));final months=<String,Map<String,int>>{};final systems=<String,Map<String,int>>{};for(final x in rows){final m='${x['month']}';final st='${x['system_type']}';final a=months.putIfAbsent(m,()=>{'total':0,'operations':0,'minutes':0});a['total']=(a['total']??0)+_n(x['total']);a['operations']=(a['operations']??0)+_n(x['operations']);a['minutes']=(a['minutes']??0)+_n(x['minutes']);final b=systems.putIfAbsent(st,()=>{'total':0,'operations':0,'minutes':0});b['total']=(b['total']??0)+_n(x['total']);b['operations']=(b['operations']??0)+_n(x['operations']);b['minutes']=(b['minutes']??0)+_n(x['minutes']);}final maxMonth=months.values.fold<int>(0,(m,x)=>(x['total']??0)>m?(x['total']??0):m);final maxSystem=systems.values.fold<int>(0,(m,x)=>(x['total']??0)>m?(x['total']??0):m);final monthKeys=months.keys.toList()..sort();return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('مقارنات الإيرادات',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة الاتجاهات المالية',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('مقارنات الإيرادات',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('قياس نمو الدخل بين الأشهر والمنظومات',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.compare_arrows_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${from!.day}/${from!.month}/${from!.year}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${to!.day}/${to!.month}/${to!.year}')),TextButton.icon(onPressed:(){final now=AppClock.now();setState((){from=DateTime(now.year,1,1);to=DateTime(now.year,now.month,now.day);});_load();},icon:const Icon(Icons.calendar_view_month_rounded,size:16),label:const Text('هذا العام')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])),const SizedBox(height:12),Row(children:[_kpi('إجمالي الإيرادات',money(total),Icons.trending_up_rounded,_reportGreen),const SizedBox(width:8),_kpi('عدد العمليات','$ops',Icons.format_list_numbered_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي الدقائق','$minutes د',Icons.timer_rounded,_reportOliveDark)]),const SizedBox(height:18),Row(children:[const Icon(Icons.calendar_month_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('مقارنة الأشهر',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${monthKeys.length} شهر',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(monthKeys.isEmpty)const EmptyView('لا توجد إيرادات للمقارنة')else ...[for(var i=0;i<monthKeys.length;i++)_monthCard(monthKeys[i],months[monthKeys[i]]!,i==0?null:months[monthKeys[i-1]],maxMonth,i)],const SizedBox(height:14),const Row(children:[Icon(Icons.category_rounded,color:_reportOliveDark),SizedBox(width:8),Text('مقارنة المنظومات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk))]),const SizedBox(height:10),for(final e in systems.entries)Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Expanded(child:Text(systemName(e.key),style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk))),Text(money(e.value['total']??0),style:const TextStyle(color:_reportOliveDark,fontWeight:FontWeight.w900))]),const SizedBox(height:8),ClipRRect(borderRadius:BorderRadius.circular(5),child:LinearProgressIndicator(value:maxSystem<=0?0:(e.value['total']??0)/maxSystem,minHeight:8,backgroundColor:_reportCream,color:_reportOliveDark)),const SizedBox(height:6),Align(alignment:Alignment.centerRight,child:Text('${e.value['operations']} عملية • ${e.value['minutes']} دقيقة',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:10)))]))])));}
}

class MonthlyFinancialReportPage extends StatefulWidget {
  final StationRepository r;final DateTime? initialFrom,initialTo;
  const MonthlyFinancialReportPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<MonthlyFinancialReportPage> createState()=>_MonthlyFinancialReportState();
}
class _MonthlyFinancialReportState extends State<MonthlyFinancialReportPage>{
  List<Map<String,Object?>> rows=[];DateTime? from,to;bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.report('monthly_financial',from:from,to:to);if(mounted)setState((){rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});_load();}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('monthly_financial',from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _month(Object? v){final s='$v';final p=s.split('-');const names=['','يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];final m=int.tryParse(p.length>1?p[1]:'')??0;return m>0&&m<13?'${names[m]} ${p.first}':s;}
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:4),Text(value,style:const TextStyle(color:_reportInk,fontSize:16,fontWeight:FontWeight.w900))]))])));
  Widget _monthCard(Map<String,Object?> x,int maxValue){final income=_n(x['income']);final expenses=_n(x['expenses']);final net=income-expenses;final margin=income<=0?0:net*100/income;final color=net>=0?_reportGreen:_reportOrange;final incomeWidth=maxValue<=0?0.0:income/maxValue;final expenseWidth=maxValue<=0?0.0:expenses/maxValue;return Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:46,height:46,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(14)),child:const Icon(Icons.calendar_month_rounded,color:_reportOliveDark)),const SizedBox(width:11),Expanded(child:Text(_month(x['month']),style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:17))),Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text('صافي النتيجة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),Text(money(net),style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:17))])]),const SizedBox(height:14),_bar('الإيرادات',income,incomeWidth,_reportGreen),const SizedBox(height:8),_bar('المصروفات',expenses,expenseWidth,_reportOrange),const SizedBox(height:12),Row(children:[Text('الهامش ${margin.toStringAsFixed(1)}%',style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:11)),const Spacer(),Text('إيرادات ${money(income)} • مصروفات ${money(expenses)}',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10))]) ]));}
  Widget _bar(String label,int value,double width,Color color)=>Row(children:[SizedBox(width:65,child:Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:11))),Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(5),child:LinearProgressIndicator(value:width,minHeight:9,backgroundColor:_reportCream,color:color))),const SizedBox(width:8),SizedBox(width:72,child:Text(money(value),textAlign:TextAlign.end,style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:11))) ]);
  @override Widget build(BuildContext context){final income=rows.fold<int>(0,(s,x)=>s+_n(x['income']));final expenses=rows.fold<int>(0,(s,x)=>s+_n(x['expenses']));final net=income-expenses;final maxValue=rows.fold<int>(0,(m,x){final a=_n(x['income']);final b=_n(x['expenses']);return a>b?(a>m?a:m):(b>m?b:m);});final margin=income<=0?0:net*100/income;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('التقرير المالي الشهري',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة الأداء المالي',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('التقرير المالي الشهري',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('مقارنة الإيرادات والمصروفات وصافي النتيجة لكل شهر',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.insights_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),TextButton.icon(onPressed:(){final now=AppClock.now();setState((){from=DateTime(now.year,1,1);to=DateTime(now.year,now.month,now.day);});_load();},icon:const Icon(Icons.calendar_view_month_rounded,size:16),label:const Text('هذا العام')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])),const SizedBox(height:12),Row(children:[_kpi('الإيرادات',money(income),Icons.trending_up_rounded,_reportGreen),const SizedBox(width:8),_kpi('المصروفات',money(expenses),Icons.receipt_long_rounded,_reportOrange),const SizedBox(width:8),_kpi('صافي النتيجة',money(net),Icons.account_balance_wallet_rounded,net>=0?_reportGreen:_reportOrange)]),const SizedBox(height:10),Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[const Icon(Icons.speed_rounded,color:_reportOliveDark),const SizedBox(width:9),const Text('الهامش المالي العام',style:TextStyle(fontWeight:FontWeight.w800)),const Spacer(),Text('${margin.toStringAsFixed(1)}%',style:TextStyle(color:net>=0?_reportGreen:_reportOrange,fontSize:19,fontWeight:FontWeight.w900))])),const SizedBox(height:18),Row(children:[const Icon(Icons.bar_chart_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('الأداء حسب الشهر',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${rows.length} شهر',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(rows.isEmpty)const EmptyView('لا توجد بيانات مالية في الفترة المحددة')else ...[for(final x in rows)_monthCard(x,maxValue)]])));}
}

class CashboxesTransfersReportPage extends StatefulWidget {
  final StationRepository r;final DateTime? initialFrom,initialTo;
  const CashboxesTransfersReportPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<CashboxesTransfersReportPage> createState()=>_CashboxesTransfersReportState();
}
class _CashboxesTransfersReportState extends State<CashboxesTransfersReportPage>{
  List<Map<String,Object?>> boxes=[],transfers=[],flow=[];DateTime? from,to;String search='';bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final b=await widget.r.cashboxes();final t=await widget.r.transfers();final f=await widget.r.report('cash_flow',from:from,to:to);if(mounted)setState((){boxes=b;transfers=t;flow=f;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});}}
  Future<void> _print(String key)async{try{final sourceRows=key=='cashboxes'?boxes: key=='cash_flow'?visibleFlow:null;await ReportService(widget.r).printPdf(key,from:from,to:to,sourceRows:sourceRows);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  bool _dateOk(Object? v){final d=DateTime.tryParse('$v');return d==null||(from==null||!d.isBefore(from!))&&(to==null||d.isBefore(to!.add(const Duration(days:1))));}
  List<Map<String,Object?>> get visibleTransfers{final q=search.trim().toLowerCase();return transfers.where((x)=>_dateOk(x['date'])&&(q.isEmpty||'${x['from_cashbox']??''} ${x['to_cashbox']??''} ${x['notes']??''}'.toLowerCase().contains(q))).toList();}
  List<Map<String,Object?>> get visibleFlow{final q=search.trim().toLowerCase();return flow.where((x)=>_dateOk(x['date'])&&(q.isEmpty||'${x['title']??''} ${x['kind']??''}'.toLowerCase().contains(q))).toList();}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Icon(icon,color:color,size:21),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:15))]))])));
  Widget _boxCard(Map<String,Object?> x){final balance=_n(x['current_balance']);return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:44,height:44,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(13)),child:const Icon(Icons.account_balance_wallet_rounded,color:_reportOliveDark)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['name']??'صندوق'}',style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:15)),const SizedBox(height:4),Text('الحساب النقدي المرتبط بالصندوق',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10))])),Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text('الرصيد',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),Text(money(balance),style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:17))]) ]));}
  Widget _transferCard(Map<String,Object?> x){return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:_reportOlive.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:const Icon(Icons.swap_horiz_rounded,color:_reportOliveDark)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['from_cashbox']??'صندوق غير محدد'}  ←  ${x['to_cashbox']??'صندوق غير محدد'}',style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk)),const SizedBox(height:4),Text('${_date(x['date'])} • ${x['notes']??'تحويل داخلي'}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),Text(money(_n(x['amount'])),style:const TextStyle(color:_reportOliveDark,fontWeight:FontWeight.w900,fontSize:16))]));}
  Widget _flowCard(Map<String,Object?> x){final amount=_n(x['amount']);final positive=amount>=0;final color=positive?_reportGreen:_reportOrange;return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:_reportLine)),child:Row(children:[Icon(positive?Icons.arrow_downward_rounded:Icons.arrow_upward_rounded,color:color),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['title']??'حركة نقدية'}',style:const TextStyle(fontWeight:FontWeight.w800,color:_reportInk)),Text(_date(x['date']),style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10))])),Text(positive?'له ${money(amount)}':'عليه ${money(amount.abs())}',style:TextStyle(color:color,fontWeight:FontWeight.w900))]));}
  @override Widget build(BuildContext context){final boxBalance=boxes.fold<int>(0,(s,x)=>s+_n(x['current_balance']));final transferIn=visibleTransfers.fold<int>(0,(s,x)=>s+_n(x['amount']));final flowIn=visibleFlow.where((x)=>_n(x['amount'])>=0).fold<int>(0,(s,x)=>s+_n(x['amount']));final flowOut=visibleFlow.where((x)=>_n(x['amount'])<0).fold<int>(0,(s,x)=>s+_n(x['amount']).abs());return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('الصناديق والتحويلات',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),IconButton(onPressed:()=>_print('cash_flow'),tooltip:'PDF التدفق النقدي',icon:const Icon(Icons.picture_as_pdf_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:()=>_print('cashboxes'),style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.account_balance_wallet_rounded,size:18),label:const Text('PDF الصناديق')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة النقدية الداخلية',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('الصناديق والتحويلات',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('الأرصدة والتحصيلات والمصروفات والتحويلات بين الصناديق',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.swap_horiz_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث في الصندوق أو البيان أو الملاحظات',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});},child:const Text('مسح الفترة'))])])),const SizedBox(height:12),Row(children:[_kpi('أرصدة الصناديق',money(boxBalance),Icons.account_balance_wallet_rounded,_reportGreen),const SizedBox(width:8),_kpi('التحويلات','${visibleTransfers.length}',Icons.swap_horiz_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('دخل نقدي',money(flowIn),Icons.south_west_rounded,_reportGreen)]),const SizedBox(height:10),Row(children:[_kpi('مصروف نقدي',money(flowOut),Icons.north_east_rounded,_reportOrange),const SizedBox(width:8),_kpi('تحويلات داخلية',money(transferIn),Icons.compare_arrows_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('صافي النقد',money(flowIn-flowOut),Icons.insights_rounded,_reportGreen)]),const SizedBox(height:18),const Row(children:[Icon(Icons.account_balance_wallet_rounded,color:_reportOliveDark),SizedBox(width:8),Text('أرصدة الصناديق',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk))]),const SizedBox(height:10),if(boxes.isEmpty)const EmptyView('لا توجد صناديق نشطة')else ...[for(final x in boxes)_boxCard(x)],const SizedBox(height:14),Row(children:[const Icon(Icons.swap_horiz_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('التحويلات بين الصناديق',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visibleTransfers.length} تحويل',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visibleTransfers.isEmpty)const EmptyView('لا توجد تحويلات مطابقة للفترة')else ...[for(final x in visibleTransfers.take(200))_transferCard(x)],const SizedBox(height:14),Row(children:[const Icon(Icons.timeline_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('التدفق النقدي',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visibleFlow.length} حركة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visibleFlow.isEmpty)const EmptyView('لا توجد حركات نقدية مطابقة للفترة')else ...[for(final x in visibleFlow.take(200))_flowCard(x)]])));}
}

class DebtsReportPage extends StatefulWidget {
  final StationRepository r;
  const DebtsReportPage(this.r,{super.key});
  @override State<DebtsReportPage> createState()=>_DebtsReportState();
}
class _DebtsReportState extends State<DebtsReportPage>{
  List<Map<String,Object?>> rows=[];String search='';String view='all';bool loading=true;String? error;
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.report('debts');if(mounted)setState((){rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('debts');}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  List<Map<String,Object?>> get visible{final q=search.trim().toLowerCase();return rows.where((x){final b=_n(x['balance']);final okView=view=='all'||(view=='alayh'&&b>0)||(view=='lah'&&b<0)||(view=='balanced'&&b==0);final okSearch=q.isEmpty||'${x['name']??''} ${x['phone']??''}'.toLowerCase().contains(q);return okView&&okSearch;}).toList();}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:4),Text(value,style:const TextStyle(color:_reportInk,fontSize:16,fontWeight:FontWeight.w900))]))])));
  Widget _card(Map<String,Object?> x){final balance=_n(x['balance']);final positive=balance>0;final color=positive?_reportOrange:balance<0?_reportGreen:_reportOliveDark;final label=positive?'عليه':balance<0?'له':'متوازن';return InkWell(onTap:x['id'] is int?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>RecordDetailsPage(widget.r,kind:'beneficiary',id:x['id'] as int,title:'تفاصيل الحساب'))):null,borderRadius:BorderRadius.circular(21),child:Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(15)),child:Icon(positive?Icons.arrow_upward_rounded:balance<0?Icons.arrow_downward_rounded:Icons.check_circle_rounded,color:color)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['name']??'غير محدد'}',style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),const SizedBox(height:4),Text('${x['phone']??'بدون هاتف'}',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:8),const Text('فتح تفاصيل الحساب',style:TextStyle(color:_reportOliveDark,fontSize:10,fontWeight:FontWeight.w800))])),Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text(label,style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:12)),const SizedBox(height:4),Text(money(balance.abs()),style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:18))])])));}
  @override Widget build(BuildContext context){final totalAlayh=rows.where((x)=>_n(x['balance'])>0).fold<int>(0,(s,x)=>s+_n(x['balance']));final totalLah=rows.where((x)=>_n(x['balance'])<0).fold<int>(0,(s,x)=>s+_n(x['balance']).abs());final onCount=rows.where((x)=>_n(x['balance'])>0).length;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('تقرير المديونيات',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة أرصدة الأطراف',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('المديونيات والحسابات',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('ترتيب واضح للحسابات التي عليها أو لها مبالغ',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.account_balance_wallet_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث باسم الحساب أو الهاتف',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[ChoiceChip(label:const Text('الكل'),selected:view=='all',onSelected:(_)=>setState(()=>view='all')),ChoiceChip(label:const Text('عليه'),selected:view=='alayh',selectedColor:_reportOrange.withValues(alpha: .18),onSelected:(_)=>setState(()=>view='alayh')),ChoiceChip(label:const Text('له'),selected:view=='lah',selectedColor:_reportGreen.withValues(alpha: .18),onSelected:(_)=>setState(()=>view='lah')),ChoiceChip(label:const Text('متوازن'),selected:view=='balanced',onSelected:(_)=>setState(()=>view='balanced'))])])),const SizedBox(height:12),Row(children:[_kpi('عدد الحسابات','${rows.length}',Icons.groups_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي عليه',money(totalAlayh),Icons.arrow_upward_rounded,_reportOrange),const SizedBox(width:8),_kpi('إجمالي له',money(totalLah),Icons.arrow_downward_rounded,_reportGreen)]),const SizedBox(height:10),Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[const Icon(Icons.warning_amber_rounded,color:_reportOrange),const SizedBox(width:8),const Text('حسابات عليها مبالغ',style:TextStyle(fontWeight:FontWeight.w800)),const Spacer(),Text('$onCount حساب',style:const TextStyle(color:_reportOrange,fontWeight:FontWeight.w900))])),const SizedBox(height:18),Row(children:[const Icon(Icons.view_list_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('كشف الحسابات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visible.length} نتيجة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visible.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد حسابات مطابقة للفلاتر')]))else ...[for(final x in visible.take(300))_card(x)]])));}
}

class RevenueCollectionsReportPage extends StatefulWidget {
  final StationRepository r;final DateTime? initialFrom,initialTo;final String? initialSystemType;
  const RevenueCollectionsReportPage(this.r,{this.initialFrom,this.initialTo,this.initialSystemType,super.key});
  @override State<RevenueCollectionsReportPage> createState()=>_RevenueCollectionsReportState();
}
class _RevenueCollectionsReportState extends State<RevenueCollectionsReportPage>{
  List<Map<String,Object?>> income=[],payments=[];DateTime? from,to;String systemType='all',search='';bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;systemType=widget.initialSystemType??'all';_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final a=await widget.r.report('income',from:from,to:to,systemType:systemType);final b=await widget.r.report('payment_log',from:from,to:to);if(mounted)setState((){income=a;payments=b;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print(String key)async{try{await ReportService(widget.r).printPdf(key,from:from,to:to,systemType:systemType);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  String _system(Object? v)=>systemName('$v');
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:40,height:40,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:20)),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontSize:15,fontWeight:FontWeight.w900))]))])));
  Widget _incomeCard(Map<String,Object?> x){final total=_n(x['total']);return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:44,height:44,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(13)),child:const Icon(Icons.water_drop_rounded,color:_reportOliveDark)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(_system(x['system_type']),style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk,fontSize:15)),const SizedBox(height:4),Text('${_n(x['operations'])} عملية • ${_n(x['minutes'])} دقيقة',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text(money(total),style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:17)),Text('إيراد',style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:10))]) ]));}
  Widget _paymentCard(Map<String,Object?> x){final amount=_n(x['amount']);return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:_reportGreen.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:const Icon(Icons.payments_rounded,color:_reportGreen)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['party_name']??'تحصيل عام'}',style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk)),const SizedBox(height:4),Text('${x['method_name']??'طريقة غير محددة'} • ${x['cashbox_name']??'صندوق غير محدد'}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text(money(amount),style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:16)),Text(_date(x['date']),style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:10))]) ]));}
  @override Widget build(BuildContext context){final revenue=income.where((x)=>'${x['system_type']}'!='الإجمالي العام').fold<int>(0,(s,x)=>s+_n(x['total']));final collected=payments.fold<int>(0,(s,x)=>s+_n(x['amount']));final due=revenue-collected;final rate=revenue<=0?0:collected*100/revenue;final q=search.trim().toLowerCase();final shownPayments=q.isEmpty?payments:payments.where((x)=>'${x['party_name']??''} ${x['method_name']??''} ${x['cashbox_name']??''}'.toLowerCase().contains(q)).toList();return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('الإيرادات والتحصيلات المالية',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),IconButton(onPressed:()=>_print('payment_log'),tooltip:'PDF التحصيلات',icon:const Icon(Icons.receipt_long_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:()=>_print('income'),style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF الإيرادات')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة الإيرادات والتحصيل',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('من الدخل إلى الصندوق',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('مقارنة الإيراد المسجل بالمبالغ المحصلة فعلياً',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.insights_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث في المستفيد أو طريقة الدفع أو الصندوق',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[DropdownButtonFormField<String>(initialValue:systemType,items:const[DropdownMenuItem(value:'all',child:Text('كل المنظومات')),DropdownMenuItem(value:'diesel',child:Text('ديزل')),DropdownMenuItem(value:'solar',child:Text('شمسي')),DropdownMenuItem(value:'equivalent_hybrid',child:Text('النوع الثالث'))],onChanged:(v){setState(()=>systemType=v??'all');_load();},decoration:const InputDecoration(labelText:'نوع المنظومة',border:OutlineInputBorder())),OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])])),const SizedBox(height:12),Row(children:[_kpi('الإيرادات',money(revenue),Icons.trending_up_rounded,_reportGreen),const SizedBox(width:8),_kpi('التحصيلات',money(collected),Icons.payments_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي عليه',money(due),Icons.pending_actions_rounded,_reportOrange)]),const SizedBox(height:10),Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[const Icon(Icons.speed_rounded,color:_reportOliveDark),const SizedBox(width:9),const Text('نسبة التحصيل',style:TextStyle(fontWeight:FontWeight.w800)),const Spacer(),Text('${rate.toStringAsFixed(1)}%',style:const TextStyle(color:_reportGreen,fontSize:18,fontWeight:FontWeight.w900))])),const SizedBox(height:18),const Row(children:[Icon(Icons.trending_up_rounded,color:_reportOliveDark),SizedBox(width:8),Text('الإيرادات حسب المنظومة',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk))]),const SizedBox(height:10),if(revenue==0)const EmptyView('لا توجد إيرادات في الفترة المحددة')else ...[for(final x in income.where((x)=>'${x['system_type']}'!='الإجمالي العام'))_incomeCard(x)],const SizedBox(height:15),Row(children:[const Icon(Icons.payments_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('سجل التحصيلات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${shownPayments.length} عملية',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(shownPayments.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد تحصيلات مطابقة للفلاتر')]))else ...[for(final x in shownPayments.take(300))_paymentCard(x)]])));}
}

class InventoryMovementReportPage extends StatefulWidget {
  final StationRepository r;final DateTime? initialFrom,initialTo;
  const InventoryMovementReportPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<InventoryMovementReportPage> createState()=>_InventoryMovementReportState();
}
class _InventoryMovementReportState extends State<InventoryMovementReportPage>{
  List<Map<String,Object?>> rows=[];DateTime? from,to;String? kind;String search='';double stock=0,capacity=0;bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.diesel();final s=await widget.r.dieselStock();final cfg=await widget.r.settings();if(mounted)setState((){rows=x;stock=s;capacity=double.tryParse('${cfg['diesel_tank_capacity_liters']??0}')??0;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('diesel_inventory',from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  double _lit(Object? v)=>(v as num?)?.toDouble()??0;
  int _n(Object? v)=>(v as num?)?.round()??0;
  bool _in(String v)=>v=='receipt'||v=='opening_balance'||v=='correction';
  String _kind(String v)=>switch(v){'receipt'=>'توريد للمستودع','opening_balance'=>'رصيد افتتاحي','correction'=>'تسوية مخزون','delivery'=>'تسليم لمستفيد','advance'=>'سلفة ديزل','consumption'=>'استهلاك تشغيلي',_=>'حركة مخزون'};
  IconData _icon(String v)=>switch(v){'receipt'=>Icons.local_shipping_rounded,'opening_balance'=>Icons.flag_rounded,'correction'=>Icons.tune_rounded,'delivery'=>Icons.outbox_rounded,'advance'=>Icons.person_pin_rounded,'consumption'=>Icons.local_fire_department_rounded,_=>Icons.inventory_2_rounded};
  Color _color(String v)=>_in(v)?_reportGreen:_reportOrange;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  List<Map<String,Object?>> get visible{final q=search.trim().toLowerCase();return rows.where((x){final d=DateTime.tryParse('${x['date']}');final okFrom=from==null||d==null||!d.isBefore(from!);final okTo=to==null||d==null||d.isBefore(to!.add(const Duration(days:1)));final okKind=kind==null||x['kind']==kind;final okSearch=q.isEmpty||'${x['kind']??''} ${x['beneficiary_name']??''} ${x['notes']??''}'.toLowerCase().contains(q);return okFrom&&okTo&&okKind&&okSearch;}).toList();}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:40,height:40,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:20)),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontSize:15,fontWeight:FontWeight.w900))]))])));
  Widget _card(Map<String,Object?> x){final v='${x['kind']}';final incoming=_in(v);final liters=_lit(x['liters']);final color=_color(v);return Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:46,height:46,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(14)),child:Icon(_icon(v),color:color)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(_kind(v),style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),const SizedBox(height:4),Text('${_date(x['date'])} • ${x['beneficiary_name']??'المستودع الرئيسي'}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),Text('${liters.toStringAsFixed(2)} لتر',style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:16))]),const SizedBox(height:11),Row(children:[_tag(Icons.scale_rounded,'${incoming?'وارد':'مصروف'} من المخزون'),_tag(Icons.payments_outlined,money(_n(x['amount']))),_tag(Icons.price_check_rounded,'سعر ${money(_n(x['unit_price']))}'),const Spacer(),const Icon(Icons.arrow_back_ios_new_rounded,size:14,color:_reportOlive)]),if('${x['notes']??''}'.trim().isNotEmpty)Padding(padding:const EdgeInsets.only(top:10),child:Align(alignment:Alignment.centerRight,child:Text('${x['notes']}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))))]));}
  Widget _tag(IconData icon,String text)=>Padding(padding:const EdgeInsetsDirectional.only(end:9),child:Row(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:14,color:_reportOlive),const SizedBox(width:4),Text(text,style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:10))]));
  @override Widget build(BuildContext context){final v=visible;final incoming=v.where((x)=>_in('${x['kind']}')).fold<double>(0,(s,x)=>s+_lit(x['liters']));final outgoing=v.where((x)=>!_in('${x['kind']}')).fold<double>(0,(s,x)=>s+_lit(x['liters']));final amount=v.fold<int>(0,(s,x)=>s+_n(x['amount']));final fill=capacity<=0?0.0:(stock/capacity).clamp(0.0,1.0).toDouble();return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('حركة المخزون والمستودعات',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة المستودع الرئيسي',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('حركة مخزون الديزل',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('التوريد والاستهلاك والتسليم والسلف في سجل واحد',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.inventory_2_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(x)=>setState(()=>search=x),decoration:const InputDecoration(labelText:'بحث في نوع الحركة أو المستفيد أو الملاحظات',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[DropdownButtonFormField<String>(initialValue:kind,items:[const DropdownMenuItem<String>(value:null,child:Text('كل أنواع الحركة')),for(final x in ['receipt','opening_balance','correction','delivery','advance','consumption'])DropdownMenuItem(value:x,child:Text(_kind(x)))],onChanged:(x)=>setState(()=>kind=x),decoration:const InputDecoration(labelText:'نوع الحركة',border:OutlineInputBorder())),OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null||kind!=null)TextButton(onPressed:(){setState((){from=null;to=null;kind=null;});},child:const Text('مسح الفلاتر'))])])),const SizedBox(height:12),Container(padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[const Icon(Icons.water_drop_rounded,color:_reportOliveDark),const SizedBox(width:7),const Text('الرصيد الحالي في المستودع',style:TextStyle(fontWeight:FontWeight.w800)),const Spacer(),Text('${stock.toStringAsFixed(2)} لتر',style:const TextStyle(color:_reportOliveDark,fontWeight:FontWeight.w900,fontSize:19))]),if(capacity>0)Padding(padding:const EdgeInsets.only(top:10),child:ClipRRect(borderRadius:BorderRadius.circular(6),child:LinearProgressIndicator(value:fill,minHeight:8,backgroundColor:_reportCream,color:_reportOliveDark))),if(capacity>0)Padding(padding:const EdgeInsets.only(top:5),child:Text('السعة ${capacity.toStringAsFixed(2)} لتر',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)))])),const SizedBox(height:12),Row(children:[_kpi('عدد الحركات','${v.length}',Icons.format_list_numbered_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('الوارد','${incoming.toStringAsFixed(2)} لتر',Icons.south_west_rounded,_reportGreen),const SizedBox(width:8),_kpi('المصروف','${outgoing.toStringAsFixed(2)} لتر',Icons.north_east_rounded,_reportOrange)]),const SizedBox(height:10),Row(children:[_kpi('قيمة الحركات',money(amount),Icons.payments_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('نتائج العرض','${v.length}',Icons.filter_alt_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('حالة المخزون',capacity>0?'${(fill*100).toStringAsFixed(0)}%':'مفتوح',Icons.speed_rounded,_reportGreen)]),const SizedBox(height:18),Row(children:[const Icon(Icons.view_list_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('سجل حركة المستودع',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${v.length} حركة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(v.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد حركات مخزون مطابقة للفلاتر')]))else ...[for(final x in v.take(300))_card(x)]])));}
}

class ExpensesDetailedReportPage extends StatefulWidget {
  final StationRepository r;final DateTime? initialFrom,initialTo;final String? initialCategory,initialStatus;
  const ExpensesDetailedReportPage(this.r,{this.initialFrom,this.initialTo,this.initialCategory,this.initialStatus,super.key});
  @override State<ExpensesDetailedReportPage> createState()=>_ExpensesDetailedReportState();
}
class _ExpensesDetailedReportState extends State<ExpensesDetailedReportPage>{
  List<Map<String,Object?>> rows=[];DateTime? from,to;String? category,status;String search='';bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;category=widget.initialCategory;status=widget.initialStatus;_load();}
  DateTime? get initialFrom=>widget.initialFrom;DateTime? get initialTo=>widget.initialTo;
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.expenseDetails(from:from,to:to,category:category,status:status);if(mounted)setState((){rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('expenses',from:from,to:to,category:category,status:status);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  String _time(Object? v){final d=DateTime.tryParse('$v');return d==null?'':'${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';}
  List<Map<String,Object?>> get visible{final q=search.trim().toLowerCase();return q.isEmpty?rows:rows.where((x)=>'${x['title']??''} ${x['notes']??''} ${x['category']??''} ${x['method_name']??''} ${x['cashbox_name']??''}'.toLowerCase().contains(q)).toList();}
  Color _statusColor(Object? v)=>'$v'=='posted'?_reportGreen:'$v'=='cancelled'?_reportOrange:_reportOliveDark;
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:40,height:40,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:20)),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontSize:15,fontWeight:FontWeight.w900))]))])));
  Widget _card(Map<String,Object?> x){final id=x['id'];final color=_statusColor(x['status']);return InkWell(onTap:id is int?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>RecordDetailsPage(widget.r,kind:'expense',id:id,title:'تفاصيل المصروف'))):null,borderRadius:BorderRadius.circular(21),child:Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:46,height:46,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(14)),child:Icon(_expenseIcon('${x['category']}'),color:_reportOliveDark)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['title']??'مصروف تشغيلي'}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),const SizedBox(height:4),Text('${categoryName('${x['category']}')} • ${_date(x['date'])} ${_time(x['date'])}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),Text(money(_n(x['amount'])),style:const TextStyle(color:_reportOrange,fontWeight:FontWeight.w900,fontSize:17))]),const SizedBox(height:11),Row(children:[_tag(Icons.category_outlined,categoryName('${x['category']}')),_tag(Icons.payments_outlined,'${x['method_name']??'طريقة غير محددة'}'),_tag(Icons.account_balance_wallet_outlined,'${x['cashbox_name']??'صندوق غير محدد'}'),const Spacer(),Container(padding:const EdgeInsets.symmetric(horizontal:9,vertical:5),decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(9)),child:Text(statusName(x['status']),style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:10)))])])));}
  IconData _expenseIcon(String k)=>switch(k){'fuel'=>Icons.local_gas_station_rounded,'maintenance'=>Icons.build_rounded,'parts'=>Icons.settings_rounded,'oil'||'grease'=>Icons.opacity_rounded,'transport'=>Icons.local_shipping_rounded,'workers'||'partners'=>Icons.groups_rounded,_=>Icons.receipt_long_rounded};
  Widget _tag(IconData icon,String text)=>Padding(padding:const EdgeInsetsDirectional.only(end:9),child:Row(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:14,color:_reportOlive),const SizedBox(width:4),Text(text,style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:10))]));
  @override Widget build(BuildContext context){final total=rows.fold<int>(0,(s,x)=>s+_n(x['amount']));final posted=rows.where((x)=>x['status']=='posted').fold<int>(0,(s,x)=>s+_n(x['amount']));final cancelled=rows.where((x)=>x['status']=='cancelled').length;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('المصروفات النثرية والتشغيلية',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة المصروفات',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('النثرية والتشغيلية',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('التصنيف والمبلغ والصندوق وطريقة الدفع لكل عملية',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.receipt_long_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث في البيان أو التصنيف أو الصندوق',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[DropdownButtonFormField<String>(initialValue:category,items:[const DropdownMenuItem<String>(value:null,child:Text('كل التصنيفات')),for(final v in ['workers','partners','fuel','oil','grease','maintenance','parts','transport','admin','other'])DropdownMenuItem(value:v,child:Text(categoryName(v)))],onChanged:(v){setState(()=>category=v);_load();},decoration:const InputDecoration(labelText:'التصنيف',border:OutlineInputBorder())),DropdownButtonFormField<String>(initialValue:status,items:[const DropdownMenuItem<String>(value:null,child:Text('كل الحالات')),for(final v in ['posted','cancelled','new','scheduled'])DropdownMenuItem(value:v,child:Text(statusName(v)))],onChanged:(v){setState(()=>status=v);_load();},decoration:const InputDecoration(labelText:'الحالة',border:OutlineInputBorder())),OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])])),const SizedBox(height:12),Row(children:[_kpi('عدد العمليات','${rows.length}',Icons.format_list_numbered_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي المصروف',money(total),Icons.payments_rounded,_reportOrange),const SizedBox(width:8),_kpi('المعتمد',money(posted),Icons.check_circle_rounded,_reportGreen)]),const SizedBox(height:10),Row(children:[_kpi('ملغى','$cancelled',Icons.cancel_rounded,_reportOrange),const SizedBox(width:8),_kpi('نتائج العرض','${visible.length}',Icons.filter_alt_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('التصنيفات','${rows.map((x)=>x['category']).toSet().length}',Icons.category_rounded,_reportOliveDark)]),const SizedBox(height:18),Row(children:[const Icon(Icons.view_list_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('سجل المصروفات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visible.length} عملية',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visible.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد مصروفات مطابقة للفلاتر')]))else ...[for(final x in visible.take(300))_card(x)]])));}
}

class InvoicesReportPage extends StatefulWidget {
  final StationRepository r;
  final DateTime? initialFrom, initialTo;
  const InvoicesReportPage(this.r, {this.initialFrom, this.initialTo, super.key});
  @override
  State<InvoicesReportPage> createState() => _InvoicesReportPageState();
}

class _InvoicesReportPageState extends State<InvoicesReportPage> {
  List<Map<String, Object?>> rows = [];
  DateTime? from, to;
  String search = '';
  String sortKey = 'start_datetime';
  bool ascending = false, loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    from = widget.initialFrom;
    to = widget.initialTo;
    _load();
  }

  int _n(Object? value) => value is num ? value.round() : int.tryParse('$value') ?? 0;
  String _dateLabel(DateTime? d) => d == null ? 'اختر تاريخًا' : DateFormat('yyyy/MM/dd').format(d);
  String _time(Object? value) {
    final d = DateTime.tryParse('$value');
    return d == null ? '—' : DateFormat('HH:mm').format(d);
  }
  String _duration(Object? value) {
    final minutes = _n(value).clamp(0, 100000000);
    return '${minutes ~/ 60} س ${minutes % 60} د';
  }
  String _money(Object? value) => NumberFormat('#,##0').format(_n(value));

  Future<void> _load() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final result = await widget.r.report('invoices', from: from, to: to, systemType: 'all');
      if (mounted) setState(() { rows = result; loading = false; });
    } catch (e) {
      if (mounted) setState(() { error = friendlyError(e); loading = false; });
    }
  }

  Future<void> _pickDate(bool start) async {
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: (start ? from : to) ?? AppClock.now(),
      locale: const Locale('ar'),
    );
    if (selected == null) return;
    setState(() {
      if (start) {
        from = DateTime(selected.year, selected.month, selected.day);
        if (to != null && from!.isAfter(to!)) to = from;
      } else {
        to = DateTime(selected.year, selected.month, selected.day);
        if (from != null && to!.isBefore(from!)) from = to;
      }
    });
    await _load();
  }

  void _quickRange(String value) {
    final now = AppClock.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      if (value == 'today') {
        from = today;
        to = today;
      } else if (value == 'week') {
        from = PeriodRanges.weekStart(today, 'saturday');
        to = today;
      } else {
        from = null;
        to = null;
      }
    });
    _load();
  }

  List<Map<String, Object?>> get visible {
    final query = search.trim().toLowerCase();
    final filtered = rows.where((row) {
      if (query.isEmpty) return true;
      return '${row['party_name'] ?? ''} ${row['notes'] ?? ''}'.toLowerCase().contains(query);
    }).toList();
    int compare(Map<String, Object?> a, Map<String, Object?> b) {
      if (sortKey == 'party_name' || sortKey == 'notes') {
        return '${a[sortKey] ?? ''}'.toLowerCase().compareTo('${b[sortKey] ?? ''}'.toLowerCase());
      }
      if (sortKey == 'start_datetime' || sortKey == 'end_datetime') {
        return '${a[sortKey] ?? ''}'.compareTo('${b[sortKey] ?? ''}');
      }
      return _n(a[sortKey]).compareTo(_n(b[sortKey]));
    }
    filtered.sort((a, b) => ascending ? compare(a, b) : compare(b, a));
    return filtered;
  }

  int get totalMinutes => visible.fold<int>(0, (sum, row) => sum + _n(row['minutes']));
  int get totalAmount => visible.fold<int>(0, (sum, row) => sum + _n(row['total_amount']));
  int get totalPaid => visible.fold<int>(0, (sum, row) => sum + _n(row['paid_amount']));

  Future<List<Map<String, Object?>>> _pdfRows() async => visible;

  Future<void> _previewPdf() async {
    try {
      final bytes = await ReportService(widget.r).invoicesPdf(rows: await _pdfRows(), from: from, to: to);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => _InvoicesPdfPreviewPage(bytes: bytes)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _printPdf() async {
    try {
      await ReportService(widget.r).printInvoicesPdf(rows: await _pdfRows(), from: from, to: to);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _sharePdf() async {
    try {
      await ReportService(widget.r).shareInvoicesPdf(rows: await _pdfRows(), from: from, to: to);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Widget _summaryCard(String title, String value, IconData icon, Color color, int delay) =>
      Expanded(child: AnimatedContainer(
        duration: Duration(milliseconds: 280 + delay * 80),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: _reportLine),
          boxShadow: [BoxShadow(color: color.withValues(alpha: .08), blurRadius: 15, offset: const Offset(0, 5))],
        ),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)),
            child: Icon(icon, color: color, size: 21)),
          const SizedBox(width: 9),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: _reportInk.withValues(alpha: .58), fontSize: 10, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(value, style: const TextStyle(color: _reportInk, fontSize: 15, fontWeight: FontWeight.w900), maxLines: 2, overflow: TextOverflow.ellipsis),
          ])),
        ]),
      ));

  void _sort(int column, bool ascendingValue) {
    const keys = ['invoice_id', 'party_name', 'start_datetime', 'end_datetime', 'minutes', 'total_amount', 'paid_amount', 'notes'];
    setState(() {
      sortKey = keys[column];
      ascending = ascendingValue;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = visible;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _reportCream,
        appBar: AppBar(
          backgroundColor: _reportCream,
          foregroundColor: _reportInk,
          elevation: 0,
          title: const Text('تقرير الفواتير', style: TextStyle(fontWeight: FontWeight.w900)),
          actions: [
            IconButton(onPressed: _load, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded)),
            IconButton(onPressed: _previewPdf, tooltip: 'معاينة PDF', icon: const Icon(Icons.picture_as_pdf_rounded)),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? ErrorBox(error!)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [_reportOliveDark, _reportOlive]),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('تقارير التحصيل والتشغيل', style: TextStyle(color: Colors.white.withValues(alpha: .72), fontSize: 12)),
                            const SizedBox(height: 6),
                            const Text('تقرير الفواتير', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 7),
                            Text('عرض الساعات والمبالغ المسلّمة لكل سقاية', style: TextStyle(color: Colors.white.withValues(alpha: .84), fontSize: 11)),
                          ])),
                          const Icon(Icons.receipt_long_rounded, color: Colors.white, size: 44),
                        ]),
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(builder: (context, constraints) {
                        final compact = constraints.maxWidth < 650;
                        final cards = [
                          _summaryCard('إجمالي الساعات والدقائق', _duration(totalMinutes), Icons.timer_rounded, _reportOliveDark, 0),
                          _summaryCard('القيمة الإجمالية', '${_money(totalAmount)} ريال', Icons.receipt_long_rounded, _reportGreen, 1),
                          _summaryCard('المسلّمة', '${_money(totalPaid)} ريال', Icons.payments_rounded, _reportOrange, 2),
                        ];
                        if (!compact) return Row(children: [cards[0], const SizedBox(width: 9), cards[1], const SizedBox(width: 9), cards[2]]);
                        return Column(children: [for (final card in cards) Padding(padding: const EdgeInsets.only(bottom: 8), child: card)]);
                      }),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(19), border: Border.all(color: _reportLine)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          TextField(
                            onChanged: (value) => setState(() => search = value),
                            decoration: const InputDecoration(labelText: 'بحث باسم المستفيد أو الملاحظات', prefixIcon: Icon(Icons.search_rounded), border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 10),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            ChoiceChip(label: const Text('اليوم'), selected: from != null && to != null && from == DateTime(AppClock.now().year, AppClock.now().month, AppClock.now().day) && to == from, onSelected: (_) => _quickRange('today')),
                            ChoiceChip(label: const Text('هذا الأسبوع'), selected: false, onSelected: (_) => _quickRange('week')),
                            ChoiceChip(label: const Text('كل الفترات'), selected: from == null && to == null, onSelected: (_) => _quickRange('all')),
                            OutlinedButton.icon(onPressed: () => _pickDate(true), icon: const Icon(Icons.calendar_today_rounded, size: 16), label: Text('من: ${_dateLabel(from)}')),
                            OutlinedButton.icon(onPressed: () => _pickDate(false), icon: const Icon(Icons.event_rounded, size: 16), label: Text('إلى: ${_dateLabel(to)}')),
                            if (from != null || to != null) TextButton(onPressed: () => _quickRange('all'), child: const Text('مسح الفترة')),
                          ]),
                        ]),
                      ),
                      const SizedBox(height: 14),
                      Row(children: [
                        const Icon(Icons.view_list_rounded, color: _reportOliveDark),
                        const SizedBox(width: 8),
                        const Text('تفاصيل الفواتير', style: TextStyle(color: _reportInk, fontSize: 18, fontWeight: FontWeight.w900)),
                        const Spacer(),
                        Text('${data.length} فاتورة', style: TextStyle(color: _reportInk.withValues(alpha: .58), fontSize: 12)),
                      ]),
                      const SizedBox(height: 10),
                      if (data.isEmpty)
                        const EmptyView('لا توجد فواتير مطابقة للفلاتر')
                      else
                        Container(
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: _reportLine)),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              sortAscending: ascending,
                              sortColumnIndex: const {'invoice_id': 0, 'party_name': 1, 'start_datetime': 2, 'end_datetime': 3, 'minutes': 4, 'total_amount': 5, 'paid_amount': 6, 'notes': 7}[sortKey],
                              headingRowColor: MaterialStateProperty.all(_reportCream),
                              dataRowMinHeight: 52,
                              dataRowMaxHeight: 70,
                              columns: [
                                DataColumn(label: const Text('م'), onSort: _sort),
                                DataColumn(label: const Text('اسم المستفيد'), onSort: _sort),
                                DataColumn(label: const Text('وقت البداية'), onSort: _sort),
                                DataColumn(label: const Text('وقت النهاية'), onSort: _sort),
                                DataColumn(label: const Text('إجمالي الساعات والدقائق'), onSort: _sort),
                                DataColumn(label: const Text('القيمة الإجمالية'), numeric: true, onSort: _sort),
                                DataColumn(label: const Text('المسلّمة'), numeric: true, onSort: _sort),
                                DataColumn(label: const Text('ملاحظات'), onSort: _sort),
                              ],
                              rows: [
                                for (var i = 0; i < data.length; i++)
                                  DataRow(
                                    color: MaterialStateProperty.resolveWith((states) => i.isEven ? Colors.white : _reportCream.withValues(alpha: .7)),
                                    cells: [
                                      DataCell(Text('${i + 1}')),
                                      DataCell(Text('${data[i]['party_name'] ?? 'غير محدد'}')),
                                      DataCell(Text(_time(data[i]['start_datetime']))),
                                      DataCell(Text(_time(data[i]['end_datetime']))),
                                      DataCell(Text(_duration(data[i]['minutes']))),
                                      DataCell(Text(_money(data[i]['total_amount']), style: const TextStyle(fontWeight: FontWeight.w800))),
                                      DataCell(Text(_money(data[i]['paid_amount']), style: const TextStyle(fontWeight: FontWeight.w800))),
                                      DataCell(SizedBox(width: 190, child: Text('${data[i]['notes'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis))),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        FilledButton.icon(onPressed: _previewPdf, icon: const Icon(Icons.preview_rounded), label: const Text('معاينة PDF')),
                        FilledButton.icon(onPressed: _printPdf, icon: const Icon(Icons.print_rounded), label: const Text('طباعة مباشرة')),
                        OutlinedButton.icon(onPressed: _sharePdf, icon: const Icon(Icons.share_rounded), label: const Text('مشاركة PDF')),
                      ]),
                    ],
                  ),
      ),
    );
  }
}

class _InvoicesPdfPreviewPage extends StatelessWidget {
  final Uint8List bytes;
  const _InvoicesPdfPreviewPage({required this.bytes});

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('معاينة PDF - تقرير الفواتير')),
      body: PdfPreview(
        build: (_) async => bytes,
        canChangeOrientation: false,
        canChangePageFormat: false,
        allowPrinting: true,
        allowSharing: true,
      ),
    ),
  );
}

class IrrigationDetailedReportPage extends StatefulWidget {
  final StationRepository r;final int? initialBeneficiaryId;final DateTime? initialFrom,initialTo;final String? initialSystemType;
  const IrrigationDetailedReportPage(this.r,{this.initialBeneficiaryId,this.initialFrom,this.initialTo,this.initialSystemType,super.key});
  @override State<IrrigationDetailedReportPage> createState()=>_IrrigationDetailedReportState();
}
class _IrrigationDetailedReportState extends State<IrrigationDetailedReportPage>{
  List<Map<String,Object?>> rows=[],beneficiaries=[];DateTime? from,to;int? beneficiaryId;String systemType='all',search='';bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;beneficiaryId=widget.initialBeneficiaryId;systemType=widget.initialSystemType??'all';_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final b=await widget.r.beneficiaries();final x=await widget.r.report('irrigations',from:from,to:to,beneficiaryId:beneficiaryId,systemType:systemType);if(mounted)setState((){beneficiaries=b;rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('irrigations',from:from,to:to,beneficiaryId:beneficiaryId,systemType:systemType);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  String _time(Object? v){final d=DateTime.tryParse('$v');return d==null?'': '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';}
  List<Map<String,Object?>> get visible{final q=search.trim().toLowerCase();return q.isEmpty?rows:rows.where((x)=>'${x['party_name']??''} ${x['start_datetime']??''}'.toLowerCase().contains(q)).toList();}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:40,height:40,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:20)),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontSize:15,fontWeight:FontWeight.w900))]))])));
  Widget _card(Map<String,Object?> x){final total=_n(x['total_amount']);final paid=_n(x['paid_amount']);final due=total-paid;final cloud=_n(x['cloud_minutes'])>0;final id=x['irrigation_id'];return InkWell(onTap:id is int?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>RecordDetailsPage(widget.r,kind:'irrigation',id:id,title:'تفاصيل السقاية'))):null,borderRadius:BorderRadius.circular(21),child:Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(15)),child:const Icon(Icons.water_drop_rounded,color:_reportOliveDark)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['party_name']??'غير محدد'}',style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),const SizedBox(height:4),Text('${_date(x['start_datetime'])} • ${_time(x['start_datetime'])}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),if(cloud)Container(padding:const EdgeInsets.symmetric(horizontal:9,vertical:6),decoration:BoxDecoration(color:_reportOrange.withValues(alpha: .12),borderRadius:BorderRadius.circular(10)),child:const Text('بسعر مخفض',style:TextStyle(color:_reportOrange,fontWeight:FontWeight.w800,fontSize:10))),const Icon(Icons.arrow_back_ios_new_rounded,size:15,color:_reportOlive)]),const SizedBox(height:12),Row(children:[_mini('المدة','${_n(x['minutes'])} دقيقة',Icons.timer_outlined),const SizedBox(width:10),_mini('الإجمالي',money(total),Icons.receipt_long_rounded),const SizedBox(width:10),_mini('المدفوع',money(paid),Icons.payments_outlined)]),const SizedBox(height:12),Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:10),decoration:BoxDecoration(color:due>0?_reportOrange.withValues(alpha: .08):_reportGreen.withValues(alpha: .08),borderRadius:BorderRadius.circular(13)),child:Row(children:[Icon(due>0?Icons.pending_actions_rounded:Icons.check_circle_rounded,color:due>0?_reportOrange:_reportGreen,size:18),const SizedBox(width:7),Text(due>0?'عليه ${money(due)}':'مكتملة السداد',style:TextStyle(color:due>0?_reportOrange:_reportGreen,fontWeight:FontWeight.w900,fontSize:12)),const Spacer(),if(id is int)const Text('فتح التفاصيل',style:TextStyle(color:_reportOliveDark,fontSize:11,fontWeight:FontWeight.w800))]))])));}
  Widget _mini(String label,String value,IconData icon)=>Expanded(child:Row(children:[Icon(icon,size:16,color:_reportOlive),const SizedBox(width:5),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:9)),Text(value,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w800,fontSize:11))]))]));
  @override Widget build(BuildContext context){final total=rows.fold<int>(0,(s,x)=>s+_n(x['total_amount']));final paid=rows.fold<int>(0,(s,x)=>s+_n(x['paid_amount']));final minutes=rows.fold<int>(0,(s,x)=>s+_n(x['minutes']));final due=total-paid;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('تقرير السقايات التفصيلي',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة التشغيل والتحصيل',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('تفاصيل السقايات',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('المدة والإجمالي والمدفوع والرصيد لكل عملية',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.water_drop_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث باسم المستفيد أو التاريخ',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[DropdownButtonFormField<String>(initialValue:systemType,items:const[DropdownMenuItem(value:'all',child:Text('كل المنظومات')),DropdownMenuItem(value:'diesel',child:Text('ديزل')),DropdownMenuItem(value:'solar',child:Text('شمسي')),DropdownMenuItem(value:'equivalent_hybrid',child:Text('النوع الثالث'))],onChanged:(v){setState(()=>systemType=v??'all');_load();},decoration:const InputDecoration(labelText:'نوع المنظومة',border:OutlineInputBorder())),DropdownButtonFormField<int>(initialValue:beneficiaryId,items:[const DropdownMenuItem<int>(value:null,child:Text('كل المستفيدين')),for(final b in beneficiaries)DropdownMenuItem(value:b['id'] as int,child:Text('${b['name']}'))],onChanged:(v){setState(()=>beneficiaryId=v);_load();},decoration:const InputDecoration(labelText:'المستفيد',border:OutlineInputBorder())),OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])])),const SizedBox(height:12),Row(children:[_kpi('عدد السقايات','${rows.length}',Icons.format_list_numbered_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي المدة','$minutes د',Icons.timer_rounded,_reportGreen),const SizedBox(width:8),_kpi('الإيراد',money(total),Icons.trending_up_rounded,_reportOliveDark)]),const SizedBox(height:10),Row(children:[_kpi('المدفوع',money(paid),Icons.payments_rounded,_reportGreen),const SizedBox(width:8),_kpi('إجمالي عليه',money(due),Icons.pending_actions_rounded,_reportOrange),const SizedBox(width:8),_kpi('نتائج العرض','${visible.length}',Icons.filter_alt_rounded,_reportOliveDark)]),const SizedBox(height:18),Row(children:[const Icon(Icons.view_list_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('سجل السقايات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visible.length} عملية',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visible.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد سقايات مطابقة للفلاتر')]))else ...[for(final x in visible.take(300))_card(x)]])));}
}

class PartnerProfitDistributionPage extends StatefulWidget {
  final StationRepository r;
  final DateTime? initialFrom,initialTo;
  const PartnerProfitDistributionPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<PartnerProfitDistributionPage> createState()=>_PartnerProfitDistributionState();
}
class _PartnerProfitDistributionState extends State<PartnerProfitDistributionPage>{
  late DateTime from,to;Map<String,Object?> summary={};List<Map<String,Object?>> partners=[];bool loading=true;String? error;
  @override void initState(){super.initState();final now=AppClock.now();from=widget.initialFrom??DateTime(now.year,now.month,1);to=widget.initialTo??DateTime(now.year,now.month,now.day);_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final a=await widget.r.partnerProfitSummary(from:from,to:to);final p=await widget.r.partners();if(mounted)setState((){summary=a;partners=p;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _postDistribution() async {
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: const Text('ترحيل أرباح الشركاء'),
      content: const Text('سيُحسب صافي الربح بعد المصروفات ومستحقات العمال، ثم يُرحّل نصيب كل شريك مرة واحدة لهذه الفترة.'),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('ترحيل الآن'))],
    )) ?? false;
    if (!ok) return;
    try {
      final count = await widget.r.accounting.distributePartnerProfits(from: from, to: to);
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم ترحيل استحقاق $count شريك')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e)))); }
  }
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:start?from:to,locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('partner_profit_distribution',from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _money(Object? v)=>money(_n(v));
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:4),Text(value,style:const TextStyle(color:_reportInk,fontSize:15,fontWeight:FontWeight.w900))]))])));
  Widget _partnerCard(Map<String,Object?> p,double totalShares,int profit){final amount=AccountingCalculations.partnerShareByMode(mode:'${p['ownership_mode']}',distributable:profit,partnerShares:(p['shares_count'] as num?)?.toDouble()??0,totalShares:totalShares,percentage:(p['ownership_percentage'] as num?)?.toDouble()??0);final percentage=profit<=0?0:(amount*100/profit);final mode=p['ownership_mode']=='percentage'?'نسبة ملكية ${p['ownership_percentage']??0}%':'${p['shares_count']??0} حصص';return Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(15)),child:Icon(p['ownership_mode']=='percentage'?Icons.percent_rounded:Icons.pie_chart_rounded,color:_reportOliveDark)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${p['name']??''}',style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),const SizedBox(height:4),Text(mode,style:TextStyle(color:_reportInk.withValues(alpha: .6),fontSize:11)),const SizedBox(height:9),ClipRRect(borderRadius:BorderRadius.circular(6),child:LinearProgressIndicator(value:percentage.clamp(0.0,1.0).toDouble(),minHeight:7,backgroundColor:_reportCream,color:_reportOlive)),const SizedBox(height:4),Text('${percentage.toStringAsFixed(1)}% من صافي الربح',style:TextStyle(color:_reportInk.withValues(alpha: .52),fontSize:10))])),const SizedBox(width:12),Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text('الاستحقاق',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(_money(amount),style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:17)),const SizedBox(height:4),const Text('له',style:TextStyle(color:_reportGreen,fontWeight:FontWeight.w800,fontSize:11))]) ]));}
  @override Widget build(BuildContext context){final revenue=_n(summary['revenue']);final expenses=_n(summary['expenses']);final workers=_n(summary['workers']);final workerDue=_n(summary['worker_due']);final partnerDue=_n(summary['partner_due']);final profit=_n(summary['distributable']);final totalShares=partners.fold<double>(0.0,(sum,p)=>sum+((p['shares_count'] as num?)?.toDouble()??0.0));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('صافي الأرباح والتوزيعات',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),FilledButton.icon(onPressed:loading ? null : _postDistribution,style:FilledButton.styleFrom(backgroundColor:_reportGreen,foregroundColor:Colors.white),icon:const Icon(Icons.account_balance_rounded,size:18),label:const Text('ترحيل التوزيع')),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة الربح والتوزيع',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('صافي الأرباح القابل للتوزيع',style:TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('الإيرادات − المصروفات العامة − مستحقات العمال',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.pie_chart_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text('من ${from.day}/${from.month}/${from.year}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text('إلى ${to.day}/${to.month}/${to.year}')),TextButton.icon(onPressed:(){final now=AppClock.now();setState((){from=DateTime(now.year,now.month,1);to=DateTime(now.year,now.month,now.day);});_load();},icon:const Icon(Icons.restart_alt_rounded,size:16),label:const Text('هذا الشهر'))])),const SizedBox(height:12),Row(children:[_kpi('إجمالي الإيرادات',_money(revenue),Icons.trending_up_rounded,_reportGreen),const SizedBox(width:8),_kpi('المصروفات العامة',_money(expenses),Icons.receipt_long_rounded,_reportOrange),const SizedBox(width:8),_kpi('مصروف أجور الفترة',_money(workers),Icons.engineering_rounded,_reportOliveDark)]),const SizedBox(height:9),Row(children:[_kpi('إجمالي مستحقات العمال',_money(workerDue),Icons.badge_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي مستحقات الشركاء',_money(partnerDue),Icons.groups_rounded,_reportGreen),const SizedBox(width:8),_kpi('الحسابات الشخصية للشركاء','${partners.length}',Icons.account_tree_rounded,_reportOrange)]),const SizedBox(height:12),Container(padding:const EdgeInsets.all(19),decoration:BoxDecoration(gradient:LinearGradient(colors:[profit>=0?_reportGreen:_reportOrange,profit>=0?_reportGreen.withValues(alpha: .72):_reportOrange.withValues(alpha: .72)]),borderRadius:BorderRadius.circular(23)),child:Row(children:[const Icon(Icons.account_balance_wallet_rounded,color:Colors.white,size:38),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('صافي الربح القابل للتوزيع',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:12)),const SizedBox(height:5),Text(_money(profit),style:const TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.w900))])),Text('${partners.length} شركاء',style:TextStyle(color:Colors.white.withValues(alpha: .85),fontWeight:FontWeight.w800))])),const SizedBox(height:18),Row(children:[const Icon(Icons.groups_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('توزيع الاستحقاقات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('$totalShares حصص إجمالي',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11))]),const SizedBox(height:10),if(partners.isEmpty)const EmptyView('أضف شركاء لعرض التوزيع')else ...[for(final p in partners)_partnerCard(p,totalShares,profit)],const SizedBox(height:8),Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[const Icon(Icons.info_outline_rounded,color:_reportOliveDark),const SizedBox(width:9),Expanded(child:Text('يتم خصم مستحقات العمال أولاً، ثم توزيع الصافي حسب النسبة أو الحصص المسجلة لكل شريك.',style:TextStyle(color:_reportInk.withValues(alpha: .72),fontSize:12,fontWeight:FontWeight.w700)))]))])));}
}

class CentralLedgerReportPage extends StatefulWidget {
  final StationRepository r;
  final DateTime? initialFrom, initialTo;
  const CentralLedgerReportPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<CentralLedgerReportPage> createState()=>_CentralLedgerReportState();
}
class _CentralLedgerReportState extends State<CentralLedgerReportPage>{
  List<Map<String,Object?>> rows=[];DateTime? from,to;String search='';bool loading=true;String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.report('ledger',from:from,to:to);if(mounted)setState((){rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print()async{try{await ReportService(widget.r).printPdf('ledger',from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  List<Map<String,Object?>> get visible{final q=search.trim().toLowerCase();return q.isEmpty?rows:rows.where((x)=>'${x['description']??''} ${x['memo']??''} ${x['account_name']??''} ${x['account_code']??''} ${x['party_name']??''}'.toLowerCase().contains(q)).toList();}
  int _running(int index){var n=0;for(var i=0;i<=index&&i<rows.length;i++) {
    n+=_n(rows[i]['debit'])-_n(rows[i]['credit']);
  }return n;}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:4),Text(value,style:const TextStyle(color:_reportInk,fontSize:16,fontWeight:FontWeight.w900))]))])));
  Widget _line(Map<String,Object?> x,int index){final debit=_n(x['debit']);final credit=_n(x['credit']);final running=_running(rows.indexOf(x));return InkWell(onTap:()=>_openJournalEntry(context,widget.r,x),borderRadius:BorderRadius.circular(19),child:Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:36,height:36,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(11)),child:Center(child:Text('${index+1}',style:const TextStyle(color:_reportOliveDark,fontWeight:FontWeight.w900)))),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['description']??x['memo']??'حركة مالية'}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk)),const SizedBox(height:3),Text(_date(x['date']),style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),const Icon(Icons.open_in_new_rounded,size:17,color:_reportOlive)]),const SizedBox(height:10),Row(children:[if(credit>0)Text('له ${money(credit)}',style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:12)),if(debit>0)Padding(padding:const EdgeInsetsDirectional.only(start:12),child:Text('عليه ${money(debit)}',style:const TextStyle(color:_reportOrange,fontWeight:FontWeight.w900,fontSize:12))),const Spacer(),Text('الرصيد ${money(running)}',style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:11,fontWeight:FontWeight.w700))])])));}
  @override Widget build(BuildContext context){final totalDebit=rows.fold<int>(0,(s,x)=>s+_n(x['debit']));final totalCredit=rows.fold<int>(0,(s,x)=>s+_n(x['credit']));final net=totalDebit-totalCredit;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('دفتر الأستاذ المركزي',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('الحركات المالية المركزية',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('دفتر الأستاذ العام',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('مصدر موحد لكل القيود والحركات المالية',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.account_balance_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث في البيان أو الحساب أو المرجع',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])])),const SizedBox(height:12),Row(children:[_kpi('عدد القيود','${rows.length}',Icons.receipt_long_rounded,_reportOliveDark),const SizedBox(width:9),_kpi('إجمالي له',money(totalCredit),Icons.south_west_rounded,_reportGreen),const SizedBox(width:9),_kpi('إجمالي عليه',money(totalDebit),Icons.north_east_rounded,_reportOrange)]),const SizedBox(height:12),Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[const Icon(Icons.balance_rounded,color:_reportOliveDark),const SizedBox(width:9),const Text('الصافي المركزي',style:TextStyle(fontWeight:FontWeight.w800)),const Spacer(),Text(money(net),style:TextStyle(color:net<=0?_reportGreen:_reportOrange,fontWeight:FontWeight.w900,fontSize:16))])),const SizedBox(height:18),Row(children:[const Icon(Icons.view_list_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('الحركات المالية',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visible.length} نتيجة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visible.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد حركات مطابقة للفلاتر')]))else ...[for(var i=0;i<visible.length&&i<300;i++)_line(visible[i],i)]])));}
}

class LedgerStatementsPage extends StatefulWidget {
  final StationRepository r;
  final DateTime? initialFrom, initialTo;
  const LedgerStatementsPage(this.r,{this.initialFrom,this.initialTo,super.key});
  @override State<LedgerStatementsPage> createState()=>_LedgerStatementsState();
}

class _LedgerStatementsState extends State<LedgerStatementsPage>{
  String kind='beneficiary'; int? selectedId; DateTime? from,to;
  List<Map<String,Object?>> rows=[],beneficiaries=[],workers=[],partners=[],cashboxes=[];
  bool loading=true; String? error;
  final labels=<String,String>{'beneficiary':'كشف المستفيد','worker':'كشف العامل','partner':'كشف الشريك','expenses':'كشف المصروفات','receipts':'كشف المقبوضات','payments':'كشف المدفوعات','cashbox':'كشف الصندوق'};
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_loadLists();}
  Future<void> _loadLists()async{try{final b=await widget.r.beneficiaries(),w=await widget.r.workers(),p=await widget.r.partners(),c=await widget.r.cashboxes();if(mounted)setState((){beneficiaries=b;workers=w;partners=p;cashboxes=c;selectedId=b.isEmpty?null:b.first['id'] as int?;});await _load();}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  Future<void> _load()async{if((kind=='beneficiary'||kind=='worker'||kind=='partner'||kind=='cashbox')&&selectedId==null){if(mounted)setState(()=>rows=[]);return;}if(mounted)setState((){loading=true;error=null;});try{final x=await widget.r.partyLedgerStatement(kind:kind,id:selectedId,from:from,to:to);if(mounted)setState((){rows=x;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  String _name(){final list=kind=='beneficiary'?beneficiaries:kind=='worker'?workers:kind=='partner'?partners:cashboxes;final x=list.where((e)=>e['id']==selectedId).toList();return x.isEmpty?'': '${x.first['name']??''}';}
  String _movementLabel(Object? value)=>switch('$value'){
    'irrigation'=>'سقاية',
    'payment'=>'دفعة مالية',
    'expense'=>'مصروف تشغيلي',
    'petty_expense'=>'مصروف نثري',
    'partner_share'=>'استحقاق أرباح الشريك',
    'partner'=>'استحقاق الشريك',
    'worker'=>'استحقاق العامل',
    'worker_salary'=>'راتب العامل',
    'cashbox_transfer'=>'تحويل بين الصناديق',
    'cashbox_opening'=>'رصيد افتتاحي للصندوق',
    'diesel_receipt'=>'شراء ديزل',
    'diesel_consumption'=>'استهلاك ديزل',
    'reversal'=>'عكس حركة',
    _=>'حركة مالية',
  };
  List<Map<String,Object?>> get visible=>rows;
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});_load();}}
  Widget _selector(){final needs=kind=='beneficiary'||kind=='worker'||kind=='partner'||kind=='cashbox';final list=kind=='beneficiary'?beneficiaries:kind=='worker'?workers:kind=='partner'?partners:cashboxes;return Column(children:[DropdownButtonFormField<String>(initialValue:kind,items:[for(final e in labels.entries)DropdownMenuItem(value:e.key,child:Text(e.value))],onChanged:(v){if(v==null)return;setState((){kind=v;final l=v=='beneficiary'?beneficiaries:v=='worker'?workers:v=='partner'?partners:cashboxes;selectedId=l.isEmpty?null:l.first['id'] as int?;});_load();},decoration:const InputDecoration(labelText:'نوع الكشف',prefixIcon:Icon(Icons.account_tree_rounded),border:OutlineInputBorder())),if(needs) ...[const SizedBox(height:10),DropdownButtonFormField<int>(initialValue:selectedId,items:[for(final x in list)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']??''}'))],onChanged:(v){setState(()=>selectedId=v);_load();},decoration:InputDecoration(labelText:labels[kind],prefixIcon:const Icon(Icons.person_search_rounded),border:const OutlineInputBorder()))],const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])]);}
  Widget _line(Map<String,Object?> x,int i){final lah=_n(x['lah']),alayh=_n(x['alayh']),balance=_n(x['balance']);return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:34,height:34,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(10)),child:Center(child:Text('${i+1}',style:const TextStyle(fontWeight:FontWeight.w900,color:_reportOliveDark)))),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['description']??x['memo']??_movementLabel(x['reference_type'])}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk)),const SizedBox(height:3),Text('${_date(x['date'])} • ${_movementLabel(x['reference_type'])}',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10))])),if(lah>0)Text('له ${money(lah)}',style:const TextStyle(color:_reportGreen,fontWeight:FontWeight.w900,fontSize:12)),if(alayh>0)Padding(padding:const EdgeInsetsDirectional.only(start:10),child:Text('عليه ${money(alayh)}',style:const TextStyle(color:_reportOrange,fontWeight:FontWeight.w900,fontSize:12)))]),const SizedBox(height:8),Row(children:[Text('${x['party_name']??''}',style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:10)),const Spacer(),Text('الرصيد ${money(balance)}',style:TextStyle(color:_reportInk.withValues(alpha: .7),fontWeight:FontWeight.w800,fontSize:11))]) ]));}
  @override Widget build(BuildContext context){final lah=rows.fold<int>(0,(s,x)=>s+_n(x['lah'])),alayh=rows.fold<int>(0,(s,x)=>s+_n(x['alayh']));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:Text(labels[kind]!,style:const TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,6,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('الكشوف المالية',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),Text('${labels[kind]} ${_name()}'.trim(),style:const TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('عرض مبسط للحركات المالية والرصيد',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.menu_book_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:_selector()),const SizedBox(height:12),Row(children:[Expanded(child:_stat('إجمالي له',money(lah),_reportGreen)),const SizedBox(width:8),Expanded(child:_stat('إجمالي عليه',money(alayh),_reportOrange)),const SizedBox(width:8),Expanded(child:_stat('عدد الحركات','${rows.length}',_reportOliveDark))]),const SizedBox(height:18),if(visible.isEmpty)const EmptyView('لا توجد حركات لهذا الكشف في الفترة المحددة')else ...[for(var i=0;i<visible.length&&i<500;i++)_line(visible[i],i)] ])));}
  Widget _stat(String label,String value,Color color)=>Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(17),border:Border.all(color:_reportLine)),child:Column(children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:4),Text(value,style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:14))]));
}

class WorkerTransactionsOverviewPage extends StatefulWidget {
  final StationRepository r; final int? initialWorkerId; final DateTime? initialFrom, initialTo;
  const WorkerTransactionsOverviewPage(this.r,{this.initialWorkerId,this.initialFrom,this.initialTo,super.key});
  @override State<WorkerTransactionsOverviewPage> createState()=>_WorkerTransactionsOverviewState();
}
class _WorkerTransactionsOverviewState extends State<WorkerTransactionsOverviewPage>{
  List<Map<String,Object?>> data=[]; DateTime? from,to; String search=''; bool loading=true; String? error;
  @override void initState(){super.initState();from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load()async{if(mounted)setState((){loading=true;error=null;});try{final ws=await widget.r.workers();final out=<Map<String,Object?>>[];for(final w in ws){final tx=await widget.r.report('worker_transactions',workerId:w['id'] as int,from:from,to:to);final lah=tx.fold<int>(0,(s,x)=>s+_n(x['lah']));final alayh=tx.fold<int>(0,(s,x)=>s+_n(x['alayh']));out.add({...w,'lahTotal':lah,'alayhTotal':alayh,'movementCount':tx.length});}if(mounted)setState((){data=out;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}}
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  Future<void> _pick(bool start)async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});_load();}}
  Future<void> _print(int id)async{try{await ReportService(widget.r).printPdf('worker_transactions',workerId:id,from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  List<Map<String,Object?>> get visible{final q=search.trim().toLowerCase();return q.isEmpty?data:data.where((x)=>'${x['name']??''} ${x['phone']??''}'.toLowerCase().contains(q)).toList();}
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[Icon(icon,color:color,size:21),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:10)),const SizedBox(height:3),Text(value,style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:15))]))])));
  Widget _mini(String l,String v,Color c)=>Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(l,style:TextStyle(color:_reportInk.withValues(alpha: .52),fontSize:10)),const SizedBox(height:3),Text(v,style:TextStyle(color:c,fontWeight:FontWeight.w900,fontSize:14))]));
  Widget _card(Map<String,Object?> x){final id=x['id'] as int;final lah=_n(x['lahTotal']);final alayh=_n(x['alayhTotal']);final balance=lah-alayh;final color=balance>=0?_reportGreen:_reportOrange;return Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:_reportLine)),child:Column(children:[Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(15)),child:const Icon(Icons.engineering_rounded,color:_reportOliveDark)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${x['name']??''}',style:const TextStyle(color:_reportInk,fontWeight:FontWeight.w900,fontSize:16)),const SizedBox(height:4),Text('${payTypeName('${x['pay_type']}')} • ${x['phone']??'بدون هاتف'}',style:TextStyle(color:_reportInk.withValues(alpha: .58),fontSize:11))])),IconButton(onPressed:()=>_print(id),tooltip:'PDF العامل',icon:const Icon(Icons.picture_as_pdf_rounded,color:_reportOliveDark)),IconButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>WorkerAccountsReportPage(widget.r,initialWorkerId:id,initialFrom:from,initialTo:to))),tooltip:'فتح الكشف',icon:const Icon(Icons.open_in_new_rounded,color:_reportOliveDark))]),const SizedBox(height:11),Row(children:[_mini('له',money(lah),_reportGreen),const SizedBox(width:10),_mini('عليه',money(alayh),_reportOrange),const SizedBox(width:10),_mini('الحركات','${x['movementCount']??0}',_reportOliveDark)]),const SizedBox(height:10),Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:9),decoration:BoxDecoration(color:color.withValues(alpha: .08),borderRadius:BorderRadius.circular(12)),child:Row(children:[Icon(balance>=0?Icons.account_balance_wallet_rounded:Icons.warning_amber_rounded,color:color,size:18),const SizedBox(width:7),Text(balance>=0?'صافي الحساب له ${money(balance.abs())}':'صافي الحساب عليه ${money(balance.abs())}',style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:12)),const Spacer(),const Text('كشف تفصيلي',style:TextStyle(color:_reportOliveDark,fontSize:10,fontWeight:FontWeight.w800))]))]));}
  @override Widget build(BuildContext context){final lah=data.fold<int>(0,(s,x)=>s+_n(x['lahTotal']));final alayh=data.fold<int>(0,(s,x)=>s+_n(x['alayhTotal']));final movements=data.fold<int>(0,(s,x)=>s+_n(x['movementCount']));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('معاملات العمال',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لوحة استحقاقات العمال',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),const Text('المعاملات والاستحقاقات',style:TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('الدفعات والاستحقاقات والسلف من دفتر الأستاذ المركزي',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.engineering_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Column(children:[TextField(onChanged:(v)=>setState(()=>search=v),decoration:const InputDecoration(labelText:'بحث باسم العامل أو الهاتف',prefixIcon:Icon(Icons.search_rounded),border:OutlineInputBorder())),const SizedBox(height:10),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pick(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pick(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))])])),const SizedBox(height:12),Row(children:[_kpi('عدد العمال','${data.length}',Icons.groups_rounded,_reportOliveDark),const SizedBox(width:8),_kpi('إجمالي له',money(lah),Icons.south_west_rounded,_reportGreen),const SizedBox(width:8),_kpi('إجمالي عليه',money(alayh),Icons.north_east_rounded,_reportOrange)]),const SizedBox(height:10),Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:_reportLine)),child:Row(children:[const Icon(Icons.timeline_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('إجمالي الحركات',style:TextStyle(fontWeight:FontWeight.w800)),const Spacer(),Text('$movements حركة',style:const TextStyle(color:_reportOliveDark,fontWeight:FontWeight.w900))])),const SizedBox(height:18),Row(children:[const Icon(Icons.view_list_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('حسابات العمال',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${visible.length} عامل',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(visible.isEmpty)const EmptyView('لا توجد معاملات عمال مطابقة للفلاتر')else ...[for(final x in visible)_card(x)]])));}
}

class WorkerAccountsReportPage extends StatefulWidget {
  final StationRepository r;
  final int? initialWorkerId;
  final DateTime? initialFrom, initialTo;
  const WorkerAccountsReportPage(this.r, {this.initialWorkerId, this.initialFrom, this.initialTo, super.key});
  @override State<WorkerAccountsReportPage> createState() => _WorkerAccountsReportState();
}

class _WorkerAccountsReportState extends State<WorkerAccountsReportPage> {
  List<Map<String,Object?>> workers=[];
  List<Map<String,Object?>> rows=[];
  Map<String,Object?> summary={};
  int? selectedId;
  DateTime? from,to;
  bool loading=true;
  String? error;
  @override void initState(){super.initState();selectedId=widget.initialWorkerId;from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load() async {
    if(mounted)setState((){loading=true;error=null;});
    try{final list=await widget.r.workers();final id=selectedId??(list.isNotEmpty?list.first['id'] as int:null);var detail=<Map<String,Object?>>[];var totals=<String,Object?>{};if(id!=null){detail=await widget.r.report('worker_transactions',workerId:id,from:from,to:to);totals=await widget.r.partyFinancialSummary('worker',id);}if(mounted)setState((){workers=list;selectedId=id;rows=detail;summary=totals;loading=false;});}catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}
  }
  Future<void> _pickDate(bool start) async{final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print() async{try{await ReportService(widget.r).printPdf('worker_transactions',workerId:selectedId,from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  Map<String,Object?>? get worker=>selectedId==null?null:workers.firstWhere((x)=>x['id']==selectedId,orElse:()=>{});
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? value){final d=DateTime.tryParse('$value');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  String _type(Object? value)=>switch('$value'){'payment'=>'دفعة للعامل','worker_entitlement'=>'استحقاق أجر','opening_balance'=>'رصيد افتتاحي','irrigation'=>'أجر سقاية',_=>'حركة محاسبية'};
  IconData _typeIcon(Object? value)=>switch('$value'){'payment'=>Icons.payments_rounded,'worker_entitlement'=>Icons.engineering_rounded,'opening_balance'=>Icons.flag_rounded,_=>Icons.water_drop_rounded};
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:4),Text(value,style:const TextStyle(color:_reportInk,fontSize:16,fontWeight:FontWeight.w900))]))])));
  Widget _movement(Map<String,Object?> x){final signed=_n(x['signed_amount']);final positive=signed>=0;final color=positive?_reportGreen:_reportOrange;return Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(14)),child:Icon(_typeIcon(x['type']),color:color)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Expanded(child:Text('${x['description']??_type(x['type'])}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk))),Text(_date(x['date']),style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:11))]),const SizedBox(height:5),Text(_type(x['type']),style:TextStyle(color:color,fontSize:11,fontWeight:FontWeight.w800)),const SizedBox(height:8),Row(children:[Text(positive?'له':'عليه',style:TextStyle(color:color,fontWeight:FontWeight.w900)),const SizedBox(width:6),Text(money(signed.abs()),style:TextStyle(color:color,fontWeight:FontWeight.w900)),const Spacer(),Text('الرصيد ${money(_n(x['balance']))}',style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:11,fontWeight:FontWeight.w700))])]))]));}
  @override Widget build(BuildContext context){final w=worker;final bal=_n(summary['balance']);final lah=rows.fold<int>(0,(sum,x)=>sum+_n(x['lah']));final alayh=rows.fold<int>(0,(sum,x)=>sum+_n(x['alayh']));final pay=w==null?'':payTypeName('${w['pay_type']}');final payDetail=w==null?'':w['pay_type']=='hourly'?'${w['hourly_rate']??0} لكل ساعة':w['pay_type']=='percentage'?'${w['percentage']??0}% من السقاية':'راتب ${w['monthly_salary']??0} شهرياً';return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('تفاصيل حسابات العمال',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('كشف استحقاقات العامل',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),Text(w==null?'اختر عاملاً':w['name']?.toString()??'اختر عاملاً',style:const TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('الساعات والاستحقاقات والدفعات من دفتر الأستاذ المركزي',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.engineering_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:DropdownButtonFormField<int>(initialValue:selectedId,items:[for(final x in workers)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],onChanged:(v){setState(()=>selectedId=v);_load();},decoration:const InputDecoration(labelText:'العامل',prefixIcon:Icon(Icons.person_search_rounded),border:OutlineInputBorder()))),const SizedBox(height:12),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pickDate(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pickDate(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))]),const SizedBox(height:15),if(w!=null)Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(15)),child:const Icon(Icons.schedule_rounded,color:_reportOliveDark)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('نظام أجر العامل',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:3),Text(pay,style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk,fontSize:17)),Text(payDetail,style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:11))])),OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>RecordDetailsPage(widget.r,kind:'worker',id:selectedId!,title:'تفاصيل العامل'))),icon:const Icon(Icons.open_in_new_rounded,size:16),label:const Text('ملف العامل'))])),const SizedBox(height:12),Row(children:[_kpi('الرصيد الحالي',money(bal),Icons.account_balance_wallet_rounded,bal>=0?_reportGreen:_reportOrange),const SizedBox(width:9),_kpi('إجمالي له',money(lah),Icons.south_west_rounded,_reportGreen),const SizedBox(width:9),_kpi('إجمالي عليه',money(alayh),Icons.north_east_rounded,_reportOrange)]),const SizedBox(height:18),Row(children:[const Icon(Icons.timeline_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('سجل الاستحقاقات والدفعات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${rows.length} حركة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(selectedId==null||workers.isEmpty)const EmptyView('أضف عاملاً لعرض كشف الحساب')else if(rows.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد حركات في الفترة المحددة')]))else ...[for(final x in rows.take(300))_movement(x)]])));}
}

class PartnerAccountsReportPage extends StatefulWidget {
  final StationRepository r;
  final int? initialPartnerId;
  final DateTime? initialFrom, initialTo;
  final int? userId;
  const PartnerAccountsReportPage(this.r, {this.initialPartnerId, this.initialFrom, this.initialTo, this.userId, super.key});
  @override State<PartnerAccountsReportPage> createState() => _PartnerAccountsReportState();
}

class _PartnerAccountsReportState extends State<PartnerAccountsReportPage> {
  List<Map<String,Object?>> partners=[];
  List<Map<String,Object?>> rows=[];
  Map<String,Object?> summary={};
  int? selectedId;
  DateTime? from,to;
  bool loading=true;
  String? error;

  @override void initState(){super.initState();selectedId=widget.initialPartnerId;from=widget.initialFrom;to=widget.initialTo;_load();}
  Future<void> _load() async {
    if (mounted) setState((){loading=true;error=null;});
    try {
      final list=await widget.r.partners();
      final id=selectedId ?? (list.isNotEmpty ? list.first['id'] as int : null);
      var detail=<Map<String,Object?>>[]; var totals=<String,Object?>{};
      if(id!=null){detail=await widget.r.report('partner_accounts',partnerId:id,from:from,to:to);totals=await widget.r.partyFinancialSummary('partner',id);}
      if(mounted)setState((){partners=list;selectedId=id;rows=detail;summary=totals;loading=false;});
    }catch(e){if(mounted)setState((){error=friendlyError(e);loading=false;});}
  }
  Future<void> _pickDate(bool start) async {final d=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:(start?from:to)??AppClock.now(),locale:const Locale('ar'));if(d!=null){setState((){if(start) {
    from=d;
  } else {
    to=d;
  }});await _load();}}
  Future<void> _print() async {try{await ReportService(widget.r).printPdf('partner_accounts',partnerId:selectedId,from:from,to:to);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(friendlyError(e))));}}
  Map<String,Object?>? get partner=>selectedId==null?null:partners.cast<Map<String,Object?>>().firstWhere((x)=>x['id']==selectedId,orElse:()=>{});
  int _n(Object? v)=>(v as num?)?.round()??0;
  String _date(Object? value){final d=DateTime.tryParse('$value');return d==null?'—':'${d.day}/${d.month}/${d.year}';}
  String _type(Object? value)=>switch('$value'){ 'payment'=>'دفعة للشريك','share_accrual'=>'استحقاق أرباح','opening_balance'=>'رصيد افتتاحي','irrigation'=>'سقاية على حساب الشريك',_=>'حركة محاسبية'};
  IconData _typeIcon(Object? value)=>switch('$value'){ 'payment'=>Icons.payments_rounded,'share_accrual'=>Icons.trending_up_rounded,'opening_balance'=>Icons.flag_rounded,_=>Icons.receipt_long_rounded};
  Widget _kpi(String label,String value,IconData icon,Color color)=>Expanded(child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:4),Text(value,style:const TextStyle(color:_reportInk,fontSize:16,fontWeight:FontWeight.w900))]))])));
  Widget _movement(Map<String,Object?> x){final signed=_n(x['signed_amount']);final positive=signed>=0;final color=positive?_reportGreen:_reportOrange;return Container(margin:const EdgeInsets.only(bottom:11),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha: .12),borderRadius:BorderRadius.circular(14)),child:Icon(_typeIcon(x['type']),color:color)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Expanded(child:Text('${x['description']??_type(x['type'])}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk))),Text(_date(x['date']),style:TextStyle(color:_reportInk.withValues(alpha: .5),fontSize:11))]),const SizedBox(height:5),Text(_type(x['type']),style:TextStyle(color:color,fontSize:11,fontWeight:FontWeight.w800)),const SizedBox(height:8),Row(children:[Text(positive?'له':'عليه',style:TextStyle(color:color,fontWeight:FontWeight.w900)),const SizedBox(width:6),Text(money(signed.abs()),style:TextStyle(color:color,fontWeight:FontWeight.w900)),const Spacer(),Text('الرصيد ${money(_n(x['balance']))}',style:TextStyle(color:_reportInk.withValues(alpha: .62),fontSize:11,fontWeight:FontWeight.w700))])]))]));}
  @override Widget build(BuildContext context){final p=partner;final bal=_n(summary['balance']);final lah=rows.fold<int>(0,(sum,x)=>sum+_n(x['lah']));final alayh=rows.fold<int>(0,(sum,x)=>sum+_n(x['alayh']));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(backgroundColor:_reportCream,appBar:AppBar(backgroundColor:_reportCream,elevation:0,foregroundColor:_reportInk,title:const Text('تفاصيل حسابات الشركاء',style:TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:_load,tooltip:'تحديث',icon:const Icon(Icons.refresh_rounded)),Padding(padding:const EdgeInsetsDirectional.only(end:10),child:FilledButton.icon(onPressed:_print,style:FilledButton.styleFrom(backgroundColor:_reportOliveDark,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(13))),icon:const Icon(Icons.picture_as_pdf_rounded,size:18),label:const Text('PDF')))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?ErrorBox(error!):ListView(padding:const EdgeInsets.fromLTRB(18,4,18,30),children:[Container(padding:const EdgeInsets.all(21),decoration:BoxDecoration(gradient:const LinearGradient(colors:[_reportOliveDark,_reportOlive]),borderRadius:BorderRadius.circular(27)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('كشف حساب مالي',style:TextStyle(color:Colors.white.withValues(alpha: .72),fontSize:12)),const SizedBox(height:6),Text(p==null?'اختر شريكاً':p['name']?.toString()??'اختر شريكاً',style:const TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:7),Text('كل الحركات مترجمة إلى له وعليه من دفتر الأستاذ المركزي',style:TextStyle(color:Colors.white.withValues(alpha: .82),fontSize:11))]),),const Icon(Icons.groups_rounded,color:Colors.white,size:46)])),const SizedBox(height:14),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:DropdownButtonFormField<int>(initialValue:selectedId,items:[for(final x in partners)DropdownMenuItem(value:x['id'] as int,child:Text('${x['name']}'))],onChanged:(v){setState(()=>selectedId=v);_load();},decoration:const InputDecoration(labelText:'الشريك',prefixIcon:Icon(Icons.person_search_rounded),border:OutlineInputBorder()))),const SizedBox(height:12),Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:()=>_pickDate(true),icon:const Icon(Icons.calendar_today_rounded,size:16),label:Text(from==null?'من تاريخ':'من ${_date(from)}')),OutlinedButton.icon(onPressed:()=>_pickDate(false),icon:const Icon(Icons.event_rounded,size:16),label:Text(to==null?'إلى تاريخ':'إلى ${_date(to)}')),if(from!=null||to!=null)TextButton(onPressed:(){setState((){from=null;to=null;});_load();},child:const Text('مسح الفترة'))]),const SizedBox(height:15),if(p!=null)Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20),border:Border.all(color:_reportLine)),child:Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:_reportCream,borderRadius:BorderRadius.circular(15)),child:Icon(p['ownership_mode']=='percentage'?Icons.percent_rounded:Icons.pie_chart_rounded,color:_reportOliveDark)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('أساس توزيع الأرباح',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:11)),const SizedBox(height:3),Text(p['ownership_mode']=='percentage'?'نسبة ملكية ${p['ownership_percentage']??0}%':'${p['shares_count']??0} حصص',style:const TextStyle(fontWeight:FontWeight.w900,color:_reportInk,fontSize:17))])),OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>RecordDetailsPage(widget.r,kind:'partner',id:selectedId!,title:'تفاصيل الشريك'))),icon:const Icon(Icons.open_in_new_rounded,size:16),label:const Text('ملف الشريك'))])),const SizedBox(height:12),Row(children:[_kpi('الرصيد الحالي',money(bal),Icons.account_balance_wallet_rounded,bal>=0?_reportGreen:_reportOrange),const SizedBox(width:9),_kpi('إجمالي له',money(lah),Icons.south_west_rounded,_reportGreen),const SizedBox(width:9),_kpi('إجمالي عليه',money(alayh),Icons.north_east_rounded,_reportOrange)]),const SizedBox(height:18),Row(children:[const Icon(Icons.timeline_rounded,color:_reportOliveDark),const SizedBox(width:8),const Text('سجل الحركات',style:TextStyle(fontWeight:FontWeight.w900,fontSize:19,color:_reportInk)),const Spacer(),Text('${rows.length} حركة',style:TextStyle(color:_reportInk.withValues(alpha: .55),fontSize:12))]),const SizedBox(height:10),if(selectedId==null||partners.isEmpty)const EmptyView('أضف شريكاً لعرض كشف الحساب')else if(rows.isEmpty)Container(padding:const EdgeInsets.all(30),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(20)),child:const Column(children:[Icon(Icons.inbox_rounded,size:42,color:_reportOlive),SizedBox(height:8),Text('لا توجد حركات في الفترة المحددة')]))else ...[for(final x in rows.take(300))_movement(x)]])));}
}

class NotificationsPage extends StatefulWidget {
  final StationRepository r;
  const NotificationsPage(this.r, {super.key});
  @override
  State<NotificationsPage> createState() => _NotificationsState();
}

class _NotificationsState extends State<NotificationsPage> {
  List<Map<String, Object?>> rows = [];
  String snoozeNote(Map<String, Object?> x) {
    final until = DateTime.tryParse('${x['snoozed_until'] ?? ''}');
    return until != null && until.isAfter(AppClock.now())
        ? '\nمؤجّل حتى ${until.toString().substring(0, 16)}'
        : '';
  }

  Future<void> load() async {
    final x = await widget.r.notifications();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(c) => PageFrame(
    title: 'الإشعارات',
    subtitle: 'تنبيهات المستفيدين وحالات القراءة',
    child: rows.isEmpty
        ? const EmptyView('لا توجد إشعارات')
        : ListView(
            children: [
              for (final x in rows)
                Card(
                  child: ListTile(
                    onTap: () async {
                      if (!await runGuarded(
                        context,
                        () => widget.r.markNotificationRead(x['id'] as int),
                      )) {
                        return;
                      }
                      load();
                    },
                    leading: Icon(
                      x['read_at'] == null
                          ? Icons.notifications_active
                          : Icons.notifications_none,
                      color: x['read_at'] == null ? _cyan : null,
                    ),
                    title: Text('${x['title']}'),
                    subtitle: Text(
                      '${x['body']}\n${x['created_at']}${snoozeNote(x)}',
                    ),
                    trailing: PopupMenuButton<int>(
                      tooltip: 'تأجيل التنبيه',
                      icon: const Icon(Icons.snooze_rounded),
                      onSelected: (m) async {
                        if (!await runGuarded(
                          context,
                          () => widget.r.snoozeNotification(
                            x['id'] as int,
                            minutes: m,
                          ),
                        )) {
                          return;
                        }
                        await load();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 10, child: Text('10 دقائق')),
                        PopupMenuItem(value: 60, child: Text('ساعة')),
                        PopupMenuItem(value: 1440, child: Text('يوم')),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}

class SettingsPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  final ValueChanged<String>? onSystemTypeChanged;
  const SettingsPage(
    this.r, {
    required this.userId,
    required this.manager,
    this.onSystemTypeChanged,
    super.key,
  });
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  Map<String, String> s = {};
  bool _bubbleEnabled = false;
  bool _bubbleBusy = false;

  Future<void> _loadBubbleState() async {
    try {
      // Permission availability is not the running state; query the service separately.
      final running = await _floatingBubbleChannel.invokeMethod<bool>('isBubbleRunning');
      if (mounted) setState(() => _bubbleEnabled = running ?? false);
    } catch (_) {
      if (mounted) setState(() => _bubbleEnabled = false);
    }
  }

  Future<void> _setBubbleEnabled(bool enable) async {
    if (_bubbleBusy) return;
    setState(() => _bubbleBusy = true);
    try {
      if (enable) {
        final allowed = await _floatingBubbleChannel.invokeMethod<bool>('canDrawOverlays') ?? false;
        if (!allowed) {
          await _floatingBubbleChannel.invokeMethod<bool>('requestOverlayPermission');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('اسمح لساقية بالظهور فوق التطبيقات، ثم ارجع واضغط تشغيل الفقاعة مرة أخرى.')),
            );
          }
          return;
        }
        await _floatingBubbleChannel.invokeMethod<bool>('startBubble');
        if (mounted) {
          setState(() => _bubbleEnabled = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم تشغيل فقاعة ساقية. يمكنك سحبها، وإيقافها من هذا المفتاح.')),
          );
        }
      } else {
        await _floatingBubbleChannel.invokeMethod<bool>('stopBubble');
        if (mounted) {
          setState(() => _bubbleEnabled = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم إيقاف الفقاعة وإزالة ظهورها فوق التطبيقات.')),
          );
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'تعذر تغيير حالة الفقاعة')),
      );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ميزة الفقاعة متاحة على أجهزة Android فقط.')),
      );
      }
    } finally {
      if (mounted) setState(() => _bubbleBusy = false);
    }
  }

  Future<void> load() async {
    final x = await widget.r.settings();
    // أي حفظ لإعداد يمر من هنا: نطبّق التفضيلات الحية (اسم التطبيق، الحركة، التنبيهات، مصدر الوقت).
    await AppPrefs.apply(x);
    if (mounted) setState(() => s = x);
  }

  @override
  void initState() {
    super.initState();
    load();
    _loadBubbleState();
  }

  Future<void> edit(
    String key,
    String label, {
    bool numeric = false,
    String? preset,
  }) async {
    final c = TextEditingController(text: preset ?? s[key] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: label,
        children: [
          TextField(
            controller: c,
            keyboardType: numeric ? TextInputType.number : null,
            decoration: InputDecoration(labelText: label),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (key == 'financial_year_start' &&
          !PeriodRanges.validFinancialYearStart(c.text)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('الصيغة المطلوبة: شهر-يوم مثل 01-01 أو 07-01'),
            ),
          );
        }
        return;
      }
      if (key == 'system_type') {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('نوع المنظومة ثابت منذ الإعداد الأولي ولا يمكن تغييره')));
        return;
      } else {
        if (!mounted) return;
        if (!await runGuarded(context, () => widget.r.setSetting(key, c.text))) {
          return;
        }
      }
      await load();
    }
  }

  Future<void> _saveAppearance(String key, String value) async {
    try {
      await widget.r.setSetting(key, value);
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تطبيق المظهر الجديد على التطبيق')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ المظهر: ${friendlyError(e)}')),
        );
      }
    }
  }

  Widget _appearanceSettings() {
    final selected = s['theme_key'] ?? 'olive';
    final mode = s['theme_mode'] ?? 'system';
    const keys = ['olive', 'ocean', 'emerald', 'violet', 'rose'];
    return SettingGroup(
      title: 'المظهر والثيمات',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text(
            'اختر لوحة ألوان عصرية، وسيتم حفظ اختيارك لهذا التطبيق.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              for (final key in keys)
                ChoiceChip(
                  selected: selected == key,
                  onSelected: selected == key
                      ? null
                      : (_) => _saveAppearance('theme_key', key),
                  avatar: CircleAvatar(
                    radius: 9,
                    backgroundColor: SaqiaTheme.accent(key),
                    child: selected == key
                        ? const Icon(Icons.check, size: 12, color: Colors.white)
                        : null,
                  ),
                  label: Text(SaqiaTheme.name(key)),
                ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.brightness_6_rounded),
          title: const Text('وضع العرض'),
          subtitle: const Text('فاتح أو داكن أو حسب إعداد الجهاز'),
          trailing: SizedBox(
            width: 145,
            child: DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: const ['system', 'light', 'dark'].contains(mode)
                  ? mode
                  : 'system',
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: const [
                DropdownMenuItem(value: 'system', child: Text('تلقائي')),
                DropdownMenuItem(value: 'light', child: Text('فاتح')),
                DropdownMenuItem(value: 'dark', child: Text('داكن')),
              ],
              onChanged: (value) {
                if (value != null && value != mode) {
                  _saveAppearance('theme_mode', value);
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> users() async {
    final x = await AdminService(widget.r.db).users();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('المستخدمون'),
        content: SizedBox(
          width: 450,
          height: 360,
          child: ListView(
            children: [
              for (final u in x)
                ListTile(
                  title: Text('${u['name']}'),
                  subtitle: Text(
                    '${u['username']} • ${roleArabic('${u['role']}')}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String roleArabic(String x) =>
      {
        'manager': 'مدير',
        'accountant': 'محاسب',
        'operations': 'تشغيل',
        'beneficiary': 'مستفيد',
      }[x] ??
      'مستخدم';

  Future<void> reconcileCashAndBank() async {
    final balances = <String, TextEditingController>{};
    final references = <String, TextEditingController>{};
    final notes = <String, TextEditingController>{};
    try {
      if (!widget.manager) throw StateError('مطابقة النقد والبنك متاحة للمدير فقط');
      final fiscalStartSetting = s['financial_year_start'] ?? '01-01';
      final currentStart = PeriodRanges.financialYearStart(AppClock.now(), fiscalStartSetting);
      final endExclusive = DateTime(currentStart.year, currentStart.month, currentStart.day);
      final start = PeriodRanges.financialYearStart(DateTime(currentStart.year - 1, 12, 31), fiscalStartSetting);
      final stationId = await widget.r.accounting.currentStationId();
      final targets = await widget.r.accounting.cashReconciliationTargets(
        stationId: stationId, endExclusive: endExclusive,
      );
      if (!mounted) return;
      if (targets.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد حسابات نقدية أو بنكية تحتاج إلى مطابقة لهذه المحطة')),
        );
        return;
      }
      for (final target in targets) {
        final code = '${target['account_code']}';
        balances[code] = TextEditingController();
        references[code] = TextEditingController();
        notes[code] = TextEditingController();
      }
      String sourceLabel(String type) => switch (type) {
        'cash_count' => 'عدّ نقدي فعلي',
        'bank_statement' => 'كشف حساب بنكي',
        'wallet_statement' => 'كشف محفظة إلكترونية',
        _ => 'مستند رصيد فعلي',
      };
      final lastDay = endExclusive.subtract(const Duration(days: 1));
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('مطابقة النقد وكشوف البنوك'),
          content: SizedBox(
            width: 560,
            height: 500,
            child: ListView(
              children: [
                Text('المحطة الحالية • تاريخ القطع ${DateFormat('yyyy/MM/dd').format(lastDay)}'),
                const SizedBox(height: 8),
                const Text('أدخل الرصيد الفعلي أو رصيد الكشف كما في تاريخ القطع. للحساب البنكي أدخل مرجع الكشف. تحفظ المحاولة للتدقيق ولا ينشأ قيد تسوية تلقائي.'),
                const SizedBox(height: 14),
                for (final target in targets) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${target['account_code']} • ${target['account_name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text('${sourceLabel('${target['source_type']}')} • ${target['currency']} • رصيد الأستاذ بتاريخ القطع: ${money(target['book_balance'])}'),
                          if ((target['cashbox_names'] as List).isNotEmpty)
                            Text('الصناديق المرتبطة: ${(target['cashbox_names'] as List).join('، ')}'),
                          if (target['currency_conflict'] == true)
                            const Text('خطأ: الحساب مرتبط بصناديق بعملات مختلفة، ولا يمكن مطابقتها معًا.'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: balances['${target['account_code']}'],
                            keyboardType: const TextInputType.numberWithOptions(signed: true),
                            decoration: InputDecoration(
                              labelText: 'الرصيد الفعلي بوحدة ${target['currency']}',
                              hintText: 'أدخل رقمًا صحيحًا دون فواصل',
                            ),
                          ),
                          if ('${target['source_type']}' != 'cash_count')
                            TextField(
                              controller: references['${target['account_code']}'],
                              decoration: const InputDecoration(labelText: 'مرجع الكشف/المستند (مطلوب)'),
                            ),
                          TextField(
                            controller: notes['${target['account_code']}'],
                            decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('حفظ واعتماد المطابقات الصفرية')),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final entries = <Map<String, Object?>>[];
      for (final target in targets) {
        final code = '${target['account_code']}';
        final raw = balances[code]!.text.trim().replaceAll(',', '').replaceAll('٬', '');
        final value = int.tryParse(raw);
        if (value == null) throw FormatException('أدخل رصيدًا صحيحًا للحساب $code');
        entries.add({
          'account_code': code,
          'actual_balance': value,
          'reference': references[code]!.text.trim(),
          'notes': notes[code]!.text.trim(),
        });
      }
      final results = await widget.r.accounting.recordCashReconciliations(
        stationId: stationId,
        start: start,
        endExclusive: endExclusive,
        userId: widget.userId,
        entries: entries,
      );
      if (!mounted) return;
      final resultLines = results.map((row) =>
        '${row['account_code']}: دفتر ${money(row['book_balance'])} / فعلي ${money(row['actual_balance'])} / فرق ${money(row['difference'])}'
      ).join('\n');
      final hasDifference = results.any((row) => row['difference'] != 0);
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(hasDifference ? 'سُجلت فروق — الإقفال ممنوع' : 'تم اعتماد المطابقات الصفرية'),
          content: SingleChildScrollView(
            child: Text('$resultLines\n\n${hasDifference ? 'راجع سبب الفرق وسجّل أي تسوية مبررة في فترة مفتوحة، ثم أعد العدّ/المطابقة. لا ينشئ التطبيق قيد تسوية تلقائيًا.' : 'أعيد فحص رصيد الأستاذ عند الإقفال؛ أي حركة لاحقة تغيّر الرصيد ستجعل المطابقة قديمة وتمنع الإقفال.'}'),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      for (final controller in [...balances.values, ...references.values, ...notes.values]) {
        controller.dispose();
      }
    }
  }

  Future<void> close() async {
    try {
      if (!widget.manager) throw StateError('إقفال السنة المالية متاح للمدير فقط');
      final fiscalStartSetting = s['financial_year_start'] ?? '01-01';
      final currentStart = PeriodRanges.financialYearStart(AppClock.now(), fiscalStartSetting);
      final endExclusive = DateTime(currentStart.year, currentStart.month, currentStart.day);
      final start = PeriodRanges.financialYearStart(DateTime(currentStart.year - 1, 12, 31), fiscalStartSetting);
      final stationId = await widget.r.accounting.currentStationId();
      final preview = await widget.r.accounting.previewFiscalYear(
        stationId: stationId, start: start, endExclusive: endExclusive,
      );
      if (!mounted) return;
      final subledgerRows = (preview['subledger_reconciliation'] as List? ?? const [])
          .cast<Map<String, Object?>>();
      final actualCashRows = (preview['actual_cash_reconciliation'] as List? ?? const [])
          .cast<Map<String, Object?>>();
      final actualCashLines = actualCashRows.map((row) {
        final state = switch ('${row['evidence_status']}') {
          'matched' => 'مطابق ومعتمد',
          'missing' => 'لم يسجل بعد',
          'stale' => 'قديم — تغير رصيد الأستاذ',
          'mixed_currency' => 'عملات مختلطة',
          'invalid_account' => 'حساب أستاذ غير موجود',
          _ => 'فرق ${money(row['difference'] ?? 0)}',
        };
        return '${row['account_code']} • ${row['account_name']}: دفتر ${money(row['book_balance'])} / فعلي ${row['actual_balance'] == null ? '—' : money(row['actual_balance'])} / $state';
      }).join('\n');
      String subledgerName(String kind) => switch (kind) {
        'beneficiaries' => 'المستفيدون',
        'workers' => 'العمال',
        'partners' => 'الشركاء',
        _ => kind,
      };
      final subledgerLines = subledgerRows.map((row) {
        final details = (row['mismatches'] as List? ?? const [])
            .cast<Map<String, Object?>>()
            .map((party) => '${party['name']}: فرق ${money(party['difference'])}')
            .join('، ');
        return '${subledgerName('${row['kind']}')}: دفتر فرعي ${money(row['subledger_balance'])} / أستاذ ${money(row['general_ledger_balance'])} / فرق ${money(row['difference'])}${details.isEmpty ? '' : '\n$details'}';
      }).join('\n');
      if (preview['valid'] != true) {
        await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('تعذّر إقفال السنة'),
            content: SingleChildScrollView(
              child: Text([
                ...(preview['errors'] as List).map((error) => '$error'),
                if (actualCashLines.isNotEmpty) '\nمطابقة العدّ النقدي وكشوف الحسابات:\n$actualCashLines',
                if (subledgerLines.isNotEmpty) '\nمطابقة الدفاتر الفرعية:\n$subledgerLines',
              ].join('\n')),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق'))],
          ),
        );
        return;
      }
      final lastDay = endExclusive.subtract(const Duration(days: 1));
      final cashLines = (preview['cashbox_reconciliation'] as List)
          .map((r) => 'حساب ${r['code']}: صندوق ${money(r['cashbox_balance'])} / أستاذ ${money(r['ledger_balance'])}')
          .join('\n');
      final carryRows = (preview['carry_accounts'] as List)
          .where((r) => ['2100', '2200', '3000', '3100', '3200', '3300'].contains('${r['code']}'))
          .map((r) => '${r['code']} ${r['name']}: ${money(r['credit_balance'])}')
          .join('\n');
      final warningLines = (preview['warnings'] as List).map((w) => '• $w').join('\n');
      final accepted = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('مراجعة إقفال السنة المالية'),
          content: Text(
            'الفترة: ${DateFormat('yyyy/MM/dd').format(start)} – ${DateFormat('yyyy/MM/dd').format(lastDay)}\n'
            'الإيرادات: ${money(preview['income'])}\n'
            'المصروفات: ${money(preview['expenses'])}\n'
            'صافي النتيجة: ${money(preview['net_profit'])}\n\n'
            'ميزان المراجعة: مدين ${money(preview['trial_balance_debit'])} / دائن ${money(preview['trial_balance_credit'])}\n'
            'مطابقة الصناديق الحالية:\n${cashLines.isEmpty ? 'لا توجد صناديق مسجلة' : cashLines}\n\n'
            'العدّ النقدي وكشوف الحسابات عند نهاية السنة:\n${actualCashLines.isEmpty ? 'لا توجد حسابات تتطلب شهادة مطابقة' : actualCashLines}\n\n'
            'مطابقة الدفاتر الفرعية مع الأستاذ:\n${subledgerLines.isEmpty ? 'لا توجد بيانات' : subledgerLines}\n\n'
            'الأرصدة المرحّلة:\n${carryRows.isEmpty ? 'لا توجد أرصدة في الحسابات المحددة' : carryRows}\n\n'
            'تنبيهات قبل الاعتماد:\n$warningLines\n\n'
            'سيُقفل صافي النتائج في 3300. تبقى الأصول والالتزامات في الدفتر المتصل دون قيود افتتاحية مكررة.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('اعتماد الإقفال')),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      await widget.r.accounting.closeFiscalYear(
        stationId: stationId, start: start, endExclusive: endExclusive,
        userId: widget.userId, notes: 'إقفال معتمد من الإعدادات',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم إقفال السنة المالية ${start.year} وترحيل نتيجتها')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _reopenClosure(int closureId) async {
    if (!widget.manager) return;
    final reason = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
          title: const Text('إعادة فتح السنة المالية'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('سيُسجَّل قيد عكسي لقيد الإقفال، ويُرفع القفل بعد إدخال سبب موثق. لا يُحذف سجل الإقفال.'),
            const SizedBox(height: 12),
            TextField(controller: reason, autofocus: true, maxLines: 2, decoration: const InputDecoration(labelText: 'سبب إعادة الفتح')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('عكس الإقفال وفتح السنة')),
          ],
      ),
    ) ?? false;
    final why = reason.text.trim();
    reason.dispose();
    if (!accepted || !mounted) return;
    if (why.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('سبب إعادة الفتح مطلوب')));
      return;
    }
    try {
      await widget.r.accounting.reopenFiscalYear(
        closureId: closureId, userId: widget.userId, reason: why,
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تسجيل عكس الإقفال وإعادة فتح السنة')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> manageClosures() async {
    if (!widget.manager) return;
    final stationId = await widget.r.accounting.currentStationId();
    final all = await AdminService(widget.r.db).closedPeriods();
    final closures = all.where((r) => (r['station_id'] as num?)?.toInt() == stationId).toList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('سجل الإقفالات المالية'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: closures.isEmpty
              ? const Center(child: Text('لا توجد إقفالات لهذه المحطة'))
              : ListView.separated(
                  itemCount: closures.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, index) {
                    final row = closures[index];
                    final status = '${row['status'] ?? 'locked'}';
                    final start = DateTime.tryParse('${row['period_start']}');
                    final end = DateTime.tryParse('${row['period_end_exclusive'] ?? row['period_end']}');
                    final title = start == null ? 'فترة محاسبية' : 'السنة المالية ${start.year}';
                    final range = start == null || end == null ? '' : '${DateFormat('yyyy/MM/dd').format(start)} – ${DateFormat('yyyy/MM/dd').format(end.subtract(const Duration(days: 1)))}';
                    return ListTile(
                      title: Text('$title • ${status == 'closed' ? 'مقفلة' : status == 'reopened' ? 'أعيد فتحها' : 'مقفلة سابقًا'}'),
                      subtitle: Text('$range\nصافي النتيجة: ${money(row['net_profit'] ?? 0)}'),
                      isThreeLine: true,
                      trailing: status == 'closed'
                          ? TextButton(
                              onPressed: () async {
                                final id = (row['id'] as num).toInt();
                                Navigator.pop(d);
                                await _reopenClosure(id);
                              },
                              child: const Text('إعادة فتح'),
                            )
                          : null,
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق'))],
      ),
    );
  }

  Widget _pumpSettingTile() => ListTile(
    title: const Text('المضخة المستخدمة في السقي'),
    subtitle: Text(s['pump_name'] ?? 'غير محددة'),
    trailing: const Icon(Icons.arrow_drop_down),
    onTap: () async {
      final pumps = await widget.r.db.query(
        'pumps',
        where: 'active=1',
        orderBy: 'id',
      );
      if (!mounted) return;
      final v = await showDialog<int>(
        context: context,
        builder: (d) => SimpleDialog(
          title: const Text('اختيار المضخة المستخدمة'),
          children: [
            for (final p in pumps)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, p['id'] as int),
                child: Text(
                  '${p['name']} • ${systemName('${p['system_type']}')}',
                ),
              ),
          ],
        ),
      );
      if (v != null) {
        if (!mounted) return;
        if (!await runGuarded(context, () => widget.r.selectPump(v))) return;
        await load();
        widget.onSystemTypeChanged?.call(s['system_type'] ?? 'diesel');
      }
    },
  );

  Widget setTile(String k, String label, [bool n = false]) => ListTile(
    title: Text(label),
    subtitle: Text(settingDisplay(k, s[k] ?? 'غير مضبوط')),
    trailing: const Icon(Icons.edit),
    onTap: () => edit(k, label, numeric: n),
  );
  Widget boolTile(String k, String label) => SwitchListTile.adaptive(
    title: Text(label),
    value: (s[k] ?? 'false') == 'true',
    onChanged: (v) async {
      if (!await runGuarded(
        context,
        () => widget.r.setSetting(k, v ? 'true' : 'false'),
      )) {
        return;
      }
      await load();
    },
    secondary: const Icon(Icons.toggle_on_outlined),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
  );
  Widget dropdownTile(
    String k,
    String label,
    List<MapEntry<String, String>> options,
  ) => ListTile(
    title: Text(label),
    subtitle: Text(settingDisplay(k, s[k] ?? 'غير مضبوط')),
    trailing: const Icon(Icons.keyboard_arrow_down_rounded),
    onTap: () async {
      final current = s[k];
      final v = await showDialog<String>(
        context: context,
        builder: (d) => SimpleDialog(
          title: Text(label),
          children: [
            for (final o in options)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, o.key),
                child: Row(
                  children: [
                    if (o.key == current)
                      const Icon(Icons.check_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(o.value),
                  ],
                ),
              ),
          ],
        ),
      );
      if (v != null) {
        if (!mounted) return;
        if (!await runGuarded(context, () => widget.r.setSetting(k, v))) return;
        await load();
      }
    },
  );

  Widget _settingsHero() => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [_reportOliveDark, _reportOlive]),
      borderRadius: BorderRadius.circular(28),
      boxShadow: [BoxShadow(color: _reportOlive.withValues(alpha: .18), blurRadius: 18, offset: const Offset(0, 8))],
    ),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('مركز التحكم', style: TextStyle(color: Colors.white.withValues(alpha: .72), fontSize: 12)),
        const SizedBox(height: 6),
        Text(s['station_name'] ?? 'إعدادات المحطة', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 7),
        Text('اضبط التشغيل والتسعير والتنبيهات والمحاسبة من مكان واحد', style: TextStyle(color: Colors.white.withValues(alpha: .84), fontSize: 11)),
        const SizedBox(height: 14),
        Wrap(spacing: 7, runSpacing: 7, children: [
          _settingBadge(Icons.water_drop_rounded, settingDisplay('system_type', s['system_type'] ?? 'diesel')),
          _settingBadge(Icons.access_time_rounded, s['time_source'] == 'server' ? 'وقت الخادم' : 'وقت الجهاز'),
          _settingBadge(Icons.currency_exchange_rounded, s['currency'] ?? 'YER'),
        ]),
      ])),
      Container(width: 66, height: 66, decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), borderRadius: BorderRadius.circular(22)), child: const Icon(Icons.tune_rounded, color: Colors.white, size: 34)),
    ]),
  );
  Widget _settingBadge(IconData icon, String text) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), borderRadius: BorderRadius.circular(11)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 5), Text(text, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800))]));

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      title: 'الإعدادات',
      subtitle: 'إعداد المحطة والمضخة والتسعير والطابور والتنبيهات',
      actions: [
        OutlinedButton.icon(
          onPressed: users,
          icon: const Icon(Icons.people_alt),
          label: const Text('المستخدمون'),
        ),
        if (widget.manager) FilledButton.icon(
          onPressed: close,
          icon: const Icon(Icons.lock_clock),
          label: const Text('إقفال آخر سنة مكتملة'),
        ),
        if (widget.manager) OutlinedButton.icon(
          onPressed: reconcileCashAndBank,
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label: const Text('مطابقة النقد والبنك'),
        ),
        if (widget.manager) OutlinedButton.icon(
          onPressed: manageClosures,
          icon: const Icon(Icons.history),
          label: const Text('سجل الإقفالات'),
        ),
      ],
      child: ListView(
        children: [
          _settingsHero(),
          _appearanceSettings(),
          SettingGroup(
            title: 'الفقاعة العائمة',
            children: [
              SwitchListTile.adaptive(
                value: _bubbleEnabled,
                onChanged: _bubbleBusy ? null : _setBubbleEnabled,
                secondary: _bubbleBusy
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bubble_chart_rounded, color: _reportOliveDark),
                title: const Text('إظهار فقاعة ساقية فوق التطبيقات'),
                subtitle: const Text('تعمل فقط بعد تفعيلك لها. تطلب صلاحية الظهور فوق التطبيقات عند التشغيل الأول، وتعرض إشعاراً أثناء عملها. لا تسجل الشاشة ولا تجمع بيانات التطبيقات الأخرى، ولا تعمل تلقائياً بعد إعادة تشغيل الهاتف.'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ],
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: _reportLine)),
            child: Row(children: [const Icon(Icons.info_outline_rounded, color: _reportOliveDark), const SizedBox(width: 9), Expanded(child: Text('اضغط على أي قسم لعرض إعداداته. يتم حفظ التغييرات مباشرة وتطبيق إعدادات الاسم والتنبيهات والحركة فوراً.', style: TextStyle(color: _reportInk.withValues(alpha: .68), fontSize: 11, fontWeight: FontWeight.w700)))]),
          ),
          SettingGroup(
            title: 'بيانات المحطة',
            children: [
              setTile('station_name', 'اسم المحطة'),
              _pumpSettingTile(),
              setTile('address', 'العنوان'),
              setTile('phone', 'الهاتف'),
              setTile('currency', 'العملة'),
              setTile('timezone', 'المنطقة الزمنية'),
              setTile('app_name', 'اسم التطبيق'),
              setTile('station_logo_path', 'مسار شعار المحطة'),
              setTile('app_icon_path', 'مسار أيقونة التطبيق'),
            ],
          ),
          SettingGroup(
            title: 'المنظومة والتسعير',
            children: [
              ListTile(
                leading: const Icon(Icons.lock_outline_rounded, color: _reportOliveDark),
                title: const Text('نوع المنظومة'),
                subtitle: Text('${settingDisplay('system_type', s['system_type'] ?? 'diesel')} • ثابت منذ الإعداد الأولي'),
                trailing: const Icon(Icons.verified_rounded, color: _reportGreen),
              ),
              if ((s['system_type'] ?? 'diesel') == 'diesel') ...[
                setTile(
                  'diesel_hourly_water_rate',
                  'سعر مياه الديزل بالساعة',
                  true,
                ),
                setTile(
                  'diesel_liters_per_hour',
                  'لترات الديزل في الساعة',
                  true,
                ),
                setTile('diesel_price_per_liter', 'سعر لتر الديزل', true),
              ],
              if ((s['system_type'] ?? 'diesel') == 'solar')
                setTile('solar_hourly_rate', 'سعر السقي الشمسي بالساعة', true),
              if ((s['system_type'] ?? 'diesel') == 'equivalent_hybrid')
                setTile(
                  'third_type_hourly_rate',
                  'سعر النوع الثالث بالساعة',
                  true,
                ),
              setTile('partial_hour', 'محاسبة الجزء من الساعة'),
              setTile('rounding', 'سياسة التقريب'),
            ],
          ),
          SettingGroup(
            title: 'الطابور والجلسات',
            children: [
              dropdownTile('queue_type', 'نمط التشغيل', const [
                MapEntry('circular', 'طابور دائري'),
                MapEntry('booking', 'نظام حجز'),
              ]),
              dropdownTile('time_source', 'مصدر الوقت', const [
                MapEntry('device', 'وقت الجهاز'),
                MapEntry('server', 'وقت الخادم'),
              ]),
              if ((s['time_source'] ?? 'device') == 'server')
                setTile('server_url', 'عنوان الخادم (لمزامنة الوقت)'),
              dropdownTile('week_start', 'بداية الأسبوع', const [
                MapEntry('saturday', 'السبت'),
                MapEntry('sunday', 'الأحد'),
                MapEntry('monday', 'الاثنين'),
                MapEntry('tuesday', 'الثلاثاء'),
                MapEntry('wednesday', 'الأربعاء'),
                MapEntry('thursday', 'الخميس'),
                MapEntry('friday', 'الجمعة'),
              ]),
              setTile('financial_year_start', 'بداية السنة المالية (شهر-يوم)'),
              setTile('min_wait_days', 'الحد الأدنى لأيام الانتظار', true),
              boolTile('manager_override_required', 'اشتراط تجاوز المدير'),
              dropdownTile('absence_policy', 'سياسة الغياب', const [
                MapEntry('keep_order', 'إبقاء الدور'),
                MapEntry('postpone', 'نقل لآخر الدور'),
                MapEntry('cancel', 'إزالة من الدور'),
              ]),
              boolTile('allow_midnight_crossing', 'السماح بعبور منتصف الليل'),
            ],
          ),
          SettingGroup(
            title: 'قنوات الإشعارات وقوالبها',
            children: [
              boolTile('sound_notifications', 'التنبيهات الصوتية'),
              boolTile('popup_notifications', 'النوافذ المنبثقة'),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final ok = await DeviceNotificationSettings.open();
                  if (!ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'إعدادات إشعارات الجهاز متاحة على أندرويد من زر الإشعارات في إعدادات التطبيق.',
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('إدارة إشعارات التطبيق من إعدادات الجهاز'),
              ),
              setTile('notification_appointment_title', 'عنوان إشعار الموعد'),
              setTile('notification_appointment_body', 'نص إشعار الموعد'),
              setTile('notification_payment_title', 'عنوان إشعار الدفع'),
              setTile('notification_payment_body', 'نص إشعار الدفع'),
              setTile('notification_balance_title', 'عنوان إشعار الرصيد'),
              setTile('notification_balance_body', 'نص إشعار الرصيد'),
            ],
          ),
          SettingGroup(
            title: 'التنبيهات والتقارير',
            children: [
              if ((s['system_type'] ?? 'diesel') == 'diesel') ...[
                setTile('diesel_warning_percent', 'نسبة تنبيه الديزل', true),
                setTile(
                  'diesel_snooze_minutes',
                  'مدة تأجيل تنبيه الديزل بالدقائق',
                  true,
                ),
              ],
              setTile('pdf_rows', 'عدد الصفوف الافتراضي في التقرير', true),
              boolTile('reduced_motion', 'تقليل الحركة'),
            ],
          ),
        ],
      ),
    );
  }
}

class SettingGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const SettingGroup({required this.title, required this.children, super.key});
  IconData get _icon => switch (title) {
    'بيانات المحطة' => Icons.storefront_rounded,
    'المنظومة والتسعير' => Icons.price_change_rounded,
    'الطابور والجلسات' => Icons.alt_route_rounded,
    'قنوات الإشعارات وقوالبها' => Icons.notifications_active_rounded,
    _ => Icons.analytics_rounded,
  };
  @override
  Widget build(BuildContext c) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: _reportLine), boxShadow: [BoxShadow(color: _reportOlive.withValues(alpha: .05), blurRadius: 14, offset: const Offset(0, 5))]),
    child: Theme(data: Theme.of(c).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 4),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      leading: Container(width: 42, height: 42, decoration: BoxDecoration(color: _reportCream, borderRadius: BorderRadius.circular(13)), child: Icon(_icon, color: _reportOliveDark)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: _reportInk, fontSize: 16)),
      subtitle: Text('${children.length} إعداد', style: TextStyle(color: _reportInk.withValues(alpha: .52), fontSize: 10)),
      children: children,
    )),
  );
}

class PerformancePage extends StatefulWidget {
  final StationRepository r;
  const PerformancePage(this.r, {super.key});
  @override
  State<PerformancePage> createState() => _PerformanceState();
}

class _PerformanceState extends State<PerformancePage> {
  List<Map<String, Object?>> reports = [], metrics = [];
  Future<void> load() async {
    final a = await widget.r.db.query(
      'report_runs',
      orderBy: 'generated_at DESC',
      limit: 30,
    );
    final b = await widget.r.db.query(
      'performance_metrics',
      orderBy: 'opened_at DESC',
      limit: 30,
    );
    if (mounted) {
      setState(() {
        reports = a;
        metrics = b;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(c) => PageFrame(
    title: 'قياس الأداء',
    subtitle: 'زمن فتح الشاشة والاستعلام وإنشاء التقارير',
    actions: [
      OutlinedButton.icon(
        onPressed: load,
        icon: const Icon(Icons.refresh),
        label: const Text('تحديث'),
      ),
    ],
    child: ListView(
      children: [
        SectionCard(
          title: 'آخر التقارير',
          icon: Icons.picture_as_pdf,
          child: reports.isEmpty
              ? const EmptyView('لا توجد قياسات تقارير بعد')
              : Column(
                  children: [
                    for (final x in reports)
                      ListTile(
                        title: Text(
                          ReportService.titles['${x['report_key'] ?? ''}'] ??
                              'تقرير',
                        ),
                        subtitle: Text(
                          '${x['generated_at'] ?? '-'} • ${x['row_count'] ?? 0} صف',
                        ),
                        trailing: Text('${x['duration_ms'] ?? 0} مللي ثانية'),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'قياسات الشاشة والاستعلام',
          icon: Icons.speed,
          child: metrics.isEmpty
              ? const EmptyView('لا توجد قياسات شاشة بعد')
              : Column(
                  children: [
                    for (final x in metrics)
                      ListTile(
                        title: Text('فتح الشاشة: ${x['screen'] ?? '-'}'),
                        subtitle: Text(
                          '${x['opened_at'] ?? '-'} • استعلام ${x['query_ms'] ?? 0} مللي ثانية',
                        ),
                        trailing: Text('${x['open_ms'] ?? 0} مللي ثانية'),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}

class BackupPage extends StatefulWidget {
  final StationRepository r;
  const BackupPage(this.r, {super.key});
  @override
  State<BackupPage> createState() => _BackupState();
}
class _BackupState extends State<BackupPage> {
  List<Map<String, Object?>> history = [];
  Map<String, String> settings = {};
  bool busy = false;
  static const schemaVersion = 15;
  BackupService get service => BackupService(widget.r.accounting);
  Future<void> load() async {
    try {
      final h = await service.history();
      final cfg = await widget.r.settings();
      if (mounted) setState(() { history = h; settings = cfg; });
    } catch (e) { if (mounted) msg(friendlyError(e)); }
  }
  @override void initState() { super.initState(); load(); }
  Future<void> backup({bool saveToLocation = false}) async {
    setState(() => busy = true);
    try {
      if (saveToLocation) {
        final path = await service.saveBackupToLocation();
        if (path != null) msg('تم حفظ النسخة والتحقق منها بنجاح');
      } else {
        await service.createAndShare();
        msg('تم إنشاء النسخة والتحقق منها ومشاركتها');
      }
      await load();
    } catch (e) { msg(friendlyError(e)); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> restore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('تأكيد استعادة البيانات'),
        content: const Text('سيتم إنشاء نقطة رجوع تلقائية ثم استبدال قاعدة البيانات الحالية. يجب أن تكون النسخة من نفس نوع المنظومة الحالية. لا تستخدم ملف الاختبار على بيانات فعلية. هل تريد المتابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(d, true), style: FilledButton.styleFrom(backgroundColor: _reportOrange), child: const Text('استعادة الآن')),
        ],
      ),
    ) ?? false;
    if (!confirmed) return;
    setState(() => busy = true);
    try {
      final x = await service.pickAndRestoreDatabase();
      msg(x['restored'] == true ? 'تم الاسترجاع والتحقق بنجاح' : x['cancelled'] == true ? 'تم الإلغاء' : '${x['error'] ?? 'تعذر الاسترجاع'}');
      await load();
    } catch (e) { msg(friendlyError(e)); }
    finally { if (mounted) setState(() => busy = false); }
  }
  void msg(String x) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x))); }
  Widget _badge(IconData icon, String title, String value, Color color) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(19), border: Border.all(color: _reportLine)),
    child: Row(children: [Container(width: 39, height: 39, decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 21)), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: _reportInk.withValues(alpha: .55), fontSize: 10)), const SizedBox(height: 3), Text(value, style: const TextStyle(color: _reportInk, fontWeight: FontWeight.w900, fontSize: 13))]))]),
  );
  Widget _historyCard(Map<String, Object?> x) {
    final restored = '${x['status']}' == 'restored';
    return Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: _reportLine)), child: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: (restored ? _reportOrange : _reportGreen).withValues(alpha: .12), borderRadius: BorderRadius.circular(13)), child: Icon(restored ? Icons.restore_rounded : Icons.verified_rounded, color: restored ? _reportOrange : _reportGreen)), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(restored ? 'استعادة نسخة' : 'نسخة احتياطية منشأة', style: const TextStyle(fontWeight: FontWeight.w900, color: _reportInk)), const SizedBox(height: 4), Text('${x['created_at'] ?? ''}', style: TextStyle(color: _reportInk.withValues(alpha: .58), fontSize: 10)), if ('${x['notes'] ?? ''}'.trim().isNotEmpty) Text('${x['notes']}', style: TextStyle(color: _reportInk.withValues(alpha: .5), fontSize: 10))])), const Icon(Icons.chevron_left_rounded, color: _reportOliveDark)]));
  }
  @override Widget build(BuildContext c) {
    final type = settings['system_type'] ?? 'diesel';
    final station = settings['station_name'] ?? 'المحطة الحالية';
    return PageFrame(title: 'النسخ الاحتياطي والاستعادة', subtitle: 'نسخ SQLite واستعادتها مع التحقق من سلامة الملف', child: ListView(children: [
      Container(padding: const EdgeInsets.all(21), decoration: BoxDecoration(gradient: const LinearGradient(colors: [_reportOliveDark, _reportOlive]), borderRadius: BorderRadius.circular(27)), child: Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(station, style: TextStyle(color: Colors.white.withValues(alpha: .72), fontSize: 12)), const SizedBox(height: 6), const Text('مركز حماية البيانات', style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w900)), const SizedBox(height: 7), Text('كل نسخة تحمل هوية منظومة ${systemName(type)} ولا تُستعاد على منظومة مختلفة', style: TextStyle(color: Colors.white.withValues(alpha: .84), fontSize: 11))])), Container(width: 61, height: 61, decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), borderRadius: BorderRadius.circular(20)), child: const Icon(Icons.shield_rounded, color: Colors.white, size: 34))])),
      const SizedBox(height: 14),
      GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 2.45, children: [_badge(Icons.lock_rounded, 'نوع المنظومة', systemName(type), _reportOliveDark), _badge(Icons.schema_rounded, 'إصدار قاعدة البيانات', '$schemaVersion', _blue), _badge(Icons.verified_user_rounded, 'حالة القفل', 'ثابت بعد التثبيت', _reportGreen), _badge(Icons.history_rounded, 'العمليات المسجلة', '${history.length}', _reportOrange)]),
      const SizedBox(height: 14),
      Container(padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: _reportLine)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Icon(Icons.backup_rounded, color: _reportOliveDark), const SizedBox(width: 8), const Text('إدارة النسخ', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: _reportInk)), const Spacer(), if (busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))]), const SizedBox(height: 8), Text('أنشئ نسخة قبل تحديث التطبيق أو صيانة قاعدة البيانات. يتم فحص سلامة SQLite والجداول والعلاقات قبل اعتماد النسخة.', style: TextStyle(color: _reportInk.withValues(alpha: .62), fontSize: 11, height: 1.45)), const SizedBox(height: 14), Wrap(spacing: 9, runSpacing: 9, children: [FilledButton.icon(onPressed: busy ? null : () => backup(), icon: const Icon(Icons.share_rounded), label: const Text('إنشاء ومشاركة')), OutlinedButton.icon(onPressed: busy ? null : () => backup(saveToLocation: true), icon: const Icon(Icons.save_alt_rounded), label: const Text('حفظ في الجهاز')), OutlinedButton.icon(onPressed: busy ? null : restore, style: OutlinedButton.styleFrom(foregroundColor: _reportOrange), icon: const Icon(Icons.restore_rounded), label: const Text('استعادة نسخة'))])])),
      const SizedBox(height: 14),
      Container(padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: _reportOrange.withValues(alpha: .08), borderRadius: BorderRadius.circular(19), border: Border.all(color: _reportOrange.withValues(alpha: .22))), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.warning_amber_rounded, color: _reportOrange), const SizedBox(width: 9), Expanded(child: Text('الاستعادة تستبدل البيانات الحالية بعد إنشاء نقطة رجوع تلقائية. لا يمكن استعادة نسخة من نوع منظومة مختلف.', style: TextStyle(color: _reportInk.withValues(alpha: .75), fontSize: 11, fontWeight: FontWeight.w800, height: 1.45)))])),
      const SizedBox(height: 20),
      Row(children: [const Icon(Icons.history_rounded, color: _reportOliveDark), const SizedBox(width: 8), const Text('سجل العمليات', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: _reportInk)), const Spacer(), IconButton(onPressed: busy ? null : load, icon: const Icon(Icons.refresh_rounded))]),
      const SizedBox(height: 8),
      if (history.isEmpty) const EmptyView('لا توجد عمليات نسخ أو استعادة بعد') else ...[for (final x in history.take(50)) _historyCard(x)],
    ]));
  }
}
