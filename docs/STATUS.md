# Project status: what is done, what is tested, what is not

**The app has NOT been compiled or run yet.** The development environment had no access to the Flutter SDK, Gradle or Android repositories, and no GitHub connection was possible. All code was written and statically checked (every import resolves, brackets and structure balance), but the Dart compiler has never processed it. Expect the first GitHub Actions build to possibly report a few compile errors that need small fixes. Don't present the app as fully functional until it has built and the device checklist (`docs/TECHNICAL.md` §5) passes on a real phone.

## Verification status

| Item | Status |
|---|---|
| Firebase project, package name, SHA-1 in `google-services.json` | ✅ Verified (file contents checked; SHA-1 matches the signing key) |
| Signing key fingerprints | ✅ Verified with `keytool` |
| GIS geometry (point-in-polygon, distance, area, location check) | ⚠️ Unit tests written; not yet executed |
| Dart / Flutter compilation | ❌ Not yet compiled |
| Android Gradle build and APK signing | ❌ Not yet run (CI workflow written to do it and to verify the signature) |
| Google Sign-In on a device | ❌ Untested; can only be tested on a real phone with the signed APK |
| Email/password login, registration, password reset | ❌ Untested |
| Firestore security rules | ❌ Not yet published or tested; written for the access model described in `TECHNICAL.md` §2 |
| Camera and ML Kit face detection | ❌ Untested on device |
| MobileFaceNet face model | ❌ The model file is downloaded at build time from a public GitHub repository; its accuracy and threshold have not been calibrated |
| GPS, live tracking, OpenStreetMap tiles | ❌ Untested on device |
| Dashboard, reports, alerts, tasks, activities | ❌ Untested; all read from live Firestore (no hard-coded values) |

## Implemented, but limited by design (see `TECHNICAL.md` §6)
- **Face verification:** a demonstration-grade open-source model. There's no liveness or anti-spoofing beyond an eyes-open check. A production model, threshold, consent and retention policy must be approved by the AI team.
- **Live location tracking:** only while the app is open (foreground). Background tracking isn't implemented.
- **Notifications:** in-app real-time banners and badges only. There are no push notifications when the app is closed, because that requires a paid Firebase plan for Cloud Functions.
- **Evidence photos:** compressed (≤ 220 KB) and stored inside Firestore, because Firebase Storage requires the paid plan.
- **Official data:** no official worker records, employee IDs or GIS boundaries were available. The demo generator creates **SYNTHETIC DEMO**-labelled data only. Official boundaries can be imported as GeoJSON.
- **Attendance rules** (late time, thresholds, status logic) are defaults that need project approval.
- **Taluk** is not modelled; the hierarchy is District → Block → Panchayat → Location, pending confirmation.

## Not included
- iOS, web and desktop builds (Android only).
- Firestore composite indexes: the queries were designed to need none, so `firestore.indexes.json` is empty. If Firestore ever reports "requires an index", follow the link in the error message to create it.
