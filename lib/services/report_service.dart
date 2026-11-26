import '../core/diesel_quantity.dart';
import '../domain/accounting/party_diesel_statement.dart';
import '../domain/maintenance/diesel_delivery_service.dart';
import 'diesel_report_columns.dart';
import '../domain/accounting/report_minute_pricing.dart';
import '../core/app_clock.dart';
import 'package:intl/intl.dart';
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';
import '../domain/accounting/debt_report_totals.dart';
import 'official_report_template.dart';
import 'party_statement_balance_display.dart';
import 'report_file_name_service.dart';
import 'report_pdf_preview_service.dart';

class ReportService {
  final StationRepository repo;
  ReportService([StationRepository? r]) : repo = r ?? StationRepository();

  // The generic report families migrate to the common reader in groups of
  // nine or fewer. Specialized receipt/statement/partner paths follow later.
  static const previewReportKeys = <String>{
    'irrigations',
    'time_comparison',
    'monthly_financial',
    'income',
    'revenue_comparison',
    'system_comparison',
    'activity_overview',
    'expenses',
    'cash_flow',
    // Batch 2 (nine additional reports)
    'cashboxes',
    'payment_methods',
    'payment_log',
    'queue_bookings',
    'diesel_inventory',
    'oil_status',
    'journal',
    'ledger',
    'debts',
    // Batch 3 (nine additional reports)
    'all_party_debts',
    'beneficiary_detailed',
    'beneficiary_stats',
    'needy',
    'beneficiary_list',
    'partner_accounts',
    'partner_profit_distribution',
    'beneficiary_statement',
    'invoices',
    // Batch 4: the worker report takes the specialist official-template path.
    'worker_transactions',
  };

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
    'diesel_inventory': 'حركة الديزل: الإضافة والتسليم والاستهلاك',
    'activity_overview': 'نظرة عامة على النشاط',
    'oil_status': 'حالة الزيت',
    'debts': 'مديونيات المستفيدين',
    'all_party_debts': 'المديونيات — المستفيدون والعمال والشركاء',
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
  'payment_log': ['date', 'party_name', 'movement_type', 'method_name', 'cashbox_name', 'amount', 'notes'],
  'beneficiary_statement': ['date', 'description', 'lah', 'alayh', 'balance'],
  'beneficiary_detailed': ['date', 'description', 'start_datetime', 'end_datetime', 'minutes', 'cloud_minutes', 'lah', 'alayh', 'balance'],
  'worker_transactions': ['date', 'description', 'lah', 'alayh', 'balance'],
  'partner_accounts': ['date', 'description', 'lah', 'alayh', 'balance'],
  'partner_profit_distribution': ['name', 'mode', 'basis', 'direct_amount', 'share_amount', 'gross_amount', 'partner_expenses', 'net_amount'],
  'beneficiary_stats': ['name', 'irrigations', 'minutes', 'total'],
  'needy': ['name', 'balance'],
  'diesel_inventory': ['date', 'kind', 'liters', 'amount', 'beneficiary_name'],
  'activity_overview': ['system_type', 'operations', 'minutes', 'total', 'diesel_cost'],
  'oil_status': ['category', 'total'],
  'debts': ['id', 'name', 'balance'],
  'all_party_debts': ['party_type', 'name', 'balance'],
  'beneficiary_list': ['name', 'phone', 'status'],
  'revenue_comparison': ['month', 'system_type', 'total'],
  'system_comparison': ['system_type', 'operations', 'minutes', 'total', 'diesel_cost'],
  'journal': ['date', 'description', 'account_code', 'account_name', 'debit', 'credit'],
  'ledger': ['date', 'account_name', 'journal_entry_id', 'description', 'alayh', 'lah', 'balance'],
};


  /// Source-filtered irrigation PDF for a person in the hybrid system.
  /// Legacy hybrid rows without a source are excluded rather than misclassified.
  Future<void> printHybridPartyIrrigationsPdf({
    required String partyType,
    required int partyId,
    required String source,
    DateTime? from,
    DateTime? to,
  }) async {
    if (!const ['beneficiary', 'worker', 'partner'].contains(partyType) ||
        partyId <= 0 || !const ['solar', 'diesel'].contains(source)) {
      throw ArgumentError('نوع الطرف أو المصدر غير صالح');
    }
    final settings = await repo.settings();
    if (settings['system_type'] != 'equivalent_hybrid') {
      throw StateError('تقارير المصدر المنفصلة متاحة للنوع الثالث فقط');
    }
    final rows = await repo.report(
      'irrigations',
      beneficiaryId: partyType == 'beneficiary' ? partyId : null,
      workerId: partyType == 'worker' ? partyId : null,
      partnerId: partyType == 'partner' ? partyId : null,
      systemType: 'equivalent_hybrid',
      from: from,
      to: to,
    );
    final filtered = rows.where((row) => row['hybrid_source'] == source).toList();
    final table = switch (partyType) {
      'beneficiary' => 'beneficiaries',
      'worker' => 'workers',
      _ => 'partners',
    };
    final person = await repo.db.rawQuery('SELECT name FROM $table WHERE id=? LIMIT 1', [partyId]);
    final name = person.isEmpty ? 'غير محدد' : '${person.first['name'] ?? 'غير محدد'}';
    final label = source == 'solar' ? 'السقايات الشمسية' : 'سقايات الديزل';
    await printPdf(
      'irrigations',
      systemType: 'equivalent_hybrid',
      beneficiaryId: partyType == 'beneficiary' ? partyId : null,
      workerId: partyType == 'worker' ? partyId : null,
      partnerId: partyType == 'partner' ? partyId : null,
      from: from,
      to: to,
      sourceRows: filtered,
      hybridSource: source,
      reportTitleOverride: '$label — $name',
      fileNameOverride: '$label $name',
    );
  }

  /// Read-only cash movements for one party: posted payments and expenses
  /// explicitly assigned to that party. Does not include fuel/liter movements.
  Future<void> printPartyCashMovementsPdf({
    required String partyType,
    required int partyId,
    DateTime? from,
    DateTime? to,
  }) async {
    const tables = <String, String>{
      'beneficiary': 'beneficiaries',
      'worker': 'workers',
      'partner': 'partners',
    };
    const labels = <String, String>{
      'beneficiary': 'المستفيد',
      'worker': 'العامل',
      'partner': 'الشريك',
    };
    final table = tables[partyType];
    if (table == null || partyId <= 0) {
      throw ArgumentError('نوع الطرف أو رقمه غير صالح');
    }
    if (from != null && to != null &&
        DateTime(from.year, from.month, from.day)
            .isAfter(DateTime(to.year, to.month, to.day))) {
      throw ArgumentError('بداية الفترة بعد نهايتها');
    }
    final station = await repo.accounting.currentStationId();
    final people = await repo.db.rawQuery(
      'SELECT name FROM $table WHERE id=? AND station_id=?',
      [partyId, station],
    );
    if (people.length != 1) throw StateError('الشخص لا يتبع المحطة الحالية');
    final personName = '${people.single['name'] ?? labels[partyType]}';
    final partyColumn = '${partyType}_id';
    final dateFrom = from == null ? null : DateFormat('yyyy-MM-dd').format(from);
    final dateTo = to == null ? null : DateFormat('yyyy-MM-dd').format(to);
    final payments = await repo.db.rawQuery(
      """SELECT p.id,p.date,p.amount,p.reference_number,p.notes,
                pm.name method_name,c.name cashbox_name,
                CASE WHEN p.beneficiary_id IS NOT NULL THEN 'قبض من الشخص'
                     ELSE 'دفع للشخص' END movement
         FROM payments p
         LEFT JOIN payment_methods pm ON pm.id=p.payment_method_id
         LEFT JOIN cashboxes c ON c.id=p.cashbox_id
         WHERE p.station_id=? AND p.$partyColumn=? AND p.status='posted'
           AND (? IS NULL OR date(p.date)>=date(?))
           AND (? IS NULL OR date(p.date)<=date(?))
         ORDER BY p.date,p.id""",
      [station, partyId, dateFrom, dateFrom, dateTo, dateTo],
    );
    final expenses = await repo.db.rawQuery(
      """SELECT e.id,e.date,e.amount,e.title,e.category,e.notes,
                pm.name method_name,c.name cashbox_name
         FROM expenses e
         LEFT JOIN payment_methods pm ON pm.id=e.payment_method_id
         LEFT JOIN cashboxes c ON c.id=e.cashbox_id
         WHERE e.station_id=? AND e.$partyColumn=? AND e.status='posted'
           AND (? IS NULL OR date(e.date)>=date(?))
           AND (? IS NULL OR date(e.date)<=date(?))
         ORDER BY e.date,e.id""",
      [station, partyId, dateFrom, dateFrom, dateTo, dateTo],
    );
    final movements = <Map<String, Object?>>[
      for (final row in payments)
        <String, Object?>{
          'id': row['id'], 'date': row['date'], 'amount': row['amount'],
          'movement': row['movement'], 'title': 'سند قبض/صرف',
          'notes': row['notes'], 'reference': row['reference_number'],
          'method': row['method_name'], 'cashbox': row['cashbox_name'],
          'currency': '',
        },
      for (final row in expenses)
        <String, Object?>{
          'id': row['id'], 'date': row['date'], 'amount': row['amount'],
          'movement': 'مصروف نقدي', 'title': row['title'],
          'notes': row['notes'], 'reference': null,
          'method': row['method_name'], 'cashbox': row['cashbox_name'],
          'currency': '',
        },
    ]..sort((a, b) {
        final byDate = '${a['date']}'.compareTo('${b['date']}');
        return byDate != 0 ? byDate : ((a['id'] as num?) ?? 0)
            .compareTo((b['id'] as num?) ?? 0);
      });
    final settings = await repo.settings();
    final now = AppClock.now();
    final money = NumberFormat('#,##0');
    num totalReceived = 0;
    num totalPaid = 0;
    num totalExpenses = 0;
    for (final row in movements) {
      final amount = (row['amount'] as num?) ?? 0;
      switch (row['movement']) {
        case 'قبض من الشخص': totalReceived += amount;
        case 'دفع للشخص': totalPaid += amount;
        case 'مصروف نقدي': totalExpenses += amount;
      }
    }
    final title = 'تقرير الحركات النقدية — ${labels[partyType]} $personName';
    await OfficialReportTemplate.preview(
      rightHeader1: settings['station_name'] ?? 'منظومة السقاية',
      rightHeader2: settings['organization_name'] ?? 'الإدارة المالية',
      rightHeader3: 'الجمهورية اليمنية',
      date: DateFormat('yyyy/MM/dd').format(now),
      refNumber: 'CASH-${DateFormat('yyMMdd-HHmm').format(now)}',
      attachments: 'الفترة: ${dateFrom ?? 'من البداية'} إلى ${dateTo ?? 'الآن'}',
      fileName: _pdfFileName(title),
      reportTitle: title,
      summaryBoxes: [
        StatBoxData(number: '1', title: 'المبالغ المستلمة', value: money.format(totalReceived)),
        StatBoxData(number: '2', title: 'المدفوعات', value: money.format(totalPaid)),
        StatBoxData(number: '3', title: 'المصروفات', value: money.format(totalExpenses)),
      ],
      columns: const ['التاريخ', 'نوع الحركة', 'المبلغ', 'البيان والتفاصيل'],
      rows: [
        for (final row in movements)
          [
            DateFormat('yyyy/MM/dd').format(
              DateTime.tryParse('${row['date'] ?? ''}') ?? now),
            '${row['movement']}',
            money.format((row['amount'] as num?) ?? 0),
            [
              '${row['title'] ?? ''}',
              if ('${row['currency'] ?? ''}'.trim().isNotEmpty) '${row['currency']}',
              if ('${row['method'] ?? ''}'.trim().isNotEmpty) 'الطريقة: ${row['method']}',
              if ('${row['cashbox'] ?? ''}'.trim().isNotEmpty) 'الصندوق: ${row['cashbox']}',
              if ('${row['reference'] ?? ''}'.trim().isNotEmpty) 'المرجع: ${row['reference']}',
              if ('${row['notes'] ?? ''}'.trim().isNotEmpty) '${row['notes']}',
            ].join(' — '),
          ],
      ],
      footerTotalRow: [
        'الإجمالي', '', money.format(totalReceived + totalPaid + totalExpenses), '',
      ],
      minTableRows: 1,
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
    );
  }

  /// A third per-person PDF: liters issued, consumed and the exact signed
  /// balance, including reversals. No money or stock is posted by this reader.
  Future<void> printPartyDieselPdf({
    required String partyType,
    required int partyId,
    DateTime? from,
    DateTime? to,
  }) async {
    const tables = <String, String>{
      'beneficiary': 'beneficiaries',
      'worker': 'workers',
      'partner': 'partners',
    };
    const labels = <String, String>{
      'beneficiary': 'المستفيد',
      'worker': 'العامل',
      'partner': 'الشريك',
    };
    final table = tables[partyType];
    if (table == null || partyId <= 0) {
      throw ArgumentError('نوع الطرف أو رقمه غير صالح');
    }
    if (from != null && to != null &&
        DateTime(from.year, from.month, from.day)
            .isAfter(DateTime(to.year, to.month, to.day))) {
      throw ArgumentError('بداية الفترة بعد نهايتها');
    }
    final station = await repo.accounting.currentStationId();
    final people = await repo.db.rawQuery(
      'SELECT * FROM $table WHERE id=? AND station_id=?',
      [partyId, station],
    );
    if (people.length != 1) throw StateError('صاحب التقرير لا يتبع المحطة الحالية');
    final person = people.single;
    final opening = partyType == 'beneficiary'
        ? ((person['opening_diesel_liters'] as num?)?.toDouble() ?? 0) +
          ((person['carried_diesel_liters'] as num?)?.toDouble() ?? 0)
        : 0.0;
    final column = '${partyType}_id';
    final movements = await repo.db.rawQuery(
      """SELECT dm.id,dm.date,dm.kind,dm.liters,dm.party_receipt,
                dm.irrigation_id,dm.reversal_of,dm.notes
         FROM diesel_movements dm
         LEFT JOIN irrigations i ON i.id=dm.irrigation_id
         WHERE dm.station_id=? AND
               (dm.$column=? OR (dm.$column IS NULL AND i.$column=?))
         ORDER BY dm.date ASC,dm.id ASC""",
      [station, partyId, partyId],
    );
    final statement = PartyDieselStatement.fromMovements(
      opening: opening, movements: movements, from: from, to: to);
    if (from == null && to == null) {
      final ledgerBalance = await DieselDeliveryService(repo.db)
          .balance(station, partyType, partyId);
      if ((ledgerBalance - statement.closing).abs() > 0.01) {
        throw StateError('تقرير الديزل لا يطابق رصيد الديزل المحفوظ؛ راجع سجل الحركات');
      }
    }

    String liters(num value) => DieselQuantity.format(value);
    String balanceLabel(num value) => DieselQuantity.balanceLabel(value);
    String movementLabel(PartyDieselStatementEntry entry) {
      final kind = switch (entry.kind) {
        'delivery' => 'تسليم ديزل',
        'receipt' => 'استلام ديزل',
        'advance' => 'سلفة ديزل مستقلة',
        'consumption' => 'استهلاك ديزل',
        _ => 'حركة ديزل',
      };
      return '${entry.reversal ? 'عكس ' : ''}$kind'
          '${entry.notes.trim().isEmpty ? '' : ' — ${entry.notes.trim()}'}';
    }
    final now = AppClock.now();
    final settings = await repo.settings();
    final name = '${person['name'] ?? labels[partyType]}';
    final title = 'كشف تسليم واستهلاك الديزل — ${labels[partyType]} $name';
    await OfficialReportTemplate.preview(
      rightHeader1: settings['station_name'] ?? 'منظومة السقاية',
      rightHeader2: settings['organization_name'] ?? 'الإدارة المالية',
      rightHeader3: 'الجمهورية اليمنية',
      date: DateFormat('yyyy/MM/dd').format(now),
      refNumber: 'DSL-${DateFormat('yyMMdd-HHmm').format(now)}',
      attachments: 'الفترة: ${from == null ? 'من البداية' : DateFormat('yyyy/MM/dd').format(from)}'
          ' إلى ${to == null ? 'الآن' : DateFormat('yyyy/MM/dd').format(to)}',
      fileName: _pdfFileName(title),
      reportTitle: title,
      summaryBoxes: [
        StatBoxData(number: '1', title: 'رصيد أول الفترة (لتر)',
          value: balanceLabel(statement.opening)),
        StatBoxData(number: '2', title: 'إجمالي المسلم (لتر)',
          value: liters(statement.delivered), isBlueTint: true),
        StatBoxData(number: '3', title: 'إجمالي المستهلك (لتر)',
          value: liters(statement.consumed)),
        StatBoxData(number: '4', title: 'المتبقي له أو عليه (لتر)',
          value: balanceLabel(statement.closing), isLarge: true),
      ],
      columns: const ['التاريخ', 'البيان', 'المسلّم (لتر)', 'المستهلك (لتر)', 'الرصيد له/عليه'],
      rows: [
        for (final entry in statement.entries)
          [
            DateFormat('yyyy/MM/dd').format(entry.date),
            movementLabel(entry),
            entry.delivered == 0 ? '—' : liters(entry.delivered),
            entry.consumed == 0 ? '—' : liters(entry.consumed),
            balanceLabel(entry.balance),
          ],
      ],
      footerTotalRow: [
        'الإجمالي', '', liters(statement.delivered),
        liters(statement.consumed), balanceLabel(statement.closing),
      ],
      minTableRows: 1,
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
    );
  }

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
    String? hybridSource,
    String? reportTitleOverride,
  }) async {
    final started = AppClock.now();
    if (!titles.containsKey(key) || !reportColumns.containsKey(key)) {
      throw StateError('تقرير غير معروف أو غير مرتبط بمصدر بيانات: $key');
    }
    final settings = await repo.settings();
    final currentType = settings['system_type'] ?? 'diesel';
    if (key == 'diesel_inventory' &&
        !const ['diesel', 'equivalent_hybrid'].contains(currentType)) {
      throw StateError('تقرير الديزل غير متاح لأن المنظومة الحالية ليست ديزل');
    }
    systemType ??= currentType;
    final rows = sourceRows != null
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
    final dieselOnly = DieselReportColumns.dieselOnly(rows, systemType);
    final fuelReport = const ['irrigations', 'beneficiary_detailed'].contains(key);
    final hybridBeneficiaryStats = key == 'beneficiary_stats' && currentType == 'equivalent_hybrid';
    final expectedHeaders = hybridBeneficiaryStats
        ? ['name','solar_irrigations','solar_minutes','solar_total','diesel_irrigations','diesel_minutes','diesel_total','irrigations','minutes','total']
        : hybridSource == 'diesel' && key == 'irrigations'
        ? ['party_name', 'start_datetime', 'end_datetime', 'minutes', 'paid_amount', 'total_amount', 'diesel_consumption_liters']
        : hybridSource == 'solar' && key == 'irrigations'
            ? ['party_name', 'start_datetime', 'end_datetime', 'minutes', 'paid_amount', 'total_amount', 'cloud_minutes', 'cloud_status']
            : fuelReport
                ? DieselReportColumns.select(reportColumns[key]!, dieselOnly: dieselOnly,
                    hasDiesel: rows.any((row) => row['system_type'] == 'diesel'))
                : reportColumns[key] ?? <String>[];
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
      const hybridStatLabels = <String, String>{
        'name': 'المستفيد',
        'solar_irrigations': 'الشمس • السقايات',
        'solar_minutes': 'الشمس • الدقائق',
        'solar_total': 'الشمس • الإجمالي (ريال)',
        'diesel_irrigations': 'الديزل • السقايات',
        'diesel_minutes': 'الديزل • الدقائق',
        'diesel_total': 'الديزل • الإجمالي (ريال)',
        'irrigations': 'الإجمالي • السقايات',
        'minutes': 'الإجمالي • الدقائق',
        'total': 'الإجمالي • القيمة (ريال)',
      };
      final label = hybridBeneficiaryStats
          ? (hybridStatLabels[header] ?? _fieldName(header))
          : key == 'irrigations'
              ? ({
                  'party_name': 'الجهة',
                  'start_datetime': 'من',
                  'end_datetime': 'إلى',
                  'minutes': 'إجمالي الدقائق',
                  'paid_amount': 'المدفوع',
                  'total_amount': 'القيمة الإجمالية',
                  'cloud_minutes': 'الغيم',
                  'cloud_status': 'حالة الخصم',
                  'diesel_consumption_liters': 'استهلاك الديزل (لتر)',
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
                .map((header) {
                  // Informational irrigation rows have no running balance.
                  // Preserve a real zero balance on financial rows.
                  if (header == 'balance' &&
                      (key == 'worker_transactions' || key == 'partner_accounts') &&
                      !PartyStatementBalanceDisplay.hasBalance(row)) {
                    return _shapeArabic('—');
                  }
                  return _shapeArabic(_formatValue(header, row[header], key));
                })
                .toList(growable: false);
          }).toList(growable: false);

    num sumOf(String field) => rows.fold<num>(0, (sum, row) {
          final value = row[field];
          if (value is num) return sum + value;
          return sum + (num.tryParse('${value ?? ''}') ?? 0);
        });
    String money(num value) => NumberFormat('#,##0.##').format(value);
    final debtTotals = (key == 'debts' || key == 'all_party_debts')
        ? DebtReportTotals.fromRows(rows)
        : null;

    // The partner report contains informational irrigation rows and a profit
    // summary. Neither is a second financial movement. Derive totals from the
    // original partner ledger, not from those synthesized display rows.
    num partnerLah = 0, partnerAlayh = 0;
    num? partnerClosing;
    if (key == 'partner_accounts' && partnerId != null) {
      final transactions = await repo.partnerTransactions(partnerId);
      for (final row in transactions) {
        if (const {'opening_balance', 'carried_balance', 'current_balance'}
            .contains(row['type'])) {
          continue;
        }
        final date = DateTime.tryParse('${row['date'] ?? ''}');
        if (from != null &&
            (date == null || date.isBefore(DateTime(from.year, from.month, from.day)))) {
          continue;
        }
        if (to != null &&
            (date == null || !date.isBefore(DateTime(to.year, to.month, to.day + 1)))) {
          continue;
        }
        final amount = row['signed_amount'] is num
            ? row['signed_amount'] as num
            : (row['lah'] as num? ?? 0) - (row['alayh'] as num? ?? 0);
        if (amount > 0) {
          partnerLah += amount;
        }
        if (amount < 0) {
          partnerAlayh -= amount;
        }
      }
      for (final row in rows) {
        if (row['type'] == 'partner_profit_total' && row['balance'] is num) {
          partnerClosing = row['balance'] as num;
          break;
        }
      }
      partnerClosing ??= rows.isEmpty
          ? 0
          : (rows.firstWhere((row) => row['balance'] is num,
              orElse: () => <String,Object?>{'balance': 0})['balance'] as num);
    }
    String partnerClosingLabel(num balance) => balance > 0
        ? 'له ${money(balance)} ريال'
        : balance < 0 ? 'عليه ${money(balance.abs())} ريال' : 'متوازن (0 ريال)';
    final summaryBoxes = hybridBeneficiaryStats
        ? <StatBoxData>[
          StatBoxData(number: 'S1', title: 'الشمس • عدد السقايات', value: money(sumOf('solar_irrigations')), isBlueTint: true),
          StatBoxData(number: 'S2', title: 'الشمس • إجمالي الدقائق', value: money(sumOf('solar_minutes')), isBlueTint: true),
          StatBoxData(number: 'S3', title: 'الشمس • إجمالي الدخل', value: '${money(sumOf('solar_total'))} ريال', isBlueTint: true),
          StatBoxData(number: 'D1', title: 'الديزل • عدد السقايات', value: money(sumOf('diesel_irrigations'))),
          StatBoxData(number: 'D2', title: 'الديزل • إجمالي الدقائق', value: money(sumOf('diesel_minutes'))),
          StatBoxData(number: 'D3', title: 'الديزل • إجمالي الدخل', value: '${money(sumOf('diesel_total'))} ريال'),
          StatBoxData(number: 'T1', title: 'الإجمالي • عدد السقايات', value: money(sumOf('irrigations')), isLarge: true, isBlueTint: true),
          StatBoxData(number: 'T2', title: 'الإجمالي • الدقائق', value: money(sumOf('minutes')), isLarge: true, isBlueTint: true),
          StatBoxData(number: 'T3', title: 'الإجمالي • الدخل', value: '${money(sumOf('total'))} ريال', isLarge: true, isBlueTint: true),
        ]
        : <StatBoxData>[
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
      if (fuelReport && (dieselOnly || hybridSource == 'diesel' || rows.any((row) => row['system_type'] == 'diesel')))
        StatBoxData(number: '3D', title: 'استهلاك الديزل (لتر)',
          value: DieselQuantity.format(sumOf('diesel_consumption_liters'))),
      if ((!fuelReport || (!dieselOnly && hybridSource != 'diesel')) && rows.any((row) => row.containsKey('cloud_minutes')))
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
      if (partnerClosing != null) ...[
        StatBoxData(number: 'P1', title: 'إجمالي له', value: '${money(partnerLah)} ريال'),
        StatBoxData(number: 'P2', title: 'إجمالي عليه', value: '${money(partnerAlayh)} ريال', isBlueTint: true),
        StatBoxData(number: 'P3', title: 'المتبقي له أو عليه', value: partnerClosingLabel(partnerClosing), isLarge: true),
      ],
      if (debtTotals != null) ...[
        StatBoxData(
          number: '10',
          title: 'إجمالي المديونية (عليه)',
          value: '${money(debtTotals.totalAlayh)} ريال',
        ),
        StatBoxData(
          number: '11',
          title: 'إجمالي الرصيد الدائن (له)',
          value: '${money(debtTotals.totalLah)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '12',
          title: 'صافي المتبقي (له / عليه)',
          // Net is a summary difference, not an offset of any party's debt.
          value: debtTotals.netLabel((amount) => '${money(amount)} ريال'),
          isLarge: true,
        ),
      ],
    ];
    final reportTitle = reportTitleOverride ?? (personName == null
        ? titles[key]!
        : '${titles[key]} — $personName');
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
      footerTotalRow: partnerClosing == null ? null : [
        for (final field in sourceHeaders)
          switch (field) {
            'date' => 'الإجمالي',
            'lah' => money(partnerLah),
            'alayh' => money(partnerAlayh),
            'balance' => partnerClosingLabel(partnerClosing),
            _ => '',
          },
      ],
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      fileName: _pdfFileName(reportTitle),
      minTableRows: 7,
      pageFormat: hybridBeneficiaryStats || sourceHeaders.length >= 5 ||
              const {
                'irrigations',
                'payment_methods',
                'cashboxes',
                'diesel_inventory',
              }.contains(key)
          ? PdfPageFormat.a4.landscape
          : PdfPageFormat.a4,
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

  // Keep logical Unicode Arabic text intact. The PDF package performs RTL
  // shaping itself; pre-shaping into presentation-form code points can crash
  // its bidi normalization (RangeError) on otherwise valid report data.
  // Replace the unsupported bullet glyph so the configured PDF fonts can
  // render notes without Helvetica Unicode warnings.
  String _shapeArabic(String value) {
    if (value.trim().isEmpty) return '-';
    return value.replaceAll('•', '-');
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
    'id':'الرقم','date':'التاريخ','movement_type':'نوع العملية','start_datetime':'بداية السقي','end_datetime':'نهاية السقي','month':'الشهر','minutes':'المدة بالدقائق','chargeable_minutes':'الدقائق المحاسبية','operations':'عدد العمليات','system_type':'نوع المنظومة','total_amount':'الإجمالي','total':'الإجمالي','income':'الإيرادات','expenses':'المصروفات','water_income':'إيراد المياه','diesel_income':'إيراد الديزل','diesel_cost':'تكلفة الديزل','paid_amount':'المدفوع','remaining':'حالة الرصيد','solar_irrigations':'سقايات شمسي','solar_minutes':'دقائق شمسي','solar_total':'دخل شمسي','diesel_irrigations':'سقايات ديزل','diesel_minutes':'دقائق ديزل','diesel_total':'دخل ديزل','beneficiary_name':'المستفيد','party_name':'الجهة','party_type':'نوع الطرف','cloud_status':'حالة خصم الغيم','worker_name':'العامل','partner_name':'الشريك','cashbox_name':'الصندوق','method_name':'طريقة الدفع','account_name':'الحساب','account_code':'رمز الحساب','debit':'له','credit':'عليه','lah':'له','alayh':'عليه','amount':'المبلغ','direct_amount':'استحقاق مباشر من السقايات','share_amount':'نصيبه من المتبقي','gross_amount':'إجمالي الاستحقاق قبل المصروفات الخاصة','partner_expenses':'مصروفات الشريك الخاصة','net_amount':'صافي نصيب الشريك بعد المصروفات الخاصة','liters':'اللترات','kind':'نوع الحركة','status':'الحالة','notes':'ملاحظات','description':'البيان','ownership_percentage':'نسبة الملكية','shares_count':'عدد الحصص','opening_balance':'الرصيد الافتتاحي','carried_balance':'الرصيد المرحل','balance':'الرصيد الجاري','water_amount':'قيمة المياه','diesel_amount':'قيمة الديزل','diesel_consumption_liters':'استهلاك الديزل (لتر)','cloud_minutes':'دقائق الغيم','category':'التصنيف','title':'العنوان','phone':'الهاتف','name':'الاسم','reference_number':'رقم المرجع','created_at':'تاريخ الإنشاء','updated_at':'تاريخ التحديث','position':'الدور','scheduled_start':'بداية الموعد','scheduled_end':'نهاية الموعد','payment_method_id':'طريقة الدفع','cashbox_id':'الصندوق','beneficiary_id':'المستفيد','worker_id':'العامل','partner_id':'الشريك','journal_id':'رقم القيد','journal_entry_id':'رقم القيد','ownership_mode':'طريقة الملكية','job_title':'المسمى الوظيفي','pay_type':'طريقة الحساب','pump_name':'المضخة','queue_position':'رقم الدور',
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
    if (reportKey == 'irrigations' &&
        (key == 'start_datetime' || key == 'end_datetime')) {
      final d = DateTime.tryParse('$value');
      if (d != null) {
        final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
        final periodLabel = d.hour < 12 ? 'ص' : 'م';
        return '${hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} $periodLabel';
      }
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
    if (key == 'diesel_consumption_liters' || key == 'liters') {
      return value == null ? '—' : DieselQuantity.format(value is num ? value : num.tryParse('$value') ?? 0);
    }
    if (key == 'party_type') {
      return switch ('$value') {
        'beneficiary' => 'مستفيد',
        'worker' => 'عامل',
        'partner' => 'شريك',
        _ => 'غير محدد',
      };
    }
    if (key == 'cloud_status') {
      return '$value' == 'discounted' ? 'تم خصم الغيم' : 'لا يوجد خصم';
    }
    if (const {'solar_irrigations','solar_minutes','solar_total','diesel_irrigations','diesel_minutes','diesel_total','irrigations','minutes','total'}.contains(key)) {
      final numeric = value is num ? value : num.tryParse('$value') ?? 0;
      return NumberFormat('#,##0.##').format(numeric);
    }
    if (key == 'system_type') {
      return switch ('$value') { 'diesel' => 'ديزل', 'solar' => 'شمسي', 'equivalent_hybrid' => 'النوع الثالث', _ => 'غير محدد' };
    }
    if (key == 'status') return switch ('$value') { 'waiting'=>'منتظر','postponed'=>'مؤجل','running'=>'قيد التشغيل','completed'=>'مكتمل','new'=>'جديد','under_review'=>'قيد المراجعة','scheduled'=>'مجدول','accepted'=>'مقبول','cancelled'=>'ملغى','posted'=>'مرحل', _=> 'غير محدد' };
    if (key == 'movement_type') return '$value' == 'receipt' ? 'قبض' : '$value' == 'payment' ? 'صرف' : 'حركة';
    if (key == 'kind') return switch ('$value') { 'receipt'=>'شراء وإضافة','delivery'=>'تسليم','advance'=>'سلفة','consumption'=>'استهلاك','correction'=>'تصحيح','opening_balance'=>'رصيد افتتاحي','payment'=>'صرف','expense'=>'مصروف', _=> 'حركة' };
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
      columns: const ['الطرف', 'المبلغ', 'نوع العملية', 'الملاحظة', 'طريقة الدفع', 'الصندوق', 'التاريخ', 'المرجع'],
      rows: [
        [
          display(x['party_name']),
          NumberFormat('#,##0.##').format(amount),
          isReceipt ? 'قبض' : 'صرف',
          display(x['notes']),
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

  Future<void> printPaymentReceipt(int paymentId) async {
    final bytes = await paymentReceiptPdf(paymentId);
    final rows = await repo.db.rawQuery(
      '''SELECT p.id, p.beneficiary_id, p.worker_id, p.partner_id,
                COALESCE(b.name, w.name, pt.name) party_name
         FROM payments p
         LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id
         LEFT JOIN workers w ON w.id=p.worker_id
         LEFT JOIN partners pt ON pt.id=p.partner_id
         WHERE p.id=? LIMIT 1''',
      [paymentId],
    );
    final isReceipt = rows.isNotEmpty && rows.first['beneficiary_id'] != null;
    final partyName = rows.isEmpty ? '' : '${rows.first['party_name'] ?? ''}'.trim();
    final baseName = '${isReceipt ? 'سند قبض' : 'سند صرف'}${partyName.isEmpty ? '' : ' $partyName'} رقم $paymentId';
    await ReportPdfPreviewService.open(
      bytes: bytes,
      suggestedName: baseName,
    );
  }

  /// إنشاء PDF مخصص لتقرير الفواتير بأعمدته الثمانية وإجمالياته الرسمية.
  Future<Uint8List> invoicesPdf({
    List<Map<String, Object?>>? rows,
    DateTime? from,
    DateTime? to,
    String? hybridSourceFilter,
  }) async {
    final sourceRows = rows ?? await repo.report('invoices', from: from, to: to);
    final selectedRows = hybridSourceFilter == null
        ? sourceRows
        : sourceRows.where((row) => row['hybrid_source'] == hybridSourceFilter).toList();
    // بعض مسارات المعاينة القديمة تمرر beneficiary_name أو رقم السقاية فقط،
    // لذلك لا نعتمد على party_name القادم من الشاشة وحده.
    final data = selectedRows
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
    // عمود الدقائق في تفاصيل PDF يعرض الصافي بعد خصم الغيم للسقايات الشمسية فقط.
    // تبقى دقائق السقاية الأصلية محفوظة ويظل الملخص العام كما هو.
    int invoiceNetMinutes(Map<String, Object?> row) {
      final minutes = n(row['minutes']).clamp(0, 100000000).toInt();
      final isSolar = '${row['system_type'] ?? ''}' == 'solar' ||
          ('${row['system_type'] ?? ''}' == 'equivalent_hybrid' && row['hybrid_source'] == 'solar');
      if (!isSolar) return minutes;
      return (minutes - n(row['cloud_minutes'])).clamp(0, 100000000).toInt();
    }
    String duration(Object? value) =>
        n(value).clamp(0, 100000000).toString();
    String hoursMinutes(Object? value) {
      final minutes = n(value).clamp(0, 100000000);
      return '${minutes ~/ 60} ساعة و ${minutes % 60} دقيقة';
    }
    String display(Object? value) {
      final text = value == null || '$value'.trim().isEmpty ? '—' : '$value';
      return _shapeArabic(text);
    }
    String money(Object? value) => NumberFormat('#,##0').format(n(value));

    final dieselInvoices = DieselReportColumns.dieselOnly(data, settings['system_type'] ?? 'diesel');
    final showInvoiceCloud = DieselReportColumns.invoiceHasCloud(data, settings['system_type'] ?? 'diesel');
    final totalFuel = data.fold<num>(0, (sum, row) => sum + ((row['diesel_consumption_liters'] as num?) ?? 0));
    final totalMinutes =
        data.fold<int>(0, (sum, row) => sum + n(row['minutes']));
    final totalCloudMinutes = data.fold<int>(0, (sum, row) =>
        sum + (('${row['system_type'] ?? ''}' == 'solar' ||
            ('${row['system_type'] ?? ''}' == 'equivalent_hybrid' && row['hybrid_source'] == 'solar'))
            ? n(row['cloud_minutes']) : 0));
    final useSpecialMinuteRate =
        settings['work_price_report_display_special_rate'] == 'true';
    final partialHour = settings['partial_hour'] != 'false';
    int hourlyRate(Map<String, Object?> row) {
      final type = '${row['system_type'] ?? ''}';
      if (type == 'solar' || (type == 'equivalent_hybrid' && row['hybrid_source'] == 'solar')) {
        return n(row['solar_hourly_rate_snapshot']);
      }
      if (type == 'equivalent_hybrid') {
        return row['hybrid_source'] == 'diesel'
            ? n(row['hybrid_diesel_hourly_rate_snapshot'])
            : n(row['third_type_hourly_rate_snapshot']); // historical records
      }
      return n(row['water_hourly_rate_snapshot']);
    }
    int reportAmount(Map<String, Object?> row, {required bool beforeCloud}) {
      final minutes = n(beforeCloud
          ? row['minutes']
          : (row['chargeable_minutes'] ?? (n(row['minutes']) - n(row['cloud_minutes']))))
          .clamp(0, 100000000)
          .toInt();
      if (useSpecialMinuteRate && row['beneficiary_id'] != null) {
        final savedMinuteRate = n(row['work_minute_rate_snapshot']);
        final minuteRate = savedMinuteRate;
        if (minuteRate > 0) {
          return ReportMinutePricing.amountAtMinuteRate(minutes, minuteRate) +
              n(row['diesel_amount']);
        }
      }
      final rate = hourlyRate(row);
      if (rate <= 0) return n(row['total_amount']);
      final waterAmount = AccountingCalculations.amountForMinutes(
        minutes, rate, 'up', partialHour,
      );
      return waterAmount + n(row['diesel_amount']);
    }
    int amountAtHourlyRate(Map<String, Object?> row, {required bool beforeCloud}) {
      final rate = hourlyRate(row);
      if (rate <= 0) return n(row['total_amount']);
      final minutes = n(beforeCloud
          ? row['minutes']
          : (row['chargeable_minutes'] ?? (n(row['minutes']) - n(row['cloud_minutes']))));
      return AccountingCalculations.amountForMinutes(
            minutes.clamp(0, 100000000).toInt(), rate, 'up', partialHour,
          ) +
          n(row['diesel_amount']);
    }
    final totalAmountBeforeCloud = data.fold<int>(
      0, (sum, row) => sum + reportAmount(row, beforeCloud: true),
    );
    final totalAmount = data.fold<int>(
      0, (sum, row) => sum + reportAmount(row, beforeCloud: false),
    );
    final totalWorkBasis = data.fold<int>(
      0, (sum, row) => sum + amountAtHourlyRate(row, beforeCloud: false),
    );
    // The recorded operational difference does not depend on the display mode.
    final totalWorkDifference =
        data.fold<int>(0, (sum, row) => sum + n(row['work_difference_snapshot']));
    final cloudDeductionAmount =
        (totalAmountBeforeCloud - totalAmount).clamp(0, 1 << 62);
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
          if (settings['system_type'] == 'equivalent_hybrid')
            display(data[i]['hybrid_source'] == 'solar' ? 'شمسي' : data[i]['hybrid_source'] == 'diesel' ? 'ديزل' : 'غير محدد'),
          time(data[i]['start_datetime']),
          time(data[i]['end_datetime']),
          '${invoiceNetMinutes(data[i])}',
          if (showInvoiceCloud) data[i]['system_type'] == 'diesel' || (data[i]['system_type'] == 'equivalent_hybrid' && data[i]['hybrid_source'] == 'diesel') ? '—' : '${n(data[i]['cloud_minutes'])}',
          money(reportAmount(data[i], beforeCloud: false)),
          money(data[i]['paid_amount']),
          if (dieselInvoices) DieselQuantity.format((data[i]['diesel_consumption_liters'] as num?) ?? 0),
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
      reportTitle: hybridSourceFilter == 'solar' ? 'تقرير فواتير السقايات الشمسية' : hybridSourceFilter == 'diesel' ? 'تقرير فواتير سقايات الديزل' : 'تقرير الفواتير',
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
          value: hoursMinutes(totalMinutes),
        ),
        StatBoxData(
          number: '3',
          title: dieselInvoices ? 'استهلاك الديزل (لتر)' : 'دقائق الغيم المخصومة',
          value: dieselInvoices ? DieselQuantity.format(totalFuel) : duration(totalCloudMinutes),
          isBlueTint: true,
        ),
        StatBoxData(
          number: '4',
          title: dieselInvoices ? 'إجمالي الإيرادات' : 'الإيرادات قبل خصم الغيم',
          value: '${money(totalAmountBeforeCloud)} ريال',
        ),
        StatBoxData(
          number: '5',
          title: dieselInvoices ? 'عدد تسقيات الديزل' : 'قيمة خصم الغيم',
          value: dieselInvoices ? '${data.length}' : '${money(cloudDeductionAmount)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '6',
          title: dieselInvoices ? 'صافي الإيرادات' : 'الإيرادات بعد خصم الغيم',
          value: '${money(totalAmount)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '7',
          title: 'أساس العمل بسعر الساعة',
          value: '${money(totalWorkBasis)} ريال',
        ),
        StatBoxData(
          number: '8',
          title: 'صافي فارق العمل المسجل',
          value: '${money(totalWorkDifference)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '9',
          title: 'إجمالي المدفوع',
          value: '${money(totalPaid)} ريال',
        ),
        StatBoxData(
          number: '10',
          title: 'المتبقي',
          value: '${money(remaining)} ريال',
          isBlueTint: true,
        ),
        StatBoxData(
          number: '11',
          title: 'الفترة',
          value: period,
        ),
      ],
      columns: [
        'م',
        'المستفيد / العامل / الشريك',
        if (settings['system_type'] == 'equivalent_hybrid') 'مصدر التشغيل',
        'من',
        'إلى',
        'إجمالي الدقائق',
        if (showInvoiceCloud) 'الغيم (دقيقة)',
        'القيمة الإجمالية',
        'المسلّم',
        if (dieselInvoices) 'استهلاك الديزل (لتر)',
        'ملاحظات',
      ],
      rows: tableRows,
      footerTotalRow: [
        '',
        'الإجمالي',
        if (settings['system_type'] == 'equivalent_hybrid') '',
        '',
        '',
        duration(data.fold<int>(0, (sum, row) => sum + invoiceNetMinutes(row))),
        if (showInvoiceCloud) duration(data.fold<int>(0, (sum, row) =>
            sum + ((row['system_type'] == 'diesel' || (row['system_type'] == 'equivalent_hybrid' && row['hybrid_source'] == 'diesel')) ? 0 : n(row['cloud_minutes'])))),
        money(totalAmount),
        money(totalPaid),
        if (dieselInvoices) DieselQuantity.format(totalFuel),
        'المتبقي: ${money(remaining)}',
      ],
      thirdSignatureLabel: 'اعتماد وختم المحطة: ....................',
      fileName: hybridSourceFilter == 'solar' ? 'تقرير-فواتير-شمسي.pdf' : hybridSourceFilter == 'diesel' ? 'تقرير-فواتير-ديزل.pdf' : 'تقرير-الفواتير.pdf',
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
    String? hybridSourceFilter,
  }) async {
    final bytes = await invoicesPdf(rows: rows, from: from, to: to, hybridSourceFilter: hybridSourceFilter);
    await ReportPdfPreviewService.open(
      bytes: bytes,
      suggestedName: 'تقرير الفواتير',
    );
  }

  Future<void> shareInvoicesPdf({
    List<Map<String, Object?>>? rows,
    DateTime? from,
    DateTime? to,
    String? hybridSourceFilter,
  }) async {
    final bytes = await invoicesPdf(rows: rows, from: from, to: to, hybridSourceFilter: hybridSourceFilter);
    await ReportPdfPreviewService.open(
      bytes: bytes,
      suggestedName: 'تقرير الفواتير',
    );
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
        final balanceText = PartyStatementBalanceDisplay.format(
          row,
          money: _workerMoney,
        );
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
        final balanceText = PartyStatementBalanceDisplay.format(
          incomeSummary,
          money: _workerMoney,
        );
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
        fileName: _pdfFileName('كشف حساب وتسوية مستحقات عامل ${worker['name'] ?? 'غير محدد'}'),
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
      fileName: _pdfFileName('كشف حساب المستفيد $name'),
      minTableRows: 7,

        preferredRowsPerPage: int.tryParse(settings['pdf_rows'] ?? '30') ?? 30,
      );
  }

  /// Removes characters rejected by Android's save/print filename field while
  /// preserving Arabic names and readable report titles.
  String _pdfFileName(String value) =>
      ReportFileNameService.normalizeBaseName(value);

  Future<String> _reportFileName(
    String key, {
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
  }) async {
    String? personName;
    if (beneficiaryId != null) {
      final rows = await repo.db.rawQuery('SELECT name FROM beneficiaries WHERE id=? LIMIT 1', [beneficiaryId]);
      if (rows.isNotEmpty) personName = '${rows.first['name'] ?? ''}'.trim();
    } else if (workerId != null) {
      final rows = await repo.db.rawQuery('SELECT name FROM workers WHERE id=? LIMIT 1', [workerId]);
      if (rows.isNotEmpty) personName = '${rows.first['name'] ?? ''}'.trim();
    } else if (partnerId != null) {
      final rows = await repo.db.rawQuery('SELECT name FROM partners WHERE id=? LIMIT 1', [partnerId]);
      if (rows.isNotEmpty) personName = '${rows.first['name'] ?? ''}'.trim();
    }
    final title = titles[key] ?? key;
    return _pdfFileName(personName == null || personName.isEmpty ? title : '$title $personName');
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
    String? hybridSource,
    String? reportTitleOverride,
    String? fileNameOverride,
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
    // The existing PDF generator keeps the report's data, totals, layout
    // and filters unchanged. Only the presentation/export UI is unified.
    final suggestedName = fileNameOverride == null
        ? await _reportFileName(
            key,
            beneficiaryId: beneficiaryId,
            workerId: workerId,
            partnerId: partnerId,
          )
        : _pdfFileName(fileNameOverride);
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
      hybridSource: hybridSource,
      reportTitleOverride: reportTitleOverride,
    );
    if (bytes.isEmpty) {
      throw StateError('تعذر إنشاء ملف PDF: المستند الناتج فارغ');
    }
    await ReportPdfPreviewService.open(
      bytes: bytes,
      suggestedName: suggestedName,
    );
  }
}
