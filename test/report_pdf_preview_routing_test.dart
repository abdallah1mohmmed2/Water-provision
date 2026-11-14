import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/report_service.dart';
import 'package:saqia_station/services/report_file_name_service.dart';

void main() {
  test('first PDF preview batch has exactly nine distinct registered keys', () {
    const batch = <String>{
      'irrigations',
      'time_comparison',
      'monthly_financial',
      'income',
      'revenue_comparison',
      'system_comparison',
      'activity_overview',
      'expenses',
      'cash_flow',
    };
    expect(batch.length, 9);
    expect(ReportService.previewReportKeys.containsAll(batch), isTrue);
    expect(ReportService.titles.keys.toSet().containsAll(batch), isTrue);
  });

  test('every common-preview key has a real report title and columns', () {
    for (final key in ReportService.previewReportKeys) {
      expect(ReportService.titles.containsKey(key), isTrue, reason: key);
      expect(ReportService.reportColumns.containsKey(key), isTrue, reason: key);
    }
  });

  test('user filename remains separate from the report title', () {
    const reportTitle = 'المديونيات — المستفيدون والعمال والشركاء';
    final changedName = ReportFileNameService.withExtension('تقرير مخصص');
    expect(changedName, 'تقرير مخصص.pdf');
    expect(reportTitle, isNot(changedName));
  });
}
