# Android contact phone picker — 2026-11-14

## Scope

Repository: `abdallah1mohmmed2/Water-provision`
Branch: `feature/firebase-station-foundation`. No change to `main`.

## Existing code and scope checked

Before implementation, the beneficiary, worker and partner add/edit forms
in `lib/features/app.dart`, the Android `MainActivity`, the app manifest,
the dependencies and the repository tree were inspected. No existing contact
selection integration was found.

## Implementation

- Added one reusable `ContactPhoneField`, replacing the phone input in
  **all six** forms: add/edit beneficiary, worker, partner. The original
  labels, style, dialog structures, account and persistence logic remain.
- Android only: a trailing contact icon opens the system picker for a *phone
  number*. Only the chosen number populates the active phone field. The name
  and other fields are unchanged; the value is not saved until the form's
  normal Save action. Cancelling leaves existing text unchanged.
- A dedicated Flutter MethodChannel `saqia/contacts` communicates with
  `MainActivity`. Kotlin uses `Intent.ACTION_PICK` with
  `ContactsContract.CommonDataKinds.Phone.CONTENT_TYPE` and an Activity
  Result API launcher. Only the returned phone-row URI is queried.
- **No `READ_CONTACTS` permission** and no new pub dependency: the selected
  phone URI carries temporary access. No address-book scan, upload or sync.
- Non-Android platforms continue offering a plain editable phone field.
- Explicit errors for missing contact app, inaccessible or empty phone;
  multiple launches are guarded against.
- Test file: `test/contact_phone_field_test.dart` covers selection, cancel,
  errors and non-Android behavior.

## Validation required

Run `flutter test test/contact_phone_field_test.dart` and `flutter analyze`
in Flutter CI, plus a manual Android device test to confirm that the system
picker opens, a phone value fills the form, and Save persists it. Android
tools/Flutter SDK are not available in the connector session.
