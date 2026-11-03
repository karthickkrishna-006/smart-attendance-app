# Project status: what is verified and what is not

**Nothing in this project has been compiled, run or emulator-tested yet.** The development environment had no access to the Flutter SDK, Gradle, Android repositories, pub.dev or the Firebase emulator, and no GitHub connection. Expect the first CI run to possibly report compile errors, analyzer warnings or rules-test failures that need small fixes. Do **not** present the app as functional until CI is green **and** the device checklist (`TECHNICAL.md` §5) passes on a real phone.

## Verified in the development environment
| Item | How it was verified |
|---|---|
| `google-services.json`: package `in.cit.smartattendance`, OAuth client with SHA-1 `31e33e99…0fac` | File inspected |
| Signing key fingerprints | `keytool` |
| Face model: file, size 5,233,552 B, SHA-256 `be4bc7cf…354854`, tensors `input float32[1,112,112,3]` → `embeddings float32[1,192]` | Flatbuffer parsed directly; licence files copied from source repositories |
| Gradle wrapper files are the official Gradle v8.10.2 files (jar SHA-256 `2db75c40…448046`) | Fetched from the `gradle/gradle` repository at tag `v8.10.2`; CI also runs `gradle/actions/wrapper-validation` |
| Dart source: all imports resolve; brackets balance; no obviously unused imports | Static scripts (not the Dart analyzer) |
| ZIP contains no keystore, passwords or `key.properties` | Scanned |

## Not yet verified
| Item | Status |
|---|---|
| Dart compilation and `flutter analyze` (now fails on warnings) | ❌ Not run |
| Gradle build, APK signing | ❌ Not run (CI is set up to do it and verify the signature) |
| Firestore / Storage rules | ❌ Written and covered by 16 emulator tests in `tests/rules`, but **the tests themselves have not run yet** |
| Google Sign-In, email login/registration/reset on a device | ❌ |
| Admin bootstrap with your Gmail | ❌ (needs your email in the rules + device test) |
| Camera, ML Kit detection, face matching quality | ❌ Threshold not calibrated |
| GPS, live tracking, OSM tiles | ❌ |
| Cloud Storage uploads | ❌ Also requires the Blaze plan |
| Dashboard, reports, alerts, tasks, activities | ❌ |

## Remaining limitations (by design or pending external input)
- **Client-side verification trust:** face matching and the GPS/GIS check run on the phone. The rules enforce consistency, server time, today's IST date, the assigned boundary and immutability, but they can't prove a tampered app didn't fake the inputs. Server-side verification needs Cloud Functions (Blaze). See `SECURITY_SETUP.md`.
- **Face model:** demonstration grade. The training-data provenance of the `.tflite` is undocumented (see `MODEL_CARD.md`). There's no liveness or anti-spoofing beyond an eyes-open check, and the threshold is uncalibrated.
- **Photo evidence** needs the Blaze plan and is disabled by default (`STORAGE.md`).
- **Location tracking** is foreground only, while the app is open.
- **Notifications** are in-app real-time only; there's no push when the app is closed.
- **Offline check-in:** Firestore queues the write, but the Submit button waits for server confirmation, so it keeps spinning until the network returns.
- **Lateness near the cut-off** is decided by the server's IST clock; if the phone clock disagrees, the app resubmits as "late".
- **Attendance dates** assume phones are set to Indian time (IST).
- **Official data** (worker master list, employee ID format, GIS boundaries, Block/Taluk hierarchy) has not been provided; demo data is synthetic and labelled.
- **Attendance business rules** are defaults pending project approval.
- **Android only.** No iOS, web or desktop build.
