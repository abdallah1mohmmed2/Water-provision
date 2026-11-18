# P3 — Worker and partner movement implementation audit (2026-11-10)

Repository: `abdallah1mohmmed2/Water-provision`  
Branch: `feature/firebase-station-foundation`  
Status: **P3 discovery / contract gate only — NOT implemented or accepted.**  
Baseline: P2 implementation commit `fc1210862b57429432c7c0f296de746ec2ee2f26`; one subsequent documentation-only ledger commit was confirmed by comparing this commit to the target branch.

## 1. Evidence and non-regression scope

Read `AGENTS.md`, `SYNC_ACCOUNTING_READINESS_AND_WORK_LEDGER.md`, `ARCHITECTURE_DECISION_SHELF_OFFLINE_FIRST.md`, `MANUAL_PARTY_DEBT_SYNC_DESIGN.md`, `SYNC_PROTOCOL_AND_INBOX.md`, and the station completion plan. Traced actual source in `AccountingService`, `BusinessSyncPayload`, `SyncInboxApplier`, `server.dart`, and the local database sync triggers. Existing P0/P1/P2 commands and tested accounting effects must not be recreated or rewritten.

## 2. Command / owner inventory (verified by source inspection)

| Business operation | Local source / subledger | Current sync command and server ownership | P3 decision |
| --- | --- | --- | --- |
| Irrigation worker entitlement | `_accrueWorkerIrrigationTx` creates worker row and GL | Root `irrigations` in P0/P1; server owns derived subledger and journal | **Do not emit worker row** |
| Irrigation partner share | `_accruePartnersFromIrrigationTx` and root irrigation | Root `irrigations`, server-owned effects | **Do not emit partner row** |
| Irrigation charged to worker/partner account | `recordIrrigation` records party subledger row | Root `irrigations`, server-owned effects | **Do not emit party row** |
| Beneficiary receipt and worker/partner payout | `receivePayment`, `payWorker`, `payPartner`; worker/partner payment rows | Root `payments` handled by P2, with subordinate rows | **Do not emit party row or rework P2** |
| Previous worker/partner debt | `addPreviousPartyDebt` creates party row and journal | Explicit `worker_transactions`/`partner_transactions` `create + opening_balance + previous_debt` handled by `_applySyncPartyOpeningDebt` | **Existing working contract; do not duplicate** |
| Single worker accrual | `createWorkerAccrual` writes `worker_transactions` and GL | Local transaction has no explicit party capture; server party dispatch only accepts previous debt | **P3 gap: distinct accrual contract** |
| Fixed worker accrual batch | `createWorkerAccrualBatch` writes multiple `worker_transactions` and GL | Local batch and anti-duplicate checks exist, but no supported P3 batch sync command | **P3 gap: atomic batch semantics / period identity** |
| Monthly fixed salary | `accrueMonthlySalaries` creates worker rows keyed by month and GL | Locally protected against duplicate monthly accrual; server party dispatch currently rejects its type | **P3 gap: server-authoritative salary snapshot and period key** |
| Standalone partner share | `createPartnerShare` writes `partner_transactions` and GL | Local transaction, no supported standalone party command | **P3 gap: partner share contract** |
| Periodic partner profit distribution | `distributePartnerProfits` calculates profit and may create share corrections and distributions | Local multi-row calculation; server party dispatch currently rejects relevant rows | **P3 gap: authoritative profit calculation and atomic multi-party command** |
| Standalone advances, deposits, settlements, correction/reversal | Must be traced from actual UI and repositories before selecting contracts | No verified full source-to-server-to-Inbox acceptance from this audit | **Unverified; do not guess or activate generic financial payloads** |

## 3. Specific gap proven

At `server/lib/server.dart` the `worker_transactions` / `partner_transactions` dispatch always invokes `_applySyncPartyOpeningDebt`; that handler requires `operation=create`, `type=opening_balance`, `reference_type=previous_debt`. Therefore mere presence of both entity types in the allow-list and sync triggers does **not** enable worker accrual or partner distribution. Sending such rows before adding an explicit server-side financial contract would be rejected.

`BusinessSyncPayload.additionalCommands` includes both party tables, but child-identity manifests are not a substitute for server-created and verified accounting effects. `SyncInboxApplier` classifies the tables but neither that fact nor the P2 payout projection proves standalone P3 accrual acceptance.

## 4. Implementation order (one independently verified slice at a time)

1. **P3a single worker accrual:** define a root-only command with UUID identities, station/role/date/closed-period validation, server-owned calculation and balanced `5000 → 2100.W` journal, atomic local capture, authoritative child IDs and receiver projection. Protect existing irrigation-derived wages and P2 payouts.
2. **P3b standalone partner share:** scoped role/partner validation, server-derived share rules when applicable, balanced `3200 → 2200.P` entry, idempotent replay and receiver projection.
3. **P3c monthly salary and fixed worker batches:** distinct period key and salary snapshots read from the server, duplicate-period guard, entire batch atomic including all child journals.
4. **P3d profit distribution and corrections:** compute revenue, expense and worker accrual from the server ledger, ensure all partner allocations and adjustments are atomic, prevent repeated distribution, never accept client-supplied profit or balanced journal totals as authority.
5. **P3e standalone advances/deposits/settlements/reversal:** complete UI-to-database inventory first, define direction and cashbox vs personal-account source for each operation, keep posted originals immutable, record reasons and single linked reversals, preserve P0/P1/P2 responsibilities.
6. **P3f account statements/permissions:** compare worker and each partner subledger to journal and cashbox, test non-manager/private-partner visibility, date filters, and two stations with overlapping local IDs.

## 5. Minimum acceptance matrix

For every new supported command: successful creation, invalid role, foreign station UUID, inactive party, closed period, nonpositive/overflow amount, missing manifest identity, stale base version, duplicate event ID, duplicate business UUID under a new event, forced journal/identity failure and complete rollback, retry after failure, no Outbox echo, two independently stored SQLite clients exchanging events through real Shelf HTTP, and exact balance/subledger/journal parity. Include posting date vs reversal date and original vs reversal entry counts. The P3 cashbox tests must explicitly distinguish personal-account movements from actual cashbox withdrawals/deposits.

## 6. Gate / proof status

- Source and ledger inspection: performed; specific scope and gaps documented above.
- Source-code change for P3 commands: **not yet performed**.
- Local `flutter analyze`, `flutter test`, `dart analyze`, `dart test`: **not run / not verified**.
- GitHub Actions and P3 APK on a code-changing HEAD: **not run / not verified**.
- Production readiness and completion of P3: **not claimed**.

This audit is deliberately a documentation-only pre-implementation checkpoint. It must not be mistaken for a completed P3 feature or an authorized change to `main`.
