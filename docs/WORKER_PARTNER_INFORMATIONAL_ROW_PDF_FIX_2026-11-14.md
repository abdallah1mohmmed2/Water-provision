# Worker and partner statement PDF: informational balance rows (2026-11-14)

Branch: `feature/firebase-station-foundation`; `main` untouched.

## Problem
The worker statement print path and partner statement print path converted
`row['balance'] == null` to zero. The repository correctly emits
`worker_irrigation_info` and `partner_irrigation_info` as nonfinancial
irrigation-description rows *without* `balance`. The PDF thus printed
"صفر" in the running balance column even though the account had not been zeroed.

## Fix
- A single `PartyStatementBalanceDisplay` helper distinguishes informational
  rows, absent or invalid balance fields, and genuine financial zero balances.
- The worker's official PDF and partner's official PDF show `—` for an
  informational/non-balance row while keeping `له`/`عليه` for real balances.
- The partner PDF footer selects a real closing-balance row, not an arbitrary
  information-only row; an unavailable closing value prints `—`.
- The generic PDF path for worker/partner reports also renders no-balance rows
  as `—`.
- Actual zero is still `صفر` in the specialized PDFs and `متوازن` in generic
  account reports. No ledger data, journal amounts, worker pay, partner profit
  calculations, report theme, or card styling was modified.

## Tests
`test/party_statement_balance_display_test.dart` checks missing balances,
both info types, explicit zero on informational rows, real financial zero,
positive/negative values, and invalid inputs.

Runtime limitation: run `flutter test test/party_statement_balance_display_test.dart`
and `flutter analyze` on an environment with the Flutter SDK installed.
