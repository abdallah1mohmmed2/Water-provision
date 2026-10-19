from pathlib import Path

p = Path(__file__).resolve().parents[1] / "lib" / "features" / "app.dart"
s = p.read_text(encoding="utf-8")
checks = {
    "shared details page": "class RecordDetailsPage extends StatefulWidget" in s,
    "detail hero": "kindIcon()" in s and "kindCaption()" in s,
    "responsive detail grid": "final columns = box.maxWidth >= 1050 ? 4" in s,
    "financial KPI cards": "الرصيد الحالي" in s and "المدين" in s and "الدائن" in s,
    "timeline history": "class _TimelineItem extends StatelessWidget" in s,
    "beneficiary uses full detail page": "kind: 'beneficiary'" in s,
    "no legacy beneficiary detail dialog": "السقايات والمدفوعات والديزل" not in s,
    "no duplicate spacing argument": s.count("spacing: 10,\n            spacing: 10,") == 0,
    "RTL details": "textDirection: TextDirection.rtl" in s,
    "dark/light theme surface": "Theme.of(c).scaffoldBackgroundColor" in s,
}
failed = [k for k,v in checks.items() if not v]
for k,v in checks.items(): print(("PASS" if v else "FAIL") + " - " + k)
if failed:
    raise SystemExit("DETAIL UI AUDIT FAILED: " + ", ".join(failed))
print("DETAIL UI AUDIT: %d/%d passed" % (len(checks), len(checks)))
