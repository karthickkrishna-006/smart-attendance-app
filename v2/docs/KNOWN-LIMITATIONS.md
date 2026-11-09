# Known limitations (honest status)

## Not verifiable in the preparation environment

- The Flutter SDK, Android build and Firebase emulator could not run there.
- Pure logic was tested by running it: 47 tests for permissions, geometry, attendance and street visits.
- The UI and data code was checked with the Dart analyzer against the app's own classes, and every Flutter, flutter_map and geolocator API used was checked against the exact package versions.
- **The real verification is CI:** `flutter analyze`, `flutter test`, the Firestore rules tests (25) and the APK build. Then the phone test in docs/TESTING.md.

## Behaviour to know

- Location checks run on the phone (free plan: no server code), so records say `evaluatedBy: device`. The security rules stop records from claiming more than their data supports, but they cannot recheck the geometry.
- Duty tracking runs as a foreground service while the app process lives. If Android kills the app or the phone restarts, the worker must tap **Start duty** again; the open street visit then has no exit time.
- Android 13+: if the notification permission is refused, tracking still runs, but its notification may be hidden. The app does not yet ask for the notification permission itself.
- Live map tiles come from OpenStreetMap (internet needed; attribution is shown). Heavy official use should move to a dedicated tile service.
- Photos are stored in Firestore (free plan, at most 600 KB each, 3 per report). The free Firestore storage is 1 GB in total.
- Reports: a 7-day table with Copy (CSV text). There is no PDF or Excel export yet.
- **Not built yet:**
  - attendance corrections (request/approve);
  - escalations;
  - Zonal Secretary assigning workers to streets (the System administrator does it);
  - face verification;
  - push notifications.
- Demo data: areas and boundaries named "Demo …" stay after **Remove demo records** (areas can never be deleted, by design); the attendance, tasks, reports, positions, routes and visits are removed.
- Tamil text needs review by a native speaker. Administrator and officer detail screens are partly English.
