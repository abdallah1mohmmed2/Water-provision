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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final report in const ['irrigations', 'statement', 'diesel'])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ReportPdfLongPress(
                  enabled: true,
                  onLongPress: () => open(report, share: true),
                  child: OutlinedButton.icon(
                    onPressed: () => open(report),
                    icon: Icon(switch (report) {
                      'irrigations' => Icons.water_drop_outlined,
                      'diesel' => Icons.local_gas_station_outlined,
                      _ => Icons.receipt_long_outlined,
                    }),
                    label: Text(switch (report) {
                      'irrigations' => 'سقايات هذا الشخص',
                      'diesel' => 'المسلّم والمستهلك والمتبقي من الديزل',
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
    super.key,
  }) : assert(partyType == 'beneficiary' ||
             partyType == 'worker' || partyType == 'partner');

  final StationRepository repository;
  final String partyType;
  final int partyId;
  final String name;
  final VoidCallback onNewIrrigation;

  Future<void> _report(String report) {
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
        OutlinedButton.icon(
          onPressed: () => showPartyPdfChoices(
            context, name: name, generate: _report),
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: const Text('PDF'),
        ),
      ],
    ),
  );
}
