import '../core/app_clock.dart';
import 'package:intl/intl.dart';
import 'package:arabic_reshaper/arabic_reshaper.dart';
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
  'irrigations': ['party_name', 'start_datetime', 'end_datetime', 'minutes', 'paid_amount', 'total_amount', 'cloud_minutes', 'cloud_status'],
  'cash_flow': ['date', 'kind', 'amount', 'title'],
  'time_comparison': ['month', 'system_type', 'minutes', 'chargeable_minutes', 'operations', 'total'],
  'monthly_financial': ['month', 'income', 'expenses'],
  'income': ['system_type', 'operations', 'water_income', 'diesel_income', 'total'],
  'payment_methods': ['method_name', 'type', 'account_number', 'total'],
  'expenses': ['category', 'count', 'total'],
  'cashboxes': ['name', 'incoming', 'outgoing', 'current_balance'],
  'queue_bookings': ['source', 'name', 'status', 'date'],
  'payment_log': ['date', 'party_name', 'method_name', 'cashbox_name', 'amount'],
  'beneficiary_statement': ['date', 'description', 'lah', 'alayh', 'balance'],
  'beneficiary_detailed': ['date', 'description', 'lah', 'alayh', 'balance'],
  'worker_transactions': ['date', 'description', 'lah', 'alayh', 'balance'],
  'partner_accounts': ['date', 'description', 'lah', 'alayh', 'balance'],
  'partner_profit_distribution': ['name', 'mode', 'basis', 'gross_amount', 'partner_expenses', 'net_amount'],
  'beneficiary_stats': ['name', 'irrigations', 'minutes', 'total'],
  'needy': ['name', 'balance'],
  'diesel_inventory': ['date', 'kind', 'liters', 'amount', 'beneficiary_name'],
  'activity_overview': ['system_type', 'operations', 'minutes', 'total'],
  'oil_status': ['category', 'total'],
  'debts': ['id', 'name', 'balance'],
  'beneficiary_list': ['name', 'phone', 'status'],
  'revenue_comparison': ['month', 'system_type', 'total'],
  'system_comparison': ['system_type', 'operations', 'minutes', 'total', 'diesel_cost'],
  'journal': ['date', 'description', 'account_code', 'account_name', 'debit', 'credit'],
  'ledger': ['date', 'account_name', 'journal_entry_id', 'description', 'alayh', 'lah', 'balance'],
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
    List<Map<String, Object?>>? sourceRows,
  }) async {
    final started = AppClock.now();
    if (!titles.containsKey(key) || !reportColumns.containsKey(key)) {
      throw StateError('تقرير غير معروف أو غير مرتبط بمصدر بيانات: $key');
    }
    final settings = await repo.settings();
    final currentType = settings['system_type'] ?? 'diesel';
    if (key == 'diesel_inventory' && currentType != 'diesel') {
      throw StateError('تقرير الديزل غير متاح لأن المنظومة الحالية ليست ديزل');
    }
    systemType ??= currentType;
    final rows = sourceRows ?? await repo.report(
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

    // Include the actual selected person's name in every related report,
    // rather than showing only a generic "selected beneficiary/worker/partner".
    String? personName;
    if (beneficiaryId != null) {
      final person = await repo.db.rawQuery(
        'SELECT name FROM beneficiaries WHERE id=? LIMIT 1',
        [beneficiaryId],
      );
      if (person.isNotEmpty) personName = '${person.first['name'] ?? ''}'.trim();
    } else if (workerId != null) {
      final person = await repo.db.rawQuery(
        'SELECT name FROM workers WHERE id=? LIMIT 1',
        [workerId],
      );
      if (person.isNotEmpty) personName = '${person.first['name'] ?? ''}'.trim();
    } else if (partnerId != null) {
      final person = await repo.db.rawQuery(
        'SELECT name FROM partners WHERE id=? LIMIT 1',
        [partnerId],
      );
      if (person.isNotEmpty) personName = '${person.first['name'] ?? ''}'.trim();
    }
    if (personName != null && personName.isEmpty) personName = null;

    final doc = pw.Document();
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
    final sourceHeaders = rows.isEmpty
        ? <String>[]
        : (reportColumns[key] ?? rows.first.keys.take(8).toList())
            .where((header) => rows.first.containsKey(header))
            .toList();
    if (sourceHeaders.isEmpty && rows.isNotEmpty) {
      sourceHeaders.addAll(rows.first.keys.take(8));
    }
    final headers = sourceHeaders.map((header) {
      final label = key == 'irrigations'
          ? ({
              'party_name': 'الجهة',
              'start_datetime': 'من',
              'end_datetime': 'إلى',
              'minutes': 'المدة',
              'paid_amount': 'المدفوع',
              'total_amount': 'المبلغ',
              'cloud_minutes': 'الغيم',
              'cloud_status': 'حالة الخصم',
            }[header] ?? _fieldName(header))
          : _fieldName(header);
      return _shapeArabic(label);
    }).toList();
    final data = rows
        .map(
          (row) => sourceHeaders
              .map((header) => _shapeArabic(_formatValue(header, row[header], key)))
              .toList(),
        )
        .toList();
    final configuredRows = int.tryParse(settings['pdf_rows'] ?? '30') ?? 30;
    final targetRows = configuredRows.clamp(1, 40).toInt();
    // The preference controls table density; long/wrapped rows still paginate
    // automatically rather than being clipped to a fixed count per page.
    final cellFontSize = targetRows >= 26
        ? 7.5
        : targetRows >= 16
        ? 8.2
        : 9.0;
    final cellVerticalPadding = targetRows >= 26
        ? 3.5
        : targetRows >= 16
        ? 5.0
        : 7.0;
    final isLandscape = sourceHeaders.length >= 5 ||
        const {
          'irrigations',
          'payment_methods',
          'cashboxes',
          'diesel_inventory',
        }.contains(key);
    final pageFormat = isLandscape
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4;
    final station = settings['station_name'] ?? 'محطة ساقية';
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
      personName: personName,
    );
    final reportTitle = personName == null
        ? titles[key]!
        : '${titles[key]} — $personName';
    final reportNumber =
        'R-${DateFormat('yyMMdd-HHmm').format(started)}';

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(30, 22, 30, 28),
        theme: pw.ThemeData.withFont(base: font, bold: bold),
        maxPages: 1000,
        header: (_) => pw.Column(
          children: [
            _reportHeader(
              title: reportTitle,
              station: station,
              reportNumber: reportNumber,
              recordCount: rows.length,
              date: started,
              font: font,
              bold: bold,
            ),
            pw.SizedBox(height: 7),
            pw.Container(
              height: 3,
              child: pw.Row(
                children: [
                  pw.Expanded(
                    child: pw.Container(color: PdfColor.fromHex('#0B8277')),
                  ),
                  pw.Expanded(
                    child: pw.Container(color: PdfColor.fromHex('#46A68C')),
                  ),
                  pw.Expanded(
                    child: pw.Container(color: PdfColor.fromHex('#D9B66F')),
                  ),
                ],
              ),
            ),
          ],
        ),
        footer: (context) => _reportFooter(
          page: context.pageNumber,
          totalPages: context.pagesCount,
          font: font,
          bold: bold,
          showSignature: false,
        ),
        build: (_) => [
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: _reportSummary(
              rows: rows,
              filterText: filterText,
              font: font,
              bold: bold,
            ),
          ),
          pw.SizedBox(height: 12),
          if (rows.isEmpty)
            _emptyReportState(font: font, bold: bold)
          else
            pw.Directionality(
              textDirection: pw.TextDirection.rtl,
              child: pw.TableHelper.fromTextArray(
                headers: headers,
                data: data,
                headerCount: 1,
                headerDecoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#123A4A'),
                ),
                headerStyle: pw.TextStyle(
                  font: bold,
                  fontSize: 8.5,
                  color: PdfColors.white,
                ),
                headerAlignment: pw.Alignment.center,
                cellStyle: pw.TextStyle(
                  font: font,
                  fontSize: cellFontSize,
                  color: PdfColor.fromHex('#23333B'),
                ),
                oddRowDecoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#F0F6F4'),
                ),
                cellAlignment: pw.Alignment.center,
                cellPadding: pw.EdgeInsets.symmetric(
                  horizontal: isLandscape ? 7 : 5,
                  vertical: cellVerticalPadding,
                ),
                border: pw.TableBorder(
                  top: pw.BorderSide(
                    color: PdfColor.fromHex('#C9D7D3'),
                    width: .8,
                  ),
                  bottom: pw.BorderSide(
                    color: PdfColor.fromHex('#C9D7D3'),
                    width: .8,
                  ),
                  horizontalInside: pw.BorderSide(
                    color: PdfColor.fromHex('#DDE7E4'),
                    width: .45,
                  ),
                  verticalInside: pw.BorderSide(
                    color: PdfColor.fromHex('#E4EBE9'),
                    width: .35,
                  ),
                ),
              ),
            ),
          pw.SizedBox(height: 12),
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: _reportClosing(
              key: key,
              rows: rows,
              font: font,
              bold: bold,
            ),
          ),
        ],
      ),
    );

    final bytes = await doc.save();

    // Audit logging must not prevent an otherwise valid PDF from being printed.
    // Older local databases may not yet contain the report_runs table.
    try {
      await repo.db.insert('report_runs', {
        'report_key': key,
        'filters_json':
            '{"from":"${from?.toIso8601String()}","to":"${to?.toIso8601String()}","systemType":"$systemType"}',
        'generated_at': AppClock.now().toIso8601String(),
        'row_count': rows.length,
        'duration_ms': AppClock.now().difference(started).inMilliseconds,
      });
    } catch (_) {
      // Report generation is independent from optional audit history.
    }
    return bytes;
  }

  // ملخص بصري على هيئة بطاقات، مع حقول تتغير حسب نوع التقرير.
  pw.Widget _reportSummary({
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
    final total = sumOf('total_amount') != 0
        ? sumOf('total_amount')
        : sumOf('total') != 0
        ? sumOf('total')
        : sumOf('amount');
    final cards = <List<String>>[
      ['عدد السجلات', _format(rows.length)],
      if (rows.any((row) => row.containsKey('minutes')))
        ['إجمالي الدقائق', '${_format(sumOf('minutes'))} دقيقة'],
      if (rows.any((row) => row.containsKey('cloud_minutes')))
        ['إجمالي الغيم', '${_format(sumOf('cloud_minutes'))} دقيقة'],
      if (rows.any(
        (row) =>
            row.containsKey('total_amount') ||
            row.containsKey('total') ||
            row.containsKey('amount'),
      ))
        ['إجمالي القيمة', '${_format(total)} ر.س'],
      if (rows.any((row) => row.containsKey('paid_amount')))
        ['إجمالي المدفوع', '${_format(sumOf('paid_amount'))} ر.س'],
      if (rows.any((row) => row.containsKey('balance')))
        ['الرصيد الختامي', _format(rows.last['balance'])],
    ];
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: PdfColor.fromHex('#D9E5E1'), width: .8),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(11)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            children: [
              pw.Container(
                width: 4,
                height: 18,
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#0B8277'),
                  borderRadius:
                      const pw.BorderRadius.all(pw.Radius.circular(2)),
                ),
              ),
              pw.SizedBox(width: 7),
              pw.Text(
                'ملخص التقرير',
                style: pw.TextStyle(
                  font: bold,
                  fontSize: 11,
                  color: PdfColor.fromHex('#123A4A'),
                ),
              ),
              pw.Spacer(),
              pw.Text(
                '${rows.length} سجل',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 8,
                  color: PdfColor.fromHex('#6C7E82'),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 9),
          pw.Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final card in cards)
                pw.Container(
                  width: 145,
                  height: 49,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#F3F8F6'),
                    border: pw.Border.all(
                      color: PdfColor.fromHex('#E0EBE7'),
                      width: .6,
                    ),
                    borderRadius:
                        const pw.BorderRadius.all(pw.Radius.circular(7)),
                  ),
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        card[0],
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 7,
                          color: PdfColor.fromHex('#65787B'),
                        ),
                        maxLines: 1,
                        overflow: pw.TextOverflow.clip,
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        card[1],
                        style: pw.TextStyle(
                          font: bold,
                          fontSize: 9,
                          color: PdfColor.fromHex('#173E4A'),
                        ),
                        maxLines: 1,
                        overflow: pw.TextOverflow.clip,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#F7F8F6'),
              borderRadius:
                  const pw.BorderRadius.all(pw.Radius.circular(6)),
            ),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'الفترة والتصفية:',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 7.5,
                    color: PdfColor.fromHex('#53676C'),
                  ),
                ),
                pw.SizedBox(width: 6),
                pw.Expanded(
                  child: pw.Text(
                    filterText,
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 7.5,
                      color: PdfColor.fromHex('#35494F'),
                    ),
                    maxLines: 3,
                    overflow: pw.TextOverflow.clip,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _emptyReportState({
    required pw.Font font,
    required pw.Font bold,
  }) =>
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 34),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#F5F9F7'),
          border: pw.Border.all(color: PdfColor.fromHex('#DFEAE6')),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(11)),
        ),
        child: pw.Column(
          children: [
            pw.Text(
              'لا توجد بيانات مطابقة',
              style: pw.TextStyle(
                font: bold,
                fontSize: 13,
                color: PdfColor.fromHex('#123A4A'),
              ),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              'لم تُسجّل نتائج وفق الفترة أو خيارات التصفية المحددة.',
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                font: font,
                fontSize: 9,
                color: PdfColor.fromHex('#63777B'),
              ),
            ),
          ],
        ),
      );

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
    final hasFinancial = rows.any(
      (row) =>
          row.containsKey('amount') ||
          row.containsKey('total') ||
          row.containsKey('total_amount'),
    );
    final isBalanceReport = const {
      'beneficiary_statement',
      'beneficiary_detailed',
      'worker_transactions',
      'partner_accounts',
      'debts',
    }.contains(key);
    final balanceMovements = rows.where((row) =>
      !const ['opening_balance', 'carried_balance'].contains(row['type'])
    ).toList();
    final netSummary = isBalanceReport &&
            balanceMovements.isNotEmpty &&
            balanceMovements.last.containsKey('balance')
        ? _reportNetSummary(balanceMovements.last)
        : null;
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      padding: const pw.EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#123A4A'),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'الخلاصة النهائية',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 9,
                    color: PdfColor.fromHex('#BFE4D7'),
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  hasFinancial
                      ? 'إجمالي التقرير: ${_format(amount)} ر.س${rows.any((row) => row.containsKey('paid_amount')) ? '  •  المدفوع: ${_format(paid)} ر.س' : ''}'
                      : 'إجمالي السجلات: ${rows.length}',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 10,
                    color: PdfColors.white,
                  ),
                ),
                if (netSummary != null) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    netSummary,
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 8,
                      color: PdfColor.fromHex('#E0EFEB'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(width: 14),
          pw.Container(
            width: 118,
            height: 46,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#F8FBF9'),
              border: pw.Border.all(color: PdfColor.fromHex('#B7D3C8')),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(7)),
            ),
            child: pw.Text(
              'اعتماد المحطة\nالتوقيع والختم',
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                font: bold,
                fontSize: 8,
                color: PdfColor.fromHex('#49635D'),
              ),
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
    return pw.Directionality(
      textDirection: pw.TextDirection.rtl,
      child: pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#123A4A'),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(11)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Container(
              width: 45,
              height: 45,
              alignment: pw.Alignment.center,
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F3FAF7'),
                borderRadius:
                    const pw.BorderRadius.all(pw.Radius.circular(8)),
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
            pw.SizedBox(width: 12),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Row(
                    children: [
                      pw.Text(
                        'نظام ساقية  •  التقارير الرسمية',
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 8,
                          color: PdfColor.fromHex('#C7DED8'),
                        ),
                      ),
                      pw.Spacer(),
                      pw.Text(
                        reportNumber,
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 7.5,
                          color: PdfColor.fromHex('#D5E8E1'),
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    title,
                    textAlign: pw.TextAlign.right,
                    style: pw.TextStyle(
                      font: bold,
                      fontSize: 16,
                      color: PdfColors.white,
                    ),
                  ),
                  pw.SizedBox(height: 3),
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: pw.Text(
                          station,
                          style: pw.TextStyle(
                            font: bold,
                            fontSize: 9,
                            color: PdfColor.fromHex('#E3F0EC'),
                          ),
                        ),
                      ),
                      pw.Text(
                        '${DateFormat('yyyy/MM/dd').format(date)}  •  $recordCount سجل',
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 7.5,
                          color: PdfColor.fromHex('#C7DED8'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // تذييل خفيف للتقارير متعددة الصفحات وإيصالات القبض.
  pw.Widget _reportFooter({
    required int page,
    required int totalPages,
    required pw.Font font,
    required pw.Font bold,
    bool showSignature = true,
  }) =>
      pw.Directionality(
        textDirection: pw.TextDirection.rtl,
        child: pw.Column(
          children: [
            pw.Container(height: .8, color: PdfColor.fromHex('#D8E3DF')),
            pw.SizedBox(height: 5),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (showSignature)
                  pw.Container(
                    width: 100,
                    height: 28,
                    alignment: pw.Alignment.center,
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(
                        color: PdfColor.fromHex('#C7D7D1'),
                        width: .7,
                      ),
                      borderRadius:
                          const pw.BorderRadius.all(pw.Radius.circular(5)),
                    ),
                    child: pw.Text(
                      'التوقيع والختم',
                      style: pw.TextStyle(
                        font: font,
                        fontSize: 7,
                        color: PdfColor.fromHex('#60736E'),
                      ),
                    ),
                  ),
                if (showSignature) pw.Spacer(),
                pw.Text(
                  'وثيقة صادرة من نظام ساقية لإدارة المحطة',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 7,
                    color: PdfColor.fromHex('#697D7A'),
                  ),
                ),
                pw.Spacer(),
                pw.Text(
                  'صفحة $page من $totalPages',
                  style: pw.TextStyle(
                    font: font,
                    fontSize: 7.5,
                    color: PdfColor.fromHex('#45615E'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  String _reportNetSummary(Map<String, Object?> row) {
    final value = row['balance'] is num ? (row['balance'] as num).round() : int.tryParse('${row['balance']}') ?? 0;
    if (value > 0) return 'إجمالي المتبقي عليه: ${_format(value)} ريال';
    if (value < 0) return 'إجمالي المتبقي له: ${_format(value.abs())} ريال';
    return 'إجمالي المتبقي: متوازن';
  }

  // Shape Arabic strings for PDF table cells, whose renderer does not shape Arabic glyphs.
  String _shapeArabic(String value) => ArabicReshaper.instance.reshape(value);

  String _fieldName(String key) => {
    'id':'الرقم','date':'التاريخ','start_datetime':'بداية السقي','end_datetime':'نهاية السقي','month':'الشهر','minutes':'المدة بالدقائق','chargeable_minutes':'الدقائق المحاسبية','operations':'عدد العمليات','system_type':'نوع المنظومة','total_amount':'الإجمالي','total':'الإجمالي','income':'الإيرادات','expenses':'المصروفات','water_income':'إيراد المياه','diesel_income':'إيراد الديزل','diesel_cost':'تكلفة الديزل','paid_amount':'المدفوع','remaining':'حالة الرصيد','beneficiary_name':'المستفيد','party_name':'الجهة','cloud_status':'حالة خصم الغيم','worker_name':'العامل','partner_name':'الشريك','cashbox_name':'الصندوق','method_name':'طريقة الدفع','account_name':'الحساب','account_code':'رمز الحساب','debit':'له','credit':'عليه','lah':'له','alayh':'عليه','amount':'المبلغ','gross_amount':'نصيب الشريك قبل المصروفات الخاصة','partner_expenses':'مصروفات الشريك الخاصة','net_amount':'صافي نصيب الشريك بعد المصروفات الخاصة','liters':'اللترات','kind':'نوع الحركة','status':'الحالة','notes':'ملاحظات','description':'البيان','ownership_percentage':'نسبة الملكية','shares_count':'عدد الحصص','opening_balance':'الرصيد الافتتاحي','carried_balance':'الرصيد المرحل','balance':'الرصيد الجاري','water_amount':'قيمة المياه','diesel_amount':'قيمة الديزل','cloud_minutes':'دقائق الغيم','category':'التصنيف','title':'العنوان','phone':'الهاتف','name':'الاسم','reference_number':'رقم المرجع','created_at':'تاريخ الإنشاء','updated_at':'تاريخ التحديث','position':'الدور','scheduled_start':'بداية الموعد','scheduled_end':'نهاية الموعد','payment_method_id':'طريقة الدفع','cashbox_id':'الصندوق','beneficiary_id':'المستفيد','worker_id':'العامل','partner_id':'الشريك','journal_id':'رقم القيد','journal_entry_id':'رقم القيد','ownership_mode':'طريقة الملكية','pump_name':'المضخة','queue_position':'رقم الدور',
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
    if ({
      'date',
      'start_datetime',
      'end_datetime',
      'scheduled_start',
      'scheduled_end',
      'created_at',
      'updated_at',
    }.contains(key)) {
      final d = DateTime.tryParse('$value');
      if (d != null) {
        final dateOnly = key == 'date' &&
            !'$value'.contains('T') &&
            !'$value'.contains(':');
        return DateFormat(
          dateOnly ? 'yyyy/MM/dd' : 'yyyy/MM/dd HH:mm',
          'ar',
        ).format(d);
      }
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
    String? status, {
    String? personName,
  }) {
    final parts = <String>[];
    if (personName != null && personName.trim().isNotEmpty) {
      parts.add('الاسم: ${personName.trim()}');
    }
    if (from != null) parts.add('من ${DateFormat('yyyy/MM/dd').format(from)}');
    if (to != null) parts.add('إلى ${DateFormat('yyyy/MM/dd').format(to)}');
    if (systemType != null) {
      parts.add(
        'المنظومة: ${systemType == 'all'
            ? 'كل الأنواع'
            : systemType == 'diesel'
            ? 'ديزل'
            : systemType == 'solar'
            ? 'شمسي'
            : 'النوع الثالث'}',
      );
    }
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
                title: x['beneficiary_id'] != null ? 'سند قبض' : 'سند صرف',
                station: receiptSettings['station_name'] ?? 'محطة ساقية',
                reportNumber: '#${x['id']}',
                recordCount: 1,
                date: DateTime.tryParse('${x['date']}') ?? AppClock.now(),
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
    List<Map<String, Object?>>? sourceRows,
  }) async {
    // Generate the document before opening Android's print UI so exceptions
    // from fonts, data formatting, or PDF layout surface in the calling screen.
    final bytes = await pdf(
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
      sourceRows: sourceRows,
    );
    if (bytes.isEmpty) {
      throw StateError('تعذر إنشاء ملف PDF: المستند الناتج فارغ');
    }
    try {
      await Printing.layoutPdf(
        // Give Android's print/save dialog the actual report name instead of
        // its generic default filename, "document".
        name: (titles[key] ?? key).replaceAll('/', '-'),
        onLayout: (_) async => bytes,
      );
    } catch (printError) {
      // Keep a usable PDF delivery path if Android's native print dialog fails
      // for any reason, not only the known "No value" bridge error.
      try {
        await Printing.sharePdf(
          bytes: bytes,
          filename: '${(titles[key] ?? 'report').replaceAll('/', '-')}.pdf',
        );
      } catch (shareError) {
        throw StateError(
          'تم إنشاء ملف PDF لكن تعذّر فتح الطباعة أو المشاركة. '
          'خطأ الطباعة: $printError؛ خطأ المشاركة/الحفظ: $shareError',
        );
      }
    }
  }
}
