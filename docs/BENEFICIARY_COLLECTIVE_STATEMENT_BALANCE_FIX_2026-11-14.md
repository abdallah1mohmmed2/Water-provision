# Fix: collective beneficiary statement closing balance (2026-11-14)

- Target: `feature/firebase-station-foundation` only (no changes to `main`).
- Problem: the collective beneficiary statement PDF footer and preview used the last
  row's running balance as the total closing balance. This is only correct for a
  single beneficiary, not a statement combining different beneficiaries.
- Fix: `StationRepository.report('beneficiary_statement')` adds the stable
  `beneficiary_id` to every combined row, preserving movement IDs and all
  individual balances. `BeneficiaryStatementTotals.closingBalance` retains
  the last running balance per beneficiary and sums those balances exactly once.
- The same computation is used in the PDF footer and report preview, including
  name-filtered rows. Individual statement behavior remains unchanged.
- Scope: display and report aggregation only; no changes to ledgers, journal
  entries, transactions, amounts, colors, or theme.
- Regression tests: `test/beneficiary_collective_statement_totals_test.dart`
  covers multiple movements, positive/negative positions, duplicate names,
  interleaved rows, filtering, an individual statement, empty input, and invalid
  group identity.
- Validation note: Flutter/Dart executables are not present in the tool runtime;
  execute `flutter test test/beneficiary_collective_statement_totals_test.dart`
  and `flutter analyze` in a Flutter-enabled environment.
