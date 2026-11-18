import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/report_pdf_preview_service.dart';

void main() {
  testWidgets('short tap keeps the ordinary PDF preview action', (tester) async {
    var previews = 0;
    var shares = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReportPdfLongPress(
          onLongPress: () async { shares++; },
          child: FilledButton(
            onPressed: () => previews++,
            child: const Text('PDF'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('PDF'));
    await tester.pumpAndSettle();
    expect(previews, 1);
    expect(shares, 0);
  });

  testWidgets('holding PDF button sends share action only', (tester) async {
    var previews = 0;
    var shares = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReportPdfLongPress(
          onLongPress: () async { shares++; },
          child: FilledButton(
            onPressed: () => previews++,
            child: const Text('PDF'),
          ),
        ),
      ),
    ));
    await tester.longPress(find.text('PDF'));
    await tester.pumpAndSettle();
    expect(previews, 0);
    expect(shares, 1);
  });

  testWidgets('long press on an icon button works without tooltip conflict', (tester) async {
    var previews = 0;
    var shares = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReportPdfLongPress(
          onLongPress: () async { shares++; },
          child: IconButton(
            onPressed: () => previews++,
            icon: const Icon(Icons.picture_as_pdf_rounded),
          ),
        ),
      ),
    ));
    await tester.longPress(find.byIcon(Icons.picture_as_pdf_rounded));
    expect(previews, 0);
    expect(shares, 1);
  });

  testWidgets('disabled PDF button does not share', (tester) async {
    var shares = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReportPdfLongPress(
          enabled: false,
          onLongPress: () async { shares++; },
          child: const FilledButton(onPressed: null, child: Text('PDF')),
        ),
      ),
    ));
    await tester.longPress(find.text('PDF'));
    expect(shares, 0);
  });

  test('long press export mode is scoped to the reporting operation', () async {
    expect(ReportPdfPreviewService.sharingFromLongPress, isFalse);
    var during = false;
    await ReportPdfPreviewService.shareOnLongPress(() async {
      await Future<void>.delayed(Duration.zero);
      during = ReportPdfPreviewService.sharingFromLongPress;
    });
    expect(during, isTrue);
    expect(ReportPdfPreviewService.sharingFromLongPress, isFalse);
  });
}
