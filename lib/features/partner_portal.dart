import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/repositories/repositories.dart';
import '../services/local_partner_auth_service.dart';
import '../services/report_service.dart';

class PartnerLoginPage extends StatefulWidget {
  const PartnerLoginPage({super.key, this.auth});
  final LocalPartnerAuthService? auth;
  @override
  State<PartnerLoginPage> createState() => _PartnerLoginPageState();
}

class _PartnerLoginPageState extends State<PartnerLoginPage> {
  late final LocalPartnerAuthService _auth = widget.auth ?? LocalPartnerAuthService();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void dispose() { _username.dispose(); _password.dispose(); super.dispose(); }

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
        MaterialPageRoute<void>(builder: (_) => PartnerHomePage(auth: _auth)),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر تسجيل الدخول: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft,
            colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).scaffoldBackgroundColor, Theme.of(context).colorScheme.surface]),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 5,
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(26),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    CircleAvatar(radius: 34, backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      child: Icon(Icons.handshake_rounded, size: 38, color: Theme.of(context).colorScheme.primary)),
                    const SizedBox(height: 16),
                    const Text('بوابة الشريك', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 7),
                    Text('تابع حركة المحطة وأرباحك وحسابك المالي', textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 24),
                    TextField(controller: _username, autocorrect: false, textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'اسم المستخدم', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder())),
                    const SizedBox(height: 13),
                    TextField(controller: _password, obscureText: _obscure, onSubmitted: (_) => _login(),
                      decoration: InputDecoration(labelText: 'كلمة المرور', prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined)),
                        border: const OutlineInputBorder())),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(onPressed: _busy ? null : _login,
                      icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login_rounded),
                      label: Text(_busy ? 'جارٍ التحقق…' : 'تسجيل الدخول')),
                    const SizedBox(height: 12),
                    const Text('بيانات الدخول ينشئها مدير المحطة.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class PartnerHomePage extends StatefulWidget {
  const PartnerHomePage({required this.auth, super.key});
  final LocalPartnerAuthService auth;
  @override
  State<PartnerHomePage> createState() => _PartnerHomePageState();
}

class _PartnerHomePageState extends State<PartnerHomePage> {
  late final StationRepository _repo = StationRepository(widget.auth.db);
  int? _partnerId;
  Map<String, Object?>? _partner, _summary;
  List<Map<String, Object?>> _transactions = [], _irrigations = [];
  int _tab = 0, _offset = 0, _stationInvoiceCount = 0, _stationMinutes = 0;
  Timer? _searchDebounce;
  int _irrigationGeneration = 0;
  bool _loading = true, _loadingMore = false, _hasMore = true;
  String _search = '';
  DateTime? _from, _to;
  String? _error;
  static const int _pageSize = 40;

  int _asInt(Object? value) => value is num ? value.round() : int.tryParse('$value') ?? 0;
  String _money(Object? value) => NumberFormat('#,##0').format(_asInt(value));
  String _date(Object? value) {
    final d = DateTime.tryParse('$value');
    return d == null ? 'غير محدد' : DateFormat('yyyy/MM/dd • hh:mm a', 'en').format(d);
  }
  String _partyBalance(int value) => value > 0 ? 'له ${_money(value)} ريال'
      : value < 0 ? 'عليه ${_money(value.abs())} ريال' : 'متوازن';

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _searchDebounce?.cancel(); super.dispose(); }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final id = await widget.auth.currentPartnerId();
      if (id == null) {
        if (mounted) setState(() { _loading = false; _error = 'انتهت جلسة الدخول. سجّل الدخول مرة أخرى.'; });
        return;
      }
      final values = await Future.wait([
        _repo.rawQuery('SELECT * FROM partners WHERE id=? AND station_id=? LIMIT 1', [id, widget.auth.stationId]),
        _repo.partyFinancialSummary('partner', id),
        _repo.partnerTransactions(id),
        _repo.rawQuery(
          "SELECT COUNT(*) invoice_count, COALESCE(SUM(minutes),0) total_minutes FROM irrigations WHERE station_id=? AND status!='cancelled'",
          [widget.auth.stationId],
        ),
      ]);
      if (!mounted) return;
      if ((values[0] as List).isEmpty) throw StateError('الشريك المرتبط بالجلسة غير موجود');
      setState(() {
        _partnerId = id;
        _partner = (values[0] as List).first as Map<String, Object?>;
        _summary = values[1] as Map<String, Object?>;
        _transactions = (values[2] as List).cast<Map<String, Object?>>();
        final stationTotals = (values[3] as List).first as Map<String, Object?>;
        _stationInvoiceCount = _asInt(stationTotals['invoice_count']);
        _stationMinutes = _asInt(stationTotals['total_minutes']);
        _loading = false;
      });
      await _loadIrrigations(reset: true);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'تعذر تحميل بيانات الشريك: $e'; });
    }
  }

  Future<void> _loadIrrigations({bool reset = false}) async {
    if (_partnerId == null || (!reset && (_loadingMore || !_hasMore))) return;
    final generation = ++_irrigationGeneration;
    if (mounted) setState(() { if (reset) { _offset = 0; _hasMore = true; _irrigations = []; } _loadingMore = true; });
    try {
      final args = <Object?>[];
      final where = <String>["i.status!='cancelled'", 'i.station_id=?'];
      args.add(widget.auth.stationId);
      if (_from != null) { where.add("date(COALESCE(i.date,i.start_datetime))>=date(?)"); args.add(_from!.toIso8601String()); }
      if (_to != null) { where.add("date(COALESCE(i.date,i.start_datetime))<=date(?)"); args.add(_to!.toIso8601String()); }
      final q = _search.trim();
      if (q.isNotEmpty) {
        where.add("(CAST(i.id AS TEXT) LIKE ? OR COALESCE(b.name,'') LIKE ? OR COALESCE(w.name,'') LIKE ? OR COALESCE(p.name,'') LIKE ? OR COALESCE(pm.name,'') LIKE ?)");
        args.addAll(List<Object?>.filled(5, '%$q%'));
      }
      args.add(_pageSize);
      args.add(_offset);
      final rows = await _repo.rawQuery('''
        SELECT i.*,
          COALESCE(i.cloud_minutes,0) cloud_minutes,
          COALESCE(b.name,w.name,p.name,'غير محدد') party_name, pm.name pump_name
        FROM irrigations i
        LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id
        LEFT JOIN workers w ON w.id=i.worker_id
        LEFT JOIN partners p ON p.id=i.partner_id
        LEFT JOIN pumps pm ON pm.id=i.pump_id
        WHERE ${where.join(' AND ')}
        ORDER BY i.start_datetime DESC, i.id DESC LIMIT ? OFFSET ?
      ''', args);
      if (!mounted || generation != _irrigationGeneration) return;
      setState(() {
        _irrigations = reset ? rows : [..._irrigations, ...rows];
        _offset += rows.length;
        _hasMore = rows.length == _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (mounted && generation == _irrigationGeneration) setState(() { _loadingMore = false; _error = 'تعذر تحميل سقايات المحطة: $e'; });
    }
  }

  Future<void> _filterDates() async {
    final picked = await showDateRangePicker(context: context,
      firstDate: DateTime(2020), lastDate: DateTime(2100),
      initialDateRange: _from != null && _to != null ? DateTimeRange(start: _from!, end: _to!) : null,
      helpText: 'تصفية حركة المحطة حسب التاريخ');
    if (picked == null) return;
    setState(() { _from = picked.start; _to = picked.end; });
    await _loadIrrigations(reset: true);
  }

  Future<void> _showIrrigation(Map<String, Object?> row) async {
    final minutes = _asInt(row['minutes']), cloud = _asInt(row['cloud_minutes']);
    await showModalBottomSheet<void>(context: context, isScrollControlled: true,
      showDragHandle: true, builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(child: Padding(padding: const EdgeInsets.all(20),
          child: Wrap(runSpacing: 12, children: [
            Row(children: [const Icon(Icons.receipt_long_rounded), const SizedBox(width: 8),
              Text('فاتورة السقاية #${row['id']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))]),
            _detail('المستفيد / الجهة', '${row['party_name']}'),
            _detail('المضخة', '${row['pump_name'] ?? '-'}'),
            _detail('التاريخ', _date(row['start_datetime'])),
            _detail('وقت النهاية', _date(row['end_datetime'])),
            _detail('المدة الإجمالية', '$minutes دقيقة'),
            _detail('خصم الغيم', '$cloud دقيقة'),
            _detail('صافي الدقائق المحتسبة', '${_asInt(row['chargeable_minutes'])} دقيقة'),
            _detail('قيمة الفاتورة', '${_money(row['total_amount'])} ريال'),
            _detail('المدفوع', '${_money(row['paid_amount'])} ريال'),
            _detail('نوع المنظومة', '${row['system_type']}'),
            _detail('ملاحظات', '${row['notes'] ?? '-'}'),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                final invoiceDate = DateTime.tryParse('${row['date'] ?? row['start_datetime']}');
                await ReportService(_repo).printPdf(
                  'invoices',
                  from: invoiceDate,
                  to: invoiceDate,
                  sourceRows: [row],
                  systemType: 'all',
                );
              },
              icon: const Icon(Icons.picture_as_pdf), label: const Text('طباعة الفاتورة')),
            ),
          ]),
        )),
      ));
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 132, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
      Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700))),
    ]),
  );

  Future<void> _changePassword() async {
    final current = TextEditingController(), next = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('تغيير كلمة المرور'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الحالية')),
        TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الجديدة')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
      ],
    ));
    if (ok == true) {
      try {
        await widget.auth.changeCurrentPassword(currentPassword: current.text, newPassword: next.text);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تغيير كلمة المرور')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    current.dispose(); next.dispose();
  }

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => PartnerLoginPage(auth: widget.auth)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null && _partner == null) return Scaffold(body: Center(child: Padding(
      padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, size: 42), const SizedBox(height: 12), Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 14), FilledButton(onPressed: _load, child: const Text('إعادة المحاولة')),
      ]),
    )));
    final pages = [_dashboard(), _stationActivity(), _myAccount(), _profile()];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(_tab == 0 ? 'الرئيسية' : _tab == 1 ? 'حركة المحطة' : _tab == 2 ? 'حسابي المالي' : 'ملفي الشخصي'),
          actions: [IconButton(tooltip: 'تحديث', onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (v) => setState(() => _tab = v),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'الرئيسية'),
            NavigationDestination(icon: Icon(Icons.water_drop_outlined), selectedIcon: Icon(Icons.water_drop), label: 'المحطة'),
            NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'حسابي'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'ملفي'),
          ]),
      ),
    );
  }

  Widget _dashboard() {
    final balance = _asInt(_summary?['balance']);
    final earnings = _asInt(_summary?['earnings']);
    final paid = _asInt(_summary?['paid']);
    final minutes = _asInt(_summary?['irrigation_minutes']);
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.tertiary]),
      ), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('مرحباً بك في بوابة الشريك', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 6),
        Text('${_partner?['name'] ?? 'الشريك'}', style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w900)),
        const SizedBox(height: 18),
        const Text('رصيدك الحالي', style: TextStyle(color: Colors.white70)),
        Text(_partyBalance(balance), style: const TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w900)),
      ]),
      ),
      const SizedBox(height: 14),
      GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: 2, childAspectRatio: 1.55, crossAxisSpacing: 10, mainAxisSpacing: 10,
        children: [
          _stat('إجمالي الاستحقاقات', earnings, Icons.trending_up_rounded),
          _stat('المبالغ المستلمة', paid, Icons.payments_outlined),
          _stat('دقائق سقايات حصتك', minutes, Icons.timer_outlined, suffix: 'دقيقة'),
          _stat('دقائق المحطة', _stationMinutes, Icons.av_timer_rounded, suffix: 'دقيقة'),
          _stat('فواتير المحطة', _stationInvoiceCount, Icons.receipt_long_outlined, suffix: 'فاتورة'),
        ]),
      const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('آخر الحركات المالية', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        TextButton(onPressed: () => setState(() => _tab = 2), child: const Text('عرض الكل')),
      ]),
      ..._transactions.reversed.take(5).map(_transactionTile),
      const SizedBox(height: 12),
      FilledButton.tonalIcon(onPressed: () => setState(() => _tab = 1),
        icon: const Icon(Icons.water_drop), label: const Text('استعراض جميع سقايات المحطة')),
    ]));
  }

  Widget _stat(String title, int value, IconData icon, {String suffix = 'ريال'}) => Card(
    child: Padding(padding: const EdgeInsets.all(13), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 8),
      Text(title, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 3), FittedBox(fit: BoxFit.scaleDown, child: Text('${_money(value)} $suffix', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
    ])),
  );

  Widget _stationActivity() => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: Row(children: [
      Expanded(child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث برقم الفاتورة أو اسم المستفيد أو المضخة', border: OutlineInputBorder(), isDense: true),
        onChanged: (v) {
          _search = v;
          _searchDebounce?.cancel();
          _searchDebounce = Timer(const Duration(milliseconds: 350), () => _loadIrrigations(reset: true));
        })),
      const SizedBox(width: 8),
      IconButton(tooltip: 'تصفية التاريخ', onPressed: _filterDates, icon: const Icon(Icons.date_range)),
      IconButton(tooltip: 'إزالة الفلاتر', onPressed: () { _searchDebounce?.cancel(); setState(() { _from = null; _to = null; _search = ''; }); _loadIrrigations(reset: true); }, icon: const Icon(Icons.filter_alt_off)),
    ])),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Row(children: [
      Expanded(child: Text(_from == null ? 'جميع التواريخ' : 'من ${DateFormat('yyyy/MM/dd').format(_from!)} إلى ${DateFormat('yyyy/MM/dd').format(_to!)}',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12))),
      TextButton.icon(onPressed: () => ReportService(_repo).printPdf('invoices', from: _from, to: _to, systemType: 'all'),
        icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('PDF')),
    ])),
    Expanded(child: _irrigations.isEmpty && !_loadingMore
      ? const Center(child: Text('لا توجد سقايات مطابقة'))
      : NotificationListener<ScrollNotification>(
        onNotification: (n) { if (n.metrics.pixels >= n.metrics.maxScrollExtent - 250) _loadIrrigations(); return false; },
        child: ListView.builder(itemCount: _irrigations.length + (_hasMore ? 1 : 0), itemBuilder: (context, index) {
          if (index >= _irrigations.length) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
          final x = _irrigations[index];
          return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: ListTile(
            onTap: () => _showIrrigation(x),
            leading: CircleAvatar(child: Text('${x['id']}')),
            title: Text('${x['party_name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text('فاتورة #${x['id']} • ${_date(x['start_datetime'])}\n${_asInt(x['minutes'])} د • غيم ${_asInt(x['cloud_minutes'])} د • ${x['pump_name'] ?? ''}'),
            isThreeLine: true,
            trailing: Text('${_money(x['total_amount'])} ريال', style: const TextStyle(fontWeight: FontWeight.w900)),
          ));
        }),
      )),
  ]);

  Widget _myAccount() {
    final balance = _asInt(_summary?['balance']);
    return Column(children: [
      Card(margin: const EdgeInsets.all(14), child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.account_balance_wallet)),
        title: const Text('الرصيد الشخصي الحالي'),
        subtitle: Text(_partyBalance(balance), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
        trailing: IconButton(tooltip: 'كشف PDF', onPressed: () => ReportService(_repo).printPdf('partner_accounts', partnerId: _partnerId),
          icon: const Icon(Icons.picture_as_pdf)),
      )),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Row(children: [
        Expanded(child: _stat('الاستحقاقات', _asInt(_summary?['earnings']), Icons.trending_up)),
        Expanded(child: _stat('المستلم', _asInt(_summary?['paid']), Icons.payments)),
      ])),
      Expanded(child: _transactions.isEmpty ? const Center(child: Text('لا توجد حركات مالية')) :
        ListView.builder(itemCount: _transactions.length, itemBuilder: (context, index) => _transactionTile(_transactions[_transactions.length - 1 - index]))),
    ]);
  }

  Widget _transactionTile(Map<String, Object?> row) {
    final signed = _asInt(row['signed_amount']);
    final amount = _asInt(row['amount']);
    final isCredit = signed > 0 || (signed == 0 && (row['lah'] != null && _asInt(row['lah']) > 0));
    final label = '${row['description'] ?? row['notes'] ?? row['type'] ?? 'حركة مالية'}';
    return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ListTile(
      leading: CircleAvatar(backgroundColor: isCredit ? Colors.green.withValues(alpha: .12) : Colors.orange.withValues(alpha: .12),
        child: Icon(isCredit ? Icons.arrow_downward : Icons.arrow_upward, color: isCredit ? Colors.green : Colors.orange)),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${_date(row['date'])} • رصيد ${_partyBalance(_asInt(row['balance']))}'),
      trailing: Text('${isCredit ? '+' : '-'}${_money(amount)}', style: TextStyle(fontWeight: FontWeight.w900, color: isCredit ? Colors.green : Colors.orange)),
    ));
  }

  Widget _profile() => ListView(padding: const EdgeInsets.all(16), children: [
    Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.handshake)),
      title: Text('${_partner?['name'] ?? 'الشريك'}', style: const TextStyle(fontWeight: FontWeight.w900)),
      subtitle: Text('${_partner?['phone'] ?? 'لا يوجد رقم هاتف'}'))),
    Card(child: ListTile(leading: const Icon(Icons.pie_chart_outline), title: const Text('طريقة توزيع الأرباح'),
      subtitle: Text(_partner?['ownership_mode'] == 'percentage'
        ? 'نسبة الملكية: ${_partner?['ownership_percentage'] ?? 0}%'
        : 'عدد الحصص: ${_partner?['shares_count'] ?? 0}'))),
    Card(child: ListTile(leading: const Icon(Icons.lock_outline), title: const Text('تغيير كلمة المرور'),
      trailing: const Icon(Icons.chevron_left), onTap: _changePassword)),
    Card(child: ListTile(leading: const Icon(Icons.logout, color: Colors.red), title: const Text('تسجيل الخروج'),
      onTap: _logout)),
  ]);
}
