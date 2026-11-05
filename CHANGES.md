# Changes in revision 2 (security and build review)

Nothing in this revision has been compiled or run (see `docs/STATUS.md`).

## 1. Gradle wrapper
- **Added** `android/gradlew` (mode 755, LF line endings), `android/gradlew.bat`, `android/gradle/wrapper/gradle-wrapper.jar`. These are the official files from `gradle/gradle` tag `v8.10.2` (commit `415adb9e`); jar SHA-256 `2db75c40782f5e8ba1fc278a5574bab070adccb2d21ca5a6e5ed840888448046`.
- **Added** `.gitattributes`, which keeps `gradlew` LF and marks binaries.
- **Workflow:** `gradle/actions/wrapper-validation@v4` checks the jar against Gradle's published checksums, and `chmod +x android/gradlew` runs before the build.
- **`.gitignore`** no longer excludes the wrapper files.

## 2. Admin security
- **No more "first user becomes Admin".** Every new account is a `worker` with status `pending_approval`.
- **The initial Admin** can only be the address in `bootstrapAdminEmail()` in `firestore.rules`, with `email_verified == true`, and only once (`meta/bootstrap` is write-once and created atomically).
- **Admins** can't change their own role or status.
- `lib/services/auth_service.dart`: new `ensureProfile` and `_tryBootstrapAdmin`, which refreshes the token so the verified-email claim is current.
- `lib/screens/auth/auth_gate.dart`: new "Awaiting approval" screen.
- **Admin UI:** `worker_edit_screen.dart`, `workers_screen.dart`, `dashboard_screen.dart` and `core/ui.dart` gain a pending-approval status, filter and banner.
- **Docs:** `docs/SECURITY_SETUP.md`.

## 3. Biometric privacy
- **Templates moved** to the new `face_templates/{uid}` collection. Rules: `get` by the owner only; no `list`; create once (owner, or staff for a worker); no update; delete by admin only (admins can't read it).
- **Profiles** (`users`) now hold only `faceEnrolled` flags.
- **No face images are stored:** the profile thumbnail (`photo`) and the attendance `faceThumb` were removed, and selfie temp files are deleted after processing.
- **`users` read access** is now limited to the owner plus admin/supervisor/auditor (it was "any signed-in user").
- **Files:** `face_service.dart` (new `FaceTemplates`), `models.dart`, `face_enroll_screen.dart`, `check_flow_screen.dart`, `worker_detail_screen.dart`, `profile_screen.dart`, `worker_home.dart`, `workers_screen.dart`.

## 4. Firestore rules review
- **`firestore.rules` rewritten** with least-privilege rules per collection.
- **Workers can't:**
  - change role, status, employee ID or boundary
  - read other profiles
  - write other workers' data, or attendance for another day
  - change attendance status after creation
  - check out twice
  - set an outcome inconsistent with the recorded face/GIS results (and "present" is checked against the server IST clock and the late cut-off)
  - back-date records (server timestamps are required)
  - self-approve activities, resolve alerts, change settings, or edit/delete audit logs
- **Unknown collections** are denied.
- **Code:** client timestamps switched to `FieldValue.serverTimestamp()`. The check-in flow resubmits as "late" if the server rejects "present" near the cut-off.
- **Tests:** added `tests/rules/rules.test.mjs` (16 emulator tests) and `tests/rules/package.json`, plus `.firebaserc` and emulator settings in `firebase.json`.

## 5. GitHub Actions
- **`|| true` removed.** The step is now `flutter analyze --no-fatal-infos`, so warnings and errors fail the build.
- **Added `analysis_options.yaml`**, which excludes `build/` and the Node test folder.
- **New `rules-test` job** runs the security tests on the Firebase emulators.
- **Signing material** is deleted at the end of the job, and the release includes `SHA256SUMS.txt`.
- **Fixed** an unused local variable in `demo_seed.dart` that would now fail analysis.

## 6. AI model
- **Model bundled and pinned**, no longer downloaded from a URL list: `assets/models/mobilefacenet.tflite`, from `MCarlomagno/FaceRecognitionAuth@82372440`, 5,233,552 bytes, SHA-256 `be4bc7cf…354854`, checked in CI.
- **Tensor specs read from the file:** input float32 `[1,112,112,3]`, output `embeddings` float32 `[1,192]`. The app checks them at load time.
- **Pre-processing corrected** to `(p − 128) / 128`, matching the source project.
- **Added** `third_party/mobilefacenet/MODEL_CARD.md` and both licences (BSD-3-Clause for the redistributing repo, Apache-2.0 for the upstream MobileFaceNet_TF). The training-data provenance gap is documented.

## 7. Evidence images
- **No Base64 images in Firestore anymore.** Photos go to Cloud Storage at `evidence/{uid}/{activityId}/{0-2}.jpg`, and Firestore stores only the paths. Reads go through the SDK so the rules are enforced; public download URLs aren't used.
- **Added** `lib/services/evidence_storage.dart`, `storage.rules` (owner-only, JPEG only, ≤ 1.5 MB, write-once) and the `firebase_storage` dependency.
- **Billing:** Cloud Storage needs the **Blaze plan**, so the feature is off by default with an Admin switch in Settings. Without Blaze, activities are recorded without photos. Details: `docs/STORAGE.md`.
- **Files:** `activity_form.dart`, `activity_tile.dart`, `task_detail_screen.dart`, `settings_screen.dart`, `db.dart`.

## Documentation
- **Updated:** `README.md`, `docs/STATUS.md`, `docs/TECHNICAL.md`, `docs/GITHUB_UPLOAD_AND_BUILD.md` (Step 0: set the admin email; new troubleshooting rows).

# Revision 3: rules-test setup fix

- **Cause of the 6 failures:** several tests called `context.firestore()` more than once on the same `RulesTestContext`. Each call re-runs `connectFirestoreEmulator()`, which throws "Firestore has already been started and its settings can no longer be changed". The affected tests were admin bootstrap, self sign-up, profile privacy, supervisors/admins, face-template enrolment, and pending accounts / pending storage.
- **Fix** (`tests/rules/rules.test.mjs` only): a new `as(uid, email, verified)` helper creates one context per test user and lazily creates its Firestore and Storage handles exactly once (`??=`), so emulator settings are applied before any operation and never again.
- **Isolation:** `beforeEach` now also calls `env.clearStorage()` (Firestore was already cleared).
- **No rule changes:** `firestore.rules` and `storage.rules` are unchanged, and all 16 assertions are unchanged.
- **Output:** `tests/rules/package.json` uses `--test-reporter=spec`, which lists every test name and result in the CI log.
- **Not yet run:** these tests have NOT been executed by the developer, because the Firebase emulator and npm registry were not reachable from the development environment. The GitHub Actions `rules-test` job is the first execution.

# Revision 4: first-time sign-in fix, activity and face-status fixes, smaller test APKs

## Sign-in (the "only the admin can sign in" problem)
- **Cause:** on a brand-new account, the sign-in code (`signInGoogle` / `register`) and `AuthGate` both called `ensureProfile` at the same moment. Both saw "no profile yet" and both wrote one; the security rules (correctly) rejected the second write. A new worker therefore saw "permission denied", "Could not load your profile", or a Google login screen that closed with no message. Existing accounts (such as the admin) were unaffected because their profile already existed.
- **Fix** (`lib/services/auth_service.dart`): `ensureProfile` is now single-flight, so concurrent callers for the same user share one operation. The name and phone typed on the registration form are remembered before the account is created, so they are used whichever caller runs first. If a create is still rejected because the profile was created elsewhere in the meantime, the app re-checks the server instead of failing.
- **Google diagnostics:** the Google Sign-In error is logged, a missing ID token gives a clear message, and cancelling the account picker now shows a message instead of silently closing (`lib/screens/auth/login_screen.dart`).

## Activity submission (`lib/screens/common/activity_form.dart`)
- The activity record and the task-status change are now written in one batch (both succeed or neither).
- The task status only moves forward along transitions the rules allow (assigned → in_progress → submitted). Previously, re-submitting on a submitted/completed task tried to set it back to `in_progress`; the rules rejected that and left the activity saved but the task unchanged.

## Face verification status (`lib/screens/worker/check_flow_screen.dart`, `lib/core/ui.dart`)
- "Not enrolled" and "could not read the template" are now reported separately (`not_enrolled` vs `unavailable`). Neither is treated as verified; both send attendance to `pending_verification`.
- `not_enrolled`, `not_performed` and `no_face` are shown with the warning colour.

## Build and APK size
- `android/app/build.gradle`: release builds without a release key are signed with the CI test key (registered in Firebase) instead of the local Android debug key, so Google Sign-In works in test release APKs. The real release key is still used whenever `key.properties` exists.
- `.github/workflows/build-debug-apk.yml` (phone-testing builds):
  - Flutter 3.27.4 (same as the release workflow), `flutter analyze --no-fatal-infos`, and a non-blocking formatting report.
  - Builds a 64-bit debug APK plus **per-CPU release APKs** (64-bit and older 32-bit phones) instead of one large universal debug APK. x86 emulator code is no longer included.
  - New verification step for every APK: package name must be `in.cit.smartattendance`; signature verified; warns if the signing SHA-1 is not registered in `google-services.json` (the usual cause of Google Sign-In "error 10"); writes a size table and the 15 largest files in the APK to the job summary.
- `.github/workflows/build-apk.yml` (official release key): now runs only when started by hand or for pull requests, so a missing release key no longer fails every push. Also builds an Android App Bundle (`.aab`) for future Google Play use.

## Not changed
- `firestore.rules` and `storage.rules` are unchanged. The placeholder admin email in the repository copy is intentional: the rules tests replace it, and the deployed copy holds the real address.

## Not yet verified
- Compilation, `flutter analyze`, unit tests, rules tests and APK sizes are verified by the first GitHub Actions run. Device testing is still required.
- In the development environment, the changed Dart files were parse-checked with the Dart SDK, the workflow YAML was validated, and the APK verification script was dry-run with stand-in tools.
