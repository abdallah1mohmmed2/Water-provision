import 'package:flutter/material.dart';

import '../data/repositories/repositories.dart';
import '../services/report_service.dart';
import '../services/report_pdf_preview_service.dart';

typedef PartyReportCallback = Future<void> Function(String report, DateTime? from, DateTime? to);

/// PDF report picker with a shared optional date range for every report.
Future<void> showPartyPdfChoices(
  BuildContext context, {
  required String name,
  required PartyReportCallback generate,
  required bool dieselEnabled,
  required bool hybridSystem,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (sheetContext) {
    DateTime? from;
    DateTime? to;
    Future<DateTime?> pickDate(DateTime? current) => showDatePicker(
      context: sheetContext,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: current ?? DateTime.now(),
      locale: const Locale('ar'),
    );
    String dateLabel(DateTime? value, String empty) =>
        value == null ? empty : '${value.day}/${value.month}/${value.year}';

    Future<void> open(String report, {bool share = false}) async {
      if (from != null && to != null &&
          DateTime(from!.year, from!.month, from!.day)
              .isAfter(DateTime(to!.year, to!.month, to!.day))) {
        ScaffoldMessenger.of(sheetContext).showSnackBar(
          const SnackBar(content: Text('تاريخ البداية يجب ألا يتجاوز تاريخ النهاية')),
        );
        return;
      }
      final selectedFrom = from;
      final selectedTo = to;
      Navigator.pop(sheetContext);
      try {
        if (share) {
          await ReportPdfPreviewService.shareOnLongPress(
            () => generate(report, selectedFrom, selectedTo));
        } else {
          await generate(report, selectedFrom, selectedTo);
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر تجهيز التقرير، حاول مرة أخرى')),
          );
        }
      }
    }

    return StatefulBuilder(
      builder: (sheetContext, updateSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text('فترة التقارير (اختياري)', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.date_range),
                      label: Text(dateLabel(from, 'من تاريخ')),
                      onPressed: () async {
                        final value = await pickDate(from);
                        if (value != null) updateSheet(() => from = value);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.event),
                      label: Text(dateLabel(to, 'إلى تاريخ')),
                      onPressed: () async {
                        final value = await pickDate(to);
                        if (value != null) updateSheet(() => to = value);
                      },
                    ),
                    if (from != null || to != null)
                      TextButton.icon(
                        icon: const Icon(Icons.filter_alt_off),
                        label: const Text('مسح الفترة'),
                        onPressed: () => updateSheet(() { from = null; to = null; }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final report in hybridSystem
                    ? ['solar_irrigations', 'diesel_irrigations', 'statement', if (dieselEnabled) 'diesel', 'cash_movements']
                    : ['irrigations', 'statement', if (dieselEnabled) 'diesel', 'cash_movements'])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ReportPdfLongPress(
                      enabled: true,
                      onLongPress: () => open(report, share: true),
                      child: OutlinedButton.icon(
                        onPressed: () => open(report),
                        icon: Icon(switch (report) {
                          'irrigations' || 'solar_irrigations' || 'diesel_irrigations' => Icons.water_drop_outlined,
                          'diesel' => Icons.local_gas_station_outlined,
                          'cash_movements' => Icons.payments_outlined,
                          _ => Icons.receipt_long_outlined,
                        }),
                        label: Text(switch (report) {
                          'irrigations' => 'سقايات هذا الشخص',
                          'solar_irrigations' => 'السقايات الشمسية لهذا الشخص',
                          'diesel_irrigations' => 'سقايات الديزل لهذا الشخص',
                          'diesel' => 'المسلّم والمستهلك والمتبقي من الديزل',
                          'cash_movements' => 'تقرير الحركات النقدية لهذا الشخص',
                          _ => 'كشف حساب هذا الشخص',
                        }),
                      ),
                    ),
                  ),
                const Text('اضغط للعرض، أو اضغط مطولًا للمشاركة',
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  },
);

class PartyQuickActions extends StatelessWidget {
  const PartyQuickActions({
    required this.repository,
    required this.partyType,
    required this.partyId,
    required this.name,
    required this.onNewIrrigation,
    this.onDieselDelivery,
    this.dieselEnabled = false,
    this.hybridSystem = false,
    super.key,
  }) : assert(partyType == 'beneficiary' ||
             partyType == 'worker' || partyType == 'partner');

  final StationRepository repository;
  final String partyType;
  final int partyId;
  final String name;
  final VoidCallback onNewIrrigation;
  final VoidCallback? onDieselDelivery;
  final bool dieselEnabled;
  final bool hybridSystem;

  Future<void> _report(String report, DateTime? from, DateTime? to) {
    if (report == 'solar_irrigations' || report == 'diesel_irrigations') {
      return ReportService(repository).printHybridPartyIrrigationsPdf(
        partyType: partyType,
        partyId: partyId,
        source: report == 'solar_irrigations' ? 'solar' : 'diesel',
        from: from, to: to,
      );
    }
    if (report == 'cash_movements') {
      return ReportService(repository).printPartyCashMovementsPdf(
        partyType: partyType, partyId: partyId, from: from, to: to);
    }
    if (report == 'diesel') {
      return ReportService(repository).printPartyDieselPdf(
        partyType: partyType, partyId: partyId, from: from, to: to);
    }
    return ReportService(repository).printPdf(
      report == 'irrigations' ? 'irrigations' : switch (partyType) {
        'worker' => 'worker_transactions',
        'partner' => 'partner_accounts',
        _ => 'beneficiary_statement',
      },
      beneficiaryId: partyType == 'beneficiary' ? partyId : null,
      workerId: partyType == 'worker' ? partyId : null,
      partnerId: partyType == 'partner' ? partyId : null,
      from: from, to: to,
      systemType: 'all',
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: onNewIrrigation,
          icon: const Icon(Icons.water_drop_rounded),
          label: const Text('سقاية جديدة'),
        ),
        if (dieselEnabled && onDieselDelivery != null)
          OutlinedButton.icon(
            key: ValueKey('party-diesel-delivery-$partyType-$partyId'),
            onPressed: onDieselDelivery,
            icon: const Icon(Icons.local_gas_station_outlined),
            label: const Text('إضافة تسليم ديزل'),
          ),
        OutlinedButton.icon(
          onPressed: () => showPartyPdfChoices(
            context,
            name: name,
            generate: _report,
            dieselEnabled: dieselEnabled,
            hybridSystem: hybridSystem,
          ),
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: const Text('PDF'),
        ),
      ],
    ),
  );
}
