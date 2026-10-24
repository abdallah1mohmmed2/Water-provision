# API and Firebase Audit — Water-provision

**Audit date:** 2026-10-24
**Repository:** `abdallah1mohmmed2/Water-provision`
**Firebase project:** `water-provision`
**Scope:** Static inspection of the checked-out repository plus read-only inspection of the Firebase Console. No production data, rules, indexes, accounts, or deployments were changed.

## Executive summary

The Flutter application and Android Firebase registration point at the same Firebase project ID, `water-provision`, but this is not yet a Firebase-backed API integration. The Android app initializes Firebase Core; it does not use Firebase Authentication, Firestore, Cloud Functions, or Cloud Run in the inspected source. In the console, the project is on the Spark plan; Firestore offers **Create database**, Authentication offers **Get started**, and Cloud Functions reports that a billing account/Blaze plan is required. Firebase Hosting also offers **Get started** rather than showing an existing hosted site.

The operational application currently uses local SQLite. The repository also contains a separate Dart Shelf API backed directly by SQLite and custom JWTs. The main admin app does not call this API; its screens use local repositories. The API and local accounting implementation have material differences in financial behavior and station scoping. Therefore the API must not be promoted as the authoritative production backend until those differences are resolved and parity-tested.

No Firestore database creation, Firebase Authentication enablement, billing-plan upgrade, data migration, or production deployment was attempted. Those actions have project-wide effects and require explicit choices about region, authentication providers, data authority, and deployment/billing.

## 1. Current architecture and sources of data

- `lib/main.dart:7-12` initializes `Firebase.initializeApp()` on Android and then launches `SaqiaApp`.
- `lib/data/local/database.dart:14-36` opens a device-local `saqia_station_v2.db`; `lib/data/repositories/repositories.dart:10-24` and the accounting services use this database for normal admin operations.
- `server/bin_server.dart:7-13` starts a separate Shelf service, opens a SQLite file, and binds to all IPv4 interfaces. `server/lib/server.dart` runs SQL directly against that SQLite handle. `server/lib/storage/storage_contract.dart` is only a future-facing interface; it is not used by the runtime server.
- `lib/api/api_client.dart` and `lib/features/beneficiary_app.dart` contain an API client and beneficiary UI, but repository call-site search found no `ApiClient(...)` construction and no `BeneficiaryApp(...)` launch from the normal app. The normal application currently starts the admin app (`lib/main.dart:7-12`).
- `lib/services/sync_service.dart` posts queued data to `/sync`, but no `/sync` route exists in the current server router and no active call site was found.

**Conclusion:** There are currently three distinct layers—local SQLite admin app, dormant client-side API/beneficiary code, and a separate SQLite server. They do not constitute a single centralized Firebase-backed source of truth.

## 2. Existing API surface

Routes are registered in `server/lib/server.dart:16-71`.

| Area | Registered routes | Notes |
|---|---|---|
| Public | `GET /api/v1/time`, `POST /api/v1/auth/login` | Admin login issues a custom JWT, not a Firebase ID token. |
| Settings/dashboard | `GET /dashboard`, `GET/PUT /settings` | Role-gated; multiple read queries are not station-filtered. |
| Beneficiaries | list/create/detail/update/delete/statement | Selected CRUD operations check station ownership; statement query does not. |
| Irrigation/sessions | irrigation create/list/cancel; session list/start/finish/postpone | Financial logic differs from the local accounting service; several ID updates do not confirm station ownership/state. |
| Queue/bookings | list/add/postpone/skip; bookings list/schedule/cancel | Several writes are not station-scoped. |
| Finance/operations | payments, cashboxes/transfers, diesel, expenses, workers, partners | Some writes use SQLite transactions; other handlers are not transactional or are inconsistent with local rules. |
| Accounting/reports | journal, ledger, named reports | 24 report names are accepted, but only a small subset has report-specific SQL; most names fall through to the same generic irrigation rows (`server/lib/server.dart:185-186`). |
| Beneficiary API | request-code/session, profile, requests, account, notifications/read | OTP is persisted locally; no SMS provider send is implemented in the handler. |
| Backup | backup/restore | Accepts filesystem path/base64 input; needs hardening before exposure. |

The API has no route for server-side Firebase ID token verification, `/sync`, Firebase App Check, session logout/revocation for admin tokens, or a consistent OpenAPI contract. Worker/partner CRUD and other operational lifecycle routes are incomplete compared with the local app.

## 3. Authentication and authorization risks

- `server/bin_server.dart:9` previously fell back to a checked-in placeholder JWT secret if `SAQIA_JWT_SECRET` was absent. This is unsafe for any network-accessible deployment.
- `server/lib/server.dart:107` and `lib/services/admin_service.dart` use unsalted SHA-256 for password comparison; this is not an appropriate password-storage KDF.
- Admin auth checks JWT signature/expiry and role but does not re-load account active status or current permissions on each request (`server/lib/server.dart:81-84`).
- Beneficiary OTP request/login endpoints are public. Request-code returns different responses for unknown and known phone numbers, allowing account enumeration. No IP/phone rate limit or SMS-provider dispatch is implemented. A development flag can expose the OTP in its response.
- Multi-station scoping is inconsistent. Examples include unscoped dashboard, irrigation/session/queue/booking/payment/diesel/expense/journal/ledger/report reads and ID-based mutations without `_requireOwn`; see `server/lib/server.dart:108-110,116,123-124,126,144,146-152,154-186`.
- `_body` converts malformed JSON and non-map bodies into `{}` (`server/lib/server.dart:79`), and there is no general body-size limit, pagination contract, or API-wide exception mapper. Some error responses include exception text.
- `lib/api/api_client.dart:21-27` hardcodes `X-Station-Id: 1`; the server derives station from a JWT claim instead. The current main admin app does not construct this client, so that mismatch is not proof of active integration.
- There is no checked-in Firestore rules or index file, and no Firestore database is set up in the observed console state. No client-side Firestore access was found in repository source.

## 4. Business and financial compatibility constraints

The local app contains the mature business rules and should remain authoritative until parity is demonstrated. Local financial amounts are integer-based, compound operations are transactional, and the accounting service handles reversals, station scoping, cashier account mapping, diesel balances, queue/session transitions, and fiscal closing. Details are implemented in `lib/domain/accounting/accounting_service.dart`, `lib/domain/accounting/balance_sql.dart`, `lib/domain/accounting/calculations.dart`, and documented in `docs_STATUS.md` and `docs/year-end-accounting-close.md`.

The server implementation diverges in several material ways, including floating-point irrigation math, accepted client-selected system type, incomplete cancellation reversals, cashbox transfer account mapping, worker/partner payment direction, station filters, and financial ledger entries that omit station assignment. These differences are documented with exact source references in this report and must be resolved with parity tests before centralizing writes.

Some business policies remain expressly unresolved in project docs, including diesel valuation and some partner-share allocation details. They must not be invented in a server rewrite.

## 5. Firebase and deployment state observed

- Repository app config registers Android package `com.saqia.saqia_station` under Firebase project `water-provision` (`android/app/google-services.json`, `lib/firebase_options.dart`, `android/app/build.gradle.kts`). The Firebase client API key in these config files is public client configuration, not a service-account secret; it should still have appropriate API restrictions and is not an authorization boundary.
- `firebase_core` is the only Firebase runtime dependency in `pubspec.yaml`; no `firebase_auth`, Firestore, Functions, Admin SDK, or App Check integration was found.
- No `firebase.json`, `.firebaserc`, `firestore.rules`, `firestore.indexes.json`, Functions source tree, service deployment manifest, or Firebase deploy workflow is checked in.
- Console read-only checks: plan is Spark; Firestore displays **Create database**; Authentication displays **Get started**; Functions indicates a billing account/Blaze plan is required; Hosting displays **Get started**. No production deployment or billing change was made.
- Console pages inspected: [Firestore](https://console.firebase.google.com/project/water-provision/firestore), [Authentication](https://console.firebase.google.com/project/water-provision/authentication), [Functions](https://console.firebase.google.com/project/water-provision/functions), and [Hosting](https://console.firebase.google.com/project/water-provision/hosting).
- No Firebase CLI, Flutter SDK, or `gcloud` executable was available at initial inspection. A Dart SDK was provisioned temporarily for local server-package testing; that does not grant access to Firebase project data or permit deployment.
- GitHub CI now also installs the native SQLite library and runs the server behavioral tests; the pre-existing Flutter job still runs one accounting integration test and `flutter analyze`. Flutter runtime tests/builds were not claimed by current project status docs.

## 6. Test and build inventory

Existing tests: `test/accounting_integration_test.dart`, `test/calculations_test.dart`, `test/manual_message_service_test.dart`, `test/permissions_test.dart`, and `test/source_acceptance_test.dart`. The latter performs source-string checks rather than exercising server route behavior. No server-specific behavioral test suite existed at audit time.

CI workflows are described in `.github/workflows/analyze.yml`, `.github/workflows/build-apk.yml`, `.github/workflows/unzip.yml`, and `codemagic.yaml`. The `unzip.yml` workflow grants `contents: write`, unpacks a repository archive, stages all files, and pushes a commit; provenance and extraction validation should be reviewed before use. Release Android builds currently use the debug signing config (`android/app/build.gradle.kts:32-37`), which is not suitable for production distribution.

## 7. Safe implementation plan and rollback

1. Keep the present local SQLite and accounting workflows unchanged; do not migrate or duplicate production data.
2. **Completed in this branch:** add direct server tests, close the unsafe JWT-secret fallback so the server fails closed unless a strong externally supplied secret is configured, and document local setup explicitly.
3. Document the full route inventory, unsupported/unverified features, and required cross-station/business-parity work.
4. Reconcile the server's transaction, station-ownership, report, cancellation, and financial-direction semantics against the local accounting service, with negative authorization and accounting tests before wiring the admin app to it.
5. Select a deployment architecture after confirming intended data authority. Cloud Functions is not available on the current Spark plan in the observed console; Cloud Run and a production database would need separately reviewed project/billing/IAM setup. Firestore database creation requires choosing a region and a data/rules design. No such choices are assumed here.
6. Only after API parity/security tests pass, pilot on a separate development Firebase/GCP project or isolated environment. Preserve current configuration and provide an explicit rollback path before production cutover.

**Rollback:** All work is confined to a feature branch until review. The current production/local SQLite data and Firebase settings remain untouched. Reverting the branch or its individual commits restores the checked-out code state; there is no database migration to reverse from this audit.

## 8. Completion status at audit

| Item | Status |
|---|---|
| Repository and Firebase read-only audit | Complete; see findings above. |
| Existing local business rules and sources inventoried | Complete at source level; no production data read. |
| Firebase Firestore/Auth/Functions setup | Not present or not enabled in the observed project state; no setup change made. |
| Full central API, Firebase ID-token integration, and Firestore model | Not implemented; requires resolving source-of-truth and project setup choices. |
| Production deployment, data migration, Firebase billing/rules changes | Not performed. |
| Server behavioral test coverage | Added; `dart analyze` reports no issues and all 6 `dart test` tests pass locally. CI is updated to run them. |
| Flutter runtime/build validation | Not available because Flutter SDK is not installed in the current environment. |
