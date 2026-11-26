# Automatic date presets for irrigation and report filters
Date: 2026-11-14
Branch: `feature/firebase-station-foundation`; `main` not modified.

## Required behavior
When a screen is opened with **no user-supplied date range**:

1. If non-cancelled irrigation exists **today**, default to today.
2. Otherwise, if irrigation exists **in the current calendar week**, default
   to the configured week start through today (`settings.week_start`,
   Saturday by default).
3. Otherwise, default to **the first day of the current month through today**,
   including when the month also has no irrigations.

The application uses `AppClock.now()` for the effective date, matching the
selected device/server time source. The check is `SELECT 1 ... LIMIT 1`
against the read-only local irrigation table, with the same date fallback
(`date` or `start_datetime`) and cancelled-record exclusion as the existing
irrigation listing. It respects the current irrigation system and selected
party when relevant. No amounts, records, history or PDFs are edited.

## Scope
- Irrigation list: automatic calendar today / current station week / calendar
  month. The list's period menu now distinguishes **هذا الأسبوع** and
  **هذا الشهر** from the existing rolling **آخر أسبوع** and **آخر شهر**.
- Report center: initial `from/to`, propagated to its report cards and
  report detail screens.
- Eight report screens in the first integration group: comparisons, monthly
  financial, cashboxes/transfers, revenue/collections, diesel movement,
  expenses, invoices and detailed irrigation.
- Five report screens in the second integration group: central ledger,
  ledger statements, worker overview, individual worker statement and
  partner statement.
- Beneficiary, worker and partner record details: default period applies
  to their irrigation table and report exports; selected party IDs are used.
- Every direct screen opening with no explicit dates gets the same automatic
  default. When a parent supplies a date range, the child preserves it.
- Date pickers, quick-period buttons, custom range selections and the
  explicit 'all periods' selection remain under user control.
  `autoSelectPeriod` prevents navigation to a child report from reapplying
  automatic dates after the user explicitly cleared the report-center dates.
  A worker's nested detail view inherits this behavior.

## Financial safeguards
- **Monthly debt report** remains month-scoped because its financial periods
  and accounting totals are monthly; the month picker still works as before.
- **Partner profit-distribution posting** retains its current month default:
  changing the default to a day/week could unintentionally change the
  accounting period used for a financial posting. Users may explicitly select
  a different period as before, with the existing confirmation.
- All code changes affect **initial UI date filters only**. No financial
  transaction is posted, no table updated, and no database migration occurs.
- If an optional date-presence probe fails, the existing screen load is
  retained rather than deleting/filtering data silently.

## Tests
`test/automatic_irrigation_period_test.dart` covers:
- Today has activity
- Today empty and current configured week has activity
- Week empty and month has activity
- Month empty
- Week boundary crossing December/January

Run `flutter analyze`, `flutter test` and APK build in CI. Review a
physical Android device by opening the reports with no dates and by manually
choosing or clearing date ranges. The existing share/print and PDF-generation
functions are unchanged.
