# Smart Attendance v2 (rebuilt from scratch)

This folder is the new application, built from the Phase 1 requirement analysis. The old app in the repository root is untouched and keeps building until v2 replaces it.

**Stage: Phase 4 (Foundation) + Phase 5.1 (Geofences) + Phase 5.2 (Attendance, assisted).**

- Foundation: sign-in, roles, the area hierarchy, organisations, adding people, role-based navigation, security rules, cloud build.
- Geofences: administrators add circle boundaries or import official GeoJSON (Setup → Boundaries). Large boundaries are simplified to at most 1,000 points.
- Attendance: the worker taps "I am at work", sees where they are, the GPS accuracy and whether the record will be Verified or checked (with plain reasons), then confirms. Failed checks flag; they never block. One record per worker per day; check-out once.

Not built yet (screens say so): automatic background geofence detection and live tracking, field activities and photos, tasks, dashboards, maps, reports, notifications.

## Decisions used (Phase 1 defaults, since no other answers were given)

| Question | Decision |
| --- | --- |
| Q1 Backend | Firebase free plan; designed so Cloud Functions can be added later |
| Q3 Officers | One Flutter app (Android now; web later from the same code) |
| Q16 Onboarding | People are added in advance by e-mail and get access the first time they sign in; no approval step. Open sign-up can be switched on in Setup |
| Q20 Projects | Uses the existing Firebase project for now; a separate production project is recommended before real data |

## Security model

- Signing in grants nothing. Access comes from **role assignments** (`roleAssignments/{uid}__{role}`), each covering areas of the district and, for third-party staff, one organisation.
- A role can only come from: a System administrator, the person's own pre-registration (exactly as prepared), open sign-up (field worker only, when switched on), or the one-time bootstrap of the first administrator.
- Every privileged write (roles, people, areas, organisations, settings) must create a **new** audit entry in the same batch, or the database refuses it. The audit log is append-only.
- A switched-off account or role loses access immediately.

## Starting up

1. Build and install the app (GitHub Actions: **Build v2 (new app)**).
2. Publish `v2/firestore.rules` in the Firebase console **only after the rules tests pass** and with your approval. Note: this replaces the rules of the old app in the same project.
3. Sign in with `krish.sep2006@gmail.com`. The app makes this account the first System administrator (only once; the rules allow this e-mail only).
4. In **Setup**: add the district, then blocks, zones and panchayats (official names only), and the organisations.
5. In **Employees**: add people by the e-mail they sign in with, choose their role and areas. They get access as soon as they sign in.

## Tests

- `test/domain_test.dart`: permission matrix, navigation, area scope, sign-in decisions (23 tests).
- `test/geo_attendance_test.dart`: distances, circle and polygon checks with GPS error, boundary simplification, GeoJSON import, attendance verdicts (15 tests).
- Both were also executed outside Flutter during development: 38 passed.
- `test/strings_test.dart`: Tamil/English completeness.
- `tests/rules/rules.test.mjs`: 17 Firestore emulator tests: the 12 foundation tests plus geofences (admin only, valid shape, real area) and attendance (honest "Verified", own area and organisation, one per day, today or yesterday only, server time, check-out once, who can read: worker, supervisor in area, organisation admin, Collector, auditor; not the System administrator).

## Known gaps in this stage

- Location checks run on the phone (no server on the free plan): records say `evaluatedBy: device`. The rules stop a record from claiming more than its own data supports, but cannot re-check the geometry.
- Duty hours use the defaults (09:00 to 17:00, 15 minutes late tolerance, 50 m GPS accuracy) until worker categories and schedules arrive.
- Whether Firestore accepts the officers' area-filtered attendance query (`array-contains-any` with `hasAny` in the rules) is checked by a rules test; if that test fails in CI, the query pattern will be changed.

- The Tamil text needs review by a native speaker.
- Administrator setup screens are English only.
- Organisation administrators can choose any area for their workers; "approved areas" per organisation is not modelled yet.
- Removing an unclaimed pre-registration is not audited.
- Rules do not yet check that a child area is exactly one level below its parent (the app does).
