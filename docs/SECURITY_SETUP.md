# Secure setup: first administrator, rules and approval flow

## How accounts and roles work
1. Anyone can sign in with Google or register with email. The new profile is always **Field Worker** with status **`pending_approval`**, and it sees an "Awaiting approval" screen with no access to data.
2. An Administrator or Supervisor activates the account (*Workers → filter "Pending approval" → Edit → Status: Active*) and assigns the boundary, employee ID and, for admins only, the role.
3. **Initial Administrator:** exactly one email address is written into `firestore.rules` (`bootstrapAdminEmail()`). When that account signs in with a **verified** email, the app asks the server to promote it to Admin. The rules allow this **once**, because `meta/bootstrap` is write-once. Every other account's attempt is rejected by the server, whatever the app sends.
4. Further admins or supervisors are appointed by an existing Admin. Admins can't change their own role or status, so nobody can lock themselves out by accident.

## One-time setup (do this before anyone else signs in)
1. Open `firestore.rules` and replace
   ```
   function bootstrapAdminEmail() { return 'REPLACE_WITH_ADMIN_EMAIL@gmail.com'; }
   ```
   with your own Gmail address, **in lower case**, exactly as Google shows it.
2. In Firebase console, go to **Firestore Database → Rules**, paste the whole file and click **Publish**.
3. If you use photo evidence (Blaze plan), also go to **Storage → Rules**, paste `storage.rules` and click **Publish** (see `STORAGE.md`).
4. Install the APK and choose **Continue with Google** with that Gmail. Google accounts are always email-verified, so this is the recommended path.
   - If you use email/password instead, open the verification link sent to your inbox first, then sign out and sign in again.
5. You should see the Admin dashboard. In *More → Audit trail* a `bootstrap_admin` entry appears.
6. **Optional hardening:** after step 5, change the email in the rules to `'bootstrap-disabled@invalid'` and publish again. Because `meta/bootstrap` already exists, re-bootstrapping is impossible either way; this just removes the address from the rules.

## Recovery (if the admin account is lost)
In Firebase console → Firestore, delete the document `meta/bootstrap`, put the new admin email into the rules, publish, and sign in with that account. Only a project owner with console access can do this.

## Permission matrix (enforced by `firestore.rules`)

| Data | Field Worker (own) | Supervisor | Admin | Auditor |
|---|---|---|---|---|
| User profiles | read own; edit own name/phone only | read all; edit **workers** (never roles) | full (not own role/status) | read |
| `face_templates` (biometric) | **read own only**; enrol once | create for a worker (worker present), **no read** | delete only, **no read** | none |
| Attendance | create today's own record only (server time, IST date, outcome must match the recorded verification results); add check-out once | read; review/override | full | read |
| Verifications log | create own, append-only | read | read, delete | read |
| Live locations | write own (server time) | read; demo writes | read; demo writes | read |
| Tasks | read assigned; move status assigned → in_progress → submitted only | full | full | read |
| Activities | create own for own task, status `pending` only | read; review | full | read |
| Alerts | raise own system alerts; read own | read; resolve | full | read |
| Boundaries | read | write | write | read |
| Settings / rules | read | read | write | read |
| Audit log | append own entries | read | read | read |
| Anything else | denied | denied | denied | denied |

Inactive, suspended and pending accounts have no data access beyond their own profile.

## Testing the rules
Automated tests are in `tests/rules/rules.test.mjs`. They cover admin bootstrap, self sign-up, profile privacy, biometric privacy, attendance tampering, settings, tasks, activities, alerts, the audit log and storage uploads.
- **In CI:** the `rules-test` job runs them on the official Firebase emulators on every push.
- **On your computer** (Node 20 and Java 17 required):
  ```bash
  cd tests/rules
  npm install
  npx firebase emulators:exec --config ../../firebase.json --only firestore,storage --project demo-smart-attendance "npm test"
  ```
- **Manually in the console:** Firestore → Rules → **Rules Playground**. Simulate, for example, a `get` on `/face_templates/<someone-else's-uid>` as an authenticated user. It must be denied.

## What the rules can't guarantee
Without server code (Cloud Functions, which need the Blaze plan), the face match and GPS check run **on the phone**. The rules make sure the stored outcome is consistent with the stored verification fields, that times are server timestamps, that the date is today in IST, that the boundary is the worker's assigned one, and that nothing can be edited afterwards. They **can't prove** that a modified (tampered) app didn't fake those fields. Supervisor review, the `verifications` log, mock-location alerts and the audit trail are the mitigations. A production deployment should move verification to a trusted server.
