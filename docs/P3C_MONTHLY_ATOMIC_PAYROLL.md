# P3c — Atomic multi-worker monthly payroll sync

Date: 2026-11-10  
Branch: `feature/firebase-station-foundation`  
Status: **Source implemented, tests authored, CI acceptance awaiting repository owner**.

## No-duplication gate

- Compared target branch with the recorded last checkpoint `0f83913ca5527744e35db0d282e447c5b0bc7a16` before editing; result **identical**.
- Existing `AccountingService.accrueMonthlySalaries` already posts per-worker entitlements and balanced local journals in one SQLite transaction, and already checks duplicates and period closure. Its financial algorithm, salary snapshot, date and notes are **retained**.
- Existing `_applySyncMonthlyWorkerSalary` already supports one worker/month; **retained** for old single-worker payloads and for a month with only one new entitlement.
- Previously implemented `createWorkerAccrualBatch` and `_applySyncWorkerFixedSalaryBatch` are a **different operation**, identified by `fixed_salary_batch`. Do not recreate it as monthly payroll.
- P0, P1, P2, P3a, P3b and their original handlers are not reimplemented; `main` is untouched. P3d partner profit distribution is intentionally not started.

## Single root command contract

- The local domain transaction creates the existing worker rows and journals. The first created `worker_transactions` row is marked as the **only Outbox root** using the existing `captureSyncRecordIds` API. Zero new salaries generate no event. One new salary retains the previous single-worker contract; two or more create a group command.
- The `BusinessSyncPayload` handler recognizes multiple `monthly_salary` creations in the same SQLite transaction, checks that all share the same `reference_id=YYYYMM` and date, and attaches `_p3c_monthly_batch` with `month_key` and ordered `members`. Each member contains its worker transaction UUID, worker UUID reference, amount and salary snapshot.
- The same command includes `_derived_global_ids` with exactly one journal-entry UUID plus two journal-line UUIDs **per worker**, and an empty cashbox list. The server never trusts the client's journal account IDs or totals.
- The monthly root remains `entity_type=worker_transactions`, `type=worker_entitlement`, `reference_type=monthly_salary`. It adds an envelope key, rather than creating a new table, migration or generic financial-event handler.
- `_applySyncMonthlySalaryBatch` executes in the **existing Shelf sync event SAVEPOINT**. It validates the authenticated station and role; YYYYMM and date; root and child UUIDv4 identity; distinct workers; active fixed-salary workers in the station; authoritative server `fixed_salary` versus each submitted amount and snapshot; no duplicate month, prior fixed-salary batch or historical worker-salary journal; open posting period; one-journal/two-lines identity manifest per worker; no cashbox effect.
- After all members pass preflight, Shelf inserts every worker movement and posts authoritative balanced journals: debit expense `5000`, credit that worker's `2100.W*` liability account. If the second worker's journal fails, no worker movement or journal may remain (event SAVEPOINT rollback). Only then is the original Outbox event acknowledged.
- The existing `_appendBusinessEffectProjections` publishes all **non-root worker movements** to source and peer clients; both get the server-created journal entries and lines. Peers also get the original root event.
- `SyncInboxApplier` skips the private `_p3c_monthly_batch` and pre-existing `_p3c_batch` command envelopes (they are **not** SQLite columns), and now preserves `reference_id=YYYYMM` for monthly worker rows instead of dropping it as if it were an unrelated foreign key. This protects local duplicate detection on every client.
- Legacy single-worker events without `_p3c_monthly_batch` still route to the existing `_applySyncMonthlyWorkerSalary`. A malformed envelope **cannot fall back** to that handler.

## Tests written (not yet confirmed passing)

| Source | Assertions |
| --- | --- |
| `test/database_sync_outbox_test.dart` | Existing monthly test updated in place (not duplicated): many local new salaries create **one** pending worker root with N worker UUIDs, N journal UUIDs, 2N line UUIDs, no derived journal Outbox, duplicate monthly rerun yields zero. |
| `server/test/sync_protocol_test.dart` | New multi-worker monthly test checks forged second salary rejection; malformed envelope rejection; **forced failure inserting the second worker's journal line** and rollback of all workers/journals/lines; success with balanced 3300 debit/credit; unchanged cashbox; origin/peer Inbox shape; idempotent duplicate; new UUID with duplicate month rejection; cross-station rejection. |
| `test/p3c_monthly_two_clients_test.dart` | Two distinct SQLite files/devices, real Shelf loopback HTTP, one Outbox root, rejected truncated manifest, successful push, source/peer parity, preserved `reference_id=209004`, exactly two balanced server-owned journals, no cashbox change, safe replay, no pending child Outbox or failed Inbox records. |
| Existing older suites | Old single-worker `monthly_salary` protocol coverage; old atomic `fixed_salary_batch` and P0/P1/P2/P3a/P3b tests remain to catch regressions. |

## Review and acceptance restrictions

- Pre-edit branch check: **identical** to previous ledger commit. This change modifies only the local monthly event ownership, its payload metadata, targeted Inbox resolution, dedicated Shelf multi-worker handler/projections, and tests.
- Post-edit code checkpoint before documentation: `6535fa382ac4872cdb3634e44866ab9afb1020c9`. Do not equate a commit with a passing CI run.
- **CI was not requested, triggered manually, polled, or awaited** by the assistant, per owner instruction. GitHub may run its normal automated workflows on branch pushes.
- No local Dart/Flutter runtime was available in the assistant's execution container; **tests have not been executed in this session**. Source inspection does not establish a successful runtime check, build or APK.
- A monthly run with more than 100 newly eligible workers is rejected atomically by the existing transaction/payload constraints rather than being silently split into independently committed payroll events. This requires a distinct scalable batch design if needed later.
- If a worker's fixed salary changed on Shelf since offline local accrual, the command rejects as one whole batch; there is no unapproved rewriting of financial history.
- **P3c source implementation is extended but not independently accepted** until the owner reports final successful CI results on the exact code revision. P3d remains unopened pending this gate.
