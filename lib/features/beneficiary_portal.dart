import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../services/report_service.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';
import '../services/local_beneficiary_auth_service.dart';
import 'beneficiary_general_accounts_page.dart';

class BeneficiaryLoginPage extends StatefulWidget {
  const BeneficiaryLoginPage({super.key});
  @override
  State<BeneficiaryLoginPage> createState() => _BeneficiaryLoginPageState();
}

class _BeneficiaryLoginPageState extends State<BeneficiaryLoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _auth = LocalBeneficiaryAuthService();
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final ok = await _auth.login(_username.text, _password.text);
      if (!mounted) return;
      if (!ok) {
        setState(() => _error = 'اسم المستخدم أو كلمة المرور غير صحيحة، أو أن الحساب غير نشط.');
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => BeneficiaryHomePage(auth: _auth)),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر تسجيل الدخول حاليًا. حاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('دخول المستفيد')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.water_drop_rounded, size: 54),
                    const SizedBox(height: 12),
                    const Text('بوابة المستفيد', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text('تابع رصيدك وطلبات السقي من مكان واحد',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 22),
                    TextField(
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'اسم المستخدم',
                        prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: _obscurePassword,
                      onSubmitted: (_) => _login(),
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword ? 'إظهار كلمة المرور' : 'إخفاء كلمة المرور',
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _login,
                      icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login_rounded),
                      label: Text(_busy ? 'جارٍ التحقق…' : 'تسجيل الدخول'),
                    ),
                    const SizedBox(height: 10),
                    const Text('بيانات الدخول ينشئها مدير المحطة. إذا لم تستلمها، تواصل مع الإدارة.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
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

class BeneficiaryHomePage extends StatefulWidget {
  const BeneficiaryHomePage({required this.auth, super.key});
  final LocalBeneficiaryAuthService auth;
  @override
  State<BeneficiaryHomePage> createState() => _BeneficiaryHomePageState();
}

class _BeneficiaryHomePageState extends State<BeneficiaryHomePage> {
  late final StationRepository _repo;
  Map<String, Object?>? _beneficiary;
  List<Map<String, Object?>> _statement = [];
  List<Map<String, Object?>> _irrigations = [];
  List<Map<String, Object?>> _bookings = [];
  List<Map<String, Object?>> _bookingQueue = [];
  List<Map<String, Object?>> _notifications = [];
  List<Map<String, Object?>> _errorReports = [];
  int? _beneficiaryId;
  int _tab = 0;
  bool _loading = true;
  bool _savingBooking = false;
  String? _error;
  String _diagnosticStage = 'تهيئة بوابة المستفيد';

  @override
  void initState() {
    super.initState();
    // Share the exact database instance used by local authentication.
    _repo = StationRepository(widget.auth.db);
    _load();
  }

  String _date(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return 'غير محدد';
    final day = parsed.day.toString().padLeft(2, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '$day/$month/${parsed.year} • $hour:$minute';
  }

  int get _balance {
    // beneficiaryDetails returns the accounting balance summary map:
    // {balance, due, credit}; the numeric value is nested under "balance".
    final summary = _beneficiary?['balance'];
    final value = summary is Map ? summary['balance'] : summary;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
  int get _irrigationCount => _statement.where((row) => row['type'] == 's').length;
  int get _totalMinutes => _statement.fold<int>(0,
    (sum, row) => sum + (row['type'] == 's' ? ((row['minutes'] as num?)?.round() ?? 0) : 0));
  int get _unreadCount => _notifications.where((row) => row['read_at'] == null).length;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      _diagnosticStage = 'المرحلة 1: قراءة جلسة المستفيد';
      final id = await widget.auth.currentBeneficiaryId();
      if (id == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'انتهت جلسة الدخول أو تم تعطيل الحساب. سجّل الدخول مرة أخرى.';
          });
        }
        return;
      }
      _diagnosticStage = 'المرحلة 2: تحميل بيانات المستفيد';
      final details = await _repo.beneficiaryDetails(id);
      _diagnosticStage = 'المرحلة 3: تحميل كشف الحساب';
      final statement = await _repo.beneficiaryStatement(id);
      _diagnosticStage = 'المرحلة 3: تحميل تسقيات المستفيد';
      final irrigations = await _repo.irrigations(beneficiaryId: id);
      _diagnosticStage = 'المرحلة 4: تحميل طلبات الحجز';
      final bookings = await _repo.beneficiaryBookings(id);
      _diagnosticStage = 'المرحلة 4: تحميل ترتيب الحجوزات';
      final bookingQueue = await _repo.activeBookingQueue();
      _diagnosticStage = 'المرحلة 5: تحميل الإشعارات';
      final notifications = await _repo.notifications(beneficiaryId: id);
      final errorReports = await _repo.beneficiaryErrorReports(id);
      _diagnosticStage = 'المرحلة 6: تجهيز واجهة المستفيد';
      final values = <dynamic>[details, statement, irrigations, bookings, bookingQueue, notifications, errorReports];
      if (!mounted) return;
      setState(() {
        _beneficiaryId = id;
        _beneficiary = values[0] as Map<String, Object?>;
        _statement = (values[1] as List).cast<Map<String, Object?>>();
        _irrigations = (values[2] as List).cast<Map<String, Object?>>();
        _bookings = (values[3] as List).cast<Map<String, Object?>>();
        _bookingQueue = (values[4] as List).cast<Map<String, Object?>>();
        _notifications = (values[5] as List).cast<Map<String, Object?>>();
        _errorReports = (values[6] as List).cast<Map<String, Object?>>();
        _loading = false;
      });
    } catch (error, stackTrace) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر تحميل بوابة المستفيد.\n$_diagnosticStage\n$error\n\n$stackTrace';
        });
      }
    }
  }

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<int> _requireCurrentBeneficiary() async {
    final current = await widget.auth.currentBeneficiaryId();
    if (current == null || current != _beneficiaryId) {
      throw StateError('انتهت جلسة الدخول. سجّل الدخول مرة أخرى.');
    }
    return current;
  }

  Future<void> _createBooking() async {
    if (_beneficiaryId == null || _savingBooking) return;
    final controller = TextEditingController();
    final notes = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('طلب حجز سقي'),
        content: TextField(controller: controller, autofocus: true, minLines: 2, maxLines: 4,
          decoration: const InputDecoration(labelText: 'ملاحظات الطلب',
            hintText: 'اكتب أي تفاصيل تريد إبلاغ المحطة بها', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('إرسال الطلب')),
        ],
      ),
    );
    controller.dispose();
    if (notes == null) return;
    setState(() => _savingBooking = true);
    try {
      final ownerId = await _requireCurrentBeneficiary();
      await _repo.createBeneficiaryBooking(ownerId, notes);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال طلب الحجز إلى المحطة')));
      setState(() => _tab = 2);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _savingBooking = false);
    }
  }

  Future<void> _cancelBooking(Map<String, Object?> booking) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إلغاء طلب الحجز'),
        content: const Text('هل تريد إلغاء هذا الطلب؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('تراجع')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('تأكيد الإلغاء')),
        ],
      ),
    );
    if (confirmed != true || _beneficiaryId == null) return;
    try {
      final ownerId = await _requireCurrentBeneficiary();
      await _repo.cancelBeneficiaryBooking((booking['id'] as num).toInt(), ownerId);
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    }
  }

  Future<void> _readNotification(Map<String, Object?> notification) async {
    if (_beneficiaryId == null || notification['read_at'] != null) return;
    try {
      final ownerId = await _requireCurrentBeneficiary();
      await _repo.markBeneficiaryNotificationRead((notification['id'] as num).toInt(), ownerId);
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    }
  }

  String _bookingStatus(Object? value) => switch ('$value') {
    'new' => 'طلب جديد',
    'under_review' => 'قيد المراجعة',
    'scheduled' => 'تم تحديد الموعد',
    'accepted' => 'مقبول',
    'notified' => 'تم إشعارك',
    'completed' => 'مكتمل',
    'cancelled' => 'ملغى',
    _ => 'غير محدد',
  };

  Widget _sectionTitle(String title, {String? subtitle}) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      if (subtitle != null) ...[
        const SizedBox(height: 3),
        Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    ]),
  );

  Widget _metric(String label, String value, IconData icon) => Expanded(
    child: Card(child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
      child: Column(children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        const SizedBox(height: 4),
        Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
      ]),
    )),
  );

  Widget _balanceCard() => Card(
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('رصيد حسابك الحالي', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(AccountingCalculations.balanceLabel(_balance),
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900,
            color: _balance == 0 ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: 5),
        Text('يتم احتساب الرصيد من الحركات المسجلة في حسابك',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    ),
  );

  Future<void> _exportAccountStatementPdf() async {
    try {
      final ownerId = await _requireCurrentBeneficiary();
      final bytes = await ReportService(_repo).pdf(
        'beneficiary_detailed',
        beneficiaryId: ownerId,
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إنشاء كشف الحساب: ${error.toString().replaceFirst('Bad state: ', '')}')),
        );
      }
    }
  }

  Future<void> _exportMovementPdf(Map<String, Object?> row) async {
    try {
      final ownerId = await _requireCurrentBeneficiary();
      final type = '${row['type'] ?? ''}';
      final movementId = (row['id'] as num?)?.toInt() ?? int.tryParse('${row['id'] ?? ''}') ?? 0;
      if (movementId <= 0) throw StateError('لا يوجد مستند لهذه الحركة');
      final report = ReportService(_repo);
      Uint8List bytes;
      if (type == 's') {
        // لا نسمح بطباعة فاتورة إلا بعد التأكد أن السقاية تخص صاحب الجلسة.
        final ownRows = await _repo.irrigations(beneficiaryId: ownerId);
        Map<String, Object?>? ownRow;
        for (final item in ownRows) {
          if (((item['id'] as num?)?.toInt() ?? -1) == movementId) {
            ownRow = item;
            break;
          }
        }
        if (ownRow == null) throw StateError('السقاية غير موجودة في حسابك');
        bytes = await report.invoicesPdf(rows: [{
          ...ownRow,
          'invoice_id': movementId,
          'party_name': _beneficiary?['name'] ?? ownRow['beneficiary_name'] ?? 'المستفيد',
        }]);
      } else if (type == 'p') {
        // سند القبض يقبل فقط دفعة مرتبطة بمعرّف المستفيد الحالي.
        final payment = await _repo.db.rawQuery(
          "SELECT id FROM payments WHERE id=? AND beneficiary_id=? AND status='posted' LIMIT 1",
          [movementId, ownerId],
        );
        if (payment.isEmpty) throw StateError('سند القبض غير موجود في حسابك');
        bytes = await report.paymentReceiptPdf(movementId);
      } else {
        throw StateError('لا يتوفر قالب مستند منفصل لهذا النوع من الحركات');
      }
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إصدار المستند: ${error.toString().replaceFirst('Bad state: ', '')}')),
        );
      }
    }
  }

  String _reportStatus(Object? value) => switch ('$value') {
    'new' => 'بلاغ جديد', 'under_review' => 'قيد المراجعة',
    'accepted' => 'تم قبول البلاغ', 'rejected' => 'تم رفض البلاغ',
    'resolved' => 'تم الحل', _ => 'غير معروف',
  };

  Future<void> _reportMovement(Map<String, Object?> row) async {
    final type = '${row['type'] ?? ''}';
    final isIrrigation = type == 's';
    final category = ValueNotifier<String>(isIrrigation ? 'المبلغ غير صحيح' : 'القبض غير صحيح');
    final description = TextEditingController();
    final categories = isIrrigation ? ['المبلغ غير صحيح','الوقت غير صحيح','السقاية غير مسجلة أو مكررة','أخرى'] : ['القبض غير صحيح','المبلغ غير صحيح','السند غير مسجل أو مكرر','أخرى'];
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(isIrrigation ? 'الإبلاغ عن خطأ في السقاية' : 'الإبلاغ عن خطأ في سند القبض'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<String>(valueListenable: category, builder: (_, value, __) =>
          DropdownButtonFormField<String>(value: value, isExpanded: true,
            items: categories.map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
            onChanged: (v) { if (v != null) category.value = v; }, decoration: const InputDecoration(labelText: 'نوع الخطأ'))),
        const SizedBox(height: 12), TextField(controller: description, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'اشرح الخطأ', border: OutlineInputBorder())),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال البلاغ'))],
    ));
    final categoryValue = category.value; category.dispose();
    if (accepted != true) { description.dispose(); return; }
    if (description.text.trim().isEmpty) { description.dispose(); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اكتب وصفاً للخطأ'))); return; }
    try {
      final ownerId = await _requireCurrentBeneficiary();
      await _repo.createBeneficiaryErrorReport(beneficiaryId: ownerId, movementType: isIrrigation ? 'irrigation' : 'payment', movementId: (row['id'] as num).toInt(), category: categoryValue, description: description.text.trim());
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال البلاغ إلى إدارة المحطة')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', '')))); }
    finally { description.dispose(); }
  }
  Widget _movementTile(Map<String, Object?> row) {
    final debit = (row['debit'] as num?)?.round() ?? 0;
    final credit = (row['credit'] as num?)?.round() ?? 0;
    final balance = (row['balance'] as num?)?.round() ?? 0;
    final amount = debit > 0 ? debit : credit;
    final isDebit = debit > 0;
    final type = '${row['type'] ?? ''}';
    final hasDocument = type == 's' || type == 'p';
    final reportType = type == 's' ? 'irrigation' : 'payment';
    final reportId = (row['id'] as num?)?.toInt() ?? -1;
    final reports = _errorReports.where((r) => r['movement_type'] == reportType && (r['movement_id'] as num?)?.toInt() == reportId).toList()
      ..sort((a, b) {
        final aDate = DateTime.tryParse('${a['created_at'] ?? ''}') ?? DateTime(1970);
        final bDate = DateTime.tryParse('${b['created_at'] ?? ''}') ?? DateTime(1970);
        return bDate.compareTo(aDate);
      });
    final report = reports.isEmpty ? null : reports.first;
    final reportIsOpen = report != null && const {'new', 'under_review'}.contains(report['status']);
    return Card(child: ListTile(
      leading: CircleAvatar(child: Icon(isDebit ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)),
      title: Text((row['description'] ?? 'حركة حساب').toString()),
      subtitle: Text(_date(row['date'])),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${isDebit ? '+' : '-'}$amount ريال',
            style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(AccountingCalculations.balanceLabel(balance),
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        if (hasDocument && report != null)
          IconButton(tooltip: _reportStatus(report['status']), onPressed: () => showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: Text(_reportStatus(report['status'])), content: Text('التصنيف: ${report['category']}\n${report['description']}\n\nرد الإدارة: ${report['admin_reply'] ?? 'لم ترد الإدارة بعد'}'), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))])), icon: const Icon(Icons.mark_email_read_outlined)),
        if (hasDocument && !reportIsOpen)
          IconButton(tooltip: report == null ? 'الإبلاغ عن خطأ' : 'إرسال بلاغ جديد بعد إغلاق البلاغ السابق', onPressed: () => _reportMovement(row), icon: const Icon(Icons.flag_outlined)),
        if (hasDocument)
          IconButton(
            tooltip: type == 's' ? 'طباعة فاتورة السقاية' : 'طباعة سند القبض',
            visualDensity: VisualDensity.compact,
            onPressed: () => _exportMovementPdf(row),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
      ]),
    ));
  }

  Widget _homeTab() {
    final name = (_beneficiary?['name'] ?? 'المستفيد').toString();
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          const CircleAvatar(radius: 25, child: Icon(Icons.person_outline_rounded, size: 28)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('مرحبًا، $name', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text((_beneficiary?['phone'] ?? 'حساب المستفيد').toString(),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])),
        ]),
      )),
      _balanceCard(),
      Row(children: [
        _metric('السقايات', _irrigationCount.toString(), Icons.water_drop_outlined),
        _metric('الدقائق', _totalMinutes.toString(), Icons.timer_outlined),
        _metric('طلبات الحجز', _bookings.length.toString(), Icons.event_note_outlined),
      ]),
      const SizedBox(height: 10),
      _bookingQueueOverview(),
      const SizedBox(height: 10),
      _allBookedBeneficiaries(),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _savingBooking ? null : _createBooking,
        icon: const Icon(Icons.add_circle_outline),
        label: Text(_savingBooking ? 'جارٍ إرسال الطلب…' : 'طلب حجز سقي')),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _sectionTitle('آخر الحركات')),
        TextButton(onPressed: () => setState(() => _tab = 1), child: const Text('كشف الحساب')),
      ]),
      if (_statement.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('لا توجد حركات مسجلة حتى الآن.')))
      else
        for (final row in _statement.reversed.take(4)) _movementTile(row),
      Row(children: [
        Expanded(child: _sectionTitle('الإشعارات')),
        TextButton(onPressed: () => setState(() => _tab = 3),
          child: Text(_unreadCount == 0 ? 'عرض الكل' : 'غير مقروء: $_unreadCount')),
      ]),
      if (_notifications.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('لا توجد إشعارات.')))
      else
        for (final item in _notifications.take(3))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(item['read_at'] == null ? Icons.notifications_active_outlined : Icons.notifications_none),
            title: Text((item['title'] ?? 'إشعار').toString()),
            subtitle: Text((item['body'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () { setState(() => _tab = 3); _readNotification(item); },
          ),
    ]);
  }

  Widget _accountTab() => ListView(physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16), children: [
      _balanceCard(),
      Row(children: [
        Expanded(child: _sectionTitle('كشف الحساب', subtitle: 'الحركات المالية المسجلة على حسابك')),
        IconButton(
          tooltip: 'تصدير كشف الحساب PDF',
          onPressed: _statement.isEmpty ? null : _exportAccountStatementPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
        ),
      ]),
      if (_statement.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('لا توجد حركات مسجلة.')))
      else
        for (final row in _statement.reversed) _movementTile(row),
    ]);

  String _irrigationTime(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return '-';
    return '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }

  String _irrigationCloudStatus(Object? value) =>
      value == 'discounted' ? 'تم خصم الغيم' : 'لا يوجد خصم';

  Future<void> _exportMyIrrigationsPdf() async {
    try {
      final ownerId = await _requireCurrentBeneficiary();
      final rows = await _repo.irrigations(beneficiaryId: ownerId);
      final bytes = await ReportService(_repo).pdf(
        'irrigations',
        beneficiaryId: ownerId,
        sourceRows: rows,
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إنشاء كشف التسقيات: ${error.toString().replaceFirst('Bad state: ', '')}')),
        );
      }
    }
  }

  Widget _irrigationsTab() {
    const headers = [
      'الجهة', 'من', 'إلى', 'إجمالي الدقائق', 'المدفوع',
      'القيمة الإجمالية', 'الغيم', 'حالة الخصم',
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(child: _sectionTitle('تسقياتي',
            subtitle: 'السقايات المسجلة على حسابك فقط')),
          IconButton(
            tooltip: 'تصدير كشف التسقيات PDF',
            onPressed: _irrigations.isEmpty ? null : _exportMyIrrigationsPdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
        ]),
        Card(child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            _metric('عدد السقايات', _irrigations.length.toString(), Icons.water_drop_outlined),
            _metric('إجمالي الدقائق',
              _irrigations.fold<int>(0, (sum, row) => sum + ((row['minutes'] as num?)?.round() ?? 0)).toString(),
              Icons.timer_outlined),
          ]),
        )),
        if (_irrigations.isEmpty)
          const Card(child: Padding(
            padding: EdgeInsets.all(18),
            child: Text('لا توجد سقايات مسجلة على حسابك حتى الآن.'),
          ))
        else
          Card(child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: headers.map((label) => DataColumn(
                label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
              )).toList(),
              rows: _irrigations.map((row) => DataRow(cells: [
                DataCell(Text((row['party_name'] ?? row['beneficiary_name'] ?? _beneficiary?['name'] ?? '').toString())),
                DataCell(Text(_irrigationTime(row['start_datetime']))),
                DataCell(Text(_irrigationTime(row['end_datetime']))),
                DataCell(Text('${row['minutes'] ?? 0} د')),
                DataCell(Text('${row['paid_amount'] ?? 0}')),
                DataCell(Text('${row['total_amount'] ?? 0}')),
                DataCell(Text('${row['cloud_minutes'] ?? 0} د')),
                DataCell(Text(_irrigationCloudStatus(row['cloud_status']))),
              ])).toList(),
            ),
          )),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _irrigations.isEmpty ? null : _exportMyIrrigationsPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('تصدير كشف التسقيات PDF'),
        ),
      ],
    );
  }

  Widget _bookingQueueOverview() {
    final ownIndex = _bookingQueue.indexWhere(
      (item) => (item['beneficiary_id'] as num?)?.toInt() == _beneficiaryId,
    );
    if (ownIndex < 0) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded),
            const SizedBox(width: 10),
            Expanded(child: Text(
              _bookingQueue.isEmpty
                ? 'لا توجد حجوزات نشطة في قائمة المحطة حاليًا.'
                : 'لا يوجد لك حجز نشط في قائمة الانتظار حاليًا. عند اعتماد طلبك سيظهر موقعك هنا.',
            )),
          ]),
        ),
      );
    }
    final current = _bookingQueue[ownIndex];
    final ahead = ownIndex;
    final behind = _bookingQueue.length - ownIndex - 1;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.confirmation_number_outlined),
            const SizedBox(width: 8),
            const Expanded(child: Text('موقعك في ترتيب الحجوزات',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
            Chip(label: Text('رقم ${ownIndex + 1} من ${_bookingQueue.length}')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _metric('أمامك', '$ahead', Icons.people_alt_outlined)),
            Expanded(child: _metric('خلفك', '$behind', Icons.groups_outlined)),
          ]),
          const SizedBox(height: 8),
          Text('حالة حجزك: ${_bookingStatus(current['status'])}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
          if (current['scheduled_start'] != null)
            Text('موعدك المحدد: ${_date(current['scheduled_start'])}'),

        ]),
      ),
    );
  }

  Widget _allBookedBeneficiaries() {
    final ownIndex = _bookingQueue.indexWhere(
      (item) => (item['beneficiary_id'] as num?)?.toInt() == _beneficiaryId,
    );

    Widget personTile(int index) {
      final item = _bookingQueue[index];
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsetsDirectional.only(start: 8),
        leading: CircleAvatar(child: Text('${index + 1}')),
        title: Text(item['beneficiary_name']?.toString() ?? 'مستفيد',
          style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${_bookingStatus(item['status'])}'
          ' • ${item['scheduled_start'] == null ? 'بانتظار تحديد الموعد' : _date(item['scheduled_start'])}',
        ),
        trailing: Text('#${index + 1}'),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('ترتيب جميع المستفيدين حول موقعك',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_bookingQueue.isEmpty)
            const Text('لا توجد حجوزات نشطة.')
          else if (ownIndex < 0) ...[
            const Text('قائمة الحجوزات النشطة في المحطة:'),
            for (var i = 0; i < _bookingQueue.length; i++) personTile(i),
          ] else ...[
            Row(children: [
              const Icon(Icons.people_alt_outlined),
              const SizedBox(width: 6),
              Text('جميع المستفيدين قبلك ($ownIndex)',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            if (ownIndex == 0)
              const Padding(padding: EdgeInsets.all(10),
                child: Text('لا يوجد مستفيد قبلك؛ أنت في بداية الترتيب.'))
            else
              for (var i = 0; i < ownIndex; i++) personTile(i),
            const Divider(height: 20),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_pin_circle)),
                title: Text('${_bookingQueue[ownIndex]['beneficiary_name'] ?? 'أنت'} (أنت)',
                  style: const TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text('موقعك رقم ${ownIndex + 1} من ${_bookingQueue.length}'),
                trailing: const Icon(Icons.my_location),
              ),
            ),
            const Divider(height: 20),
            Row(children: [
              const Icon(Icons.groups_outlined),
              const SizedBox(width: 6),
              Text('جميع المستفيدين بعدك (${_bookingQueue.length - ownIndex - 1})',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            if (ownIndex == _bookingQueue.length - 1)
              const Padding(padding: EdgeInsets.all(10),
                child: Text('لا يوجد مستفيد بعدك؛ أنت في نهاية الترتيب.'))
            else
              for (var i = ownIndex + 1; i < _bookingQueue.length; i++) personTile(i),
          ],
        ]),
      ),
    );
  }

  Widget _bookingsTab() => ListView(physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: _sectionTitle('طلباتي', subtitle: 'تابع حالة طلبات الحجز ومواعيد السقي')),
        IconButton(tooltip: 'تحديث', onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
      ]),
      FilledButton.icon(onPressed: _savingBooking ? null : _createBooking,
        icon: const Icon(Icons.add), label: const Text('طلب حجز جديد')),
      const SizedBox(height: 12),
      if (_bookings.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(20), child: Text('لا توجد طلبات حجز حتى الآن.')))
      else
        for (final booking in _bookings)
          Card(child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.event_note_outlined),
                const SizedBox(width: 8),
                Expanded(child: Text('طلب رقم ${booking['id'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800))),
                Chip(label: Text(_bookingStatus(booking['status']))),
              ]),
              const SizedBox(height: 6),
              Text((booking['notes'] ?? 'دون ملاحظات').toString()),
              const SizedBox(height: 6),
              Text('تاريخ الطلب: ${_date(booking['created_at'])}'),
              if (booking['scheduled_start'] != null)
                Text('موعد السقي: ${_date(booking['scheduled_start'])}'),
              if (booking['cancel_reason'] != null && booking['cancel_reason'].toString().isNotEmpty)
                Text('ملاحظة الإلغاء: ${booking['cancel_reason']}'),
              if (booking['status'] == 'new' || booking['status'] == 'under_review')
                Align(alignment: Alignment.centerLeft,
                  child: TextButton.icon(onPressed: () => _cancelBooking(booking),
                    icon: const Icon(Icons.cancel_outlined), label: const Text('إلغاء الطلب'))),
            ]),
          )),
    ]);

  Widget _notificationsTab() => ListView(physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16), children: [
      _sectionTitle('الإشعارات', subtitle: '$_unreadCount إشعار غير مقروء'),
      if (_notifications.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(20), child: Text('لا توجد إشعارات حاليًا.')))
      else
        for (final item in _notifications)
          Card(child: ListTile(
            leading: CircleAvatar(child: Icon(item['read_at'] == null
              ? Icons.mark_email_unread_outlined : Icons.drafts_outlined)),
            title: Text((item['title'] ?? 'إشعار').toString()),
            subtitle: Text('${(item['body'] ?? '').toString()}\n${_date(item['created_at'])}'),
            isThreeLine: true,
            trailing: item['read_at'] == null ? const Icon(Icons.circle, size: 9) : null,
            onTap: () => _readNotification(item),
          )),
    ]);


  Future<void> _editMyProfile() async {
    final ownerId = await _requireCurrentBeneficiary();
    final current = _beneficiary ?? <String, Object?>{};
    final name = TextEditingController(text: '${current['name'] ?? ''}');
    final phone = TextEditingController(text: '${current['phone'] ?? ''}');
    final address = TextEditingController(text: '${current['address'] ?? ''}');
    final location = TextEditingController(text: '${current['location'] ?? ''}');
    final jerba = TextEditingController(text: '${current['jerba_number'] ?? ''}');
    final area = TextEditingController(text: '${current['area'] ?? ''}');
    final notes = TextEditingController(text: '${current['notes'] ?? ''}');
    final formKey = GlobalKey<FormState>();
    final values = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تعديل بياناتي'),
          content: SizedBox(width: 440, child: SingleChildScrollView(
            child: Form(key: formKey, child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(controller: name, decoration: const InputDecoration(labelText: 'الاسم'), validator: (v) => v == null || v.trim().isEmpty ? 'الاسم مطلوب' : null),
              TextFormField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')),
              TextFormField(controller: address, decoration: const InputDecoration(labelText: 'العنوان')),
              TextFormField(controller: location, decoration: const InputDecoration(labelText: 'الموقع')),
              TextFormField(controller: jerba, decoration: const InputDecoration(labelText: 'رقم الجربة')),
              TextFormField(controller: area, decoration: const InputDecoration(labelText: 'المنطقة')),
              TextFormField(controller: notes, minLines: 2, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات')),
            ])),
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, <String, Object?>{
                  'name': name.text.trim(),
                  'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
                  'address': address.text.trim().isEmpty ? null : address.text.trim(),
                  'location': location.text.trim().isEmpty ? null : location.text.trim(),
                  'jerba_number': jerba.text.trim().isEmpty ? null : jerba.text.trim(),
                  'area': area.text.trim().isEmpty ? null : area.text.trim(),
                  'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
                });
              }
            }, child: const Text('حفظ التعديلات')),
          ],
        ),
      ),
    );
    for (final c in [name, phone, address, location, jerba, area, notes]) { c.dispose(); }
    if (values == null) return;
    try {
      await _repo.updateBeneficiaryPersonalProfile(ownerId, values);
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تحديث بياناتك بنجاح')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))));
    }
  }

  Future<void> _changeMyPassword() async {
    final oldPassword = TextEditingController();
    final newPassword = TextEditingController();
    final confirm = TextEditingController();
    bool obscure = true;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, refresh) =>
        Directionality(textDirection: TextDirection.rtl, child: AlertDialog(
          title: const Text('تغيير كلمة المرور'),
          content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: oldPassword, obscureText: obscure, decoration: const InputDecoration(labelText: 'كلمة المرور الحالية')),
            TextField(controller: newPassword, obscureText: obscure, decoration: const InputDecoration(labelText: 'كلمة المرور الجديدة (10 أحرف على الأقل)')),
            TextField(controller: confirm, obscureText: obscure, decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور الجديدة')),
            TextButton.icon(onPressed: () => refresh(() => obscure = !obscure),
              icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              label: Text(obscure ? 'إظهار كلمات المرور' : 'إخفاء كلمات المرور')),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(onPressed: () {
              if (newPassword.text.length < 10) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('كلمة المرور يجب ألا تقل عن 10 أحرف')));
                return;
              }
              if (newPassword.text != confirm.text) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تأكيد كلمة المرور غير مطابق')));
                return;
              }
              Navigator.pop(dialogContext, [oldPassword.text, newPassword.text]);
            }, child: const Text('تغيير كلمة المرور')),
          ],
        )),
      ),
    );
    oldPassword.dispose(); newPassword.dispose(); confirm.dispose();
    if (result == null) return;
    try {
      await widget.auth.changeCurrentBeneficiaryPassword(currentPassword: result[0], newPassword: result[1]);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تغيير كلمة المرور بنجاح')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))));
    }
  }

  Future<void> _showStationSwitcher() async {
    try {
      // المرحلة المحلية تعرض المحطة الفعلية المرتبط بها سجل المستفيد.
      // لا ننشئ مشاريع وهمية ولا نسمح بتبديل station_id قبل وجود عضويات موثقة.
      final ownerId = await _requireCurrentBeneficiary();
      final rows = await _repo.rawQuery(
        '''SELECT s.id, s.name, s.address
           FROM stations s
           JOIN beneficiaries b ON b.station_id=s.id
           WHERE b.id=? AND s.active=1
           LIMIT 1''',
        [ownerId],
      );
      if (!mounted) return;
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر تحديد المحطة المرتبط بها حسابك')),
        );
        return;
      }
      final station = rows.first;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('المحطة / المشروع الحالي'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.water_drop_rounded),
                  title: Text('${station['name'] ?? 'محطة بدون اسم'}'),
                  subtitle: Text('المشروع المرتبط بحسابك حاليًا'),
                  trailing: const Icon(Icons.check_circle, color: Colors.green),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'يمكنك لاحقًا اختيار مشروع آخر مثل البركة أو الثراء إذا كان حسابك مرتبطًا به. '
                'في النسخة المحلية الحالية، تسجيل الدخول وقاعدة البيانات يعملان على محطة واحدة فقط. '
                'سيُفعّل التبديل عند ربط Firebase والتحقق من عضويتك في كل مشروع، حتى لا تختلط الحسابات أو تظهر بيانات مشروع غير مصرح به.',
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('تم'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر عرض المحطة: ${error.toString().replaceFirst('Bad state: ', '')}')),
        );
      }
    }
  }

  Widget _settingsTab() => ListView(padding: const EdgeInsets.all(16), children: [
    _sectionTitle('الإعدادات', subtitle: 'إدارة بياناتك وحماية حسابك'),
    Card(child: Column(children: [
      ListTile(leading: const Icon(Icons.person_outline), title: const Text('البيانات الشخصية'),
        subtitle: const Text('تعديل الاسم والهاتف والعنوان والموقع وغيرها'),
        trailing: const Icon(Icons.chevron_left), onTap: _editMyProfile),
      const Divider(height: 1),
      ListTile(leading: const Icon(Icons.business_outlined), title: const Text('تغيير المحطة / المشروع'),
        subtitle: const Text('عرض المشروع الحالي وتجهيز اختيار مشاريعك الأخرى'),
        trailing: const Icon(Icons.chevron_left), onTap: _showStationSwitcher),
      const Divider(height: 1),
      ListTile(leading: const Icon(Icons.lock_outline), title: const Text('تغيير كلمة المرور'),
        subtitle: const Text('تأكيد كلمة المرور الحالية قبل التغيير'),
        trailing: const Icon(Icons.chevron_left), onTap: _changeMyPassword),
      const Divider(height: 1),
      ListTile(leading: const Icon(Icons.logout_rounded), title: const Text('تسجيل الخروج'),
        subtitle: const Text('إنهاء جلسة الدخول على هذا الجهاز'),
        trailing: const Icon(Icons.chevron_left), onTap: _logout),
    ])),
    const SizedBox(height: 12),
    Card(child: Column(children: [
      const ListTile(leading: Icon(Icons.info_outline), title: Text('حول بوابة المستفيد'),
        subtitle: Text('بوابة لمتابعة الحساب والسقايات والطلبات')),
      ListTile(leading: const Icon(Icons.refresh_rounded), title: const Text('تحديث البيانات'),
        trailing: const Icon(Icons.chevron_left), onTap: _load),
    ])),
    const SizedBox(height: 8),
    const Text('تعديل بياناتك الشخصية لا يغيّر الأرصدة أو السقايات أو الحركات المالية.',
      style: TextStyle(fontSize: 12)),
  ]);

  @override
  Widget build(BuildContext context) {
    const titles = ['الرئيسية', 'حسابي', 'الحسابات العامة', 'طلباتي', 'الإشعارات', 'بياناتي', 'تسقياتي', 'الإعدادات'];
    final pages = [
      _homeTab(),
      _accountTab(),
      BeneficiaryGeneralAccountsPage(_repo, auth: widget.auth),
      _bookingsTab(),
      _notificationsTab(),
      _profileTab(),
      _irrigationsTab(),
      _settingsTab(),
    ];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(titles[_tab]), actions: [
          IconButton(tooltip: 'تحديث البيانات', onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded)),
          IconButton(tooltip: 'تسجيل الخروج', onPressed: _logout,
            icon: const Icon(Icons.logout_rounded)),
        ]),
        body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
            ? Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.info_outline_rounded, size: 42),
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded),
                    label: const Text('إعادة المحاولة')),
                ]),
              ))
            : RefreshIndicator(onRefresh: _load,
                child: IndexedStack(index: _tab, children: pages)),
        bottomNavigationBar: _error == null && !_loading
          ? NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (index) => setState(() => _tab = index),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'الرئيسية'),
                NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'حسابي'),
                NavigationDestination(icon: Icon(Icons.account_balance_outlined), selectedIcon: Icon(Icons.account_balance), label: 'الحسابات العامة'),
                NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'طلباتي'),
                NavigationDestination(icon: Icon(Icons.notifications_outlined), selectedIcon: Icon(Icons.notifications), label: 'الإشعارات'),
                NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'بياناتي'),
                NavigationDestination(icon: Icon(Icons.water_drop_outlined), selectedIcon: Icon(Icons.water_drop), label: 'تسقياتي'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'الإعدادات'),
              ],
            )
          : null,
      ),
    );
  }
}
