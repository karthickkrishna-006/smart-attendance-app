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
