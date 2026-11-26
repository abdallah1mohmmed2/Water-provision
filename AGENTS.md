# Mandatory repository instructions

Before making any code, test, migration, configuration, or documentation change in this repository:

1. Read docs/SYNC_ACCOUNTING_READINESS_AND_WORK_LEDGER.md in full.
2. Read docs/ARCHITECTURE_DECISION_SHELF_OFFLINE_FIRST.md and the domain-specific document referenced by the task.
3. Inspect the current target branch HEAD and commits after the last ledger entry. The ledger is a guardrail, not a substitute for checking newer code.
4. Do not reimplement completed work. Trace the full path from Flutter UI/Repository and SQLite transaction through Outbox, SyncService, API, server handler, accounting/inventory effects, and Inbox tests.
5. Work on the explicitly requested feature branch only. Never modify or merge main without explicit user approval.
6. Implement one ledger task at a time. Before moving to the next task, update the ledger with the exact commit SHA, changed files, tests, CI run URLs and final statuses, APK artifact where applicable, and accounting reversal evidence.
7. Never mark a task complete based only on code presence or a commit. Required tests and CI checks must have final successful results. If evidence is missing, mark it not verified.
8. Financial records must not be physically deleted after posting. Use audited cancellation and linked reversal entries, with idempotency and atomic rollback.
9. Do not send derived journal lines, balances, or child effects as independent business events when the server creates those effects from the parent business command.
10. If the ledger conflicts with newer code, inspect the newer code, update the ledger with evidence, and only then proceed.

The ledger is a mandatory pre-work gate for every developer and coding agent. Do not skip it.