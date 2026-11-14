# Report-specific and editable PDF file names (2026-11-14)

Repository: `abdallah1mohmmed2/Water-provision`, branch:
`feature/firebase-station-foundation`. No changes to `main`.

## Prior behavior
The generic ReportService path supplied a report-specific filename; other
paths used fixed names, sometimes generic `official_report.pdf`, and the
invoices PDF preview exposed the printing package's own export controls.
There was no single in-app option to edit the suggested filename.

## Change
- A shared `ReportFileNameService` presents the actual report or party name
  before print or share. Users can edit it or cancel. The export filename is
  normalized (unsafe characters removed, Arabic preserved, one .pdf extension).
- The app's root navigator allows the same picker to be used by all existing
  report entry points without duplicating the interface.
- The official report template uses its `reportTitle` as fallback instead
  of `official_report.pdf`. It prompts only when `printAfterGenerate` is
  true; PDF generation-only calls remain noninteractive.
- Applied to generic report print and its share fallback, worker and
  beneficiary official statements, partner reports and distributions,
  receipt printing, invoice print/share, and filtered irrigation sharing.
- Invoice PDF preview uses explicit toolbar print/share controls through the
  shared prompt instead of embedded package export actions.
- Filename editing does not alter the visible title inside the PDF, report
  rows, amounts, themes, accounting, or persisted settings. Cancel does not
  initiate print or share.
- Tests added at `test/report_file_name_service_test.dart`.

## Validation
Flutter and Android SDKs are unavailable in the connector session. Validate
with `flutter test`, `flutter analyze`, Android native Save as PDF and share.
