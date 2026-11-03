# Technical documentation

## 1. Data model (Cloud Firestore)

All timestamps are Firestore `Timestamp`. `date` fields use local `yyyy-MM-dd`. Every collection can hold `synthetic: true` records, which the UI labels as demo data.

| Collection | Document ID | Key fields |
|---|---|---|
| `users` | Firebase UID (login users) or auto ID (record-only workers) | `name, email, phone, role, status` (`pending_approval`/`active`/`inactive`/`suspended`), `employeeId` (human-facing), `category, supervisorId, boundaryId, hasLogin, faceEnrolled, faceEnrolledAt, faceConsent, synthetic`. **No biometric data.** |
| `face_templates` | uid | `embedding[192], dims, model, consent, enrolledBy, enrolledAt`. **Readable only by the owner** |
| `boundaries` | auto | `name, district, block, panchayat, layer, attributeColumn, attributeValue, source, synthetic, points[{lat,lng}]` |
| `attendance` | `{uid}_{yyyy-MM-dd}` (one per worker per day) | `uid, name, employeeId, date, status, boundaryId, checkIn{…}, checkOut{…}, reviewNote, reviewedBy` |
| `verifications` | auto | type `face` → `worker_id, verified, similarity, threshold, status, message, timestamp, model`; type `location` → `status, lat, lng, accuracy, boundaryId` |
| `locations` | uid | Live position: `lat, lng, accuracy, mocked, geoStatus, distanceToEdge, onDuty, updatedAt` |
| `tasks` | auto | `title, description, assignedTo, assignedName, priority, status, dueDate, createdBy` |
| `activities` | auto | `taskId, uid, visitType, description, measurement, lat, lng, accuracy, geoStatus, images[Cloud Storage paths], reviewStatus, reviewNote` |
| `alerts` | auto or deterministic dedup ID | `type, description, severity, uid, workerName, taskId, status, resolution, resolvedBy` |
| `audit_logs` | auto | `action, target, details, actorUid, actorEmail, createdAt` (append-only) |
| `settings/config` | — | `lateAfter, missingAfter, faceThreshold, maxGpsAccuracy, requireFace, requireBoundary, rules{…}` |
| `meta/bootstrap` | — | `adminUid`: write-once record of the allow-listed initial Admin |

The check-in/out point (`checkIn` / `checkOut`) holds: `time, lat, lng, accuracy, gpsTime, mocked, geoStatus, geoMessage, distanceToEdge, boundaryId, boundaryLayer, attributeColumn, attributeValue, boundarySynthetic, faceStatus, similarity, faceThreshold, faceMessage`. No images.

Administrative hierarchy: District → Block → Panchayat → Location (boundary). Taluk is not modelled separately, pending the confirmation required by Report §9.

## 2. API contract / authorisation

The Firebase SDK is the API transport. `firestore.rules` and `storage.rules` are the server-side authorisation layer. The full permission matrix, the bootstrap procedure and how to test the rules are in `SECURITY_SETUP.md`.

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
3. The face is cropped with an 18% margin, EXIF orientation is baked in, and the crop is resized to 112×112 and normalised to (p − 128) / 128, matching the source project. The model's tensor shapes are checked at load time.
4. MobileFaceNet produces an embedding, which is L2-normalised.
5. Enrolment averages 2 samples, which must match each other at ≥ 0.5. Verification compares the selfie by cosine similarity against the configured threshold.
6. Outcome states: `verified`, `failed`, `no_face`, `not_enrolled`, `unavailable`. Only `verified` counts as a pass, and every attempt is logged to `verifications`.

The model file is bundled and pinned (SHA-256 verified in CI). Specification and licences: `third_party/mobilefacenet/MODEL_CARD.md`. Selfies are deleted right after processing; only the template is stored, in `face_templates/{uid}`.

## 5. Tests

| Type | What | How |
|---|---|---|
| Security rules | 16 emulator tests: bootstrap, sign-up, profile privacy, biometric privacy, attendance tampering, settings, tasks, activities, alerts, audit, storage | `tests/rules` (CI job `rules-test`) |
| Unit | Point-in-polygon, distance to edge, area, `checkLocation` (inside, outside, low accuracy, no boundary), settings merge, time parsing | `flutter test` (runs in CI on every build) |
| Static | `flutter analyze --no-fatal-infos` (warnings and errors fail the build) | CI |
| Build | Release APK compiles, signature verified against the Firebase SHA-1 | CI |
| Device (manual) | Google Sign-In, email login, register, reset, camera, GPS, live map, check-in/out, alerts | Checklist below, run on a real phone |

### Device test checklist
- [ ] App installs and opens; splash appears, then login.
- [ ] *Continue with Google* with the allow-listed Gmail → Admin dashboard. With another account → "Awaiting approval".
- [ ] Register with email: account is created and a verification email is sent.
- [ ] Forgot password: reset email arrives.
- [ ] Settings → Load demo data: dashboard numbers and charts populate.
- [ ] Live Map shows OSM tiles, purple SYNTHETIC zones and worker pins.
- [ ] Worker: enrol face (2 selfies), then check in. Similarity % and an inside/outside result are shown.
- [ ] A different person's face → `failed` plus an alert on the admin's phone.
- [ ] Check out: duration shown, worker goes off duty on the map.
- [ ] Submit an activity (with photos only if Storage/Blaze is enabled) → supervisor approves it → task becomes completed.
- [ ] A worker can't see other workers in any screen, and the Rules Playground denies reading another user's `face_templates` document.
- [ ] Deny location permission → a clear message with a Settings button.
- [ ] Airplane mode → records queue offline and sync when back online.

## 6. Known limitations

See `STATUS.md` (kept up to date as the single list of limitations).
