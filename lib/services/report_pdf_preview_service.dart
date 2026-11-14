import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'report_file_name_service.dart';

/// A single PDF reader for all report families. It never mutates the source
/// PDF bytes, accounting data or the report's printed title.
class ReportPdfPreviewService {
  ReportPdfPreviewService._();

  static Future<void> open({
    required Uint8List bytes,
    required String suggestedName,
  }) async {
    if (bytes.isEmpty) {
      throw StateError('تعذر عرض التقرير: ملف PDF فارغ');
    }
    final navigator = ReportFileNameService.navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      throw StateError('لا يمكن فتح معاينة PDF قبل تهيئة شاشة التطبيق');
    }

    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _UnifiedReportPdfPreviewPage(
          bytes: bytes,
          suggestedName: ReportFileNameService.normalizeBaseName(suggestedName),
        ),
      ),
    );
  }
}

class _UnifiedReportPdfPreviewPage extends StatefulWidget {
  const _UnifiedReportPdfPreviewPage({
    required this.bytes,
    required this.suggestedName,
  });

  final Uint8List bytes;
  final String suggestedName;

  @override
  State<_UnifiedReportPdfPreviewPage> createState() =>
      _UnifiedReportPdfPreviewPageState();
}

class _UnifiedReportPdfPreviewPageState
    extends State<_UnifiedReportPdfPreviewPage> {
  bool _exporting = false;

  Future<void> _export({required bool share}) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final selectedName =
          await ReportFileNameService.choose(widget.suggestedName);
      if (selectedName == null) return;

      if (share) {
        await Printing.sharePdf(
          bytes: widget.bytes,
          filename: ReportFileNameService.withExtension(selectedName),
        );
      } else {
        try {
          await Printing.layoutPdf(
            name: selectedName,
            onLayout: (_) async => widget.bytes,
          );
        } catch (printError) {
          // Preserve the existing recovery route: even if the device's native
          // print dialog fails, the exact same PDF can still be shared/saved.
          try {
            await Printing.sharePdf(
              bytes: widget.bytes,
              filename: ReportFileNameService.withExtension(selectedName),
            );
          } catch (shareError) {
            throw StateError(
              'تم إنشاء PDF لكن تعذرت الطباعة والمشاركة. '
              'الطباعة: $printError؛ المشاركة: $shareError',
            );
          }
        }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تصدير التقرير: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          'معاينة PDF - ${widget.suggestedName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'طباعة أو حفظ PDF',
            onPressed: _exporting ? null : () => _export(share: false),
            icon: const Icon(Icons.print_rounded),
          ),
          IconButton(
            tooltip: 'مشاركة PDF',
            onPressed: _exporting ? null : () => _export(share: true),
            icon: const Icon(Icons.share_rounded),
          ),
        ],
      ),
      body: PdfPreview(
        build: (_) async => widget.bytes,
        canChangeOrientation: false,
        canChangePageFormat: false,
        useActions: false,
      ),
    ),
  );
}
