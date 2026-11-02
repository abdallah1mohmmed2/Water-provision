import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
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
  Map<String, Object?>? _partner, _summary, _profitStatement;
  List<Map<String, Object?>> _transactions = [], _irrigations = [];
  int _tab = 0, _offset = 0, _stationInvoiceCount = 0, _stationMinutes = 0;
  DateTime? _accountFrom, _accountTo;
  late DateTime _profitFrom = DateTime(DateTime.now().year, DateTime.now().month, 1);
  late DateTime _profitTo = DateTime.now();
  Timer? _searchDebounce;
  int _irrigationGeneration = 0;
  bool _loading = true, _loadingMore = false, _hasMore = true, _profitLoading = false;
  String? _profitError;
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
        _repo.db.rawQuery('SELECT * FROM partners WHERE id=? AND station_id=? LIMIT 1', [id, widget.auth.stationId]),
        _repo.partyFinancialSummary('partner', id),
        _repo.partnerTransactions(id),
        _repo.db.rawQuery(
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
      final rows = await _repo.db.rawQuery('''
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
    if (_error != null && _partner == null) {
      return Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 42), const SizedBox(height: 12), Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 14), FilledButton(onPressed: _load, child: const Text('إعادة المحاولة')),
        ]),
      )));
    }
    final pages = [_dashboard(), _stationActivity(), _myAccount(), _myProfits(), _profile()];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(_tab == 0 ? 'الرئيسية' : _tab == 1 ? 'حركة المحطة' : _tab == 2 ? 'حسابي المالي' : _tab == 3 ? 'أرباحي' : 'ملفي الشخصي'),
          actions: [IconButton(tooltip: 'تحديث', onPressed: _tab == 3 ? _loadProfitStatement : _load, icon: const Icon(Icons.refresh_rounded))]),
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (v) {
          setState(() => _tab = v);
          if (v == 3 && _profitStatement == null) _loadProfitStatement();
        },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'الرئيسية'),
            NavigationDestination(icon: Icon(Icons.water_drop_outlined), selectedIcon: Icon(Icons.water_drop), label: 'المحطة'),
            NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'حسابي'),
            NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'أرباحي'),
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

  Future<void> _loadProfitStatement() async {
    if (_partnerId == null || _profitLoading) {
      return;
    }
    setState(() { _profitLoading = true; _profitError = null; });
    try {
      final rows = await _repo.report(
        'partner_profit_statement',
        from: _profitFrom,
        to: _profitTo,
        partnerId: _partnerId,
      );
      if (!mounted) return;
      setState(() {
        _profitStatement = rows.isEmpty ? null : rows.first;
        _profitLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _profitLoading = false;
          _profitError = 'تعذر تحميل كشف الأرباح: $e';
        });
      }
    }
  }

  Future<void> _filterProfitDates() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _profitFrom, end: _profitTo),
      helpText: 'تحديد فترة كشف الأرباح',
    );
    if (picked == null) {
      return;
    }
    setState(() { _profitFrom = picked.start; _profitTo = picked.end; });
    await _loadProfitStatement();
  }

  Future<void> _printProfitStatement() async {
    if (_partnerId == null) {
      return;
    }
    try {
      await ReportService(_repo).printPdf(
        'partner_profit_statement',
        partnerId: _partnerId,
        from: _profitFrom,
        to: _profitTo,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إنشاء كشف PDF: $e')),
        );
      }
    }
  }

  Widget _myProfits() {
    final row = _profitStatement;
    String money(Object? value) => '${_money(value)} ريال';
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: _filterProfitDates,
            icon: const Icon(Icons.date_range),
            label: Text('${DateFormat('yyyy/MM/dd').format(_profitFrom)} — ${DateFormat('yyyy/MM/dd').format(_profitTo)}'),
          )),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'تحديث كشف الأرباح',
            onPressed: _loadProfitStatement,
            icon: const Icon(Icons.refresh),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: SizedBox(width: double.infinity, child: FilledButton.tonalIcon(
          onPressed: row == null || _profitLoading ? null : _printProfitStatement,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('طباعة كشف أرباحي PDF'),
        )),
      ),
      if (_profitLoading) const Expanded(child: Center(child: CircularProgressIndicator()))
      else if (_profitError != null) Expanded(child: Center(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_profitError!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: _loadProfitStatement, child: const Text('إعادة المحاولة')),
        ]),
      )))
      else if (row == null) const Expanded(child: Center(child: Text('لا توجد بيانات أرباح لهذه الفترة')))
      else Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('صافي استحقاقك خلال الفترة', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(money(row['net_amount']), style: TextStyle(
                fontSize: 27, fontWeight: FontWeight.w900,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              )),
              const SizedBox(height: 5),
              const Text('بعد خصم المصروفات الخاصة بك'),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        _profitLine('استحقاقك المباشر من السقايات', row['direct_amount']),
        _profitLine('نصيبك من الأرباح الموزعة', row['share_amount']),
        _profitLine('إجمالي الاستحقاق قبل المصروفات', row['gross_amount']),
        _profitLine('المصروفات الخاصة بك', row['partner_expenses']),
        _profitLine('صافي استحقاقك', row['net_amount'], emphasize: true),
        const SizedBox(height: 12),
        Card(child: ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('طريقة احتساب الاستحقاق'),
          subtitle: Text(row['mode'] == 'percentage'
            ? 'نسبة الملكية المعتمدة: ${row['basis']}%'
            : 'عدد الحصص المعتمد: ${row['basis']}'),
        )),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('هذا الكشف للعرض فقط. لا ينشئ تسوية أو قيداً محاسبياً ولا يغيّر أرصدة المحطة.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
        ),
      ])),
    ]);
  }

  Widget _profitLine(String title, Object? amount, {bool emphasize = false}) => Card(
    child: ListTile(
      title: Text(title, style: TextStyle(fontWeight: emphasize ? FontWeight.w900 : FontWeight.w600)),
      trailing: Text('${_money(amount)} ريال', style: TextStyle(
        fontWeight: FontWeight.w900,
        color: emphasize ? Theme.of(context).colorScheme.primary : null,
      )),
    ),
  );

  List<Map<String, Object?>> get _visibleAccountTransactions {
    final start = _accountFrom == null
        ? null
        : DateTime(_accountFrom!.year, _accountFrom!.month, _accountFrom!.day);
    final end = _accountTo == null
        ? null
        : DateTime(_accountTo!.year, _accountTo!.month, _accountTo!.day).add(const Duration(days: 1));
    return _transactions.where((row) {
      final date = DateTime.tryParse('${row['date'] ?? ''}');
      if (date == null) return start == null && end == null;
      if (start != null && date.isBefore(start)) return false;
      if (end != null && !date.isBefore(end)) return false;
      return true;
    }).toList();
  }

  int get _accountOpeningBalance {
    if (_accountFrom == null) return 0;
    final start = DateTime(_accountFrom!.year, _accountFrom!.month, _accountFrom!.day);
    return _transactions.fold<int>(0, (sum, row) {
      final date = DateTime.tryParse('${row['date'] ?? ''}');
      if (date == null || !date.isBefore(start)) return sum;
      return sum + _asInt(row['signed_amount']);
    });
  }

  Future<void> _filterAccountDates() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: _accountFrom == null && _accountTo == null
          ? null
          : DateTimeRange(
              start: _accountFrom ?? _accountTo!,
              end: _accountTo ?? _accountFrom!,
            ),
      helpText: 'تحديد فترة كشف الحساب',
    );
    if (picked == null) return;
    setState(() {
      _accountFrom = picked.start;
      _accountTo = picked.end;
    });
  }

  void _clearAccountDates() {
    setState(() { _accountFrom = null; _accountTo = null; });
  }

  Widget _myAccount() {
    final balance = _asInt(_summary?['balance']);
    return Column(children: [
      Card(margin: const EdgeInsets.all(14), child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.account_balance_wallet)),
        title: const Text('الرصيد الشخصي الحالي'),
        subtitle: Text(_partyBalance(balance), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
        trailing: IconButton(tooltip: 'كشف PDF', onPressed: () => ReportService(_repo).printPdf(
          'partner_accounts', partnerId: _partnerId, from: _accountFrom, to: _accountTo),
          icon: const Icon(Icons.picture_as_pdf)),
      )),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Row(children: [
        Expanded(child: _stat('الاستحقاقات', _asInt(_summary?['earnings']), Icons.trending_up)),
        Expanded(child: _stat('المستلم', _asInt(_summary?['paid']), Icons.payments)),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 8), child: Row(children: [
        Expanded(child: OutlinedButton.icon(
          onPressed: _filterAccountDates,
          icon: const Icon(Icons.date_range),
          label: Text(_accountFrom == null && _accountTo == null
            ? 'كل الفترات'
            : '${_accountFrom == null ? 'البداية' : DateFormat('yyyy/MM/dd').format(_accountFrom!)} — ${_accountTo == null ? 'النهاية' : DateFormat('yyyy/MM/dd').format(_accountTo!)}'),
        )),
        if (_accountFrom != null || _accountTo != null)
          IconButton(tooltip: 'إلغاء التصفية', onPressed: _clearAccountDates, icon: const Icon(Icons.filter_alt_off)),
      ])),
      if (_accountFrom != null)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          child: Align(alignment: Alignment.centerRight,
            child: Text('الرصيد المرحّل قبل الفترة: ${_partyBalance(_accountOpeningBalance)}',
              style: const TextStyle(fontWeight: FontWeight.w700)))),
      Expanded(child: _visibleAccountTransactions.isEmpty
        ? const Center(child: Text('لا توجد حركات مالية في الفترة المحددة'))
        : ListView.builder(
            itemCount: _visibleAccountTransactions.length,
            itemBuilder: (context, index) => _transactionTile(_visibleAccountTransactions[index]),
          )),
    ]);
  }

  Future<void> _showPaymentDetails(Map<String, Object?> row) async {
    final paymentId = _asInt(row['reference_id']);
    if (_partnerId == null || paymentId <= 0) return;
    try {
      // لا نثق بمرجع الحركة وحده؛ نتحقق من ملكية السند للشريك الحالي
      // ومن أن السند مرحّل قبل عرض أي تفاصيل.
      final matches = await _repo.db.rawQuery('''
        SELECT p.id, p.date, p.amount, p.reference_number, p.notes,
               pm.name method_name, pm.type method_type,
               c.name cashbox_name
        FROM payments p
        JOIN payment_methods pm ON pm.id=p.payment_method_id
        JOIN cashboxes c ON c.id=p.cashbox_id
        WHERE p.id=? AND p.partner_id=? AND p.status='posted'
        LIMIT 1
      ''', [paymentId, _partnerId]);
      if (!mounted) return;
      if (matches.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر العثور على سند تسديد مرتبط بهذا الحساب.')),
        );
        return;
      }
      final payment = matches.first;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Row(children: [
              Icon(Icons.receipt_long_outlined),
              SizedBox(width: 9),
              Expanded(child: Text('تفاصيل سند التسديد')),
            ]),
            content: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _paymentDetailLine('رقم السند', payment['reference_number'] ?? 'غير محدد'),
                _paymentDetailLine('التاريخ', _date(payment['date'])),
                _paymentDetailLine('المبلغ', '${_money(payment['amount'])} ريال'),
                _paymentDetailLine('طريقة الدفع', payment['method_name'] ?? 'غير محددة'),
                _paymentDetailLine('الصندوق', payment['cashbox_name'] ?? 'غير محدد'),
                if ('${payment['notes'] ?? ''}'.trim().isNotEmpty)
                  _paymentDetailLine('البيان', payment['notes']),
                const SizedBox(height: 8),
                const Text('هذه بيانات للعرض فقط ولا يمكن تعديل السند من بوابة الشريك.',
                  style: TextStyle(fontSize: 12)),
              ],
            )),
            actions: [TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('إغلاق'),
            )],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل تفاصيل السند: $e')),
        );
      }
    }
  }

  Widget _paymentDetailLine(String label, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 105, child: Text(label,
        style: const TextStyle(fontWeight: FontWeight.w700))),
      Expanded(child: Text('$value')),
    ]),
  );

  Future<void> _showPartnerExpenseDetails(Map<String, Object?> row) async {
    final expenseId = _asInt(row['reference_id']);
    if (_partnerId == null || expenseId <= 0) return;
    final matches = await _repo.db.rawQuery('''
      SELECT e.id, e.date, e.title, e.category, e.amount, e.notes,
             pm.name method_name, c.name cashbox_name
      FROM expenses e
      LEFT JOIN payment_methods pm ON pm.id=e.payment_method_id
      LEFT JOIN cashboxes c ON c.id=e.cashbox_id
      WHERE e.id=? AND e.partner_id=? AND e.status='posted'
      LIMIT 1
    ''', [expenseId, _partnerId]);
    if (!mounted) return;
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم العثور على مصروف مرحّل مرتبط بحسابك.')),
      );
      return;
    }
    final expense = matches.first;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تفاصيل المصروف الخاص بالشريك'),
          content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _paymentDetailLine('رقم المصروف', expense['id']),
              _paymentDetailLine('التاريخ', _date(expense['date'])),
              _paymentDetailLine('العنوان', expense['title']),
              _paymentDetailLine('التصنيف', expense['category']),
              _paymentDetailLine('المبلغ', '${_money(expense['amount'])} ريال'),
              _paymentDetailLine('طريقة الدفع', expense['method_name'] ?? 'غير محددة'),
              _paymentDetailLine('الصندوق', expense['cashbox_name'] ?? 'غير محدد'),
              if ('${expense['notes'] ?? ''}'.trim().isNotEmpty)
                _paymentDetailLine('البيان', expense['notes']),
              const SizedBox(height: 8),
              const Text('تفاصيل للعرض فقط؛ لا يمكن تعديل المصروف أو القيد من بوابة الشريك.',
                style: TextStyle(fontSize: 12)),
            ],
          )),
          actions: [TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('إغلاق'),
          )],
        ),
      ),
    );
  }

  Future<void> _showPartnerAccrualDetails(Map<String, Object?> row) async {
    if (_partnerId == null) return;
    Map<String, Object?>? transaction;
    final referenceType = '${row['reference_type'] ?? ''}';
    final referenceId = _asInt(row['reference_id']);

    // في الأستاذ يشير مرجع partner إلى سجل الحركة الفرعي؛ أما المصدر القديم
    // فيحمل reference_type/reference_id الأصليين مباشرة.
    if (referenceType == 'partner' && referenceId > 0) {
      final matches = await _repo.db.rawQuery(
        'SELECT * FROM partner_transactions WHERE id=? AND partner_id=? LIMIT 1',
        [referenceId, _partnerId],
      );
      if (matches.isNotEmpty) transaction = matches.first;
    }

    final sourceType = '${transaction?['reference_type'] ?? referenceType}';
    final sourceId = transaction == null
        ? referenceId
        : _asInt(transaction['reference_id']);
    Map<String, Object?>? irrigation;
    if (sourceType == 'irrigation_profit' && sourceId > 0) {
      final matches = await _repo.db.rawQuery('''
        SELECT i.id, i.date, i.start_datetime, i.end_datetime, i.minutes,
               i.cloud_minutes, i.chargeable_minutes, i.total_amount,
               i.status, pm.name pump_name
        FROM irrigations i LEFT JOIN pumps pm ON pm.id=i.pump_id
        WHERE i.id=? AND i.partner_id=? AND i.station_id=? AND i.status!='cancelled'
        LIMIT 1
      ''', [sourceId, _partnerId, widget.auth.stationId]);
      if (matches.isNotEmpty) irrigation = matches.first;
    }
    if (!mounted) return;
    final tx = transaction;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تفاصيل الاستحقاق / التسوية'),
          content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _paymentDetailLine('نوع الحركة', row['description'] ?? row['type']),
              _paymentDetailLine('التاريخ', _date(row['date'])),
              _paymentDetailLine('المبلغ', '${_money(row['amount'])} ريال'),
              if (tx != null) ...[
                _paymentDetailLine('رقم الحركة', tx['id']),
                if (tx['ownership_snapshot'] != null)
                  _paymentDetailLine('أساس الحصة وقت الترحيل', tx['ownership_snapshot']),
                if ('${tx['notes'] ?? ''}'.trim().isNotEmpty)
                  _paymentDetailLine('البيان', tx['notes']),
              ],
              if (irrigation != null) ...[
                const Divider(),
                const Text('السقاية المرتبطة', style: TextStyle(fontWeight: FontWeight.w900)),
                _paymentDetailLine('رقم الفاتورة', irrigation['id']),
                _paymentDetailLine('المضخة', irrigation['pump_name'] ?? 'غير محددة'),
                _paymentDetailLine('بداية السقاية', _date(irrigation['start_datetime'])),
                _paymentDetailLine('المدة', '${irrigation['minutes']} دقيقة'),
                _paymentDetailLine('خصم الغيم', '${irrigation['cloud_minutes']} دقيقة'),
                _paymentDetailLine('الدقائق المحتسبة', '${irrigation['chargeable_minutes']} دقيقة'),
                _paymentDetailLine('إجمالي الفاتورة', '${_money(irrigation['total_amount'])} ريال'),
              ],
              const SizedBox(height: 8),
              const Text('عرض توضيحي فقط. لا يتم تعديل الاستحقاق أو التسوية أو أي قيد محاسبي.',
                style: TextStyle(fontSize: 12)),
            ],
          )),
          actions: [TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('إغلاق'),
          )],
        ),
      ),
    );
  }

  Future<void> _showTransactionDetails(Map<String, Object?> row) async {
    final referenceType = '${row['reference_type'] ?? ''}';
    if (row['type'] == 'payment' || referenceType == 'payment') {
      await _showPaymentDetails(row);
    } else if (referenceType == 'expense' || referenceType == 'petty_expense') {
      await _showPartnerExpenseDetails(row);
    } else {
      await _showPartnerAccrualDetails(row);
    }
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
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${isCredit ? '+' : '-'}${_money(amount)}', style: TextStyle(fontWeight: FontWeight.w900, color: isCredit ? Colors.green : Colors.orange)),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_left, size: 20),
      ]),
      onTap: () => _showTransactionDetails(row),
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
