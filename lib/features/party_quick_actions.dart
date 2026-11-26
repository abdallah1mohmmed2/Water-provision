import 'package:flutter/material.dart';

import '../data/repositories/repositories.dart';
import '../services/report_service.dart';
import '../services/report_pdf_preview_service.dart';

typedef PartyReportCallback = Future<void> Function(String report);

/// The three PDF choices share preview and long-press-to-share behavior.
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
    Future<void> open(String report, {bool share = false}) async {
      Navigator.pop(sheetContext);
      try {
        if (share) {
          await ReportPdfPreviewService.shareOnLongPress(() => generate(report));
        } else {
          await generate(report);
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر تجهيز التقرير، حاول مرة أخرى')),
          );
        }
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Text(name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final report in hybridSystem
                ? ['solar_irrigations', 'diesel_irrigations', 'statement', if (dieselEnabled) 'diesel', 'deliveries']
                : ['irrigations', 'statement', if (dieselEnabled) 'diesel', 'deliveries'])
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
                      'deliveries' => Icons.swap_horiz_rounded,
                      _ => Icons.receipt_long_outlined,
                    }),
                    label: Text(switch (report) {
                      'irrigations' => 'سقايات هذا الشخص',
                      'solar_irrigations' => 'السقايات الشمسية لهذا الشخص',
                      'diesel_irrigations' => 'سقايات الديزل لهذا الشخص',
                      'diesel' => 'المسلّم والمستهلك والمتبقي من الديزل',
                      'deliveries' => 'تقرير المسلّمات والمستلمات لهذا الشخص',
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

  Future<void> _report(String report) {
    if (report == 'solar_irrigations' || report == 'diesel_irrigations') {
      return ReportService(repository).printHybridPartyIrrigationsPdf(
        partyType: partyType,
        partyId: partyId,
        source: report == 'solar_irrigations' ? 'solar' : 'diesel',
      );
    }
    if (report == 'deliveries') {
      return ReportService(repository).printPartyDeliveryReceiptPdf(
        partyType: partyType, partyId: partyId);
    }
    if (report == 'diesel') {
      return ReportService(repository).printPartyDieselPdf(
        partyType: partyType, partyId: partyId);
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
