# Net outstanding-balance card for debt reports — 2026-11-14

- Repository: `abdallah1mohmmed2/Water-provision`
- Target branch: `feature/firebase-station-foundation` (`main` unchanged).
- Problem: the debts screen and PDF display the separate "إجمالي عليه" and
  "إجمالي له" gross totals but do not make their net difference explicit.
- Accounting sign convention for the *unified debt report*:
  positive balances mean "عليه" (party owes station); negative balances mean
  "له" (station owes party), including workers and partners whose personal
  balances are normalized by the existing repository layer.
- Added `DebtReportTotals`, which computes gross positives, gross negatives
  and **net = عليه − له** without altering individual financial balances.
- Added "صافي المتبقي (له / عليه)" to the existing themed report card area,
  and also to both `debts` and `all_party_debts` PDF summary boxes.
- Both the screen and exported PDF operate on the rows currently selected by
  month, name and balance-direction filters; the PDF already passes `visible`
  as `sourceRows`.
- Net zero is clearly labeled "متوازن (0 ريال)" but may coexist with nonzero
  individual balances; it does **not** settle or offset any party's debt.
- No change to database tables, ledger transactions, reports for other
  categories, app theme, colors or navigation.
- Added regression tests at `test/debt_report_totals_test.dart`.

## Validation

Run `flutter test test/debt_report_totals_test.dart` and `flutter analyze`.
Local Flutter runtime is not available to this connector session; CI is
expected to validate the commit after push.
