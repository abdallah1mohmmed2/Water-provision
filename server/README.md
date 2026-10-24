# SAQIA REST server (current implementation)

This package is a standalone Dart Shelf API backed by a pre-provisioned SQLite database. It is **not** a Firebase Functions/Cloud Run service and is not currently wired into the main Flutter admin application. Keep the local application/database as the source of truth until the documented API parity, authorization, and migration work is complete.

## Local startup

From the `server/` directory, provide a fresh, private JWT signing secret of at least 32 characters before starting the process:

```bash
export SAQIA_JWT_SECRET="$(openssl rand -base64 48)"
export SAQIA_DB="../saqia_station_v2.db"
export PORT="8080"
dart pub get
dart run bin_server.dart
```

Do not commit the generated secret, put it in a client app, or use a shared example value. The server now exits before opening the database when `SAQIA_JWT_SECRET` is missing or too short. Store production secrets in the deployment environment's secret manager. `SAQIA_DB` must point to a compatible database; the server does not currently provision or migrate its schema on startup.

## Important deployment limits

- The current implementation uses direct SQLite queries and was designed for single-station/offline operation. It is not a safe multi-tenant or horizontal-scale deployment as-is.
- The server uses custom JWT authentication, not Firebase Authentication ID-token verification. No Firestore adapter or Firebase Admin SDK integration exists.
- Do not expose the listener directly to the public internet. A reviewed TLS/proxy, rate limiting, request-size limits, database backup/restore procedure, station scoping, and production secret management are still required.
- OTP delivery to beneficiaries requires a real messaging provider; the current request-code handler does not send SMS.
- The current server's accounting operations are not yet fully equivalent to `lib/domain/accounting/accounting_service.dart`; do not use it as the authoritative financial write path until parity tests pass.

## Tests

Run the server behavior tests from this directory:

```bash
dart pub get
dart test
```

The server package needs a system SQLite shared library available to `sqlite3` FFI (on Ubuntu runners, install `libsqlite3-dev`).
