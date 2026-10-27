import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// نموذج بيانات البطاقة الإحصائية العلوية.
class StatBoxData {
  final String number;
  final String title;
  final String value;
  final bool isBlueTint;
  final bool isLarge;

  const StatBoxData({
    required this.number,
    required this.title,
    this.value = '',
    this.isBlueTint = false,
    this.isLarge = false,
  });
}

/// قالب التقرير المالي والإحصائي الرسمي، مستقل عن قالب الطباعة الحالي.
///
/// يعتمد على خطوط المشروع المحلية لتجنب تنزيل الخطوط من الإنترنت وقت الطباعة.
class OfficialReportTemplate {
  OfficialReportTemplate._();

  static const PdfColor blueCardBg = PdfColor.fromInt(0xFFD6E6F2);
  static const PdfColor greyCardBg = PdfColor.fromInt(0xFFE5E6E8);
  static const PdfColor blueBorder = PdfColor.fromInt(0xFF6B9AC4);
  static const PdfColor greyBorder = PdfColor.fromInt(0xFF8C8C8C);
  static const PdfColor tableHeaderBg = PdfColor.fromInt(0xFFC5D5E4);
  static const PdfColor innerBoxBg = PdfColor.fromInt(0xFFF5F5F5);

  static Future<pw.Font> _loadFont(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return pw.Font.ttf(data);
  }

  /// معاينة وطباعة التقرير بصيغة PDF.
  static Future<Uint8List> preview({
    String rightHeader1 = 'الجمهورية اليمنية',
    String rightHeader2 = 'وزارة ... / ..............',
    String rightHeader3 = 'المؤسسة العامة ...',
    String date = '.... / .... / 202م',
    String refNumber = '........................',
    String attachments = '........................',
    required String reportTitle,
    required List<StatBoxData> summaryBoxes,
    required List<String> columns,
    required List<List<String>> rows,
    List<String>? footerTotalRow,
    Uint8List? emblemImageBytes,
    String thirdSignatureLabel = 'الاعتماد والختم: ....................',
    String fileName = 'official_report.pdf',
    int minTableRows = 7,
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    int preferredRowsPerPage = 30,
    bool printAfterGenerate = true,
  }) async {
    if (columns.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'يجب توفير عمود واحد على الأقل.');
    }
    if (minTableRows < 0) {
      throw ArgumentError.value(minTableRows, 'minTableRows', 'لا يمكن أن يكون سالبًا.');
    }

    final normalizedRows = rows
        .map((row) => _fitRow(row, columns.length))
        .toList(growable: true);
    while (normalizedRows.length < minTableRows) {
      normalizedRows.add(List<String>.filled(columns.length, ''));
    }
    final normalizedFooter = footerTotalRow == null
        ? null
        : _fitRow(footerTotalRow, columns.length);
    final density = preferredRowsPerPage.clamp(1, 40).toInt();
    final cellFontSize = density >= 26 ? 7.5 : density >= 16 ? 8.2 : 9.0;
    final cellVerticalPadding = density >= 26 ? 2.5 : density >= 16 ? 3.5 : 5.0;

    final arabicFont = await _loadFont(
      'assets/fonts/NotoNaskhArabic-Regular.ttf',
    );
    final arabicBold = await _loadFont(
      'assets/fonts/NotoNaskhArabic-Bold.ttf',
    );
    final document = pw.Document();

    document.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        textDirection: pw.TextDirection.rtl,
        margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text(
            'صفحة ${context.pageNumber} / ${context.pagesCount}',
            style: pw.TextStyle(
              font: arabicFont,
              fontSize: 8,
              color: PdfColors.grey700,
            ),
          ),
        ),
        theme: pw.ThemeData.withFont(
          base: arabicFont,
          bold: arabicBold,
          // Arabic font lacks some Latin punctuation used by references and dates.
          fontFallback: [pw.Font.helvetica()],
        ),
        build: (context) => [
          _buildOfficialHeader(
            right1: rightHeader1,
            right2: rightHeader2,
            right3: rightHeader3,
            date: date,
            refNumber: refNumber,
            attachments: attachments,
            emblemBytes: emblemImageBytes,
            boldFont: arabicBold,
          ),
          pw.SizedBox(height: 14),
          pw.Center(
            child: pw.Text(
              reportTitle,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], 
                font: arabicBold,
                fontSize: 18,
                color: PdfColors.black,
              ),
            ),
          ),
          pw.SizedBox(height: 14),
          if (summaryBoxes.isNotEmpty) ...[
            _buildStatsGrid(summaryBoxes, arabicFont, arabicBold),
            pw.SizedBox(height: 18),
          ],
          _buildOfficialTable(
            columns: columns,
            rows: normalizedRows,
            footerRow: normalizedFooter,
            font: arabicFont,
            boldFont: arabicBold,
            cellFontSize: cellFontSize,
            cellVerticalPadding: cellVerticalPadding,
          ),
          pw.SizedBox(height: 35),
          _buildOfficialSignatures(arabicBold, thirdLabel: thirdSignatureLabel),
        ],
      ),
    );

    final bytes = await document.save();
    if (printAfterGenerate) {
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: fileName,
      );
    }
    return bytes;
  }

  static List<String> _fitRow(List<String> row, int columnCount) {
    return List<String>.generate(
      columnCount,
      (index) => index < row.length ? row[index] : '',
      growable: false,
    );
  }

  static pw.Widget _buildOfficialHeader({
    required String right1,
    required String right2,
    required String right3,
    required String date,
    required String refNumber,
    required String attachments,
    required Uint8List? emblemBytes,
    required pw.Font boldFont,
  }) {
    final headerTextStyle = pw.TextStyle(fontFallback: [pw.Font.helvetica()], font: boldFont, fontSize: 10);

    pw.Widget headerColumn(List<String> lines) => pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final line in lines) ...[
                pw.Text(line, style: headerTextStyle),
                pw.SizedBox(height: 3),
              ],
              pw.SizedBox(height: 3),
              pw.Container(height: 1, color: PdfColors.black),
            ],
          ),
        );

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        headerColumn([right1, right2, right3]),
        pw.SizedBox(width: 8),
        pw.Container(
          width: 68,
          height: 62,
          alignment: pw.Alignment.center,
          child: emblemBytes != null
              ? pw.Image(pw.MemoryImage(emblemBytes), fit: pw.BoxFit.contain)
              : pw.Container(
                  width: 50,
                  height: 50,
                  alignment: pw.Alignment.center,
                  decoration: pw.BoxDecoration(
                    shape: pw.BoxShape.circle,
                    border: pw.Border.all(
                      color: PdfColors.grey600,
                      width: 1.2,
                    ),
                  ),
                  child: pw.Text(
                    'الشعار',
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], 
                      font: boldFont,
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
        ),
        pw.SizedBox(width: 8),
        headerColumn([
          'التاريخ: $date',
          'الرقم: $refNumber',
          'المرفقات: $attachments',
        ]),
      ],
    );
  }

  static pw.Widget _buildStatsGrid(
    List<StatBoxData> boxes,
    pw.Font font,
    pw.Font boldFont,
  ) {
    final widgets = <pw.Widget>[];
    for (var i = 0; i < boxes.length; i += 3) {
      final chunk = boxes.skip(i).take(3).toList();
      widgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              for (var j = 0; j < 3; j++) ...[
                if (j > 0) pw.SizedBox(width: 12),
                pw.Expanded(
                  child: j < chunk.length
                      ? _buildSingleStatCard(chunk[j], font, boldFont)
                      : pw.SizedBox(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return pw.Column(children: widgets);
  }

  static pw.Widget _buildSingleStatCard(
    StatBoxData data,
    pw.Font font,
    pw.Font boldFont,
  ) {
    final bgColor = data.isBlueTint ? blueCardBg : greyCardBg;
    final borderColor = data.isBlueTint ? blueBorder : greyBorder;
    final cardHeight = data.isLarge ? 76.0 : 60.0;

    return pw.Stack(
      children: [
        pw.Container(
          height: cardHeight,
          width: double.infinity,
          margin: const pw.EdgeInsets.only(top: 5),
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: pw.BoxDecoration(
            color: bgColor,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            border: pw.Border.all(
              color: borderColor,
              width: data.isLarge ? 1.5 : 0.9,
            ),
          ),
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(right: 14),
                child: pw.Text(
                  data.title,
                  textAlign: pw.TextAlign.center,
                  maxLines: 2,
                  style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], 
                    font: boldFont,
                    fontSize: data.isLarge ? 9 : 9.5,
                    height: 1.15,
                  ),
                ),
              ),
              pw.Container(
                width: 82,
                height: 22,
                alignment: pw.Alignment.center,
                decoration: pw.BoxDecoration(
                  color: innerBoxBg,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                  border: pw.Border.all(color: PdfColors.grey700, width: 0.8),
                ),
                child: pw.FittedBox(
                  fit: pw.BoxFit.scaleDown,
                  child: pw.Text(
                    data.value,
                    style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], font: boldFont, fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
        pw.Positioned(
          top: 0,
          right: data.isLarge ? 50 : 6,
          child: pw.Container(
            width: 17,
            height: 17,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: bgColor,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
              border: pw.Border.all(color: PdfColors.grey800, width: 0.9),
            ),
            child: pw.Text(
              data.number,
              style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], font: boldFont, fontSize: 9),
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildOfficialTable({
    required List<String> columns,
    required List<List<String>> rows,
    List<String>? footerRow,
    required pw.Font font,
    required pw.Font boldFont,
    required double cellFontSize,
    required double cellVerticalPadding,
  }) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.black, width: 0.8),
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: tableHeaderBg),
          // PDF Table lays out its children from left to right even when
          // the surrounding document text direction is RTL. Reverse the
          // display order here so the first logical column appears at the
          // right edge of the printed table.
          children: columns
              .reversed
              .map(
                (col) => pw.Container(
                  constraints: const pw.BoxConstraints(minHeight: 32),
                  padding: pw.EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: cellVerticalPadding,
                  ),
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    col,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], 
                      font: boldFont,
                      fontSize: cellFontSize,
                      height: 1.15,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        ...rows.map(
          (row) => pw.TableRow(
            // Keep each cell attached to its original heading while rendering
            // the table visually from right to left.
            children: row
                .reversed
                .map(
                  (cell) => pw.Container(
                    constraints: const pw.BoxConstraints(minHeight: 24),
                    padding: pw.EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: cellVerticalPadding,
                    ),
                    alignment: pw.Alignment.center,
                    child: pw.Text(
                      cell,
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], font: font, fontSize: cellFontSize),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: tableHeaderBg),
          children: List.generate(
            columns.length,
            (index) => pw.Container(
              constraints: const pw.BoxConstraints(minHeight: 24),
              padding: pw.EdgeInsets.symmetric(
                horizontal: 3,
                vertical: cellVerticalPadding,
              ),
              alignment: pw.Alignment.center,
              child: pw.Text(
                footerRow != null && index < footerRow.length
                    ? footerRow[footerRow.length - 1 - index]
                    : '',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontFallback: [pw.Font.helvetica()], font: boldFont, fontSize: cellFontSize),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildOfficialSignatures(
    pw.Font boldFont, {
    required String thirdLabel,
  }) {
    final style = pw.TextStyle(fontFallback: [pw.Font.helvetica()], font: boldFont, fontSize: 10.5);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Text('إعداد: ....................', style: style),
        ),
        pw.Expanded(
          child: pw.Text('المراجعة: ....................', style: style),
        ),
        pw.Expanded(
          child: pw.Text(thirdLabel, style: style),
        ),
      ],
    );
  }
}
