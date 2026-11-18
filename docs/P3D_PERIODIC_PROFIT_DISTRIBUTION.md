# P3d — Server-authoritative periodic partner profit distribution

Date: 2026-11-10  
Branch: `feature/firebase-station-foundation`  
**Status: **P3d source slice CI-ACCEPTED on commit `8089811aed5e955a10800ced0625e95f40654664` (2026-11-11)**; production rollout not approved.**

## Baseline and no-repeat rule

- Source branch checked against the preceding P3c work ledger: only one newer **documentation** commit was present. No P3d business implementation was present.
- Existing local `AccountingService.distributePartnerProfits(from,to)` already calculates posted-journal revenue, general expenses excluding worker wages, worker expense account 5000, direct irrigation partner earnings, excess-share adjustments, and percentage/share ownership distribution. **These business formulas and transactions were reused**, not rebuilt in the local client.
- Existing P0/P1/P2, P3a, P3b and P3c sync handlers remain unchanged. The local distribution does not hand off to the standalone partner share handler P3b. `main` was not modified.

## Atomic P3d command / implementation

1. Existing local distribution creates the same `partner_transactions` and balanced journals, adding only a `P3D_RANGE:<start ISO date>:<exclusive end ISO date>` marker to each newly created profit allocation or excess-adjustment row. Local `AppDatabase.transaction` now uses its existing `captureSyncTables` and `captureSyncRecordIds` to place **only the first partner row** in Outbox, whether it is a distribution or an adjustment. There is no independent child Outbox echo. Zero effect produces no new business command.
2. `BusinessSyncPayload.prepare` captures all newly posted partner rows in `_p3d_distribution.members` with root/member UUIDs, worker-independent partner global UUIDs, amount, ownership snapshot, operation type, the existing distribution's numeric period reference, and any adjustment's original direct-irrigation share UUID. It binds N journal entry UUIDs and 2N journal-line UUIDs in `_derived_global_ids`; the cashbox manifest remains empty. It refuses unknown/unlinked adjustment origins instead of guessing local IDs.
3. Dedicated `_applySyncPartnerProfitDistribution` handles only commands with the P3d envelope. The existing server sync SAVEPOINT applies **every** adjustment, allocation, journal, UUID link, event version and Inbox projection together or rolls back the entire group. It authenticates manager/accountant role and station, date range, locked period, UUID manifest, original historical adjustment links, partner ownership, uniqueness and exact values.
4. Shelf **recomputes** revenue, general non-worker expenses and wages from its own posted GL using the same SQL categories already in `AccountingService`. It computes distributable profit, applicable direct irrigations (excluding cancelled irrigation), pre-existing adjustments, only the necessary excess-share corrections, and remaining percentage/share allocations, then compares all member types, partner IDs, amounts and snapshots with the client command. A stale or manipulated offline financial state results in **rejection**, not a rewrite of posted history.
5. `server/lib/profit_distribution_calculations.dart` is a standalone server-packaged pure-Dart copy of the existing validated allocation calculation. It avoids making the independently deployable server package import Flutter parent sources. `server/test/p3d_calculations_parity_test.dart` compares this calculation directly with the existing `AccountingCalculations` across percentage/share combinations, rounding, zero/loss outcomes and invalid percentages.
6. Previous `profit_distribution` transactions and any new period with a `P3D_RANGE` marker are inspected on Shelf. An overlapping time interval or a legacy distribution with the same beginning (allowing timezone offset) is **rejected**. Parallel client attempts are serialized by the existing sync `BEGIN IMMEDIATE` and checked against posted server effects.
7. Existing `_appendBusinessEffectProjections` now publishes N-1 non-root partner rows to the origin and peers, plus authoritative journals and journal lines. `SyncInboxApplier` skips P3d command envelopes, preserves the numeric distribution-period reference (which is a business key, **not** a foreign ID), and resolves adjustments to the previously linked original partner transaction UUID. The old source rows remain posted and unchanged; corrections are additional journal entries only.

## Tests written

- `server/test/sync_protocol_test.dart`: valid two-partner split with 400/800 from server profit 1200; forged amount rejection; forced failure on second partner GL line and full rollback; two balanced GL entries; unchanged cashbox; idempotent replay; renamed-root duplicate period rejection; cross-station denial; source/peer Inbox effects.
- Same file: adjustment-only scenario where a historic direct-irrigation share exceeds server profit. The old share remains posted, a single linked compensation is inserted, its 500/500 GL is balanced, there is no phantom distribution; forged original UUID and truncated GL manifest are rejected.
- `server/test/p3d_calculations_parity_test.dart`: pure allocation parity against client code, including mixed ownership modes and invalid totals.
- `test/p3d_two_clients_test.dart`: two separate SQLite database files, real Shelf loopback HTTP, one Outbox root, malformed journal manifest rejection, authoritative profit distribution and N/2N journal projections, unchanged cash, numerical period-reference parity across devices, replay and no child Outbox echo.
- Older P3a/P3b/P3c, P0/P1/P2 tests remain in place as regression checks.

## Safety limitations / acceptance

- Source accepts historical direct profit corrections only when the server can resolve **the original share's trusted global UUID**. Historical rows lacking that link require a separate reconciliation/migration; do not reassign numeric IDs or infer cross-station relationships.
- If local and server GL differ, the source event is **rejected** to protect accounting truth. No automatic adjustment of client totals, period rewrite, or deletion of existing financial movements is permitted.
- Zero-effect periods do not produce a financial command; posting status for an empty period is not modelled as a standalone durable period-closure event.
- At most 100 newly created partner/adjustment movements fit one command. Larger groups fail without partial local posting, pending a distinct scalable design.
- No Dart/Flutter executable was available in the assistant's local container. **GitHub CI was explicitly inspected at the owner's request**; its final results are now recorded below. No production physical-device test is claimed.
- **P3d is CI-accepted within the source and two-SQLite-client test scope**, not equivalent to completing P3 or approving production rollout. P3e/P3f remain open; legacy unlinked records and empty-period close semantics remain separate constraints.

## CI acceptance evidence — 2026-11-11

- Verified branch source HEAD at acceptance: `8089811aed5e955a10800ced0625e95f40654664`; branch compare at inspection: **identical, zero ahead/behind**.
- **Flutter Analyze**: GitHub Actions run [42972049114](https://github.com/abdallah1mohmmed2/Water-provision/actions/runs/42972049114), final **success**.
- **SonarCloud**: run [42972049001](https://github.com/abdallah1mohmmed2/Water-provision/actions/runs/42972049001), final **success**; its Flutter suite recorded **158/158 passed**, including `test/p3d_two_clients_test.dart`, both P3c two-client tests, and all existing regressions.
- **Build / SonarQube**: run [42972049028](https://github.com/abdallah1mohmmed2/Water-provision/actions/runs/42972049028), final **success**. Shelf suite **97/97 passed**, Flutter Analyze **no issues found**, Flutter **158/158 passed**, LCOV verification succeeded, Android Debug APK built and uploaded, SonarQube scanner reported `ANALYSIS SUCCESSFUL`.
- Debug artifact: [Saqia-App-Debug, artifact 13834151432](https://github.com/abdallah1mohmmed2/Water-provision/actions/runs/42972049028/artifacts/13834151432) (93,700,988 archive bytes when inspected; not a signed Release).
- Original P3d commit `6b25a3e978eecaf13867f04341d2ca20ba29b223` had **failed** runs 42866489719 / 42866489524 / 42866489590. Log review found two Flutter lints, a test-fixture account-deletion FK failure, and missing peer child rows.
- Fix commits up to `8089811a` corrected the lints, preserved journal-referenced accounts in test cleanup, and repaired the actual sync bug: newly posted child `worker_transactions`/`partner_transactions` had been projected with `operation=update` merely because the server UUID link existed before its first Inbox event. For these child projections, version absence now yields `create`, **without changing** previously working P0/P1/P2 projection semantics. Added explicit server regression tests for child `create` events and peer Inbox error assertions. All three CI workflows subsequently passed on the identical code commit.
- Sonar scanner execution success does not independently certify a remote quality-gate status beyond the successful CI workflow. No physical-device pairing, production backup/restore rehearsal, signed Release, or deployment approval is asserted.

