# Cloud storage boundary

The specification requires local SQLite and a future MySQL/PostgreSQL server layer.
The Flutter data layer does not depend on SQL dialect details. The server currently
runs SQLite for the single-station/offline deployment and exposes a storage contract
so a MySQL/PostgreSQL adapter can replace the storage engine without changing the
feature/API contract.

The production cloud adapter must preserve:

- transactions for irrigation/payment/compound operations;
- station/user isolation;
- migrations without data loss;
- exact integer monetary values;
- the same 25 required business tables plus helper tables;
- Arabic error semantics and permission checks.
