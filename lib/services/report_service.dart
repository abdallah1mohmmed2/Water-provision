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
    final configuredRows = int.tryParse(set['pdf_rows'] ?? '30') ?? 30;
    final pageRows = configuredRows < 1 ? 30 : configuredRows;
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
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(24, 22, 24, 20),
          theme: pw.ThemeData.withFont(base: font, bold: bold),
          build: (ctx) => pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#10243E'),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(16)),
                  ),
                  child: pw.Row(children: [
                    pw.Container(width: 38, height: 38, decoration: pw.BoxDecoration(color: PdfColor.fromHex('#22C7D6'), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(11))), child: pw.Center(child: pw.Text('س', style: pw.TextStyle(font: bold, fontSize: 20, color: PdfColors.white)))),
                    pw.SizedBox(width: 12),
                    pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                      pw.Text(titles[key] ?? key, style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColors.white)),
                      pw.SizedBox(height: 3),
                      pw.Text(station, style: pw.TextStyle(font: font, fontSize: 8, color: PdfColor.fromHex('#D9E7F5'))),
                    ])),
                    pw.Container(padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7), decoration: pw.BoxDecoration(color: PdfColor.fromHex('#183B5F'), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10))), child: pw.Text('عدد السجلات: ${rows.length}', style: pw.TextStyle(font: bold, fontSize: 8, color: PdfColors.white))),
                  ]),
                ),
                pw.SizedBox(height: 9),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: pw.BoxDecoration(color: PdfColor.fromHex('#EEF4FA'), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10))),
                  child: pw.Text(filterText, style: pw.TextStyle(font: font, fontSize: 8, color: PdfColor.fromHex('#34495E'))),
                ),
                pw.SizedBox(height: 9),
                pw.Expanded(
                  child: pw.Container(
                    decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColor.fromHex('#D6E1EC'), width: .6), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12))),
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Table.fromTextArray(
                      headers: headers,
                      data: data,
                      headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1C5D8F')),
                      headerStyle: pw.TextStyle(font: bold, fontSize: 7, color: PdfColors.white),
                      cellStyle: pw.TextStyle(font: font, fontSize: 6.5, color: PdfColor.fromHex('#182532')),
                      oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F7FAFD')),
                      cellAlignment: pw.Alignment.center,
                      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                      border: pw.TableBorder.symmetric(inside: pw.BorderSide(color: PdfColor.fromHex('#DCE6EF'), width: .35)),
                    ),
                  ),
                ),
                if (pi == pages.length - 1 && rows.isNotEmpty)
                  pw.Container(
                    alignment: pw.Alignment.centerRight,
                    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: pw.Text(_reportNetSummary(rows.last), style: pw.TextStyle(font: bold, fontSize: 9, color: PdfColor.fromHex('#10243E'))),
                  ),
                pw.SizedBox(height: 7),
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Text('صفحة ${pi + 1} / ${pages.length}', style: pw.TextStyle(font: font, fontSize: 7, color: PdfColor.fromHex('#667788'))),
                  pw.Text('تقرير مولّد من نظام إدارة المحطة', style: pw.TextStyle(font: font, fontSize: 7, color: PdfColor.fromHex('#667788'))),
                ]),
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
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5,
        theme: pw.ThemeData.withFont(base: font, bold: bold),
        build: (c) => pw.Directionality(
          textDirection: pw.TextDirection.rtl,
          child: pw.Center(
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  'إيصال قبض',
                  style: pw.TextStyle(font: bold, fontSize: 20),
                ),
                pw.SizedBox(height: 12),
                pw.Text('الطرف: ${x['party_name'] ?? '-'}'),
                pw.Text('المبلغ: ${x['amount']} ريال'),
                pw.Text('طريقة الدفع: ${x['method_name']}'),
                pw.Text('الصندوق: ${x['cashbox_name']}'),
                pw.Text('التاريخ: ${x['date']}'),
                pw.Text('المرجع: ${x['reference_number'] ?? '-'}'),
              ],
            ),
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
