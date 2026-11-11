# P3e — verified implementation gap and non-duplication audit

Date: 2026-11-11  
Branch: `feature/firebase-station-foundation`  
Baseline HEAD inspected: `ce4d00d9652da4c3400868945cf094f7e9ed90ac`  
Status: **audit only; P3e is NOT implemented or accepted by this document.**

## Existing functionality that MUST be preserved

- `AccountingService.payWorker` and `payPartner` already create a `payments` root and a linked `worker_transactions` or `partner_transactions` payment row in one local database transaction; both capture only `payments` in Outbox. Do not introduce duplicate party-payment Outbox roots.
- `BusinessSyncPayload.prepare` already has a P2 `payments` manifest containing derived party rows, journals, cashboxes and replacement references. Its coverage of every worker/partner payment variant must be verified against P2 server tests before changing it.
- `server/lib/server.dart` dispatches `payments` to existing `_applyP2Payment`; worker/partner standalone accrual, fixed/monthly salary, P3d distribution and previous-debt commands have their own handlers. Do not reroute or duplicate these.
- `_applySyncPartyOpeningDebt` currently accepts only `type=opening_balance` and `reference_type=previous_debt`; its generic fallback is NOT evidence of support for advances, deposits, settlements or reversals.
- Existing accounting service contains reversal-journal logic that preserves the original posted journal and adds a balanced inverse. Reuse this convention rather than deleting financial history.
- P3d accepted code SHA `8089811aed5e955a10800ced0625e95f40654664`: three successful CI workflows, 97 server tests and 158 Flutter tests per acceptance ledger. P3c source implementation exists; independent P3c acceptance is not established by this audit.

## Specific remaining P3e implementation gates

1. Inventory the exact existing client commands and `type/reference_type` values for advances, deposits, settlements and reversals. Differentiate party advances from beneficiary diesel advances and beneficiary payments.
2. Trace each command from its local transaction and Outbox root through `BusinessSyncPayload`, Shelf dispatch, server-owned journal, Inbox projections and two independent SQLite clients. Record missing links rather than assuming a handler exists.
3. For each genuinely missing operation, implement one server-authoritative business command with JWT station/role checks, global UUID links, immutable originals, precise balanced journal/cashbox effects and one event SAVEPOINT.
4. Reversals must reference the original trusted global UUID, reject cross-station references, be idempotent, and never mutate or erase posted originals. Validate that a second reversal cannot double-post.
5. Add forged amount, invalid role/station, malformed manifest, forced failure after partial derived effects, replay, peer projection, no child Outbox echo, and balance-parity regression tests.
6. Do not close P3e until exact code SHA and CI results are documented. Do not change `main`.

## Verified source locations

- `lib/domain/accounting/accounting_service.dart`: `payWorker`, `payPartner`, reversal helpers.
- `lib/data/local/business_sync_payload.dart`: `prepare` and P2 party-payment manifest.
- `server/lib/server.dart`: sync dispatcher, `_applySyncPartyOpeningDebt`, P3a/P3b/P3c/P3d handlers.
- `docs/SYNC_ACCOUNTING_READINESS_AND_WORK_LEDGER.md`: §24 P3d acceptance.

This audit deliberately makes no assertion that P3e synchronization works, and makes no change to existing financial source or historical records.
