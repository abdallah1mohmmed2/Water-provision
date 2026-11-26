import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/report_file_name_service.dart';

void main() {
  group('PDF report names', () {
    test('Arabic title and person name are preserved', () {
      expect(ReportFileNameService.normalizeBaseName('كشف حساب العامل محمد'),
          'كشف حساب العامل محمد');
    });
    test('only one .pdf suffix is retained', () {
      expect(ReportFileNameService.withExtension('الفواتير.PDF.pdf'),
          'الفواتير.pdf');
    });
    test('unsafe file characters are replaced', () {
      expect(ReportFileNameService.normalizeBaseName('كشف: شريك/ محمد?'),
          'كشف- شريك- محمد-');
    });
    test('empty and dotted filenames use a safe fallback', () {
      expect(ReportFileNameService.withExtension(''), 'تقرير.pdf');
      expect(ReportFileNameService.withExtension('...'), 'تقرير.pdf');
    });
    test('very long names are shortened', () {
      expect(
        ReportFileNameService.normalizeBaseName(List.filled(150, 'x').join()).length,
        120,
      );
    });
  });

  testWidgets('report filename can be edited before export', (tester) async {
    String? selected;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: ReportFileNameService.navigatorKey,
      home: Scaffold(body: ElevatedButton(
        child: const Text('فتح'),
        onPressed: () async {
          selected = await ReportFileNameService.choose('مديونيات المستفيدين.pdf');
        },
      )),
    ));
    await tester.tap(find.text('فتح'));
    await tester.pumpAndSettle();
    expect(find.text('اسم ملف PDF'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'مديونيات المستفيدين');
    await tester.enterText(find.byType(TextField), 'مديونيات نوفمبر 2026.pdf');
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    expect(selected, 'مديونيات نوفمبر 2026');
  });

  testWidgets('cancelling filename dialog aborts export', (tester) async {
    String? selected = 'default';
    await tester.pumpWidget(MaterialApp(
      navigatorKey: ReportFileNameService.navigatorKey,
      home: Scaffold(body: ElevatedButton(
        child: const Text('فتح'),
        onPressed: () async {
          selected = await ReportFileNameService.choose('تقرير الفواتير');
        },
      )),
    ));
    await tester.tap(find.text('فتح'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });
}
