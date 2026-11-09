# Smart Attendance and Field Activity Monitoring (v2)

Android app (Flutter) with a Firebase backend for field workers and the officers who supervise them in Chengalpattu District (195 village panchayats). One app, two experiences: field workers get a simple five-tab app; officers get a menu with only what their role may see.

- **Setup:** see [docs/SETUP.md](docs/SETUP.md)
- **Role-by-role test checklist:** see [docs/TESTING.md](docs/TESTING.md)
- **What is not done or not verified:** see [docs/KNOWN-LIMITATIONS.md](docs/KNOWN-LIMITATIONS.md)

The old app in the repository root is separate and unchanged. v2 has its own Android package `in.cit.smartattendance.v2` and its own Firebase project.

## What each role gets

| Role | Screens |
| --- | --- |
| Field worker | Home (duty on/off, today, recent work), Attendance, Activity (camera reports), Tasks, Profile |
| District Collector | Overview, Live monitoring, Attendance, Field activities, Coverage, Reports, Alerts (whole district) |
| AD / higher officer | the above in their area, plus Tasks (create, approve) |
| Zonal Secretary | the above in their zone, plus Tasks (create, approve) |
| Supervisor | the above for assigned areas; reviews reports; creates tasks if switched on |
| Organisation admin | Overview, Attendance, Employees (adds own workers), Field activities, Reports, Alerts (own organisation; no live location) |
| Auditor | Overview, Attendance, Field activities, Coverage, Reports, Alerts, Audit log (no live location) |
| System administrator | Employees, Setup (areas, boundaries, organisations, access, settings, demo data), Audit log (no operational data) |

## Main flows

- **Sign-in:** Google or e-mail. People are added in advance by e-mail (Employees) and get exactly their role and area on first sign-in, with no approval step. `krish.sep2006@gmail.com` becomes the first System administrator.
- **Attendance:**
  - Manual: "I am at work" shows where you are and whether the record will be Verified or checked, then you confirm.
  - Automatic: with **Start duty**, the first street entry of the day marks attendance, and **Stop duty** records the check-out.
  - Failed checks (outside, edge, poor GPS, mock location, outside hours) flag the record; they never block it.
- **Duty tracking:** only between Start and Stop duty, always with a visible notification. It records the live position, today's route, and **street entry and exit times** automatically (in after 1 minute inside a boundary, out after 2 minutes away). Officers see the entry and exit times; the worker's app does not list them.
- **Field activities:** up to 3 camera photos, GPS, an optional task link. Reviewed by AD, Zonal Secretary or Supervisor: approve, redo (with reason), or reject (with reason).
- **Tasks:** assigned to a street or area by AD or Zonal Secretary (Supervisor/Collector if switched on); every worker in that area sees it.
- **Scope:** every list shows only the officer's area or organisation, enforced by the Firestore security rules, not only by the app.

## Repository layout

```
v2/
  lib/domain/      pure logic (permissions, geometry, attendance, street visits), unit-tested
  lib/data/        Firebase access (session, attendance, work, duty tracking, demo data)
  lib/features/    screens
  firestore.rules  security rules (the real access control)
  firestore.indexes.json  optional indexes (the app works without them)
  tests/rules/     Firestore emulator tests for the rules
  test/            Dart unit tests
  android/         Android project (package in.cit.smartattendance.v2)
.github/workflows/build-v2.yml  CI: analyze, unit tests, rules tests, signed APK build
```
