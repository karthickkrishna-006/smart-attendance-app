# Revision 8 report: review fixes for Revisions 5–7

Base: GitHub `main` at commit `559712a` ("Apply revision 4 application fixes").
Revisions 5–7 had **not** been uploaded yet, so this package contains Revisions 5, 6, 7 and 8 together.

**Status: not complete and not device-tested.**
- Nothing in this package has been compiled by Flutter, built into an APK or run on a phone yet.
- The 29 Firebase rules tests have **not** been run: the Firebase emulator cannot be downloaded in the environment where this was prepared.
- All of these run in GitHub Actions after upload.
- No Firebase rules were deployed. No billing or paid service was changed.

---

## 1. Fixes requested in this review

| # | Request | Fix | Files |
|---|---|---|---|
| 1 | Stop-duty race; await final point; no false "saved" | The final point is awaited before the session is closed. Each write is reported as saved, queued (offline) or failed. `stopDuty()` returns `StopResult`. Messages only say "saved" on server confirmation. Failed background points are counted and shown. A failed close is retried instead of tracking resuming. | `lib/services/tracking_service.dart`, `lib/screens/worker/duty_card.dart`, `lib/screens/worker/check_flow_screen.dart` |
| 2 | Real notification-permission result; handle denial; no false promise | Java waits for `onRequestPermissionsResult` and also detects notifications switched off in settings; no request is left hanging. When denied, the worker can open settings, cancel or start anyway, and is told the notification may not appear. Wording corrected. | `android/.../MainActivity.java`, `lib/screens/worker/duty_card.dart`, `lib/services/location_service.dart` |
| 3 | Admin e-mail in rules | `bootstrapAdminEmail()` returns `krish.sep2006@gmail.com`. The tests use the same address and fail fast if they differ. Docs updated. | `firestore.rules`, `tests/rules/rules.test.mjs`, `docs/SECURITY_SETUP.md`, `docs/GITHUB_UPLOAD_AND_BUILD.md` |
| 4 | `_pendingDetails` could leak between accounts | Replaced by `PendingDetails`, keyed by normalised e-mail, single use, cleared on failure, 10-minute expiry. | `lib/services/pending_details.dart` (new), `lib/services/auth_service.dart`, `test/pending_details_test.dart` (new) |
| 5 | Rules match reads and writes | Writes checked by script; reads checked query by query (tables below). | — |
| 6–7 | Run the rules tests, analyze, unit tests and compile in CI | Cannot be run here (section 4). The CI now writes a **Test report** with counts and failing test names to the build summary. | `.github/workflows/build-debug-apk.yml`, `tests/rules/package.json` |

## 2. Rules vs application

### Writes (checked by script against the `hasOnly([...])` lists in `firestore.rules`)

| Write | Code location | Fields | Result |
|---|---|---|---|
| Start session | `TrackingService.startDuty` | 12 | match |
| Route point | `TrackingService._savePoint` | 16 | match |
| Live position | `TrackingService._savePoint` | 13 | match |
| Off-duty position | `TrackingService.stopDuty` | 2 | match |
| Session totals | `TrackingService._savePoint` | 4 | match |
| Session end | `TrackingService.stopDuty` | 7 | match |
| Session auto-close | `TrackingService._endSessionDoc` | 7 | match |
| Activity | `activity_form.dart` | 17 | match |
| Activity point | `activity_form.dart` | 17 | match |
| Coverage report | `coverage_screen.dart` | 14 | match |

### Reads (each query and the rule clause that allows it)

| Who | Query | Allowed by |
|---|---|---|
| Worker | `tracking_sessions` where `uid == me` and `status == active` (resume) | owner |
| Worker | sessions / points where `uid == me` and `date == day` (My route) | owner |
| Supervisor | sessions / points / `locations` where `supervisorId == me` (plus `uid`, `date`) | `canSeeTracking`: own workers |
| Admin | any tracking query | `isAdmin` |
| Auditor | `tracking_sessions` (route screen, coverage); `panchayat_coverage` | `isAuditor`. No `locations` or route-point query is ever made for auditors (`Db.trackingQuery` returns null). |
| Admin, Auditor | `panchayat_coverage` where `date == day` | `isAdmin() \|\| isAuditor()`. The query is not made for supervisors. |

## 3. Checks actually performed in the preparation environment

| Check | Tool | Result |
|---|---|---|
| All 49 Dart files parse | Dart SDK 3.13.7 formatter (`--language-version=3.6`) | 0 failures |
| Calls into the app's own classes (named arguments, required arguments, positional arguments) | Real Dart analyzer, app package only | 0 errors |
| `PendingDetails` | Real Dart analyzer `--fatal-infos`, plus 8 scenarios executed | No issues; 8/8 passed |
| `MainActivity.java` | `javac` 17 `-Xlint:all` against the real Android API 34 `android.jar` (Flutter classes replaced by stand-ins with the same signatures) | Compiled, 0 warnings |
| geolocator / flutter_map APIs used | Compared with the library source at the versions this project resolves (`geolocator_android` 4.6.2, `flutter_map` 7.0.2) | Parameters exist; the location foreground service is declared by the plugin; the default notification icon exists in the app |
| Rules file structure | Script | Brackets balanced; all functions defined; admin e-mail present |
| Rules test file | `node --check` | Valid, 29 tests |
| Test-report step | Dry run with real Node TAP output | Counts and failing-test names reported correctly |
| Workflows, manifest | YAML / XML parsers | Valid |

## 4. Not run, and why

| Check | Status |
|---|---|
| 29 Firebase rules tests | **Not run.** The emulator download (Google storage) is blocked here. They run in the *Run Firebase emulator security tests* step. |
| `flutter analyze`, `flutter test` | **Not run.** The Flutter SDK and pub.dev are blocked here. They run in CI. |
| Android/Gradle compilation, APK build | **Not run.** Runs in CI. |
| Device testing (background tracking, notification, battery, offline upload) | **Not done.** Needs a real phone. |

## 5. Still incomplete

- **Evidence still needed:**
  - a green CI build;
  - the test report from that build;
  - a device test of field duty.
- **Not built yet:**
  - the frontend redesign;
  - APK size optimisation, beyond the per-CPU split APKs from Revision 4;
  - official Chengalpattu panchayat boundaries (official GeoJSON/shapefile needed; nothing is invented).
- **Needs the paid Blaze plan, so not enabled:**
  - photo evidence storage;
  - push notifications.
- **Known limitation:** if a worker swipes the app away, Android stops tracking. The session resumes when the app is reopened the same day; otherwise it is closed automatically.
- **Possible future change:** auditors can still read check-in coordinates in attendance and verification records (historical records). This is unchanged; tell me if it should be restricted.
