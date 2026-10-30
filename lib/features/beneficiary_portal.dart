import 'package:flutter/material.dart';
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
  List<Map<String, Object?>> _bookings = [];
  List<Map<String, Object?>> _notifications = [];
  int? _beneficiaryId;
  int _tab = 0;
  bool _loading = true;
  bool _savingBooking = false;
  String? _error;

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

  int get _balance => (_beneficiary?['balance'] as num?)?.round() ?? 0;
  int get _irrigationCount => _statement.where((row) => row['type'] == 's').length;
  int get _totalMinutes => _statement.fold<int>(0,
    (sum, row) => sum + (row['type'] == 's' ? ((row['minutes'] as num?)?.round() ?? 0) : 0));
  int get _unreadCount => _notifications.where((row) => row['read_at'] == null).length;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
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
      final values = await Future.wait<dynamic>([
        _repo.beneficiaryDetails(id),
        _repo.beneficiaryStatement(id),
        _repo.beneficiaryBookings(id),
        _repo.notifications(beneficiaryId: id),
      ]);
      if (!mounted) return;
      setState(() {
        _beneficiaryId = id;
        _beneficiary = values[0] as Map<String, Object?>;
        _statement = (values[1] as List).cast<Map<String, Object?>>();
        _bookings = (values[2] as List).cast<Map<String, Object?>>();
        _notifications = (values[3] as List).cast<Map<String, Object?>>();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'تعذر تحميل بيانات الحساب. حاول تحديث الصفحة.'; });
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

  Widget _movementTile(Map<String, Object?> row) {
    final debit = (row['debit'] as num?)?.round() ?? 0;
    final credit = (row['credit'] as num?)?.round() ?? 0;
    final balance = (row['balance'] as num?)?.round() ?? 0;
    final amount = debit > 0 ? debit : credit;
    final isDebit = debit > 0;
    return Card(child: ListTile(
      leading: CircleAvatar(child: Icon(isDebit ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)),
      title: Text((row['description'] ?? 'حركة حساب').toString()),
      subtitle: Text(_date(row['date'])),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${isDebit ? '+' : '-'}$amount ريال',
          style: const TextStyle(fontWeight: FontWeight.w800)),
        Text(AccountingCalculations.balanceLabel(balance),
          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
      _sectionTitle('كشف الحساب', subtitle: 'الحركات المالية المسجلة على حسابك'),
      if (_statement.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('لا توجد حركات مسجلة.')))
      else
        for (final row in _statement.reversed) _movementTile(row),
    ]);

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
            subtitle: Text('${(item['body'] ?? '').toString()}\\n${_date(item['created_at'])}'),
            isThreeLine: true,
            trailing: item['read_at'] == null ? const Icon(Icons.circle, size: 9) : null,
            onTap: () => _readNotification(item),
          )),
    ]);

  Widget _profileTab() => ListView(physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16), children: [
      _sectionTitle('بيانات حسابي'),
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.person_outline), title: const Text('الاسم'),
          subtitle: Text((_beneficiary?['name'] ?? 'غير محدد').toString())),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.phone_outlined), title: const Text('رقم الهاتف'),
          subtitle: Text((_beneficiary?['phone'] ?? 'غير مسجل').toString())),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.location_on_outlined), title: const Text('العنوان'),
          subtitle: Text((_beneficiary?['address'] ?? 'غير مسجل').toString())),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.place_outlined), title: const Text('الموقع'),
          subtitle: Text((_beneficiary?['location'] ?? 'غير محدد').toString())),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.tag_outlined), title: const Text('رقم الجربة'),
          subtitle: Text((_beneficiary?['jerba_number'] ?? 'غير مسجل').toString())),
      ])),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _logout, icon: const Icon(Icons.logout_rounded),
        label: const Text('تسجيل الخروج')),
    ]);

  @override
  Widget build(BuildContext context) {
    const titles = ['الرئيسية', 'حسابي', 'الحسابات العامة', 'طلباتي', 'الإشعارات', 'بياناتي'];
    final pages = [
      _homeTab(),
      _accountTab(),
      BeneficiaryGeneralAccountsPage(_repo, auth: widget.auth),
      _bookingsTab(),
      _notificationsTab(),
      _profileTab(),
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
              ],
            )
          : null,
      ),
    );
  }
}
