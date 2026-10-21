import '../core/app_clock.dart';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';

class ReportService {
  final StationRepository repo;
  ReportService([StationRepository? r]) : repo = r ?? StationRepository();

  static const titles = {
    'irrigations': 'تقرير السقايات التفصيلي',
    'cash_flow': 'التدفق النقدي',
    'time_comparison': 'المقارنة الزمنية',
    'monthly_financial': 'التقرير المالي الشهري',
    'income': 'تقرير الدخل',
    'payment_methods': 'طرق الدفع وأرقام الحسابات',
    'expenses': 'المصروفات',
    'cashboxes': 'الصناديق والتحويلات',
    'queue_bookings': 'الطابور وطلبات الحجز',
    'payment_log': 'سجل المدفوعات',
    'beneficiary_statement': 'كشف حساب المستفيد',
    'beneficiary_detailed': 'كشف الحساب المفصل للمستفيد',
    'beneficiary_stats': 'إحصائيات المستفيدين',
    'needy': 'المستفيدون المحتاجون',
    'diesel_inventory': 'مخزون الديزل',
    'activity_overview': 'نظرة عامة على النشاط',
    'oil_status': 'حالة الزيت',
    'debts': 'المديونيات',
    'beneficiary_list': 'قائمة المستفيدين',
    'revenue_comparison': 'مقارنة الإيرادات',
    'system_comparison': 'مقارنة منظومات الري',
    'journal': 'دفتر اليومية',
    'ledger': 'دفتر الأستاذ العام',
    'worker_transactions': 'معاملات العمال',
    'partner_accounts': 'حسابات الشركاء',
    'partner_profit_distribution': 'صافي أرباح وتوزيعات الشركاء',
  };

  static const reportColumns = <String, List<String>>{
    'irrigations': ['party_name','start_datetime','end_datetime','minutes','paid_amount','total_amount','cloud_minutes','cloud_status'],
    'cash_flow': ['date','kind','amount','title'],
    'time_comparison': ['month','system_type','minutes','chargeable_minutes','operations','total'],
    'monthly_financial': ['month','income','expenses'],
    'income': ['system_type','operations','water_income','diesel_income','total'],
    'payment_methods': ['method_name','type','account_number','total'],
    'expenses': ['category','count','total'],
    'cashboxes': ['name','incoming','outgoing','current_balance'],
    'queue_bookings': ['source','name','status','date'],
    'payment_log': ['date','party_name','method_name','cashbox_name','amount'],
    'beneficiary_statement': ['date','description','lah','alayh','balance'],
    'beneficiary_detailed': ['date','description','lah','alayh','balance'],
    'worker_transactions': ['date','description','lah','alayh','balance'],
    'partner_accounts': ['date','description','lah','alayh','balance'],
    'partner_profit_distribution': ['name','mode','basis','amount'],
    'beneficiary_stats': ['name','irrigations','minutes','total'],
    'needy': ['name','balance'],
    'diesel_inventory': ['date','kind','liters','amount','beneficiary_name'],
    'activity_overview': ['system_type','operations','minutes','total'],
    'oil_status': ['category','total'],
    'debts': ['id','name','balance'],
    'beneficiary_list': ['name','phone','status'],
    'revenue_comparison': ['month','system_type','total'],
    'system_comparison': ['system_type','operations','minutes','total','diesel_cost'],
    'journal': ['date','description','account_code','account_name','debit','credit'],
    'ledger': ['date','description','account_code','account_name','debit','credit'],
    'worker_transactions': ['date','description','lah','alayh','balance'],
    'partner_accounts': ['date','description','lah','alayh','balance'],
  };

  Future<Uint8List> pdf(
    String key, {
    DateTime? from,
    DateTime? to,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    String? systemType,
    int? cashboxId,
    int? paymentMethodId,
    String? category,
    String? status,
  }) async {
    final started = AppClock.now();
    if (!titles.containsKey(key) || !reportColumns.containsKey(key)) {
      throw StateError('تقرير غير معروف أو غير مرتبط بمصدر بيانات: $key');
    }
    final currentType = (await repo.settings())['system_type'] ?? 'diesel';
    if (key == 'diesel_inventory' && currentType != 'diesel') {
      throw StateError('تقرير الديزل غير متاح لأن المنظومة الحالية ليست ديزل');
    }
    systemType ??= currentType;
    final rows = await repo.report(
      key,
      from: from,
      to: to,
      beneficiaryId: beneficiaryId,
      workerId: workerId,
      partnerId: partnerId,
      systemType: systemType,
      cashboxId: cashboxId,
      paymentMethodId: paymentMethodId,
      category: category,
      status: status,
    );
    final doc = pw.Document();
    final set = await repo.settings();
    final font = pw.Font.ttf(
      (await rootBundle.load(
        'assets/fonts/NotoNaskhArabic-Regular.ttf',
      )).buffer.asByteData(),
    );
    final bold = pw.Font.ttf(
      (await rootBundle.load(
        'assets/fonts/NotoNaskhArabic-Bold.ttf',
      )).buffer.asByteData(),
    );
    // Keep each portrait page close to the reference layout: compact table,
    // summary cards and closing section remain visible without vertical overflow.
    final configuredRows = int.tryParse(set['pdf_rows'] ?? '8') ?? 8;
    final pageRows = configuredRows < 1 ? 8 : configuredRows.clamp(1, 10).toInt();
    final pages = <List<Map<String, Object?>>>[];
    for (var i = 0; i < rows.length; i += pageRows)
      pages.add(
        rows.sublist(
          i,
          (i + pageRows > rows.length ? rows.length : i + pageRows),
        ),
      );
    if (pages.isEmpty) pages.add(<Map<String, Object?>>[]);
    final station = set['station_name'] ?? 'محطة ساقية';
    final filterText = _filters(
      from,
      to,
      systemType,
      beneficiaryId,
      workerId,
      partnerId,
      cashboxId,
      paymentMethodId,
      category,
      status,
    );
    for (var pi = 0; pi < pages.length; pi++) {
      final chunk = pages[pi];
      final sourceHeaders = chunk.isEmpty
          ? <String>[]
          : (reportColumns[key] ?? chunk.first.keys.take(8).toList())
              .where((h) => chunk.first.containsKey(h))
              .toList();
      if (sourceHeaders.isEmpty && chunk.isNotEmpty) sourceHeaders.addAll(chunk.first.keys.take(8));
      final headers = sourceHeaders.map(_fieldName).toList();
      final data = chunk
          .map((r) => sourceHeaders.map((h) => _formatValue(h, r[h], key)).toList())
          .toList();
      if (chunk.isEmpty) data.add(['لا توجد بيانات']);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(24, 22, 24, 20),
          theme: pw.ThemeData.withFont(base: font, bold: bold),
          build: (ctx) => pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _reportHeader(
                  title: titles[key] ?? key,
                  station: station,
                  reportNumber: '#${(pi + 1).toString().padLeft(4, '0')}',
                  recordCount: rows.length,
                  date: AppClock.now(),
                  font: font,
                  bold: bold,
                ),
                pw.SizedBox(height: 0),
                pw.Container(
                  height: 7,
                  child: pw.Row(children: [
                    pw.Expanded(child: pw.Container(color: PdfColor.fromHex('#174A70'))),
                    pw.Expanded(child: pw.Container(color: PdfColor.fromHex('#087A68'))),
                    pw.Expanded(child: pw.Container(color: PdfColor.fromHex('#48A23F'))),
                  ]),
                ),
                pw.SizedBox(height: 9),
                _reportSummary(
                  key: key,
                  rows: rows,
                  filterText: filterText,
                  font: font,
                  bold: bold,
                ),
                pw.SizedBox(height: 9),
                pw.Container(
                  decoration: pw.BoxDecoration(
                    color: PdfColors.white,
                    border: pw.Border.all(color: PdfColor.fromHex('#B9C2CA'), width: .7),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(9)),
                  ),
                  padding: const pw.EdgeInsets.all(5),
                  child: pw.Table.fromTextArray(
                    headers: headers.isEmpty ? ['البيان'] : headers,
                    data: data.isEmpty ? [['لا توجد بيانات']] : data,
                    headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#123C5A')),
                    headerStyle: pw.TextStyle(font: bold, fontSize: 8, color: PdfColors.white),
                    cellStyle: pw.TextStyle(font: font, fontSize: 7, color: PdfColor.fromHex('#182532')),
                    oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F0F1F2')),
                    cellAlignment: pw.Alignment.center,
                    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
                    border: pw.TableBorder.symmetric(inside: pw.BorderSide(color: PdfColor.fromHex('#D2D5D8'), width: .45)),
                  ),
                ),
                if (pi == pages.length - 1)
                  _reportClosing(
                    key: key,
                    rows: rows,
                    font: font,
                    bold: bold,
                  ),
                pw.Spacer(),
                pw.SizedBox(height: 7),
                _reportFooter(
                  page: pi + 1,
                  totalPages: pages.length,
                  font: font,
                  bold: bold,
                ),
              ],
            ),
          ),
        ),
      );
    }
    await repo.db.insert('report_runs', {
      'report_key': key,
      'filters_json':
          '{"from":"${from?.toIso8601String()}","to":"${to?.toIso8601String()}","systemType":"$systemType"}',
      'generated_at': AppClock.now().toIso8601String(),
      'row_count': rows.length,
      'duration_ms': AppClock.now().difference(started).inMilliseconds,
    });
    return doc.save();
  }

  // ملخص بصري على هيئة بطاقات، مع حقول تتغير حسب نوع التقرير.
  pw.Widget _reportSummary({
    required String key,
    required List<Map<String, Object?>> rows,
    required String filterText,
    required pw.Font font,
    required pw.Font bold,
  }) {
    num sumOf(String field) => rows.fold<num>(0, (sum, row) {
      final value = row[field];
      if (value is num) return sum + value;
      return sum + (num.tryParse('$value') ?? 0);
    });
    final count = rows.length;
    final total = sumOf('total_amount') != 0
        ? sumOf('total_amount')
        : sumOf('total') != 0
            ? sumOf('total')
            : sumOf('amount');
    final minutes = sumOf('minutes');
    final paid = sumOf('paid_amount');
    final cards = <List<String>>[
      ['عدد السجلات', _format(count)],
      if (rows.any((r) => r.containsKey('minutes'))) ['إجمالي الدقائق', '${_format(minutes)} دقيقة'],
      if (rows.any((r) => r.containsKey('total_amount') || r.containsKey('total') || r.containsKey('amount'))) ['الإجمالي', '${_format(total)} ر.س'],
      if (rows.any((r) => r.containsKey('paid_amount'))) ['إجمالي المدفوع', '${_format(paid)} ر.س'],
      if (rows.any((r) => r.containsKey('balance'))) ['الرصيد الختامي', _format(rows.isEmpty ? 0 : rows.last['balance'])],
      ['الفترة والتصفية', filterText],
    ];
    return pw.Container(
      padding: const pw.EdgeInsets.all(9),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#EEF0F2'),
        border: pw.Border.all(color: PdfColor.fromHex('#AEB7BE'), width: .7),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(9)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text('ملخص التقرير', style: pw.TextStyle(font: bold, fontSize: 11)),
          pw.SizedBox(height: 6),
          pw.GridView(
            crossAxisCount: 3,
            childAspectRatio: 3.4,
            crossAxisSpacing: 5,
            mainAxisSpacing: 5,
            children: [
              for (final card in cards)
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.white,
                    border: pw.Border.all(color: PdfColor.fromHex('#C5C9CD'), width: .6),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
                  ),
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(card[0], style: pw.TextStyle(font: font, fontSize: 7, color: PdfColor.fromHex('#48545D')),
                          maxLines: 1, overflow: pw.TextOverflow.clip),
                      pw.SizedBox(height: 2),
                      pw.Text(card[1], style: pw.TextStyle(font: bold, fontSize: 9),
                          maxLines: 2, overflow: pw.TextOverflow.clip),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _reportClosing({
    required String key,
    required List<Map<String, Object?>> rows,
    required pw.Font font,
    required pw.Font bold,
  }) {
    num sumOf(String field) => rows.fold<num>(0, (sum, row) {
      final value = row[field];
      if (value is num) return sum + value;
      return sum + (num.tryParse('$value') ?? 0);
    });
    final amount = sumOf('total_amount') != 0
        ? sumOf('total_amount')
        : sumOf('total') != 0
            ? sumOf('total')
            : sumOf('amount');
    final paid = sumOf('paid_amount');
    final hasFinancial = rows.any((r) => r.containsKey('amount') || r.containsKey('total') || r.containsKey('total_amount'));
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 7),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#E5E7E9'),
        border: pw.Border.all(color: PdfColor.fromHex('#B8BEC3'), width: .7),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(7)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: PdfColor.fromHex('#D1D5D8'),
            child: pw.Text('الخلاصة والختام', style: pw.TextStyle(font: bold, fontSize: 10)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: pw.Text(
              hasFinancial
                  ? 'إجمالي التقرير: ${_format(amount)} ر.س${rows.any((r) => r.containsKey('paid_amount')) ? '  •  إجمالي المدفوع: ${_format(paid)} ر.س' : ''}'
                  : 'إجمالي السجلات: ${rows.length}',
              style: pw.TextStyle(font: bold, fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }

  // قالب موحّد قابل لإعادة الاستخدام لرؤوس جميع تقارير PDF.
  pw.Widget _reportHeader({
    required String title,
    required String station,
    required String reportNumber,
    required int recordCount,
    required DateTime date,
    required pw.Font font,
    required pw.Font bold,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: PdfColor.fromHex('#D0D5D9'), width: .6),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('تاريخ التقرير: ${DateFormat('yyyy-MM-dd').format(date)}',
                    style: pw.TextStyle(font: font, fontSize: 8)),
                pw.SizedBox(height: 4),
                pw.Text('رقم التقرير: $reportNumber',
                    style: pw.TextStyle(font: font, fontSize: 8)),
                pw.SizedBox(height: 4),
                pw.Text('عدد السجلات: $recordCount',
                    style: pw.TextStyle(font: font, fontSize: 8)),
              ],
            ),
          ),
          pw.SizedBox(width: 8),
          pw.Expanded(
            flex: 2,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Text('إدارة المحطة - نظام السقايات الرقمي',
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(font: bold, fontSize: 9)),
                pw.SizedBox(height: 7),
                pw.Text(title,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColor.fromHex('#111827'))),
                pw.SizedBox(height: 4),
                pw.Text(station,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(font: bold, fontSize: 10)),
              ],
            ),
          ),
          pw.SizedBox(width: 8),
          pw.Container(
            width: 48,
            height: 48,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#F4FAF8'),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.SvgImage(
              svg: '''<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
                <path d="M24 3 C19 12 9 20 9 29 A15 15 0 0 0 39 29 C39 20 29 12 24 3Z" fill="#1598C7"/>
                <path d="M23 39 C22 29 26 21 34 16" fill="none" stroke="#238B53" stroke-width="2.6" stroke-linecap="round"/>
                <path d="M25 29 C15 29 14 23 14 21 C21 21 25 24 25 29Z" fill="#55A64A"/>
                <path d="M29 23 C29 15 35 12 38 12 C38 20 34 23 29 23Z" fill="#368C45"/>
              </svg>''',
            ),
          ),
        ],
      ),
    );
  }

  // تذييل موحّد مع مساحة توقيع وختم وترقيم الصفحات.
  pw.Widget _reportFooter({
    required int page,
    required int totalPages,
    required pw.Font font,
    required pw.Font bold,
  }) {
    return pw.Column(
      children: [
        pw.Container(height: .8, color: PdfColor.fromHex('#687780')),
        pw.SizedBox(height: 5),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Container(
              width: 105,
              height: 35,
              alignment: pw.Alignment.bottomCenter,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColor.fromHex('#C9CED3'), width: .7),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Text('التوقيع والختم', style: pw.TextStyle(font: font, fontSize: 7)),
            ),
            pw.Spacer(),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('التطوير مولّد من النظام - إدارة المحطة',
                    style: pw.TextStyle(font: bold, fontSize: 7)),
                pw.SizedBox(height: 3),
                pw.Text('صفحة $page من $totalPages',
                    style: pw.TextStyle(font: font, fontSize: 7, color: PdfColor.fromHex('#667788'))),
              ],
            ),
          ],
        ),
      ],
    );
  }

  String _reportNetSummary(Map<String, Object?> row) {
    final value = row['balance'] is num ? (row['balance'] as num).round() : int.tryParse('${row['balance']}') ?? 0;
    if (value > 0) return 'إجمالي المتبقي عليه: ${_format(value)} ريال';
    if (value < 0) return 'إجمالي المتبقي له: ${_format(value.abs())} ريال';
    return 'إجمالي المتبقي: متوازن';
  }

  String _fieldName(String key) => {
    'id':'الرقم','date':'التاريخ','start_datetime':'بداية السقي','end_datetime':'نهاية السقي','month':'الشهر','minutes':'المدة بالدقائق','chargeable_minutes':'الدقائق المحاسبية','operations':'عدد العمليات','system_type':'نوع المنظومة','total_amount':'الإجمالي','total':'الإجمالي','income':'الإيرادات','expenses':'المصروفات','water_income':'إيراد المياه','diesel_income':'إيراد الديزل','diesel_cost':'تكلفة الديزل','paid_amount':'المدفوع','remaining':'حالة الرصيد','beneficiary_name':'المستفيد','party_name':'الجهة','cloud_status':'حالة خصم الغيم','worker_name':'العامل','partner_name':'الشريك','cashbox_name':'الصندوق','method_name':'طريقة الدفع','account_name':'الحساب','account_code':'رمز الحساب','debit':'له','credit':'عليه','lah':'له','alayh':'عليه','amount':'المبلغ','liters':'اللترات','kind':'نوع الحركة','status':'الحالة','notes':'ملاحظات','description':'البيان','ownership_percentage':'نسبة الملكية','shares_count':'عدد الحصص','opening_balance':'الرصيد الافتتاحي','carried_balance':'الرصيد المرحل','balance':'حالة الرصيد','water_amount':'قيمة المياه','diesel_amount':'قيمة الديزل','cloud_minutes':'دقائق الغيم','category':'التصنيف','title':'العنوان','phone':'الهاتف','name':'الاسم','reference_number':'رقم المرجع','created_at':'تاريخ الإنشاء','updated_at':'تاريخ التحديث','position':'الدور','scheduled_start':'بداية الموعد','scheduled_end':'نهاية الموعد','payment_method_id':'طريقة الدفع','cashbox_id':'الصندوق','beneficiary_id':'المستفيد','worker_id':'العامل','partner_id':'الشريك','journal_id':'رقم القيد','journal_entry_id':'رقم القيد','ownership_mode':'طريقة الملكية','pump_name':'المضخة','queue_position':'رقم الدور',
  }[key] ?? 'بيان';

  String _categoryName(String v) => {
    'workers': 'عمال', 'partners': 'شركاء', 'fuel': 'وقود', 'oil': 'زيت',
    'grease': 'شحم', 'maintenance': 'صيانة', 'parts': 'قطع غيار',
    'transport': 'نقل', 'admin': 'إدارية', 'other': 'أخرى',
  }[v] ?? 'تصنيف';

  String _paymentTypeName(String v) => {
    'cash': 'نقدي', 'check': 'شيك', 'bank_transfer': 'تحويل بنكي',
    'wallet': 'محفظة', 'other': 'أخرى',
  }[v] ?? 'طريقة دفع';

  String _formatValue(String key, Object? value, [String? reportKey]) {
    final partyReport = reportKey == 'worker_transactions' || reportKey == 'partner_accounts';
    if (partyReport && key == 'type') {
      return AccountingCalculations.partyTransactionTypeName('$value');
    }
    if (key == 'start_datetime' || key == 'end_datetime') {
      final d = DateTime.tryParse('$value');
      if (d != null) return DateFormat('yyyy/MM/dd HH:mm', 'ar').format(d);
    }
    if (key == 'cloud_status') {
      return '$value' == 'discounted' ? 'تم خصم الغيم' : 'لا يوجد خصم';
    }
    if (key == 'system_type') {
      return switch ('$value') { 'diesel' => 'ديزل', 'solar' => 'شمسي', 'equivalent_hybrid' => 'النوع الثالث', _ => 'غير محدد' };
    }
    if (key == 'status') return switch ('$value') { 'waiting'=>'منتظر','postponed'=>'مؤجل','running'=>'قيد التشغيل','completed'=>'مكتمل','new'=>'جديد','under_review'=>'قيد المراجعة','scheduled'=>'مجدول','accepted'=>'مقبول','cancelled'=>'ملغى','posted'=>'مرحل', _=> 'غير محدد' };
    if (key == 'kind') return switch ('$value') { 'receipt'=>'شراء وإضافة','delivery'=>'تسليم','advance'=>'سلفة','consumption'=>'استهلاك','correction'=>'تصحيح','opening_balance'=>'رصيد افتتاحي','payment'=>'دفعة','expense'=>'مصروف', _=> 'حركة' };
    if (key == 'lah' || key == 'alayh') return _format(value);
    if (key == 'balance' || key == 'remaining') {
      final n = value is num ? value.round() : int.tryParse('$value') ?? 0;
      // العامل/الشريك: الموجب = له (مستحق على المحطة)، عكس المستفيد.
      if (partyReport && key == 'balance') return _partyDueLabel(n);
      return _balanceLabel(n);
    }
    if (key == 'category') return _categoryName('$value');
    if (key == 'type') return _paymentTypeName('$value');
    if (key == 'ownership_mode') return value == 'percentage' ? 'نسبة ملكية' : 'عدد حصص';
    return _format(value);
  }

  String _filters(
    DateTime? from,
    DateTime? to,
    String? systemType,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    int? cashboxId,
    int? paymentMethodId,
    String? category,
    String? status,
  ) {
    final parts = <String>[];
    if (from != null) parts.add('من ${DateFormat('yyyy/MM/dd').format(from)}');
    if (to != null) parts.add('إلى ${DateFormat('yyyy/MM/dd').format(to)}');
    if (systemType != null)
      parts.add(
        'المنظومة: ${systemType == 'all'
            ? 'كل الأنواع'
            : systemType == 'diesel'
            ? 'ديزل'
            : systemType == 'solar'
            ? 'شمسي'
            : 'النوع الثالث'}',
      );
    if (beneficiaryId != null) parts.add('تم تحديد مستفيد');
    if (workerId != null) parts.add('تم تحديد عامل');
    if (partnerId != null) parts.add('تم تحديد شريك');
    if (cashboxId != null) parts.add('تم تحديد صندوق');
    if (paymentMethodId != null) parts.add('تم تحديد طريقة دفع');
    if (category != null) parts.add('التصنيف: $category');
    if (status != null) parts.add('الحالة: $status');
    return parts.isEmpty ? 'بدون فلاتر' : parts.join(' • ');
  }

  String _partyDueLabel(int balance) => balance > 0
      ? 'له ${NumberFormat('#,##0', 'ar').format(balance)} ريال'
      : balance < 0
      ? 'عليه ${NumberFormat('#,##0', 'ar').format(balance.abs())} ريال'
      : 'متوازن';

  String _balanceLabel(int balance) => balance > 0
      ? 'عليه ${NumberFormat('#,##0', 'ar').format(balance)} ريال'
      : balance < 0
      ? 'له ${NumberFormat('#,##0', 'ar').format(balance.abs())} ريال'
      : 'متوازن';

  String _format(Object? value) {
    if (value == null) return '-';
    if (value is num) return NumberFormat('#,##0.##', 'ar').format(value);
    return '$value';
  }

  Future<Uint8List> paymentReceiptPdf(int paymentId) async {
    final rows = await repo.db.query(
      'SELECT p.*, COALESCE(b.name,COALESCE(w.name,pt.name)) party_name,pm.name method_name,c.name cashbox_name FROM payments p LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id LEFT JOIN workers w ON w.id=p.worker_id LEFT JOIN partners pt ON pt.id=p.partner_id JOIN payment_methods pm ON pm.id=p.payment_method_id JOIN cashboxes c ON c.id=p.cashbox_id WHERE p.id=?',
      args: [paymentId],
    );
    if (rows.isEmpty) throw StateError('الإيصال غير موجود');
    final x = rows.first;
    final font = pw.Font.ttf(
      (await rootBundle.load(
        'assets/fonts/NotoNaskhArabic-Regular.ttf',
      )).buffer.asByteData(),
    );
    final bold = pw.Font.ttf(
      (await rootBundle.load(
        'assets/fonts/NotoNaskhArabic-Bold.ttf',
      )).buffer.asByteData(),
    );
    final receiptSettings = await repo.settings();
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5,
        theme: pw.ThemeData.withFont(base: font, bold: bold),
        margin: const pw.EdgeInsets.all(18),
        build: (c) => pw.Directionality(
          textDirection: pw.TextDirection.rtl,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _reportHeader(
                title: 'إيصال قبض',
                station: receiptSettings['station_name'] ?? 'محطة ساقية',
                reportNumber: '#${x['id']}',
                recordCount: 1,
                date: AppClock.now(),
                font: font,
                bold: bold,
              ),
              pw.SizedBox(height: 5),
              pw.Container(
                height: 5,
                child: pw.Row(children: [
                  pw.Expanded(child: pw.Container(color: PdfColor.fromHex('#174A70'))),
                  pw.Expanded(child: pw.Container(color: PdfColor.fromHex('#087A68'))),
                  pw.Expanded(child: pw.Container(color: PdfColor.fromHex('#48A23F'))),
                ]),
              ),
              pw.SizedBox(height: 16),
              pw.Container(
                padding: const pw.EdgeInsets.all(14),
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#EEF0F2'),
                  border: pw.Border.all(color: PdfColor.fromHex('#B9C2CA')),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(9)),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    for (final item in <List<String>>[
                      ['الطرف', '${x['party_name'] ?? '-'}'],
                      ['المبلغ', '${x['amount']} ريال'],
                      ['طريقة الدفع', '${x['method_name']}'],
                      ['الصندوق', '${x['cashbox_name']}'],
                      ['التاريخ', '${x['date']}'],
                      ['المرجع', '${x['reference_number'] ?? '-'}'],
                    ]) ...[
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 7),
                        child: pw.Row(
                          children: [
                            pw.Expanded(child: pw.Text(item[0], style: pw.TextStyle(font: bold, fontSize: 10))),
                            pw.Expanded(flex: 2, child: pw.Text(item[1], style: pw.TextStyle(font: font, fontSize: 10))),
                          ],
                        ),
                      ),
                      pw.Divider(color: PdfColor.fromHex('#D6DCE1')),
                    ],
                  ],
                ),
              ),
              pw.Spacer(),
              _reportFooter(page: 1, totalPages: 1, font: font, bold: bold),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }

  Future<void> printPaymentReceipt(int paymentId) async =>
      Printing.layoutPdf(onLayout: (_) => paymentReceiptPdf(paymentId));

  Future<void> printPdf(
    String key, {
    DateTime? from,
    DateTime? to,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    String? systemType,
    int? cashboxId,
    int? paymentMethodId,
    String? category,
    String? status,
  }) async => Printing.layoutPdf(
    onLayout: (_) => pdf(
      key,
      from: from,
      to: to,
      beneficiaryId: beneficiaryId,
      workerId: workerId,
      partnerId: partnerId,
      systemType: systemType,
      cashboxId: cashboxId,
      paymentMethodId: paymentMethodId,
      category: category,
      status: status,
    ),
  );
}
