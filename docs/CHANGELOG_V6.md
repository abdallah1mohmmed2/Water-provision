# SAQIA V6 Change Log

## Scope
V6 continues the same `saqia_station_v2` source tree from V5. No parallel project was created.

## Implemented in V6

### Admin application screens
- Dashboard remains DB-backed and reads live counters.
- Beneficiaries: add/search/details remain DB-backed.
- Irrigations: creation remains through the accounting service with calculation, waiting-period, overlap, snapshot and journal rules.
- Irrigation sessions: beneficiary/pump/queue/booking are explicitly selectable; start/stop/postpone persist to SQLite.
- Queue/bookings: add beneficiary to queue, create booking request, postpone, manager override with reason, schedule and cancel.
- Diesel: receipt, delivery, advance and inventory correction; stock warning and 10-minute snooze.
- Payments: beneficiary receipts plus worker/partner payments, using the accounting service and double-entry.
- Cashboxes: create cashbox, transfers, balances and transfer history.
- Workers: create worker, accrue entitlement and record payment.
- Partners: create partner, accrue share and record payment.
- Journal and ledger: live database reads.
- Reports: 24 report definitions remain available with the existing PDF service and filters.
- Notifications: live database list with read state and refresh.
- Settings: live settings persistence.
- Backup/restore: existing database backup/restore workflow retained.

### Database
- Schema remains 25 required tables.
- Added `station_id` to beneficiaries, partners, workers, cashboxes and payment methods to support future multi-station isolation.
- Local database version advanced from 7 to 8 with migration/indexes.
- Existing data receives station 1 by default during migration.

### API
- Financial write operations are wrapped in atomic transactions.
- API journal helper no longer opens a nested transaction; the caller owns the transaction.
- API financial writes now include journal entries for irrigation, payments, expenses, cashbox transfers, diesel receipt/consumption/advance where applicable, worker transactions and partner transactions.
- API validates station ownership for station-scoped entities before writes.
- Worker and partner creation endpoints were added.
- Admin JWT retains station identity and role claims.
- Audit logging was added to relevant API-created records.

## Verification performed in this environment
- `python3 tools/spec_audit.py` PASS.
- `python3 tools/verify_source.py` PASS.
- `python3 tools/screen_db_audit.py` PASS: 17/17 admin screens mapped to persistence/service operations.
- Authoritative SQL executed successfully in Python SQLite: 25/25 required tables.
- Station ownership columns validated on 5 station-scoped entities.
- Python syntax checks for project audit tools PASS.
- ZIP integrity will be checked after packaging.

## Not claimed
Flutter/Dart SDK is not installed in this execution environment. Therefore V6 does **not** claim successful `flutter analyze`, `flutter test`, Android debug/release builds, or Web builds. Those remain runtime verification steps, not static-source claims.
