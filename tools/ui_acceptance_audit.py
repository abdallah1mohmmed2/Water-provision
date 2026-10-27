#!/usr/bin/env python3
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
app=(ROOT/'lib/features/app.dart').read_text(encoding='utf8')
theme=(ROOT/'lib/core/theme.dart').read_text(encoding='utf8')
report=(ROOT/'lib/services/report_service.dart').read_text(encoding='utf8')
template=(ROOT/'lib/services/official_report_template.dart').read_text(encoding='utf8')
errors=[]
checks={
 'RTL root': 'TextDirection.rtl' in app,
 'Arabic locale': "locale: const Locale('ar')" in app,
 'Arabic localization delegates': 'GlobalMaterialLocalizations.delegates' in app,
 'Arabic embedded font': 'NotoNaskhArabic-Regular.ttf' in template and 'NotoNaskhArabic-Bold.ttf' in template,
 'central Arabic font': "fontFamily: 'NotoNaskhArabic'" in theme,
 'electric blue': '287bff' in theme,
 'purple': '7c4dff' in theme,
 'cyan': '00d7ff' in theme,
 'phosphor green': '18e58c' in theme,
 'concave/rounded cards': 'BorderRadius.circular(22)' in theme and 'CardThemeData' in theme,
 'reduced motion setting': "'reduced_motion'" in app,
 'dashboard current session': 'جلسة السقي الحالية' in app,
 'dashboard due paid balance direction': all(x in app for x in ['المستحق','المدفوع','حالة الرصيد']),
 'dashboard quick access': len(re.findall(r'QuickButton\(',app)) >= 6,
 'menu quick search': 'بحث سريع في القائمة' in app,
 'menu counters': all(x in app for x in ['الطابور','التنبيهات','حالة الرصيد']),
 'new irrigation search': 'بحث سريع بالاسم أو الهاتف أو رقم الجربة أو الموقع' in app,
 'new irrigation first irrigation': 'أول سقاية' in app,
 'new irrigation diesel balance': 'رصيد ديزل المستفيد' in app,
 'new irrigation cloud discount': 'إضافة فترة غيم' in app and 'بداية الغيم' in app and 'نهاية الغيم' in app and 'cloudPeriods' in app,
 'new irrigation waiting override': 'تجاوز مدة الانتظار' in app,
 'new irrigation success/new operation': 'عملية جديدة' in app and 'تم حفظ السقاية والقيد المحاسبي بنجاح' in app,
 'diesel snooze': 'تأجيل التنبيه 10 دقائق' in app,
 'performance screen': 'class PerformancePage' in app,
 '24 required reports': len(re.findall(r"'[^']+':", report.split('titles = {',1)[1].split('};',1)[0])) >= 24,
 'PDF row density setting preserved': "pdf_rows" in report and 'preferredRowsPerPage' in report and 'preferredRowsPerPage = 30' in template,
 'official template handles empty reports': (
     'OfficialReportTemplate.preview(' in report
     and 'لا توجد بيانات مطابقة' in report
     and 'rows.isEmpty' in report
     and 'columns.isEmpty' in template
 ),
 'all report PDF paths use the official template': (
     'OfficialReportTemplate.preview(' in report
     and 'printAfterGenerate: false' in report
     and 'Future<Uint8List> paymentReceiptPdf' in report
     and 'Future<Uint8List> invoicesPdf' in report
 ),
 'official template controls PDF layout and optional printing': (
     'pw.MultiPage(' in template
     and 'pageFormat: pageFormat' in template
     and 'if (printAfterGenerate)' in template
 ),
 'PDF print path': 'Printing.layoutPdf' in report,
}
for k,v in checks.items():
    if not v: errors.append(k)
# Ensure all admin page labels are Arabic-only literals in the declared pages list.
m=re.search(r'final\s+pages\s*=\s*const\s*\[(.*?)\];',app,re.S)
if not m: errors.append('admin pages list missing')
else:
    vals=re.findall(r"'([^']*)'",m.group(1))
    if len(vals)<19: errors.append(f'admin screens expected >=19, found {len(vals)}')
    latin=[x for x in vals if re.search(r'[A-Za-z]',x)]
    if latin: errors.append('latin text in admin page labels: '+','.join(latin))
if errors:
    print('UI ACCEPTANCE AUDIT FAILED')
    for e in errors: print('-',e)
    raise SystemExit(1)
print('UI ACCEPTANCE AUDIT PASSED')
print('Admin screens: >=19')
print('Quick actions: >=6')
print('Arabic RTL/theme/PDF checks: PASS')
print('New irrigation requirement checks: PASS')
