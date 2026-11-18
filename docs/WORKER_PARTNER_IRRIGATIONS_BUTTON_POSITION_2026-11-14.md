# Worker/partner record details — irrigation PDF action placement

Date: 2026-11-14

## Issue
In `RecordDetailsPage`, the "PDF التسقيات المرتبطة بالعامل" and
"PDF التسقيات المرتبطة بالشريك" buttons were placed inside the
"sجل زمني" timeline section after other account details.

## Change
- Extracted the existing two PDF actions into one
  `_irrigationPdfShortcut()` with the same labels, PDF export action,
  selected party ID, `filterFrom` / `filterTo` date filters,
  `systemType: 'all'` and existing error handling.
- The shortcut appears as the **first content widget** in the record
  detail `ListView` for `worker` or `partner`, ahead of
  `financialPanel(c)` and `irrigationTable(c)`.
- Removed the old duplicated buttons from the timeline.
- Beneficiary and all other record details are unchanged.
- No changes to database, transaction or report calculations, theme,
  card design, permissions, or existing reporting data.

## Validation
Review the worker and partner detail screens at mobile width:
the irrigation PDF button should be visible at the top without scrolling,
and the same action should export using the current date filters.
Verify beneficiary detail does not show this worker/partner shortcut.

Flutter SDK is not present in the connector environment; CI and
on-device UI verification remain necessary.
