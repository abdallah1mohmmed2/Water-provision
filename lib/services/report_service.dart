import '../core/app_clock.dart';
import 'package:intl/intl.dart';
import 'package:arabic_reshaper/arabic_reshaper.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';
import 'official_report_template.dart';

class ReportService {
  final StationRepository repo;
  ReportService([StationRepository? r]) : repo = r ?? StationRepository();

  static const titles = {
    'irrigations': 'تقرير السقايات التفصيلي',
    'invoices': 'تقرير الفواتير',
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
  'invoices': ['party_name', 'start_datetime', 'end_datetime', 'minutes', 'total_amount', 'paid_amount', 'notes'],
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
  'beneficiary_detailed': ['date', 'description', 'start_datetime', 'end_datetime', 'minutes', 'cloud_minutes', 'lah', 'alayh', 'balance'],
  'worker_transactions': ['date', 'description', 'lah', 'alayh', 'balance'],
  'partner_accounts': ['date', 'description', 'lah', 'alayh', 'balance'],
  'partner_profit_distribution': ['name', 'mode', 'basis', 'direct_amount', 'share_amount', 'gross_amount', 'partner_expenses', 'net_amount'],
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
    final rows = (sourceRows != null && sourceRows.isNotEmpty)
        ? _normalizeRows(key, sourceRows)
        : _normalizeRows(key, await repo.report(
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
    ));
    if (key == 'invoices') {
      return await invoicesPdf(rows: rows, from: from, to: to);
    }

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
    final availableKeys = <String>{
      for (final row in rows) ...row.keys,
    };
    final expectedHeaders = reportColumns[key] ?? <String>[];
    final sourceHeaders = rows.isEmpty
        ? <String>[]
        : expectedHeaders.where(availableKeys.contains).toList();
    if (sourceHeaders.isEmpty && rows.isNotEmpty) {
      sourceHeaders.addAll(rows.first.keys.take(8));
    } else if (sourceHeaders.length <= 1 && rows.isNotEmpty) {
      if (key == 'worker_transactions' && availableKeys.contains('pay_type')) {
        sourceHeaders
          ..clear()
          ..addAll(['name', 'phone', 'job_title', 'pay_type', 'balance'].where(availableKeys.contains));
      } else if (key == 'partner_accounts' && availableKeys.contains('ownership_mode')) {
        sourceHeaders
          ..clear()
          ..addAll(['name', 'phone', 'ownership_mode', 'shares_count', 'ownership_percentage', 'balance'].where(availableKeys.contains));
      } else {
        sourceHeaders
          ..clear()
          ..addAll(rows.first.keys.take(8));
      }
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
      if (rows.isNotEmpty && rows.first.containsKey('minutes'))
        ['إجمالي السقوات', _format(rows.length)],
      if (rows.any((row) => row.containsKey('minutes')))
        ['إجمالي الدقائق', '${_format(sumOf('minutes'))} دقيقة'],
      if (!(rows.isNotEmpty && rows.first.containsKey('minutes')))
        ['عدد السجلات', _format(rows.length)],
      if (rows.any((row) => row.containsKey('cloud_minutes')))
        ['إجمالي الغيم', '${_format(sumOf('cloud_minutes'))} دقيقة'],
      if (rows.isNotEmpty && rows.first.containsKey('distributable_profit'))
        ['صافي الربح القابل للتوزيع', '${_format(rows.first['distributable_profit'])} ر.س'],
      if (rows.any((row) => row.containsKey('gross_amount')))
        ['إجمالي استحقاقات الشركاء', '${_format(sumOf('gross_amount'))} ر.س'],
      if (rows.any((row) => row.containsKey('partner_expenses')))
        ['مصروفات الشركاء الخاصة', '${_format(sumOf('partner_expenses'))} ر.س'],
      if (rows.any((row) => row.containsKey('net_amount')))
        ['صافي الاستحقاقات بعد المصروفات', '${_format(sumOf('net_amount'))} ر.س'],
      if (rows.any(
        (row) =>
            row.containsKey('total_amount') ||
            row.containsKey('total') ||
            row.containsKey('amount'),
      ) && !(rows.isNotEmpty && rows.first.containsKey('distributable_profit')))
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

  // Guard the Arabic shaper so one unsupported value cannot abort PDF generation.
  String _shapeArabic(String value) {
    if (value.trim().isEmpty) return '-';
    try {
      return ArabicReshaper.instance.reshape(value);
    } catch (_) {
      return value;
    }
  }

  List<Map<String, Object?>> _normalizeRows(
    String key,
    List<Map<String, Object?>> source,
  ) {
    if (source.isEmpty || key != 'irrigations') return source;
    return source.map((row) {
      final rawCloudMinutes = row['cloud_minutes'];
      final cloudMinutes = rawCloudMinutes is num
          ? rawCloudMinutes.round()
          : int.tryParse('$rawCloudMinutes') ?? 0;
      return <String, Object?>{
        ...row,
        'party_name': row['party_name'] ?? row['beneficiary_name'] ?? 'غير محدد',
        'cloud_minutes': cloudMinutes,
        'cloud_status': row['cloud_status'] ?? (cloudMinutes > 0 ? 'discounted' : 'none'),
      };
    }).toList();
  }

  String _fieldName(String key) => {
    'id':'الرقم','date':'التاريخ','start_datetime':'بداية السقي','end_datetime':'نهاية السقي','month':'الشهر','minutes':'المدة بالدقائق','chargeable_minutes':'الدقائق المحاسبية','operations':'عدد العمليات','system_type':'نوع المنظومة','total_amount':'الإجمالي','total':'الإجمالي','income':'الإيرادات','expenses':'المصروفات','water_income':'إيراد المياه','diesel_income':'إيراد الديزل','diesel_cost':'تكلفة الديزل','paid_amount':'المدفوع','remaining':'حالة الرصيد','beneficiary_name':'المستفيد','party_name':'الجهة','cloud_status':'حالة خصم الغيم','worker_name':'العامل','partner_name':'الشريك','cashbox_name':'الصندوق','method_name':'طريقة الدفع','account_name':'الحساب','account_code':'رمز الحساب','debit':'له','credit':'عليه','lah':'له','alayh':'عليه','amount':'المبلغ','direct_amount':'استحقاق مباشر من السقايات','share_amount':'نصيبه من المتبقي','gross_amount':'إجمالي الاستحقاق قبل المصروفات الخاصة','partner_expenses':'مصروفات الشريك الخاصة','net_amount':'صافي نصيب الشريك بعد المصروفات الخاصة','liters':'اللترات','kind':'نوع الحركة','status':'الحالة','notes':'ملاحظات','description':'البيان','ownership_percentage':'نسبة الملكية','shares_count':'عدد الحصص','opening_balance':'الرصيد الافتتاحي','carried_balance':'الرصيد المرحل','balance':'الرصيد الجاري','water_amount':'قيمة المياه','diesel_amount':'قيمة الديزل','cloud_minutes':'دقائق الغيم','category':'التصنيف','title':'العنوان','phone':'الهاتف','name':'الاسم','reference_number':'رقم المرجع','created_at':'تاريخ الإنشاء','updated_at':'تاريخ التحديث','position':'الدور','scheduled_start':'بداية الموعد','scheduled_end':'نهاية الموعد','payment_method_id':'طريقة الدفع','cashbox_id':'الصندوق','beneficiary_id':'المستفيد','worker_id':'العامل','partner_id':'الشريك','journal_id':'رقم القيد','journal_entry_id':'رقم القيد','ownership_mode':'طريقة الملكية','job_title':'المسمى الوظيفي','pay_type':'طريقة الحساب','pump_name':'المضخة','queue_position':'رقم الدور',
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
        // The custom pattern needs no locale data; avoid an uninitialized Arabic locale.
        return DateFormat(
          dateOnly ? 'yyyy/MM/dd' : 'yyyy/MM/dd HH:mm',
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
      ? 'له ${NumberFormat('#,##0').format(balance)} ريال'
      : balance < 0
      ? 'عليه ${NumberFormat('#,##0').format(balance.abs())} ريال'
      : 'متوازن';

  String _balanceLabel(int balance) => balance > 0
      ? 'عليه ${NumberFormat('#,##0').format(balance)} ريال'
      : balance < 0
      ? 'له ${NumberFormat('#,##0').format(balance.abs())} ريال'
      : 'متوازن';

  String _format(Object? value) {
    if (value == null) return '-';
    if (value is num) return NumberFormat('#,##0.##').format(value);
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

  /// إنشاء PDF مخصص لتقرير الفواتير بأعمدته الثمانية وإجمالياته الرسمية.
  Future<Uint8List> invoicesPdf({
    List<Map<String, Object?>>? rows,
    DateTime? from,
    DateTime? to,
  }) async {
    final sourceRows = rows ?? await repo.report('invoices', from: from, to: to);
    // بعض مسارات المعاينة القديمة تمرر beneficiary_name أو رقم السقاية فقط،
    // لذلك لا نعتمد على party_name القادم من الشاشة وحده.
    final data = sourceRows
        .map((row) => <String, Object?>{...row})
        .toList(growable: false);
    final irrigationIds = data
        .map((row) => row['invoice_id'] ?? row['irrigation_id'] ?? row['id'])
        .whereType<num>()
        .map((id) => id.toInt())
        .where((id) => id > 0)
        .toSet()
        .toList();
    final resolvedPartyNames = <int, String>{};
    if (irrigationIds.isNotEmpty) {
      final placeholders = List.filled(irrigationIds.length, '?').join(',');
      final partyRows = await repo.db.rawQuery(
        '''SELECT i.id invoice_id,
                  CASE i.party_type
                    WHEN 'beneficiary' THEN COALESCE(
                      NULLIF(TRIM(b.name),''),
                      CASE WHEN i.beneficiary_id IS NOT NULL
                        THEN 'مستفيد #' || i.beneficiary_id
                        ELSE 'مستفيد غير محدد' END
                    )
                    WHEN 'worker' THEN COALESCE(
                      NULLIF(TRIM(w.name),''),
                      CASE WHEN i.worker_id IS NOT NULL
                        THEN 'عامل #' || i.worker_id
                        ELSE 'عامل غير محدد' END
                    )
                    WHEN 'partner' THEN COALESCE(
                      NULLIF(TRIM(p.name),''),
                      CASE WHEN i.partner_id IS NOT NULL
                        THEN 'شريك #' || i.partner_id
                        ELSE 'شريك غير محدد' END
                    )
                    ELSE COALESCE(
                      NULLIF(TRIM(b.name),''),
                      NULLIF(TRIM(w.name),''),
                      NULLIF(TRIM(p.name),''),
                      'غير محدد'
                    )
                  END party_name
           FROM irrigations i
           LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id
           LEFT JOIN workers w ON w.id=i.worker_id
           LEFT JOIN partners p ON p.id=i.partner_id
           WHERE i.id IN ($placeholders)''',
        irrigationIds.cast<Object?>(),
      );
      for (final row in partyRows) {
        final id = (row['invoice_id'] as num?)?.toInt();
        final name = '${row['party_name'] ?? ''}'.trim();
        if (id != null && name.isNotEmpty) resolvedPartyNames[id] = name;
      }
    }
    for (final row in data) {
      final rawId = row['invoice_id'] ?? row['irrigation_id'] ?? row['id'];
      final id = rawId is num ? rawId.toInt() : int.tryParse('$rawId');
      final currentName = [
        row['party_name'],
        row['beneficiary_name'],
        row['worker_name'],
        row['partner_name'],
      ].map((value) => '${value ?? ''}'.trim()).firstWhere(
            (value) => value.isNotEmpty && value != 'غير محدد',
            orElse: () => '',
          );
      final resolved = id == null ? null : resolvedPartyNames[id];
      row['party_name'] = resolved != null &&
              resolved.isNotEmpty &&
              resolved != 'غير محدد'
          ? resolved
          : (currentName.isNotEmpty ? currentName : (resolved ?? 'غير محدد'));
    }
    final settings = await repo.settings();
    final now = AppClock.now();

    int n(Object? value) =>
        value is num ? value.round() : int.tryParse('${value ?? ''}') ?? 0;
    String time(Object? value) {
      final d = DateTime.tryParse('${value ?? ''}');
      return d == null
          ? '—'
          : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    String duration(Object? value) {
      final minutes = n(value).clamp(0, 100000000);
      return '${minutes ~/ 60} س ${minutes % 60} د';
    }
    String display(Object? value) {
      final text = value == null || '$value'.trim().isEmpty ? '—' : '$value';
      return _shapeArabic(text);
    }
    String money(Object? value) => NumberFormat('#,##0').format(n(value));

    final totalMinutes =
        data.fold<int>(0, (sum, row) => sum + n(row['minutes']));
    final totalAmount =
        data.fold<int>(0, (sum, row) => sum + n(row['total_amount']));
    final totalPaid =
        data.fold<int>(0, (sum, row) => sum + n(row['paid_amount']));
    final remaining = totalAmount - totalPaid;
    final dateFormat = DateFormat('yyyy/MM/dd');
    final period = from == null && to == null
        ? 'كل الفترات'
        : '${from == null ? 'البداية' : dateFormat.format(from)} — ${to == null ? 'حتى الآن' : dateFormat.format(to)}';

    final tableRows = <List<String>>[
      for (var i = 0; i < data.length; i++)
        [
          '${i + 1}',
          display(data[i]['party_name']),
          time(data[i]['start_datetime']),
          time(data[i]['end_datetime']),
          duration(data[i]['minutes']),
          money(data[i]['total_amount']),
          money(data[i]['paid_amount']),
          display(data[i]['notes']),
        ],
    ];

    return OfficialReportTemplate.preview(
      rightHeader1: 'الجمهورية اليمنية',
      rightHeader2: 'نظام ساقية لإدارة محطة ضخ مياه الري',
      rightHeader3: settings['station_name'] ?? 'محطة ساقية',
      date: dateFormat.format(now),
      refNumber: 'INV-${DateFormat('yyyyMMdd-HHmmss').format(now)}',
      attachments: 'عدد الفواتير: ${data.length}',
      reportTitle: 'تقرير الفواتير',
      summaryBoxes: [
        StatBoxData(
          number: '1',
          title: 'عدد الفواتير',
          value: NumberFormat('#,##0').format(data.length),
          isBlueTint: true,
        ),
        StatBoxData(
          number: '2',
          title: 'إجمالي الساعات والدقائق',
          value: duration(totalMinutes),
        ),
        StatBoxData(
          number: '3',
          title: 'القيمة الإجمالية',
          value: '${money(totalAmount)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '4',
          title: 'إجمالي المدفوع',
          value: '${money(totalPaid)} ريال',
        ),
        StatBoxData(
          number: '5',
          title: 'المتبقي',
          value: '${money(remaining)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '6',
          title: 'الفترة',
          value: period,
        ),
      ],
      columns: const [
        'م',
        'المستفيد / العامل / الشريك',
        'وقت البداية',
        'وقت النهاية',
        'الساعات والدقائق',
        'القيمة الإجمالية',
        'المسلّم',
        'ملاحظات',
      ],
      rows: tableRows,
      footerTotalRow: [
        '',
        'الإجمالي',
        '',
        '',
        duration(totalMinutes),
        money(totalAmount),
        money(totalPaid),
        'المتبقي: ${money(remaining)}',
      ],
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      fileName: 'تقرير-الفواتير.pdf',
      minTableRows: 7,
    );
  }

  Future<void> printInvoicesPdf({
    List<Map<String, Object?>>? rows,
    DateTime? from,
    DateTime? to,
  }) async {
    final bytes = await invoicesPdf(rows: rows, from: from, to: to);
    await Printing.layoutPdf(
      name: 'تقرير-الفواتير',
      onLayout: (_) async => bytes,
    );
  }

  Future<void> shareInvoicesPdf({
    List<Map<String, Object?>>? rows,
    DateTime? from,
    DateTime? to,
  }) async {
    final bytes = await invoicesPdf(rows: rows, from: from, to: to);
    await Printing.sharePdf(bytes: bytes, filename: 'تقرير-الفواتير.pdf');
  }

  num _workerNum(Object? value) {
    if (value is num) return value;
    return num.tryParse('${value ?? ''}') ?? 0;
  }

  String _workerMoney(Object? value) =>
      NumberFormat('#,##0.##').format(_workerNum(value));

  String _workerPayType(Map<String, Object?> worker) {
    final type = '${worker['pay_type'] ?? ''}';
    return switch (type) {
      'hourly' => 'بالساعة',
      'percentage' => 'بالنسبة',
      'fixed' || 'monthly' || 'salary' => 'راتب مقطوع',
      _ => 'راتب مقطوع',
    };
  }

  String _workerPayBasis(Map<String, Object?> worker) {
    final type = '${worker['pay_type'] ?? ''}';
    return switch (type) {
      'hourly' => '${_workerMoney(worker['hourly_rate'])} لكل ساعة',
      'percentage' => '${_workerMoney(worker['percentage_rate'])}% من الدخل',
      'fixed' || 'monthly' || 'salary' =>
        '${_workerMoney(worker['fixed_salary'])} راتب شهري',
      _ => '${_workerMoney(worker['fixed_salary'])} راتب شهري',
    };
  }

  Future<void> _printWorkerTransactionsOfficial({
    required int? workerId,
    required DateTime? from,
    required DateTime? to,
  }) async {
    final settings = await repo.settings();
    final workers = await repo.workers();
    Map<String, Object?>? selectedWorker;
    if (workerId != null) {
      for (final worker in workers) {
        if (_workerNum(worker['id']).toInt() == workerId) {
          selectedWorker = worker;
          break;
        }
      }
    }
    if (workerId != null && selectedWorker == null) {
      throw StateError('العامل المحدد غير موجود');
    }

    final invoices = await repo.report(
      'invoices',
      from: from,
      to: to,
      systemType: 'all',
    );
    final reportRows = <List<String>>[];
    num totalMinutes = 0;
    num totalDue = 0;
    num totalWithdrawals = 0;
    num totalNet = 0;

    // Keep each worker's original ledger entries as the source of financial totals.
    final statementRows = workerId == null
        ? <Map<String, Object?>>[]
        : await repo.report('worker_transactions', workerId: workerId, from: from, to: to);

    if (workerId != null) {
      final worker = selectedWorker!;
      // Opening/carried/current balance rows describe a balance, not a movement;
      // including them in the period totals double-counts amounts.
      final movementRows = statementRows.where((row) =>
        !const ['opening_balance', 'carried_balance', 'current_balance'].contains(row['type'])
      ).toList();
      final due = movementRows.fold<num>(0, (sum, row) => sum + _workerNum(row['lah']));
      final withdrawals = movementRows.fold<num>(0, (sum, row) => sum + _workerNum(row['alayh']));
      final net = movementRows.isNotEmpty
          ? _workerNum(movementRows.first['balance'])
          : statementRows.isEmpty
              ? due - withdrawals
              : _workerNum(statementRows.first['balance']);
      final minutes = invoices.where((row) => _workerNum(row['worker_id']).toInt() == workerId)
          .fold<num>(0, (sum, row) => sum + _workerNum(row['minutes']));
      totalMinutes = minutes;
      totalDue = due;
      totalWithdrawals = withdrawals;
      totalNet = net;
      // The repository returns rows newest-first and places the opening balance
      // before same-day movements in that order. Reversing the whole list would
      // move the opening row after the first day's movements, so move opening
      // rows to the front after reversing for chronological print order.
      final ordered = statementRows.reversed.toList();
      final openingRows = ordered
          .where((row) => row['type'] == 'opening_balance')
          .toList();
      ordered.removeWhere((row) => row['type'] == 'opening_balance');
      ordered.insertAll(0, openingRows);
      final movements = ordered.map((row) {
        final balance = _workerNum(row['balance']);
        final balanceText = balance > 0
            ? 'له ${_workerMoney(balance)}'
            : balance < 0
                ? 'عليه ${_workerMoney(balance.abs())}'
                : 'صفر';
        return <String>[
          _workerDate(row['date']),
          '${row['description'] ?? ''}',
          _workerMoney(row['lah']),
          _workerMoney(row['alayh']),
          balanceText,
        ];
      }).toList();
      final now = AppClock.now();
      await OfficialReportTemplate.preview(
        rightHeader1: settings['station_name'] ?? 'منظومة السقاية',
        rightHeader2: settings['organization_name'] ?? 'الإدارة المالية',
        rightHeader3: 'الجمهورية اليمنية',
        date: DateFormat('yyyy/MM/dd').format(now),
        refNumber: 'WST-${DateFormat('yyMMdd-HHmm').format(now)}',
        attachments: 'الفترة: ${_workerPeriod(from)} إلى ${_workerPeriod(to)}',
        thirdSignatureLabel: 'إقرار العامل وتوقيعه: ....................',
        fileName: 'كشف-حساب-وتسوية-مستحقات-عامل.pdf',
        reportTitle: 'كشف حساب وتسوية مستحقات عامل — ${worker['name'] ?? 'غير محدد'}',
        summaryBoxes: [
          StatBoxData(number: '1', title: 'اسم العامل', value: '${worker['name'] ?? 'غير محدد'}'),
          StatBoxData(number: '2', title: 'نوع وطريقة التحاسب', value: '${_workerPayType(worker)} — ${_workerPayBasis(worker)}'),
          StatBoxData(number: '3', title: 'إجمالي المستحق', value: _workerMoney(due)),
          StatBoxData(number: '4', title: 'إجمالي المسحوبات', value: _workerMoney(withdrawals), isBlueTint: true),
          StatBoxData(number: '5', title: 'الصافي النهائي', value: net > 0 ? 'له ${_workerMoney(net)}' : net < 0 ? 'عليه ${_workerMoney(net.abs())}' : 'صفر', isLarge: true),
        ],
        columns: const ['التاريخ', 'البيان', 'له', 'عليه', 'المتبقي (له / عليه)'],
        rows: movements,
        footerTotalRow: ['الإجمالي', '', _workerMoney(due), _workerMoney(withdrawals), net > 0 ? 'له ${_workerMoney(net)}' : net < 0 ? 'عليه ${_workerMoney(net.abs())}' : 'صفر'],
        minTableRows: 1,
      );
      return;
    }

    for (final worker in workers) {
      final id = _workerNum(worker['id']).toInt();
      if (id == 0) continue;
      final tx = await repo.report('worker_transactions', workerId: id, from: from, to: to);
      // The opening/current balance is a carried position, not an in-period transaction.
      final movementRows = tx.where((row) =>
        !const ['opening_balance', 'carried_balance', 'current_balance'].contains(row['type'])
      ).toList();
      final due = movementRows.fold<num>(0, (sum, row) => sum + _workerNum(row['lah']));
      final withdrawals = movementRows.fold<num>(0, (sum, row) => sum + _workerNum(row['alayh']));
      final net = movementRows.isNotEmpty
          ? _workerNum(movementRows.first['balance'])
          : tx.isEmpty
              ? due - withdrawals
              : _workerNum(tx.first['balance']);
      final minutes = invoices.where((row) => _workerNum(row['worker_id']).toInt() == id)
          .fold<num>(0, (sum, row) => sum + _workerNum(row['minutes']));
      totalMinutes += minutes;
      totalDue += due;
      totalWithdrawals += withdrawals;
      totalNet += net;
      final netText = net > 0 ? 'له ${_workerMoney(net)}' : net < 0 ? 'عليه ${_workerMoney(net.abs())}' : 'صفر';
      reportRows.add([
        '${reportRows.length + 1}',
        '${worker['name'] ?? 'غير محدد'}',
        _workerPayType(worker),
        _workerPayBasis(worker),
        _workerMoney(due),
        _workerMoney(withdrawals),
        netText,
        '',
      ]);
    }
    final now = AppClock.now();
    await OfficialReportTemplate.preview(
      rightHeader1: settings['station_name'] ?? 'منظومة السقاية',
      rightHeader2: settings['organization_name'] ?? 'الإدارة المالية',
      rightHeader3: 'الجمهورية اليمنية',
      date: DateFormat('yyyy/MM/dd').format(now),
      refNumber: 'WPR-${DateFormat('yyMMdd-HHmm').format(now)}',
      attachments: 'الفترة: ${_workerPeriod(from)} إلى ${_workerPeriod(to)}',
      fileName: 'تقرير-أجور-ومسير-مستحقات-العمال.pdf',
      reportTitle: 'تقرير أجور ومسير مستحقات العمال',
      summaryBoxes: [
        StatBoxData(number: '1', title: 'إجمالي ساعات العمل', value: '${(totalMinutes / 60).toStringAsFixed(2)} ساعة'),
        StatBoxData(number: '2', title: 'إجمالي الأجور المستحقة', value: _workerMoney(totalDue), isBlueTint: true),
        StatBoxData(number: '3', title: 'إجمالي المسحوبات والسلف', value: _workerMoney(totalWithdrawals)),
        StatBoxData(number: '4', title: 'صافي المتبقي للعمال', value: totalNet > 0 ? 'له ${_workerMoney(totalNet)}' : totalNet < 0 ? 'عليه ${_workerMoney(totalNet.abs())}' : 'صفر', isLarge: true),
      ],
      columns: const ['م', 'اسم العامل', 'طريقة التحاسب', 'أساس الاحتساب', 'إجمالي الاستحقاق', 'المسحوبات', 'المتبقي (له / عليه)', 'ملاحظات'],
      rows: reportRows,
      footerTotalRow: ['الإجمالي', '', '', '', _workerMoney(totalDue), _workerMoney(totalWithdrawals), totalNet > 0 ? 'له ${_workerMoney(totalNet)}' : totalNet < 0 ? 'عليه ${_workerMoney(totalNet.abs())}' : 'صفر', ''],
      minTableRows: 1,
    );
  }

  String _workerDate(Object? value) {
    final date = DateTime.tryParse('${value ?? ''}');
    return date == null ? '${value ?? '—'}' : DateFormat('yyyy/MM/dd').format(date);
  }

  String _workerPeriod(DateTime? value) =>
      value == null ? 'غير محدد' : DateFormat('yyyy/MM/dd').format(value);

  /// معاينة كشف حساب مستفيد واحد بالقالب الرسمي الجديد.
  Future<void> printBeneficiaryStatementOfficial({
    required int beneficiaryId,
    DateTime? from,
    DateTime? to,
  }) async {
    final settings = await repo.settings();
    final people = await repo.db.rawQuery(
      'SELECT name FROM beneficiaries WHERE id=? LIMIT 1',
      [beneficiaryId],
    );
    if (people.isEmpty) throw StateError('المستفيد المحدد غير موجود');
    final name = '${people.first['name'] ?? 'المستفيد'}';
    final rawRows = await repo.report(
      'beneficiary_statement',
      beneficiaryId: beneficiaryId,
      from: from,
      to: to,
    );
    num number(Object? value) {
      if (value is num) return value;
      return num.tryParse('${value ?? ''}') ?? 0;
    }

    final rows = rawRows.map((row) => Map<String, Object?>.from(row)).toList();
    // Opening/carried balance rows show a brought-forward position, not
    // movements in the selected period. Exclude them from movement totals.
    final movementRows = rows.where((row) =>
      !const ['opening_balance', 'carried_balance', 'current_balance']
          .contains(row['type'])
    ).toList();
    final totalCredit = movementRows.fold<num>(
      0,
      (sum, row) => sum + number(row['lah']),
    );
    final totalDebit = movementRows.fold<num>(
      0,
      (sum, row) => sum + number(row['alayh']),
    );
    final balance = rows.isEmpty ? 0 : number(rows.last['balance']);
    final dateFormat = DateFormat('yyyy/MM/dd');
    final now = AppClock.now();
    final tableRows = <List<String>>[
      for (var i = 0; i < rows.length; i++)
        [
          '${i + 1}',
          '${rows[i]['date'] ?? '—'}',
          '${rows[i]['description'] ?? '—'}',
          NumberFormat('#,##0').format(number(rows[i]['lah'])),
          NumberFormat('#,##0').format(number(rows[i]['alayh'])),
          NumberFormat('#,##0').format(number(rows[i]['balance'])),
        ],
    ];

    await OfficialReportTemplate.preview(
      rightHeader1: 'الجمهورية اليمنية',
      rightHeader2: 'نظام ساقية لإدارة محطة ضخ مياه الري',
      rightHeader3: settings['station_name'] ?? 'محطة ساقية',
      date: dateFormat.format(now),
      refNumber: 'BST-${DateFormat('yyyyMMdd-HHmmss').format(now)}',
      attachments: 'المستفيد: $name',
      reportTitle: 'كشف حساب المستفيد: $name',
      summaryBoxes: [
        StatBoxData(number: '1', title: 'عدد الحركات', value: NumberFormat('#,##0').format(rows.length), isBlueTint: true),
        StatBoxData(number: '2', title: 'إجمالي له', value: '${NumberFormat('#,##0').format(totalCredit)} ريال'),
        StatBoxData(number: '3', title: 'إجمالي عليه', value: '${NumberFormat('#,##0').format(totalDebit)} ريال', isBlueTint: true),
        StatBoxData(number: '4', title: 'الرصيد الحالي', value: '${NumberFormat('#,##0').format(balance)} ريال', isLarge: true),
      ],
      columns: const ['م', 'التاريخ', 'البيان', 'له (ريال)', 'عليه (ريال)', 'الرصيد المتراكم (ريال)'],
      rows: tableRows,
      footerTotalRow: ['', 'الإجمالي', '', NumberFormat('#,##0').format(totalCredit), NumberFormat('#,##0').format(totalDebit), NumberFormat('#,##0').format(balance)],
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      fileName: 'كشف-حساب-$name.pdf',
      minTableRows: 7,
    );
  }

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
    if (key == 'beneficiary_statement' && beneficiaryId != null) {
      await printBeneficiaryStatementOfficial(
        beneficiaryId: beneficiaryId,
        from: from,
        to: to,
      );
      return;
    }
    if (key == 'worker_transactions') {
      await _printWorkerTransactionsOfficial(workerId: workerId, from: from, to: to);
      return;
    }
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
