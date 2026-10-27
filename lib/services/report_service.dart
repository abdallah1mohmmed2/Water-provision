import '../core/app_clock.dart';
import 'package:intl/intl.dart';
import 'package:arabic_reshaper/arabic_reshaper.dart';
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
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

    final availableKeys = <String>{
      for (final row in rows) ...row.keys,
    };
    final expectedHeaders = reportColumns[key] ?? <String>[];
    // Empty reports keep the configured columns so the official template can
    // render a useful empty-state table instead of failing on zero columns.
    final sourceHeaders = rows.isEmpty
        ? List<String>.from(expectedHeaders)
        : expectedHeaders.where(availableKeys.contains).toList();
    if (sourceHeaders.isEmpty && rows.isNotEmpty) {
      sourceHeaders.addAll(rows.first.keys.take(8));
    } else if (sourceHeaders.length <= 1 && rows.isNotEmpty) {
      if (key == 'worker_transactions' && availableKeys.contains('pay_type')) {
        sourceHeaders
          ..clear()
          ..addAll(['name', 'phone', 'job_title', 'pay_type', 'balance']
              .where(availableKeys.contains));
      } else if (key == 'partner_accounts' && availableKeys.contains('ownership_mode')) {
        sourceHeaders
          ..clear()
          ..addAll(['name', 'phone', 'ownership_mode', 'shares_count',
                  'ownership_percentage', 'balance']
              .where(availableKeys.contains));
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
              'minutes': 'إجمالي الدقائق',
              'paid_amount': 'المدفوع',
              'total_amount': 'القيمة الإجمالية',
              'cloud_minutes': 'الغيم',
              'cloud_status': 'حالة الخصم',
            }[header] ?? _fieldName(header))
          : _fieldName(header);
      return _shapeArabic(label);
    }).toList();

    final tableRows = rows.isEmpty
        ? <List<String>>[
            [
              _shapeArabic('لا توجد بيانات مطابقة'),
              ...List<String>.filled(sourceHeaders.length - 1, ''),
            ],
          ]
        : rows.map((row) {
            return sourceHeaders
                .map((header) => _shapeArabic(_formatValue(header, row[header], key)))
                .toList(growable: false);
          }).toList(growable: false);

    num sumOf(String field) => rows.fold<num>(0, (sum, row) {
          final value = row[field];
          if (value is num) return sum + value;
          return sum + (num.tryParse('${value ?? ''}') ?? 0);
        });
    String money(num value) => NumberFormat('#,##0.##').format(value);
    final summaryBoxes = <StatBoxData>[
      StatBoxData(
        number: '1',
        title: rows.any((row) => row.containsKey('minutes'))
            ? 'عدد السقايات / السجلات'
            : 'عدد السجلات',
        value: NumberFormat('#,##0').format(rows.length),
        isBlueTint: true,
      ),
      if (rows.any((row) => row.containsKey('minutes')))
        StatBoxData(
          number: '2',
          title: 'إجمالي الدقائق',
          value: '${money(sumOf('minutes'))} د',
        ),
      if (rows.any((row) => row.containsKey('cloud_minutes')))
        StatBoxData(
          number: '3',
          title: 'إجمالي الغيم',
          value: '${money(sumOf('cloud_minutes'))} د',
          isBlueTint: true,
        ),
      if (rows.any((row) => row.containsKey('total_amount') ||
          row.containsKey('total') || row.containsKey('amount')))
        StatBoxData(
          number: '4',
          title: 'إجمالي القيمة',
          value: '${money(sumOf(rows.any((row) => row.containsKey('total_amount'))
              ? 'total_amount'
              : rows.any((row) => row.containsKey('total')) ? 'total' : 'amount'))} ريال',
          isBlueTint: true,
        ),
      if (rows.any((row) => row.containsKey('paid_amount')))
        StatBoxData(
          number: '5',
          title: 'إجمالي المدفوع',
          value: '${money(sumOf('paid_amount'))} ريال',
        ),
      if (rows.any((row) => row.containsKey('distributable_profit')))
        StatBoxData(
          number: '6',
          title: 'صافي الربح القابل للتوزيع',
          // This is a report-level value repeated on partner rows, not a
          // per-partner amount; use it once rather than multiplying it by row count.
          value: '${money(rows.isEmpty ? 0 : (rows.first['distributable_profit'] is num
              ? rows.first['distributable_profit'] as num
              : num.tryParse('${rows.first['distributable_profit'] ?? ''}') ?? 0))} ريال',
          isLarge: true,
          isBlueTint: true,
        ),
      if (rows.any((row) => row.containsKey('gross_amount')))
        StatBoxData(
          number: '7',
          title: 'إجمالي استحقاقات الشركاء',
          value: '${money(sumOf('gross_amount'))} ريال',
        ),
      if (rows.any((row) => row.containsKey('partner_expenses')))
        StatBoxData(
          number: '8',
          title: 'مصروفات الشركاء الخاصة',
          value: '${money(sumOf('partner_expenses'))} ريال',
        ),
      if (rows.any((row) => row.containsKey('net_amount')))
        StatBoxData(
          number: '9',
          title: 'صافي الاستحقاقات بعد المصروفات',
          value: '${money(sumOf('net_amount'))} ريال',
          isBlueTint: true,
        ),
    ];

    final reportTitle = personName == null
        ? titles[key]!
        : '${titles[key]} — $personName';
    final reportNumber = 'R-${DateFormat('yyMMdd-HHmm').format(started)}';
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

    final bytes = await OfficialReportTemplate.preview(
      rightHeader1: 'الجمهورية اليمنية',
      rightHeader2: 'نظام ساقية لإدارة محطة ضخ مياه الري',
      rightHeader3: settings['station_name'] ?? 'محطة ساقية',
      date: DateFormat('yyyy/MM/dd').format(started),
      refNumber: reportNumber,
      attachments: filterText.isEmpty ? 'عدد السجلات: ${rows.length}' : filterText,
      reportTitle: reportTitle,
      summaryBoxes: summaryBoxes,
      columns: headers,
      rows: tableRows,
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      fileName: '${titles[key] ?? key}.pdf',
      minTableRows: 7,
      pageFormat: sourceHeaders.length >= 6 ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
      preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
      printAfterGenerate: false,
    );

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
    if (to != null) parts.add('حتى ${DateFormat('yyyy/MM/dd').format(to)}');
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

  String _format(Object? value) {
    if (value == null) return '-';
    if (value is num) return NumberFormat('#,##0.##').format(value);
    return '$value';
  }

  Future<Uint8List> paymentReceiptPdf(int paymentId) async {
    final rows = await repo.db.rawQuery(
      '''SELECT p.*, COALESCE(b.name,COALESCE(w.name,pt.name)) party_name,
                pm.name method_name,c.name cashbox_name
         FROM payments p
         LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id
         LEFT JOIN workers w ON w.id=p.worker_id
         LEFT JOIN partners pt ON pt.id=p.partner_id
         JOIN payment_methods pm ON pm.id=p.payment_method_id
         JOIN cashboxes c ON c.id=p.cashbox_id
         WHERE p.id=?''',
      [paymentId],
    );
    if (rows.isEmpty) throw StateError('الإيصال غير موجود');
    final x = rows.first;
    final settings = await repo.settings();
    final now = DateTime.tryParse('${x['date']}') ?? AppClock.now();
    final amount = x['amount'] is num
        ? (x['amount'] as num)
        : num.tryParse('${x['amount'] ?? ''}') ?? 0;
    final isReceipt = x['beneficiary_id'] != null;
    String display(Object? value) {
      final text = value == null || '$value'.trim().isEmpty ? '—' : '$value';
      return _shapeArabic(text);
    }
    final dateFormat = DateFormat('yyyy/MM/dd');
    return OfficialReportTemplate.preview(
      rightHeader1: 'الجمهورية اليمنية',
      rightHeader2: 'نظام ساقية لإدارة محطة ضخ مياه الري',
      rightHeader3: settings['station_name'] ?? 'محطة ساقية',
      date: dateFormat.format(AppClock.now()),
      refNumber: 'PAY-$paymentId',
      attachments: 'تاريخ الحركة: ${dateFormat.format(now)}',
      reportTitle: isReceipt ? 'سند قبض' : 'سند صرف',
      summaryBoxes: [
        StatBoxData(
          number: '1',
          title: 'المبلغ',
          value: '${NumberFormat('#,##0.##').format(amount)} ريال',
          isBlueTint: true,
          isLarge: true,
        ),
        StatBoxData(number: '2', title: 'طريقة الدفع', value: display(x['method_name'])),
        StatBoxData(number: '3', title: 'الصندوق', value: display(x['cashbox_name'])),
      ],
      columns: const ['الطرف', 'المبلغ', 'طريقة الدفع', 'الصندوق', 'التاريخ', 'المرجع'],
      rows: [
        [
          display(x['party_name']),
          NumberFormat('#,##0.##').format(amount),
          display(x['method_name']),
          display(x['cashbox_name']),
          dateFormat.format(now),
          display(x['reference_number']),
        ],
      ],
      thirdSignatureLabel: 'توقيع المستلم / المسلّم: ....................',
      fileName: '${isReceipt ? 'سند-قبض' : 'سند-صرف'}-$paymentId.pdf',
      minTableRows: 1,
      pageFormat: PdfPageFormat.a4,
      preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
      printAfterGenerate: false,
    );
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
      if (d == null) return '—';
      final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
      final periodLabel = d.hour < 12 ? 'ص' : 'م';
      return '${hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} $periodLabel';
    }
    String duration(Object? value) {
      final minutes = n(value).clamp(0, 100000000);
      return '$minutesد';
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
          title: 'إجمالي الدقائق',
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
        'من',
        'إلى',
        'إجمالي الدقائق',
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
      pageFormat: PdfPageFormat.a4.landscape,
      preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
      printAfterGenerate: false,
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

  num _workerPeriodEndingBalance({
    required List<Map<String, Object?>> statementRows,
    required List<Map<String, Object?>> movementRows,
    required DateTime? from,
    required num due,
    required num withdrawals,
  }) {
    // With a start date, calculate the closing balance from the brought-forward
    // balance plus movements in the selected period. Do not rely on transaction
    // balance snapshots when calculating a period summary.
    if (from != null) {
      Map<String, Object?>? openingRow;
      for (final row in statementRows) {
        if (row['type'] == 'opening_balance') {
          openingRow = row;
          break;
        }
      }
      if (openingRow != null) {
        final openingBalance = _workerNum(openingRow['balance']);
        return openingBalance + movementRows.fold<num>(
          0,
          (sum, row) =>
              sum + _workerNum(row['lah']) - _workerNum(row['alayh']),
        );
      }
    }

    // The aggregate-income row carries the closing balance, while the
    // informational irrigation rows intentionally have no financial balance.
    final aggregate = statementRows.where((row) => row['type'] == 'worker_income_total').firstOrNull;
    if (aggregate != null) return _workerNum(aggregate['balance']);

    // Without a start date, the latest included financial transaction's
    // cumulative balance is the closing balance as of the selected end date.
    final latestFinancial = movementRows.where((row) =>
      row['type'] != 'worker_irrigation_info' && row['balance'] != null
    ).toList();
    if (latestFinancial.isNotEmpty) {
      return _workerNum(latestFinancial.first['balance']);
    }
    if (statementRows.isNotEmpty) {
      return _workerNum(statementRows.first['balance']);
    }
    return due - withdrawals;
  }

  Future<void> _printWorkerTransactionsOfficial({
    required int? workerId,
    required DateTime? from,
    required DateTime? to,
  }) async {
    final settings = await repo.settings();
    final workers = await repo.workers(includeInactive: true);
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

    // ساعات العامل تُسجّل على حركة استحقاق العامل المرتبطة بالسقاية،
    // وليس على irrigations.worker_id؛ فهذا الحقل يحدد عامل السقاية المختار
    // ولا يمثل بالضرورة كل العمال الذين احتُسب لهم أجر.
    final workerMinuteFilters = <String>[
      "i.status!='cancelled'",
    ];
    final workerMinuteArgs = <Object?>[];
    if (from != null) {
      workerMinuteFilters.add("COALESCE(date(i.date),date(i.start_datetime))>=date(?)");
      workerMinuteArgs.add(from.toIso8601String());
    }
    if (to != null) {
      workerMinuteFilters.add("COALESCE(date(i.date),date(i.start_datetime))<=date(?)");
      workerMinuteArgs.add(to.toIso8601String());
    }
    final workerMinuteRows = await repo.db.rawQuery(
      '''
      SELECT worker_id, SUM(minutes) minutes
      FROM (
        SELECT wt.worker_id, i.id irrigation_id,
               COALESCE(MAX(wt.hours) * 60, i.chargeable_minutes, i.minutes, 0) minutes
        FROM worker_transactions wt
        JOIN irrigations i ON i.id=wt.reference_id
        WHERE wt.reference_type='irrigation'
          AND wt.type='irrigation'
          AND wt.worker_id IS NOT NULL
          AND ${workerMinuteFilters.join(' AND ')}
        GROUP BY wt.worker_id, i.id

        UNION ALL

        SELECT i.worker_id, i.id irrigation_id,
               COALESCE(i.chargeable_minutes, i.minutes, 0) minutes
        FROM irrigations i
        WHERE i.worker_id IS NOT NULL
          AND ${workerMinuteFilters.join(' AND ')}
          AND NOT EXISTS (
            SELECT 1 FROM worker_transactions wt
            WHERE wt.worker_id=i.worker_id
              AND wt.reference_type='irrigation'
              AND wt.reference_id=i.id
              AND wt.type='irrigation'
          )
      )
      GROUP BY worker_id
      ''',
      [...workerMinuteArgs, ...workerMinuteArgs],
    );
    final minutesByWorker = <int, num>{
      for (final row in workerMinuteRows)
        _workerNum(row['worker_id']).toInt(): _workerNum(row['minutes']),
    };
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
      final net = _workerPeriodEndingBalance(
        statementRows: statementRows,
        movementRows: movementRows,
        from: from,
        due: due,
        withdrawals: withdrawals,
      );
      final minutes = minutesByWorker[workerId] ?? 0;
      totalMinutes = minutes;
      totalDue = due;
      totalWithdrawals = withdrawals;
      totalNet = net;
      // The repository returns rows newest-first and places the opening balance
      // before same-day movements in that order. Reversing the whole list would
      // move the opening row after the first day's movements, so move opening
      // rows to the front after reversing for chronological print order.
      final ordered = statementRows
          .where((row) => row['type'] != 'worker_income_total')
          .toList()
          .reversed
          .toList();
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
      final incomeSummary = statementRows.where((row) => row['type'] == 'worker_income_total').firstOrNull;
      if (incomeSummary != null) {
        final balance = _workerNum(incomeSummary['balance']);
        final balanceText = balance > 0
            ? 'له ${_workerMoney(balance)}'
            : balance < 0
                ? 'عليه ${_workerMoney(balance.abs())}'
                : 'صفر';
        movements.add([
          _workerDate(incomeSummary['date']),
          '${incomeSummary['description'] ?? 'إجمالي دخل العامل'}',
          _workerMoney(incomeSummary['lah']),
          _workerMoney(incomeSummary['alayh']),
          balanceText,
        ]);
      }
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
          StatBoxData(number: '1', title: 'نوع وطريقة التحاسب', value: '${_workerPayType(worker)} — ${_workerPayBasis(worker)}'),
          StatBoxData(number: '2', title: 'إجمالي المستحق', value: _workerMoney(due)),
          StatBoxData(number: '3', title: 'إجمالي المسحوبات', value: _workerMoney(withdrawals), isBlueTint: true),
          StatBoxData(number: '4', title: 'الصافي النهائي', value: net > 0 ? 'له ${_workerMoney(net)}' : net < 0 ? 'عليه ${_workerMoney(net.abs())}' : 'صفر', isLarge: true),
        ],
        columns: const ['التاريخ', 'البيان', 'له', 'عليه', 'المتبقي (له / عليه)'],
        rows: movements,
        footerTotalRow: ['الإجمالي', '', _workerMoney(due), _workerMoney(withdrawals), net > 0 ? 'له ${_workerMoney(net)}' : net < 0 ? 'عليه ${_workerMoney(net.abs())}' : 'صفر'],
        minTableRows: 1,
        preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
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
      final net = _workerPeriodEndingBalance(
        statementRows: tx,
        movementRows: movementRows,
        from: from,
        due: due,
        withdrawals: withdrawals,
      );
      final minutes = minutesByWorker[id] ?? 0;
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

        preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
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

        preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
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
