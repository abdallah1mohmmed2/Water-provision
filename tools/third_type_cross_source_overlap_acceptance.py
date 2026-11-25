#!/usr/bin/env python3
"""Static acceptance checks for optional cross-source overlap in third system type."""
from pathlib import Path

app = Path("lib/features/app.dart").read_text(encoding="utf-8")
accounting = Path("lib/domain/accounting/accounting_service.dart").read_text(encoding="utf-8")
checks = {
    "setting is visible only in third-type settings section": "if ((s['system_type'] ?? 'diesel') == 'equivalent_hybrid') ...[\n                setTile('hybrid_diesel_hourly_rate', 'سعر ساعة تشغيل الديزل في النوع الثالث', true),\n                boolTile('third_type_cross_source_overlap_enabled'" in app,
    "screen hints shown for enabled setting": app.count("settings['third_type_cross_source_overlap_enabled'] == 'true'") >= 2,
    "feature only enables for equivalent hybrid": "effectiveType == 'equivalent_hybrid' &&\n          set['third_type_cross_source_overlap_enabled'] == 'true'" in accounting,
    "same-source overlap SQL filter": "system_type='equivalent_hybrid' AND hybrid_source=? AND start_datetime<? AND end_datetime>?" in accounting,
    "disabled path retains original overlap check": "SELECT id FROM irrigations WHERE pump_id=? AND status!='cancelled' AND start_datetime<? AND end_datetime>? LIMIT 1" in accounting,
    "same-source rejection message": "يوجد تعارض زمني مع سقاية من المصدر نفسه" in accounting,
}
for name, passed in checks.items():
    print(("PASS" if passed else "FAIL") + " - " + name)
if not all(checks.values()):
    raise SystemExit(1)
