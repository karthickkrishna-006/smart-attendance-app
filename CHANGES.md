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

# Revision 5: workers can use the app immediately (no approval step)

Requested change: new workers must reach the worker dashboard straight after signing in, without waiting for an administrator.

## Security rules (`firestore.rules`): needs publishing in the Firebase console
- Self sign-up may now create the profile with status `active` (still always role `worker`, empty employee ID, own email only). `pending_approval` is still accepted so older app versions keep working.
- New rule: a Field Worker whose profile is `pending_approval` may change **only** its own `status`, **only** to `active`. Inactive/suspended accounts (blocked by an admin), and pending supervisor/admin records, cannot use this.
- Unchanged: nobody can give themselves admin/supervisor/auditor; workers can only read their own data; admin bootstrap is unchanged.

## App
- `lib/services/auth_service.dart`: new profiles are created `active`. If the deployed rules are still the old ones, it falls back to `pending_approval`, so registration never breaks whichever is published first. Older pending worker accounts activate themselves on sign-in (`_activateLegacyPending`). The Revision 4 single-flight fix is unchanged.
- `lib/screens/auth/auth_gate.dart`: the "Awaiting approval" screen is gone from the normal flow. A pending screen only appears if the new rules are not yet published, and says so. Inactive/suspended accounts still see a blocked screen.
- `lib/screens/admin/worker_edit_screen.dart`: "Pending approval" is no longer offered as a status (only shown for older accounts that have it). Use Inactive or Suspended to block someone.
- `lib/screens/worker/worker_home.dart`: new "Work area not assigned yet" notice for workers without a panchayat.

## Tests (`tests/rules/rules.test.mjs`)
- Updated: self sign-up as an active worker succeeds; choosing admin/supervisor role, suspended status, an employee ID, another email, or another user's profile fails.
- New: older app versions can still create a pending account; a pending worker can activate itself but cannot change its role or boundary or activate someone else; suspended/inactive accounts and pending supervisors cannot self-activate; suspended workers cannot read settings or write attendance.

## Workflows
- The Revision 4 workflow files did not reach the repository (GitHub's web uploader skipped the `.github` folder). They are included again unchanged.

## Not yet verified
- Rules tests, compilation and APK build run in GitHub Actions. Device testing is still required. The new rules must be published by the project owner.

# Revision 6: security-rules review for tracking and photo evidence

No rules have been published. The project owner reviews and publishes them.

## Checked against the code
- Collections used by the app: `users`, `face_templates`, `boundaries`, `settings` (only `settings/config`), `meta` (only `meta/bootstrap`), `attendance`, `verifications`, `locations`, `tasks`, `activities`, `alerts`, `audit_logs`. Every one has a rule; there are no sub-collections.
- `tracking_sessions`, `worker_location_updates` and `panchayat_coverage` are **not used anywhere in the code**. They stay denied by the final "deny everything else" rule. Proposed rules for them are kept as a separate draft, to be added together with the tracking code.
- The camera/activity form opens only from a worker's assigned task, so the rule requiring an assigned task matches the current workflow.

## `firestore.rules`
- `locations/{uid}` (latest position only; no history is stored):
  - workers may only write their own document, with only the fields LiveTracker sends;
  - `uid` must match;
  - latitude and longitude must be in range;
  - the boundary must be the worker's own assigned boundary;
  - the time must be server time; no synthetic flag;
  - auditors stay read-only, and workers still cannot read anyone else's position.
- `activities` (photo evidence metadata):
  - workers may only send the fields the activity form sends, so review fields such as `reviewedAt` can no longer be injected;
  - `images` may contain only the worker's own photo paths for this activity (`evidence/{uid}/{activityId}/0|1|2.jpg`, in order), so another worker's or another activity's photos cannot be attached;
  - `taskId` must be a string.
- Nothing was loosened. Revision 5 (immediate worker access, self-activation of older pending accounts) and the admin bootstrap are unchanged.

## Tests (`tests/rules/rules.test.mjs`, now 22 tests)
- New live-location tests:
  - workers cannot write another worker's point, a mismatched uid, a fake boundary, the synthetic flag, an impossible latitude, unexpected fields, or a client timestamp;
  - the off-duty merge write succeeds;
  - a blocked account cannot write;
  - workers cannot read or list other workers' positions;
  - admins and auditors can read, and auditors cannot write.
- New evidence tests:
  - an activity with its own photos, or with no photos, succeeds;
  - another worker's photo, another activity's photo, wrong order, more than 3 photos, review fields, a non-list `images`, or someone else's task all fail;
  - other workers cannot read the activity.

## Not yet verified
- The rules tests have not run yet (the Firebase emulator is not reachable from the development environment). They run in GitHub Actions.

# Revision 7: field-duty tracking (sessions, background GPS, routes, coverage)

Approved access policy:
- **Admin:** whole district.
- **Supervisor:** assigned workers only.
- **Auditor:** duty summaries and coverage reports only, with no live positions or routes.
- **Worker:** own data only.

No rules have been published.

## How it works
- **Start / stop field duty** (`lib/screens/worker/duty_card.dart`):
  - The worker reads what is recorded and who can see it, agrees, and starts duty.
  - The card shows elapsed time, distance, points saved and % of time in the assigned area.
  - Duty ends with *Stop duty*, check-out or sign-out.
  - Tracking is **no longer started automatically at check-in**.
- **Background GPS with a visible notification** (`LocationService.dutyStream`):
  - A geolocator Android foreground service with a permanent "Field duty in progress" notification.
  - Android 13+ asks for notification permission (`MainActivity.java` channel).
  - New manifest permissions: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`, `WAKE_LOCK`.
  - `ACCESS_BACKGROUND_LOCATION` is not requested.
- **Session records** (`tracking_sessions`, `lib/services/tracking_service.dart`):
  - One record per duty period, holding owner, date, panchayat, supervisor, consent, start/end, end reason and running totals.
  - Today's session resumes if the app is reopened.
  - Sessions left open on earlier days are closed automatically.
- **Location history** (`worker_location_updates`):
  - A point is saved after moving 50 m, after 5 minutes, or when inside/outside changes (both adjustable by admins in Settings).
  - Each save is one batch: history point + live position (+ session totals every 10 points).
  - Writes queue on the phone when offline and upload later.
- **Route visualisation** (`lib/screens/common/route_screen.dart`):
  - A day picker; each session as a coloured line, with start/stop markers, activity photo markers (tap to open the activity) and the assigned boundary.
  - Opened from: the worker's *My route*, worker profile, and the live-map pop-up.
  - Auditors see duty summaries without the map.
- **Activity-linked GPS and photos** (`activity_form.dart`):
  - The activity, task status and an `activity` history point (with `activityId` and `sessionId`) are written in one batch.
- **Admin live map / dashboard:**
  - Role-scoped queries: admin = all; supervisor = `supervisorId == me`; auditor = no live positions.
  - "Today's route" button on each worker.
  - `LiveQueries` accepts `null` for data a role may not read.
- **Panchayat-wise coverage** (`lib/screens/admin/coverage_screen.dart`):
  - Per-day panchayats covered, workers, km, % time in area, with block and covered/not-covered filters.
  - Admins save the day to `panchayat_coverage`.
  - Auditors get a *Coverage* tab instead of the live map.
- **Synthetic demo data** (`demo_seed.dart`):
  - 3 days of walked routes per demo worker; one worker drifts outside the boundary.
  - All labelled synthetic and removed by *Clear demo data*.

## `firestore.rules`
- New: `tracking_sessions`, `worker_location_updates`, `panchayat_coverage`.
  - Field lists match the code exactly (checked by script).
  - Workers can only start their own session (today, own area, own supervisor, consent recorded).
  - Totals can never decrease; a session can be ended once and never reopened.
  - Route points go only into the worker's own *active* session, copying its area, supervisor and date.
  - Activity points are only accepted together with the worker's own activity.
  - History is never edited.
- `locations`:
  - Read: admin all, supervisor own workers, worker self; **auditors no longer have access**.
  - Workers cannot claim another supervisor.
  - Writes other than the worker's own are admin synthetic-demo only (supervisors can no longer write positions).
- `activities`: also accepts `mocked` and `sessionId`.

## Tests
- `tests/rules/rules.test.mjs` now has 29 tests.
- New tests cover: session start/totals/ending/stale-close; route points (wrong session, worker, area, supervisor, date, latitude, kind, client time; editing; after the session ended); activity points; who can read history and sessions (worker, supervisor in and out of area, auditor, admin); coverage reports.
- The live-location read test was updated for the auditor change.

## Not yet verified
- Flutter compile/analyze, `MainActivity.java` compilation, the rules tests and the APK build run only in GitHub Actions.
- Background tracking, the notification and battery use must be tested on a real phone.
- Known limit: if the worker swipes the app away, Android stops tracking. The session resumes when the app is reopened that day; otherwise it is closed the next day.

# Revision 8: review fixes for Revisions 5–7

1. **Stop-duty race fixed** (`lib/services/tracking_service.dart`):
   - The final route point is awaited, then the session is closed. Firestore sends one phone's writes in order, so the close can never reach the server before the final point.
   - Every write has a real outcome: `saved` (server confirmed), `queued` (no reply within 15 s; kept on the phone and uploaded later), or `failed` (with the reason).
   - `stopDuty()` returns a `StopResult`. The duty card and check-out only say "route saved" when the server confirmed it; otherwise they say exactly what happened (waiting for internet, final point failed, N points failed, record not closed).
   - Failed background points are counted and shown on the duty card instead of being only logged.
   - If closing the session fails, the app retries the close on next open instead of resuming tracking the worker had stopped.
2. **Notification permission** (`MainActivity.java`, `duty_card.dart`):
   - The native side now replies only after the worker answers the Android 13+ dialog (`onRequestPermissionsResult`).
   - It also reports `false` when notifications are switched off in settings.
   - No request is left hanging if the activity closes.
   - If notifications are off, the worker is told the notification may not appear and chooses *Open settings*, *Cancel* or *Start anyway*.
   - Consent text and comments no longer promise the notification is always visible.
3. **Admin email**:
   - `firestore.rules` now contains `krish.sep2006@gmail.com`.
   - The rules tests use the same address and stop with an error if the two ever differ.
   - The docs were updated.
4. **Registration details** (`lib/services/pending_details.dart`, `auth_service.dart`):
   - The single global `_pendingDetails` slot is replaced by a store keyed by normalised e-mail. One account's name/phone can no longer be written into another account's profile when sign-ins overlap.
   - Entries are used once, cleared when account creation fails, kept for a retry if profile creation fails, and expire after 10 minutes.
   - New unit test: `test/pending_details_test.dart`.
5. **Rules vs code**:
   - Writes: re-checked by script, all 10 write paths match.
   - Reads: every tracking/location/coverage query was checked against the rule that allows it (see the Revision 8 report).
6. **CI test report**: `build-debug-apk.yml` now writes a *Test report* to the build summary, even when a step fails:
   - rules tests passed/failed counts, with the names of failing tests;
   - the `flutter analyze` result and issues;
   - the `flutter test` result.

# Revision 9: CI signing integration (test builds)

Reviewed `android/app/build.gradle` and `.github/workflows/build-debug-apk.yml` together.

**Finding:** `build.gradle` on GitHub (`559712a`) already reads `CI_DEBUG_KEYSTORE_PATH/_PASSWORD/_KEY_ALIAS/_KEY_PASSWORD` into a separate `ciDebug` signing config, used for debug builds and for release builds when no `key.properties` exists. Test builds intentionally do **not** use `key.properties`: in this project its presence means "official production signing".

Gaps fixed:
- **`build.gradle`:** new `CI_REQUIRE_CI_DEBUG_SIGNING=true` (set by the test workflow) stops the build if the CI key is missing or blank, instead of silently signing with Android's default debug key.
- **`build-debug-apk.yml`:**
  - **New guard step:** fails if `android/key.properties` or `android/app/release.jks` exist (production material), or if `build.gradle` does not read the CI signing variables (catches an outdated `build.gradle`).
  - **Staging step validates before building:** the four secrets are present; the keystore, alias and store password open; the key password opens the key; and the key's SHA-1 is registered for `in.cit.smartattendance` in `google-services.json`, otherwise the build stops. Passwords reach `keytool` only through environment variables (`-storepass:env`, `-keypass:env`), never the command line. No `keytool` output is printed. The keystore is created with owner-only permissions.
  - **APK check now fails instead of warning:** each APK must be signed with exactly the staged CI key (and that key must be registered), with a valid SHA-1 and passing `apksigner verify`. Otherwise the build fails and nothing is uploaded.
  - **Cleanup (`if: always()`):** also removes the certificate dumps and Gradle's signing-config intermediates.
- **`build-apk.yml` (production) is unchanged:** it still writes `key.properties` from the production secrets, verifies the production SHA-1, and deletes the key in an `if: always()` step.
- **`docs/GITHUB_UPLOAD_AND_BUILD.md`:** the steps for registering the debug SHA-1 are corrected, and the new error messages are explained.

# Revision 10: interface fixes from phone screenshots

Revisions 5–9 built successfully on GitHub Actions (Build Debug APK run 12, commit `79a6b31`): rules tests, `flutter analyze`, `flutter test` and the signing checks passed; the phone APK download is 29.8 MB. Screenshots from the installed app showed these interface problems, now fixed:

- **Dashboard / Field coverage / worker home cards cut off or overflowing** with a large phone font: fixed-ratio grids are replaced by `StatGrid` (`lib/core/ui.dart`). Each row grows to its tallest card, cards in a row share the height, and long sub-lines wrap to 2 lines.
- **More screen tiles** use the same layout, so long titles and descriptions no longer clip.
- **Workers list showed no names** (the demo badge and status chip squeezed the name to zero width): each row now has the name on its own line, details below, then status and demo badge.
- **Outdated "awaiting approval… set status Active" banner** (approval was removed in Revision 5): replaced by a small note that older pending accounts activate automatically at next sign-in.
- **"New task" / "Add worker" buttons covering list content:** they shrink to an icon while scrolling down and expand when scrolling up.
- **Text size:** the phone's font size is respected up to 130 %; beyond that, navigation bars and buttons stop fitting.
- `.github/workflows/build-apk.yml`: the Revision 6 version (manual start only) is included again. GitHub still has the old version, which runs on every push and fails ("Build Android APK") because no production release key is configured.
