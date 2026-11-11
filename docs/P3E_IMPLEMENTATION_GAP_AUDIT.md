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

## Source-level trace — payment creation and reversal (2026-11-11)

Verified exact local implementation, rather than treating all P3e operations as missing:

| Operation | Existing client path | Outbox / server route | Status |
| --- | --- | --- | --- |
| Worker payment | `AccountingService.payWorker` invokes `_paymentInTx`, inserts linked `worker_transactions(type=payment, reference_type=payment)` | Single `payments` root; `BusinessSyncPayload` P2 effect manifest; server dispatcher calls `_applyP2Payment` | Existing route; peer effect correctness requires targeted tests |
| Partner payment | `AccountingService.payPartner` invokes `_paymentInTx`, inserts linked `partner_transactions(type=payment, reference_type=payment)` | Same single `payments` root and P2 server dispatcher | Existing route; do not duplicate |
| Payment cancellation | Existing local cancellation updates `payments.status=cancelled`, changes cashbox balance, invokes `_reverseEntriesTx`, and inserts `payment_reversal` party row referencing original payment ID | `BusinessSyncPayload.prepare` captures updated payment and created child effects under P2 manifest | Existing local code; server acceptance and two-client replay need verification |
| Payment replacement | `AccountingService.replacePayment` documented to reverse original and create replacement in one local transaction | `BusinessSyncPayload.prepare` supports `_p2_replacement` | Existing contract; needs explicit worker/partner regression proof |
| Beneficiary diesel advance | `diesel_movements(kind=advance)` and `diesel_advance` journal logic | Diesel domain, not worker/partner cash advance | **Not** evidence that P3e party advances exist |
| Party opening debt | `_applySyncPartyOpeningDebt` requires `opening_balance/previous_debt` | Dedicated worker/partner fallback | Existing only for opening debt; never accept arbitrary party types |

### Important no-repeat implementation decision

**Do not add a new worker/partner payment handler, payment-reversal handler or independent party-payment Outbox root before exercising the existing P2 path.** A second handler would risk double-posting cashbox and journal effects. The P2 effect manifest already explicitly captures created `worker_transactions` and `partner_transactions` as derived rows. The local cancellation preserves original journals and posts reversals.

The first safe executable change should be a focused regression test for a worker payment and partner payment across two independent SQLite clients, followed by cancellation/replacement and replay checks. Only failures proven by that test should be repaired. Genuine P3e party advance/deposit/settlement contracts must be separately identified; neither the diesel advance nor the previous-debt handler can substitute for them.

This section records source inspection only. No test execution or CI acceptance is asserted.
