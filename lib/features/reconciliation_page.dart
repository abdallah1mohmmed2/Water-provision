import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart' as pdf;
import '../core/app_clock.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/reconciliation_service.dart';
import '../services/official_report_template.dart';

class ReconciliationPage extends StatefulWidget {
  final StationRepository repo;
  final int userId;
  const ReconciliationPage(this.repo, {super.key, required this.userId});

  @override
  State<ReconciliationPage> createState() => _ReconciliationPageState();
}

class _ReconciliationPageState extends State<ReconciliationPage> {
  late DateTime month;
  final manualPaid = TextEditingController();
  final openingAmount = TextEditingController();
  final openingDetails = TextEditingController();
  final service = ReconciliationService();
  Map<String, Object?>? data;
  bool loading = true;
  bool saving = false;
  bool openingIsPartnerDue = true;
  String? error;

  @override
  void initState() {
    super.initState();
    final now = AppClock.now();
    month = DateTime(now.year, now.month, 1);
    _load();
  }

  @override
  void dispose() {
    manualPaid.dispose();
    openingAmount.dispose();
    openingDetails.dispose();
    super.dispose();
  }

  int _n(Object? value) => value is num ? value.round() : int.tryParse('$value') ?? 0;
  String _money(Object? value) => NumberFormat('#,##0').format(_n(value));
  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final result = await service.loadMonth(month);
      if (!mounted) return;
      data = result;
      manualPaid.text = _n(result['manual_paid']).toString();
      final opening = _n(result['opening_balance']);
      openingIsPartnerDue = opening >= 0;
      openingAmount.text = opening.abs().toString();
      openingDetails.text = '${result['opening_details'] ?? ''}';
      setState(() => loading = false);
    } catch (e) {
      if (mounted) setState(() { error = '$e'; loading = false; });
    }
  }

  Future<void> _save() async {
    if (saving || data == null) return;
    final paid = int.tryParse(manualPaid.text.trim());
    final opening = int.tryParse(openingAmount.text.trim().isEmpty ? '0' : openingAmount.text.trim());
    if (paid == null || paid < 0 || opening == null || opening < 0) {
      setState(() => error = 'أدخل مبالغ صحيحة من دون قيم سالبة.');
      return;
    }
    setState(() { saving = true; error = null; });
    try {
      await service.saveMonth(
        month: month,
        openingBalance: openingIsPartnerDue ? opening : -opening,
        manualPaid: paid,
        openingDetails: openingDetails.text,
        userId: widget.userId,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ تسوية الشهر في دفتر التسويات المستقل.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _exportPdf() async {
    if (data == null || loading) return;
    final d = data!;
    final closing = _n(d['closing_balance']);
    final boxes = <StatBoxData>[
      StatBoxData(number: '1', title: 'إجمالي أرباح الشركاء لهذا الشهر', value: '${_money(d['partner_profit'])} ريال', isBlueTint: true, isLarge: true),
      StatBoxData(number: '2', title: _n(d['opening_balance']) >= 0 ? 'المتبقي للشركاء من الأشهر السابقة' : 'المتبقي للمحاسب عند الشركاء من الأشهر السابقة', value: '${_money(_n(d['opening_balance']).abs())} ريال'),
      StatBoxData(number: '3', title: 'المسلّم للشركاء عبر سجلات التطبيق', value: '${_money(d['partner_app_paid'])} ريال', isBlueTint: true),
      StatBoxData(number: '4', title: 'المسلّم يدوياً من المحاسب هذا الشهر', value: '${_money(d['manual_paid'])} ريال'),
      StatBoxData(number: '5', title: closing > 0 ? 'المتبقي للشركاء عند المحاسب' : closing < 0 ? 'المتبقي للمحاسب عند الشركاء' : 'حساب الشركاء متوازن', value: '${_money(closing.abs())} ريال', isBlueTint: true, isLarge: true),
      StatBoxData(number: '6', title: 'المتبقي على جميع المستفيدين حتى نهاية الشهر', value: '${_money(d['beneficiary_due'])} ريال'),
      StatBoxData(number: '7', title: 'المسلّم من المستفيدين هذا الشهر', value: '${_money(d['beneficiary_paid'])} ريال', isBlueTint: true),
      StatBoxData(number: '8', title: 'المبالغ التي للمستفيدين', value: '${_money(d['beneficiary_credit'])} ريال'),
      StatBoxData(number: '9', title: 'المتبقي للعمال حتى نهاية الشهر', value: '${_money(d['worker_due'])} ريال', isBlueTint: true),
      StatBoxData(number: '10', title: 'المسلّم للعمال هذا الشهر', value: '${_money(d['worker_paid'])} ريال'),
      StatBoxData(number: '11', title: 'المتبقي للمحطة عند العمال', value: '${_money(d['worker_credit'])} ريال', isBlueTint: true),
      StatBoxData(number: '12', title: 'إجمالي المصروفات المسجلة', value: '${_money(d['expenses'])} ريال', isBlueTint: true),
    ];
    final settings = await widget.repo.settings();
    await OfficialReportTemplate.preview(
      rightHeader1: 'الجمهورية اليمنية',
      rightHeader2: 'نظام ساقية لإدارة محطة ضخ مياه الري',
      rightHeader3: settings['station_name'] ?? 'محطة ساقية',
      date: DateFormat('yyyy/MM/dd').format(AppClock.now()),
      refNumber: 'REC-${d['month_key']}',
      attachments: 'ملخص إحصائي فقط',
      reportTitle: 'بطاقات التسوية الشهرية — ${d['month_key']}',
      summaryBoxes: boxes,
      columns: const [],
      rows: const [],
      cardsOnly: true,
      pageFormat: pdf.PdfPageFormat.a4,
      fileName: 'reconciliation_${d['month_key']}.pdf',
      printAfterGenerate: true,
    );
  }

  Widget _card(String title, Object? amount, IconData icon, Color color, {String suffix = 'ريال'}) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: color.withValues(alpha: .22))),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(color: color.withValues(alpha: .11), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: color)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 5),
            Text('${_money(amount)} $suffix', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: color)),
          ])),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final closing = _n(d?['closing_balance']);
    final hasPrevious = d?['has_previous'] == true;
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التسوية الشهرية'),
          actions: [
            IconButton(onPressed: loading ? null : _load, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded)),
            IconButton(onPressed: loading || d == null ? null : _exportPdf, tooltip: 'PDF بطاقات إحصائية', icon: const Icon(Icons.picture_as_pdf_rounded)),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null && d == null
                ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(error!)))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                    children: [
                      Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            IconButton(onPressed: () { setState(() => month = DateTime(month.year, month.month - 1, 1)); _load(); }, icon: const Icon(Icons.chevron_right_rounded)),
                            Expanded(child: Column(children: [
                              const Text('الشهر المحدد', style: TextStyle(fontSize: 12)),
                              Text('${month.year}/${month.month.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                            ])),
                            IconButton(onPressed: () { setState(() => month = DateTime(month.year, month.month + 1, 1)); _load(); }, icon: const Icon(Icons.chevron_left_rounded)),
                          ]),
                        ),
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Material(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                error!,
                                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _sectionTitle('أولاً: حساب الشركاء'),
                      _card('إجمالي أرباح الشركاء لهذا الشهر', d?['partner_profit'], Icons.groups_rounded, Colors.teal),
                      _card('المسلّم للشركاء من خلال سجلات التطبيق', d?['partner_app_paid'], Icons.payments_rounded, Colors.blue),
                      _card(_n(d?['opening_balance']) < 0 ? 'المتبقي للمحاسب عند الشركاء من الأشهر السابقة' : 'المتبقي للشركاء عند المحاسب من الأشهر السابقة', _n(d?['opening_balance']).abs(), Icons.history_rounded, Colors.deepOrange, suffix: _n(d?['opening_balance']) < 0 ? 'ريال (على الشركاء للمحاسب)' : 'ريال (على المحاسب للشركاء)'),
                      Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        child: Padding(
                          padding: const EdgeInsets.all(15),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            const Text('تسليمات المحاسب اليدوية للشركاء', style: TextStyle(fontWeight: FontWeight.w900)),
                            const SizedBox(height: 8),
                            TextField(key: const ValueKey('reconciliation-manual-paid-field'), controller: manualPaid, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ المسلّم خلال هذا الشهر', suffixText: 'ريال', border: OutlineInputBorder())),
                            const SizedBox(height: 5),
                            const Text('أدخل هنا ما سلّمه المحاسب خارج سجلات المدفوعات؛ المبالغ المسجلة في التطبيق محسوبة تلقائياً أعلاه.', style: TextStyle(fontSize: 11, color: Colors.black54)),
                            if (!hasPrevious) ...[
                              const SizedBox(height: 14),
                              const Text('الرصيد الافتتاحي عند أول استخدام', style: TextStyle(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 5),
                              SegmentedButton<bool>(
                                segments: const [
                                  ButtonSegment(value: true, label: Text('المحاسب مدين للشركاء')),
                                  ButtonSegment(value: false, label: Text('الشركاء مدينون للمحاسب')),
                                ],
                                selected: {openingIsPartnerDue},
                                onSelectionChanged: (v) => setState(() => openingIsPartnerDue = v.first),
                              ),
                              const SizedBox(height: 8),
                              TextField(controller: openingAmount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قيمة الرصيد الافتتاحي', suffixText: 'ريال', border: OutlineInputBorder())),
                              const SizedBox(height: 8),
                              TextField(
                                controller: openingDetails,
                                minLines: 2,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                  labelText: 'تفصيل الأشهر التي يتكون منها الرصيد السابق',
                                  hintText: 'مثال: أغسطس 2026: 50,000 ريال\nسبتمبر 2026: 25,000 ريال',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            FilledButton.icon(onPressed: saving ? null : _save, icon: saving ? const SizedBox(width: 18,height: 18,child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded), label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ تسوية الشهر')),
                          ]),
                        ),
                      ),
                      Card(
                        elevation: 0,
                        color: closing == 0 ? Colors.green.withValues(alpha: .07) : closing > 0 ? Colors.orange.withValues(alpha: .08) : Colors.red.withValues(alpha: .07),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        child: Padding(padding: const EdgeInsets.all(17), child: Column(children: [
                          const Text('نتيجة تسوية الشركاء', style: TextStyle(fontWeight: FontWeight.w900)),
                          const SizedBox(height: 8),
                          Text('${_money(closing.abs())} ريال', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                          Text(closing > 0 ? 'المحاسب ما زال مديناً للشركاء' : closing < 0 ? 'الشركاء أصبحوا مدينين للمحاسب' : 'الحساب متوازن'),
                        ])),
                      ),
                      _sectionTitle('ثانياً: حساب المستفيدين (الرعية)'),
                      _card('المتبقي على المستفيدين حتى نهاية الشهر', d?['beneficiary_due'], Icons.people_alt_rounded, Colors.deepOrange),
                      _card('المسلّم من المستفيدين هذا الشهر', d?['beneficiary_paid'], Icons.receipt_long_rounded, Colors.teal),
                      _card('الأرصدة التي للمستفيدين حتى نهاية الشهر', d?['beneficiary_credit'], Icons.account_balance_wallet_rounded, Colors.blue),
                      _sectionTitle('ثالثاً: حساب العمال'),
                      _card('المتبقي للعمال حتى نهاية الشهر', d?['worker_due'], Icons.engineering_rounded, Colors.deepOrange),
                      _card('المتبقي للمحطة عند العمال حتى نهاية الشهر', d?['worker_credit'], Icons.account_balance_wallet_rounded, Colors.blue),
                      _card('إجمالي المسلّم للعمال هذا الشهر', d?['worker_paid'], Icons.payments_rounded, Colors.teal),
                      _sectionTitle('رابعاً: المصروفات'),
                      _card('إجمالي المصروفات المسجلة لهذا الشهر', d?['expenses'], Icons.receipt_rounded, Colors.indigo),
                      if ((d?['history'] as List? ?? const []).isNotEmpty) ...[
                        _sectionTitle('التسويات المحفوظة للأشهر السابقة'),
                        for (final row in (d!['history'] as List).cast<Map<String, Object?>>())
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            title: Text('${row['month_key']}'),
                            subtitle: Text(
                              _historySubtitle(row),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              '${_n(row['closing_balance']) > 0 ? 'للشركاء: ' : _n(row['closing_balance']) < 0 ? 'للمحاسب: ' : ''}${_money(_n(row['closing_balance']).abs())} ريال',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                      ],
                      const SizedBox(height: 10),
                      OutlinedButton.icon(onPressed: _exportPdf, icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('طباعة PDF — بطاقات إحصائية فقط')),
                    ],
                  ),
      ),
    );
  }

  String _historySubtitle(Map<String, Object?> row) {
    final details = '${row['opening_details'] ?? ''}'.trim();
    return 'افتتاحي: ${_money(row['opening_balance'])} | أرباح: ${_money(row['partner_profit'])} | مسلّم بالتطبيق: ${_money(row['partner_app_paid'])} | يدوي: ${_money(row['manual_paid'])} ريال'
        '${details.isEmpty ? '' : '\nتفصيل الافتتاحي: $details'}';
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(4, 18, 4, 5),
    child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
  );
}
