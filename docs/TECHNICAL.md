# Technical documentation

## 1. Data model (Cloud Firestore)

All timestamps are Firestore `Timestamp`. `date` fields use local `yyyy-MM-dd`. Every collection can hold `synthetic: true` records, which the UI labels as demo data.

| Collection | Document ID | Key fields |
|---|---|---|
| `users` | Firebase UID (login users) or auto ID (record-only workers) | `name, email, phone, role, status, employeeId` (human-facing), `category, supervisorId, boundaryId, hasLogin, faceEmbedding[192], photo` (96 px face thumbnail), `faceEnrolledAt, faceConsent, synthetic` |
| `boundaries` | auto | `name, district, block, panchayat, layer, attributeColumn, attributeValue, source, synthetic, points[{lat,lng}]` |
| `attendance` | `{uid}_{yyyy-MM-dd}` (one per worker per day) | `uid, name, employeeId, date, status, boundaryId, checkIn{…}, checkOut{…}, reviewNote, reviewedBy` |
| `verifications` | auto | type `face` → `worker_id, verified, similarity, threshold, status, message, timestamp, model`; type `location` → `status, lat, lng, accuracy, boundaryId` |
| `locations` | uid | Live position: `lat, lng, accuracy, mocked, geoStatus, distanceToEdge, onDuty, updatedAt` |
| `tasks` | auto | `title, description, assignedTo, assignedName, priority, status, dueDate, createdBy` |
| `activities` | auto | `taskId, uid, visitType, description, measurement, lat, lng, accuracy, geoStatus, images[base64 JPEG ≤ 220 KB], reviewStatus, reviewNote` |
| `alerts` | auto or deterministic dedup ID | `type, description, severity, uid, workerName, taskId, status, resolution, resolvedBy` |
| `audit_logs` | auto | `action, target, details, actorUid, actorEmail, createdAt` (append-only) |
| `settings/config` | — | `lateAfter, missingAfter, faceThreshold, maxGpsAccuracy, requireFace, requireBoundary, rules{…}` |
| `meta/bootstrap` | — | `adminUid`: makes the first user Admin |

The check-in/out point (`checkIn` / `checkOut`) holds: `time, lat, lng, accuracy, gpsTime, mocked, geoStatus, geoMessage, distanceToEdge, boundaryId, boundaryLayer, attributeColumn, attributeValue, boundarySynthetic, faceStatus, similarity, faceThreshold, faceMessage, faceThumb`.

Administrative hierarchy: District → Block → Panchayat → Location (boundary). Taluk is not modelled separately, pending the confirmation required by Report §9.

## 2. API contract / authorisation

The Firebase SDK is the API transport. `firestore.rules` is the server-side authorisation layer:

- Every request needs a valid Firebase ID token. Inactive and suspended accounts are denied.
- Workers can read and write only their own attendance, verifications, location and activities. They can only add check-out to their own attendance, and can only move their own tasks to `in_progress` or `submitted`.
- Workers can enrol their face once. Re-enrolment requires an admin to delete the old reference.
- Supervisors manage workers (but not roles), tasks, boundaries, reviews and alerts.
- Admins have full access, including roles and settings.
- Auditors have read-only access to everything except settings writes.
- Audit logs are append-only; nobody can edit or delete them.

## 3. Business rules (configurable in Settings)

| Rule | Default |
|---|---|
| Late after | 09:30 |
| Missing-attendance alert after | 11:00 |
| Face match threshold (cosine) | 0.60 |
| Max GPS accuracy | ±50 m |
| Require face / require boundary | on / on |

How the check-in status is decided:
- Face failed, or location outside the boundary (when the boundary is required) → `rejected`.
- Face not performed or unavailable, or location unverifiable (no boundary or poor accuracy) → `pending_verification`.
- Otherwise `late` if after the late time, else `present`.

Supervisors can override any status, with a mandatory note, and the change is audited.

## 4. AI face pipeline

1. Selfie from the front camera (`image_picker`).
2. ML Kit detection, which requires exactly one face, |yaw| and |roll| ≤ 25°, and eyes open.
3. The face is cropped with an 18% margin, EXIF orientation is baked in, and the crop is resized to the model input (read from the TFLite tensor shape, typically 112×112) and normalised to (p − 127.5) / 128.
4. MobileFaceNet produces an embedding, which is L2-normalised.
5. Enrolment averages 2 samples, which must match each other at ≥ 0.5. Verification compares the selfie by cosine similarity against the configured threshold.
6. Outcome states: `verified`, `failed`, `no_face`, `not_enrolled`, `unavailable`. Only `verified` counts as a pass, and every attempt is logged to `verifications`.

The model file is downloaded in CI from a public GitHub source. The URL is recorded in each release note.

## 5. Tests

| Type | What | How |
|---|---|---|
| Unit | Point-in-polygon, distance to edge, area, `checkLocation` (inside, outside, low accuracy, no boundary), settings merge, time parsing | `flutter test` (runs in CI on every build) |
| Static | `flutter analyze` | CI |
| Build | Release APK compiles, signature verified against the Firebase SHA-1 | CI |
| Device (manual) | Google Sign-In, email login, register, reset, camera, GPS, live map, check-in/out, alerts | Checklist below, run on a real phone |

### Device test checklist
- [ ] App installs and opens; splash appears, then login.
- [ ] *Continue with Google* shows the account picker and signs in (first user becomes Admin).
- [ ] Register with email: account is created and a verification email is sent.
- [ ] Forgot password: reset email arrives.
- [ ] Settings → Load demo data: dashboard numbers and charts populate.
- [ ] Live Map shows OSM tiles, purple SYNTHETIC zones and worker pins.
- [ ] Worker: enrol face (2 selfies), then check in. Similarity % and an inside/outside result are shown.
- [ ] A different person's face → `failed` plus an alert on the admin's phone.
- [ ] Check out: duration shown, worker goes off duty on the map.
- [ ] Submit an activity with photos → supervisor approves it → task becomes completed.
- [ ] Deny location permission → a clear message with a Settings button.
- [ ] Airplane mode → records queue offline and sync when back online.

## 6. Known limitations and external dependencies

- **Official data not supplied:** worker master data, the employee ID format and GIS boundary datasets must come from authorised sources. Everything shipped is synthetic and labelled as such.
- **Face model:** the open-source MobileFaceNet is suitable for demonstration. Production use needs an approved model, a calibrated threshold, a liveness/anti-spoofing check (only an eyes-open check is implemented) and a biometric retention policy agreed with the AI team (Report §5.3).
- **GPS:** location is tracked while the app is open (foreground). Background tracking with a persistent notification is not implemented. Mock-location detection relies on Android flags and can be bypassed on rooted devices.
- **Evidence images:** stored compressed inside Firestore documents, because Firebase Storage needs the paid Blaze plan. Moving to Cloud Storage is recommended for production.
- **Push notifications:** alerts are delivered in-app in real time while the app is open. FCM push for a closed app would need Cloud Functions (Blaze plan).
- **Attendance business rules** are defaults and must be approved by the project team (Report §15).
- **OpenStreetMap tiles** are for light/demo use under the OSM tile usage policy. A production deployment should use its own tile server or a commercial provider.
