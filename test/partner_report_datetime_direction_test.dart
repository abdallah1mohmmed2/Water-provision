import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/official_report_template.dart';

void main() {
  group('partner private report PDF date/time bidi', () {
    test('keeps complete Gregorian dates and clocks in LTR run', () {
      expect(OfficialReportTemplate.isDateTimeCell('2026/11/07 16:38'), isTrue);
      expect(OfficialReportTemplate.isDateTimeCell('2026/11/07 09:21'), isTrue);
      expect(OfficialReportTemplate.isDateTimeCell('2026/11/01 08:23'), isTrue);
      expect(OfficialReportTemplate.isDateTimeCell('2026-11-07T16:37:00'), isTrue);
      expect(OfficialReportTemplate.isDateTimeCell('2026/11/07'), isTrue);
      expect(OfficialReportTemplate.isDateTimeCell('07/11/2026'), isTrue);
    });

    test('does not change direction for Arabic descriptions and amounts', () {
      expect(OfficialReportTemplate.isDateTimeCell('مديونية الشريك'), isFalse);
      expect(OfficialReportTemplate.isDateTimeCell('الرصيد المرحل قبل الفترة'), isFalse);
      expect(OfficialReportTemplate.isDateTimeCell('2026/11/07 سقاية'), isFalse);
      expect(OfficialReportTemplate.isDateTimeCell('7,000'), isFalse);
      expect(OfficialReportTemplate.isDateTimeCell('-'), isFalse);
    });
  });
}
