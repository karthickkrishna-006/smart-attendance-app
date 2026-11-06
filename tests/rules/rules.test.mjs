// Security-rules tests for Firestore and Storage, run against the Firebase
// emulators:
//   cd tests/rules && npm install
//   npx firebase emulators:exec --only firestore,storage --project demo-smart-attendance "npm test"
// The CI workflow substitutes the admin e-mail placeholder with ADMIN_EMAIL below.

import { test, before, after, beforeEach } from 'node:test';
import { readFileSync } from 'node:fs';
import {
  initializeTestEnvironment, assertFails, assertSucceeds,
} from '@firebase/rules-unit-testing';
import {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs,
  serverTimestamp, writeBatch, Timestamp,
} from 'firebase/firestore';
import { ref, uploadBytes } from 'firebase/storage';

// Must equal bootstrapAdminEmail() in firestore.rules. The emulator uses fake
// tokens, so no real account is involved in the tests.
const ADMIN_EMAIL = 'krish.sep2006@gmail.com';
const PROJECT = 'demo-smart-attendance';

const rules = readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8');
if (!rules.includes(`bootstrapAdminEmail() { return '${ADMIN_EMAIL}'; }`)) {
  throw new Error('ADMIN_EMAIL in this test does not match bootstrapAdminEmail() in firestore.rules');
}
const storageRules = readFileSync(new URL('../../storage.rules', import.meta.url), 'utf8');

let env;

// IST "today" in yyyy-MM-dd (matches the rules' isTodayIst()).
function istToday() {
  const d = new Date(Date.now() + 330 * 60 * 1000);
  return d.toISOString().slice(0, 10);
}

// One RulesTestContext per test user. Each context's Firestore/Storage handle
// is created exactly ONCE and then reused: calling context.db a
// second time re-runs connectFirestoreEmulator() on an already-started
// instance, which throws "Firestore has already been started and its
// settings can no longer be changed".
function as(uid, email, verified = true) {
  const c = env.authenticatedContext(uid, { email, email_verified: verified });
  let db;
  let storage;
  return {
    get db() { return (db ??= c.firestore()); },
    get storage() { return (storage ??= c.storage()); },
  };
}

async function seed(path, data) {
  await env.withSecurityRulesDisabled(async (c) => setDoc(doc(c.firestore(), path), data));
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT,
    firestore: { rules, host: '127.0.0.1', port: 8080 },
    storage: { rules: storageRules, host: '127.0.0.1', port: 9199 },
  });
});
after(async () => { await env.cleanup(); });

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearStorage();
  await seed('users/admin1', { name: 'Admin', role: 'admin', status: 'active', email: ADMIN_EMAIL });
  await seed('users/sup1', { name: 'Sup', role: 'supervisor', status: 'active' });
  await seed('users/aud1', { name: 'Aud', role: 'auditor', status: 'active' });
  await seed('users/sup2', { name: 'Sup2', role: 'supervisor', status: 'active' });
  await seed('users/w1', { name: 'W1', role: 'worker', status: 'active', boundaryId: 'b1', supervisorId: 'sup1', faceEnrolled: true });
  await seed('users/w2', { name: 'W2', role: 'worker', status: 'active', boundaryId: 'b1', supervisorId: 'sup2' });
  await seed('users/pending', { name: 'P', role: 'worker', status: 'pending_approval' });
  await seed('settings/config', { lateAfter: '23:59', requireFace: true, requireBoundary: true });
  await seed('face_templates/w1', { embedding: Array(192).fill(0.1), dims: 192 });
  await seed('tasks/t1', { title: 'T', assignedTo: 'w1', status: 'assigned' });
  await seed('meta/placeholder', { x: 1 });
});

// ------------------------------------------------------------------ bootstrap
test('admin bootstrap: only the authorised, verified e-mail can become admin', async () => {
  await env.clearFirestore();
  const newUser = (u, uid, email) => setDoc(doc(u.db, `users/${uid}`), {
    name: 'X', email, phone: '', role: 'worker', status: 'pending_approval', employeeId: '',
    category: '', hasLogin: true, synthetic: false, faceEnrolled: false, createdAt: serverTimestamp(),
  });
  const promote = (u, uid) => {
    const b = writeBatch(u.db);
    b.update(doc(u.db, `users/${uid}`), { role: 'admin', status: 'active' });
    b.set(doc(u.db, 'meta/bootstrap'), { adminUid: uid, createdAt: serverTimestamp() });
    return b.commit();
  };

  const intruder = as('u-x', 'someone@gmail.com');
  await assertSucceeds(newUser(intruder, 'u-x', 'someone@gmail.com'));
  await assertFails(promote(intruder, 'u-x'));

  const unverified = as('u-a', ADMIN_EMAIL, false);
  await assertSucceeds(newUser(unverified, 'u-a', ADMIN_EMAIL));
  await assertFails(promote(unverified, 'u-a'));

  const owner = as('u-a', ADMIN_EMAIL, true);
  await assertSucceeds(promote(owner, 'u-a'));
  // write-once
  await assertFails(setDoc(doc(owner.db, 'meta/bootstrap'), { adminUid: 'u-x' }));
});

test('self sign-up: active worker immediately, but cannot choose role, privileged status or employee ID', async () => {
  const c = as('new1', 'new1@gmail.com');
  const base = { name: 'N', email: 'new1@gmail.com', phone: '', role: 'worker', status: 'active',
    employeeId: '', category: '', hasLogin: true, synthetic: false, faceEnrolled: false, createdAt: serverTimestamp() };
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, role: 'admin' }));
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, role: 'supervisor' }));
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, status: 'suspended' }));
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, employeeId: 'EMP-1' }));
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, email: 'other@gmail.com' }));
  await assertFails(setDoc(doc(c.db, 'users/someone-else'), base));
  await assertSucceeds(setDoc(doc(c.db, 'users/new1'), base));
  // A new active worker can use worker features straight away.
  await assertSucceeds(getDoc(doc(c.db, 'settings/config')));
});

test('older app versions may still create a pending account', async () => {
  const c = as('old1', 'old1@gmail.com');
  await assertSucceeds(setDoc(doc(c.db, 'users/old1'), { name: 'O', email: 'old1@gmail.com', phone: '', role: 'worker',
    status: 'pending_approval', employeeId: '', category: '', hasLogin: true, synthetic: false, faceEnrolled: false,
    createdAt: serverTimestamp() }));
});

test('a pending worker can activate itself; blocked accounts cannot', async () => {
  const p = as('pending', 'p@x.com');
  await assertFails(updateDoc(doc(p.db, 'users/pending'), { status: 'active', role: 'admin' }));
  await assertFails(updateDoc(doc(p.db, 'users/pending'), { status: 'active', boundaryId: 'b1' }));
  await assertFails(updateDoc(doc(p.db, 'users/pending'), { status: 'suspended' }));
  await assertFails(updateDoc(doc(as('w1', 'w1@x.com').db, 'users/pending'), { status: 'active' })); // not their own
  await assertSucceeds(updateDoc(doc(p.db, 'users/pending'), { status: 'active' }));

  await seed('users/blocked', { name: 'B', role: 'worker', status: 'suspended' });
  await seed('users/off', { name: 'O', role: 'worker', status: 'inactive' });
  await assertFails(updateDoc(doc(as('blocked', 'b@x.com').db, 'users/blocked'), { status: 'active' }));
  await assertFails(updateDoc(doc(as('off', 'o@x.com').db, 'users/off'), { status: 'active' }));

  // A pending supervisor/admin record (created by staff) cannot self-activate.
  await seed('users/psup', { name: 'PS', role: 'supervisor', status: 'pending_approval' });
  await assertFails(updateDoc(doc(as('psup', 'ps@x.com').db, 'users/psup'), { status: 'active' }));
});

test('suspended workers cannot read operational data or write attendance', async () => {
  await seed('users/blocked', { name: 'B', role: 'worker', status: 'suspended', boundaryId: 'b1' });
  const b = as('blocked', 'b@x.com');
  await assertFails(getDoc(doc(b.db, 'settings/config')));
  await assertFails(setDoc(doc(b.db, `attendance/blocked_${istToday()}`), att('blocked', 'pending_verification', 'not_performed', 'inside')));
});

// ------------------------------------------------------------------ profiles
test('workers cannot read other profiles or change their own role/status', async () => {
  const w1 = as('w1', 'w1@x.com');
  await assertSucceeds(getDoc(doc(w1.db, 'users/w1')));
  await assertFails(getDoc(doc(w1.db, 'users/w2')));
  await assertFails(getDocs(collection(w1.db, 'users')));
  await assertFails(updateDoc(doc(w1.db, 'users/w1'), { role: 'admin' }));
  await assertFails(updateDoc(doc(w1.db, 'users/w1'), { status: 'active', boundaryId: 'b2' }));
  await assertSucceeds(updateDoc(doc(w1.db, 'users/w1'), { phone: '9876543210' }));
});

test('supervisors cannot grant roles; admins cannot lock themselves out', async () => {
  const s = as('sup1', 's@x.com');
  await assertFails(updateDoc(doc(s.db, 'users/w2'), { role: 'admin' }));
  await assertSucceeds(updateDoc(doc(s.db, 'users/pending'), { status: 'active' }));
  const a = as('admin1', ADMIN_EMAIL);
  await assertSucceeds(updateDoc(doc(a.db, 'users/w2'), { role: 'supervisor' }));
  await assertFails(updateDoc(doc(a.db, 'users/admin1'), { role: 'worker' }));
});

test('pending accounts cannot read operational data', async () => {
  const p = as('pending', 'p@x.com');
  await assertFails(getDocs(collection(p.db, 'boundaries')));
  await assertFails(getDoc(doc(p.db, 'settings/config')));
});

// ------------------------------------------------------------------ biometrics
test('face templates are readable only by their owner (not other workers, not admins)', async () => {
  await assertSucceeds(getDoc(doc(as('w1', 'w1@x.com').db, 'face_templates/w1')));
  await assertFails(getDoc(doc(as('w2', 'w2@x.com').db, 'face_templates/w1')));
  await assertFails(getDoc(doc(as('admin1', ADMIN_EMAIL).db, 'face_templates/w1')));
  await assertFails(getDocs(collection(as('admin1', ADMIN_EMAIL).db, 'face_templates')));
  await assertSucceeds(deleteDoc(doc(as('admin1', ADMIN_EMAIL).db, 'face_templates/w1')));
});

test('face template: one enrolment, correct size, no overwrite', async () => {
  const w2 = as('w2', 'w2@x.com');
  const t = { embedding: Array(192).fill(0.05), dims: 192, model: 'm', consent: true, enrolledBy: 'w2', enrolledAt: serverTimestamp() };
  await assertFails(setDoc(doc(w2.db, 'face_templates/w2'), { ...t, embedding: Array(10).fill(0) }));
  await assertFails(setDoc(doc(w2.db, 'face_templates/w1'), t));
  await assertSucceeds(setDoc(doc(w2.db, 'face_templates/w2'), t));
  await assertFails(setDoc(doc(as('w1', 'w1@x.com').db, 'face_templates/w1'), t)); // overwrite
});

// ------------------------------------------------------------------ attendance
const checkIn = (face, geo) => ({
  time: serverTimestamp(), lat: 12.69, lng: 79.97, accuracy: 8, faceStatus: face, geoStatus: geo,
});
const att = (uid, status, face, geo, extra = {}) => ({
  uid, name: uid, employeeId: '', date: istToday(), status, boundaryId: 'b1',
  checkIn: checkIn(face, geo), synthetic: false, createdAt: serverTimestamp(), ...extra,
});

test('worker attendance outcome must match verification results', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  const id = `w1_${istToday()}`;
  await assertFails(setDoc(doc(w1, `attendance/${id}`), att('w1', 'present', 'failed', 'inside')));
  await assertFails(setDoc(doc(w1, `attendance/${id}`), att('w1', 'present', 'verified', 'outside')));
  await assertFails(setDoc(doc(w1, `attendance/${id}`), att('w1', 'present', 'verified', 'inside', { createdAt: Timestamp.fromDate(new Date(2020, 0, 1)) })));
  await assertSucceeds(setDoc(doc(w1, `attendance/${id}`), att('w1', 'present', 'verified', 'inside')));
});

test('workers cannot write attendance for others, other days, or change outcomes', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertFails(setDoc(doc(w1, `attendance/w2_${istToday()}`), att('w2', 'rejected', 'failed', 'inside')));
  await assertFails(setDoc(doc(w1, 'attendance/w1_2020-01-01'), { ...att('w1', 'rejected', 'failed', 'inside'), date: '2020-01-01' }));
  const id = `w1_${istToday()}`;
  await assertSucceeds(setDoc(doc(w1, `attendance/${id}`), att('w1', 'pending_verification', 'not_performed', 'inside')));
  await assertFails(updateDoc(doc(w1, `attendance/${id}`), { status: 'present' }));
  await assertSucceeds(updateDoc(doc(w1, `attendance/${id}`), { checkOut: { time: serverTimestamp() }, updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, `attendance/${id}`), { checkOut: { time: serverTimestamp() }, updatedAt: serverTimestamp() }));
  await assertFails(getDoc(doc(as('w2', 'w2@x.com').db, `attendance/${id}`)));
  await assertSucceeds(updateDoc(doc(as('sup1', 's@x.com').db, `attendance/${id}`), { status: 'present', reviewNote: 'ok' }));
});

// ------------------------------------------------------------------ settings, tasks, activities, alerts, audit
test('only admins change settings', async () => {
  await assertFails(setDoc(doc(as('w1', 'w1@x.com').db, 'settings/config'), { lateAfter: '23:59' }));
  await assertFails(setDoc(doc(as('sup1', 's@x.com').db, 'settings/config'), { lateAfter: '23:59' }));
  await assertSucceeds(setDoc(doc(as('admin1', ADMIN_EMAIL).db, 'settings/config'), { lateAfter: '10:00' }));
});

test('workers only move their own task forward', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertFails(updateDoc(doc(w1, 'tasks/t1'), { status: 'completed', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'tasks/t1'), { assignedTo: 'w2' }));
  await assertSucceeds(updateDoc(doc(w1, 'tasks/t1'), { status: 'in_progress', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(as('w2', 'w2@x.com').db, 'tasks/t1'), { status: 'submitted', updatedAt: serverTimestamp() }));
});

test('workers cannot self-approve activities', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  const a = { taskId: 't1', uid: 'w1', description: 'Inspected', reviewStatus: 'pending', synthetic: false, images: [], createdAt: serverTimestamp() };
  await assertFails(setDoc(doc(w1, 'activities/a0'), { ...a, reviewStatus: 'approved' }));
  await assertSucceeds(setDoc(doc(w1, 'activities/a1'), a));
  await assertFails(updateDoc(doc(w1, 'activities/a1'), { reviewStatus: 'approved' }));
  await assertSucceeds(updateDoc(doc(as('sup1', 's@x.com').db, 'activities/a1'), { reviewStatus: 'approved', reviewNote: 'ok' }));
});

test('workers cannot resolve alerts or raise them about others', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  const al = { type: 'face_failed', description: 'x', severity: 'high', uid: 'w1', status: 'open', synthetic: false, createdAt: serverTimestamp() };
  await assertFails(setDoc(doc(w1, 'alerts/x0'), { ...al, uid: 'w2' }));
  await assertSucceeds(setDoc(doc(w1, 'alerts/x1'), al));
  await assertFails(updateDoc(doc(w1, 'alerts/x1'), { status: 'resolved' }));
  await assertFails(getDocs(query(collection(w1, 'alerts'))));
  await assertSucceeds(getDocs(query(collection(w1, 'alerts'), where('uid', '==', 'w1'))));
});

test('audit log is append-only', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertSucceeds(setDoc(doc(w1, 'audit_logs/l1'), { action: 'login', actorUid: 'w1', createdAt: serverTimestamp() }));
  await assertFails(setDoc(doc(w1, 'audit_logs/l2'), { action: 'login', actorUid: 'admin1', createdAt: serverTimestamp() }));
  const a = as('admin1', ADMIN_EMAIL).db;
  await assertFails(updateDoc(doc(a, 'audit_logs/l1'), { action: 'edited' }));
  await assertFails(deleteDoc(doc(a, 'audit_logs/l1')));
  await assertFails(getDocs(collection(w1, 'audit_logs')));
});

// ------------------------------------------------------------------ live location (latest point only)
const loc = (uid, extra = {}) => ({
  uid, name: uid, lat: 12.69, lng: 79.97, accuracy: 8, mocked: false, geoStatus: 'inside',
  distanceToEdge: 40, boundaryId: 'b1', onDuty: true, updatedAt: serverTimestamp(), ...extra,
});

test('live location: workers write only their own point, against their own boundary', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertFails(setDoc(doc(w1, 'locations/w2'), loc('w2')));                       // someone else
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w2')));                       // uid mismatch
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w1', { boundaryId: 'b2' }))); // fake boundary
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w1', { synthetic: true })));
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w1', { lat: 123 })));          // impossible latitude
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w1', { role: 'admin' })));     // unexpected field
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w1', { updatedAt: Timestamp.fromDate(new Date(2020, 0, 1)) })));
  await assertSucceeds(setDoc(doc(w1, 'locations/w1'), loc('w1')));
  // Going off duty (merge write used by LiveTracker.stop)
  await assertSucceeds(setDoc(doc(w1, 'locations/w1'), { onDuty: false, updatedAt: serverTimestamp() }, { merge: true }));
  await assertFails(setDoc(doc(as('blocked', 'b@x.com').db, 'locations/blocked'), loc('blocked')));
});

test('live location: admin sees all, supervisor only own workers, auditor none, workers only self', async () => {
  await seed('locations/w1', { uid: 'w1', lat: 12.7, lng: 79.9, boundaryId: 'b1', supervisorId: 'sup1' });
  await seed('locations/w2', { uid: 'w2', lat: 12.7, lng: 79.9, boundaryId: 'b1', supervisorId: 'sup2' });
  const w1 = as('w1', 'w1@x.com').db;
  await assertSucceeds(getDoc(doc(w1, 'locations/w1')));
  await assertFails(getDoc(doc(w1, 'locations/w2')));
  await assertFails(getDocs(collection(w1, 'locations')));
  await assertSucceeds(getDocs(collection(as('admin1', ADMIN_EMAIL).db, 'locations')));
  const sup = as('sup1', 's@x.com').db;
  await assertSucceeds(getDocs(query(collection(sup, 'locations'), where('supervisorId', '==', 'sup1'))));
  await assertSucceeds(getDoc(doc(sup, 'locations/w1')));
  await assertFails(getDoc(doc(sup, 'locations/w2')));                                   // not their worker
  await assertFails(getDocs(collection(sup, 'locations')));                              // whole district
  await assertFails(getDocs(query(collection(sup, 'locations'), where('supervisorId', '==', 'sup2'))));
  const aud = as('aud1', 'a@x.com').db;
  await assertFails(getDocs(collection(aud, 'locations')));                              // no live positions
  await assertFails(getDoc(doc(aud, 'locations/w1')));
  await assertFails(setDoc(doc(aud, 'locations/w2'), loc('w2')));
});

test('live location: a worker cannot claim another supervisor', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertFails(setDoc(doc(w1, 'locations/w1'), loc('w1', { supervisorId: 'sup2' })));
  await assertSucceeds(setDoc(doc(w1, 'locations/w1'), loc('w1', { supervisorId: 'sup1', sessionId: 's1' })));
});

// ------------------------------------------------------------------ field-duty tracking
const sess = (uid, extra = {}) => ({
  uid, name: uid, date: istToday(), boundaryId: 'b1', supervisorId: uid === 'w1' ? 'sup1' : 'sup2',
  status: 'active', consent: true, pointCount: 0, insideCount: 0, distanceM: 0, synthetic: false,
  startedAt: serverTimestamp(), ...extra,
});
const pt = (uid, sessionId, extra = {}) => ({
  uid, sessionId, supervisorId: uid === 'w1' ? 'sup1' : 'sup2', boundaryId: 'b1', date: istToday(), kind: 'track',
  lat: 12.69, lng: 79.97, accuracy: 8, speed: null, mocked: false, geoStatus: 'inside', distanceToEdge: 30,
  gpsTime: Timestamp.now(), synthetic: false, createdAt: serverTimestamp(), ...extra,
});

test('tracking session: a worker starts duty only for themself, today, in their own area', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x1'), sess('w2')));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x2'), sess('w1', { boundaryId: 'b9' })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x3'), sess('w1', { supervisorId: 'sup2' })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x4'), sess('w1', { date: '2020-01-01' })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x5'), sess('w1', { consent: false })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x6'), sess('w1', { pointCount: 50, distanceM: 9000 })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x7'), sess('w1', { status: 'ended' })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x8'), sess('w1', { synthetic: true })));
  await assertFails(setDoc(doc(w1, 'tracking_sessions/x9'), sess('w1', { startedAt: Timestamp.fromDate(new Date(2020, 0, 1)) })));
  await assertFails(setDoc(doc(as('blocked', 'b@x.com').db, 'tracking_sessions/xb'), sess('blocked')));
  await assertFails(setDoc(doc(as('sup1', 's@x.com').db, 'tracking_sessions/xs'), sess('sup1')));
  await assertSucceeds(setDoc(doc(w1, 'tracking_sessions/s1'), sess('w1')));
});

test('tracking session: totals only grow; ending is one-way; supervisors close only their own workers\' sessions', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertSucceeds(setDoc(doc(w1, 'tracking_sessions/s1'), sess('w1')));
  await assertSucceeds(updateDoc(doc(w1, 'tracking_sessions/s1'), { pointCount: 10, insideCount: 8, distanceM: 420.5, lastPointAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'tracking_sessions/s1'), { pointCount: 3, insideCount: 2, distanceM: 420.5, lastPointAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'tracking_sessions/s1'), { pointCount: 12, insideCount: 20, distanceM: 500, lastPointAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'tracking_sessions/s1'), { boundaryId: 'b2' }));
  await assertFails(updateDoc(doc(as('w2', 'w2@x.com').db, 'tracking_sessions/s1'), {
    status: 'ended', endedAt: serverTimestamp(), endReason: 'stopped_by_worker', pointCount: 10, insideCount: 8, distanceM: 420.5, lastPointAt: serverTimestamp() }));
  const end = { status: 'ended', endedAt: serverTimestamp(), endReason: 'stopped_by_worker', pointCount: 12, insideCount: 9, distanceM: 510, lastPointAt: serverTimestamp() };
  await assertFails(updateDoc(doc(w1, 'tracking_sessions/s1'), { ...end, endReason: 'whatever' }));
  await assertSucceeds(updateDoc(doc(w1, 'tracking_sessions/s1'), end));
  await assertFails(updateDoc(doc(w1, 'tracking_sessions/s1'), { status: 'active' }));     // no reopening

  await assertSucceeds(setDoc(doc(w1, 'tracking_sessions/s2'), sess('w1')));
  const close = (by) => ({ status: 'ended', endedAt: serverTimestamp(), endReason: 'auto_closed', endedBy: by });
  await assertFails(updateDoc(doc(as('sup2', 's2@x.com').db, 'tracking_sessions/s2'), close('sup2')));
  await assertFails(updateDoc(doc(as('aud1', 'a@x.com').db, 'tracking_sessions/s2'), close('aud1')));
  await assertSucceeds(updateDoc(doc(as('sup1', 's@x.com').db, 'tracking_sessions/s2'), close('sup1')));
});

test('route points: only into the worker\'s own active session, matching its area and date; never edited', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  await assertSucceeds(setDoc(doc(w1, 'tracking_sessions/s1'), sess('w1')));
  await seed('tracking_sessions/s2', { ...sess('w2'), startedAt: Timestamp.now() });
  await assertSucceeds(setDoc(doc(w1, 'worker_location_updates/p1'), pt('w1', 's1', { kind: 'start' })));
  await assertSucceeds(setDoc(doc(w1, 'worker_location_updates/p2'), pt('w1', 's1')));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p3'), pt('w1', 's2')));                       // someone else's session
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p4'), pt('w2', 's1')));                       // someone else's name on it
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p5'), pt('w1', 's1', { boundaryId: 'b2' })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p6'), pt('w1', 's1', { supervisorId: 'sup2' })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p7'), pt('w1', 's1', { date: '2020-01-01' })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p8'), pt('w1', 's1', { lat: 95 })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/p9'), pt('w1', 's1', { activityId: 'a1' })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/pa'), pt('w1', 's1', { createdAt: Timestamp.fromDate(new Date(2020, 0, 1)) })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/pb'), pt('w1', 's1', { synthetic: true })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/pc'), pt('w1', 's1', { kind: 'teleport' })));
  await assertFails(updateDoc(doc(w1, 'worker_location_updates/p2'), { lat: 12.1 }));
  await assertFails(deleteDoc(doc(w1, 'worker_location_updates/p2')));
  await assertSucceeds(updateDoc(doc(w1, 'tracking_sessions/s1'), {
    status: 'ended', endedAt: serverTimestamp(), endReason: 'stopped_by_worker', pointCount: 2, insideCount: 2, distanceM: 0, lastPointAt: serverTimestamp() }));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/pd'), pt('w1', 's1')));                      // session ended
});

test('activity points: saved together with the worker\'s own activity', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  const act = { taskId: 't1', taskTitle: 'T', uid: 'w1', name: 'W1', visitType: 'inspection', description: 'Done',
    measurement: '', lat: 12.69, lng: 79.97, accuracy: 8, geoStatus: 'inside', mocked: false, sessionId: null,
    images: ['evidence/w1/act1/0.jpg'], reviewStatus: 'pending', synthetic: false, createdAt: serverTimestamp() };
  const b = writeBatch(w1);
  b.set(doc(w1, 'activities/act1'), act);
  b.set(doc(w1, 'worker_location_updates/ap1'), pt('w1', null, { kind: 'activity', activityId: 'act1' }));
  await assertSucceeds(b.commit());
  await seed('activities/other', { ...act, uid: 'w2', createdAt: Timestamp.now() });
  await assertFails(setDoc(doc(w1, 'worker_location_updates/ap2'), pt('w1', null, { kind: 'activity', activityId: 'other' })));
  await assertFails(setDoc(doc(w1, 'worker_location_updates/ap3'), pt('w1', null, { kind: 'activity', activityId: 'missing' })));
});

test('movement history and sessions: who can read what', async () => {
  await seed('tracking_sessions/s1', { ...sess('w1'), startedAt: Timestamp.now() });
  await seed('tracking_sessions/s2', { ...sess('w2'), startedAt: Timestamp.now() });
  await seed('worker_location_updates/p1', { ...pt('w1', 's1'), gpsTime: Timestamp.now(), createdAt: Timestamp.now() });
  await seed('worker_location_updates/p2', { ...pt('w2', 's2'), gpsTime: Timestamp.now(), createdAt: Timestamp.now() });
  const pts = (c) => collection(c, 'worker_location_updates');
  const w1 = as('w1', 'w1@x.com').db;
  await assertSucceeds(getDocs(query(pts(w1), where('uid', '==', 'w1'))));
  await assertFails(getDocs(query(pts(w1), where('uid', '==', 'w2'))));                 // other worker's history
  await assertFails(getDocs(pts(w1)));
  await assertFails(getDoc(doc(w1, 'tracking_sessions/s2')));
  const sup = as('sup1', 's@x.com').db;
  await assertSucceeds(getDocs(query(pts(sup), where('supervisorId', '==', 'sup1'), where('uid', '==', 'w1'))));
  await assertFails(getDocs(query(pts(sup), where('uid', '==', 'w2'))));
  await assertFails(getDocs(pts(sup)));
  await assertSucceeds(getDocs(query(collection(sup, 'tracking_sessions'), where('supervisorId', '==', 'sup1'))));
  await assertFails(getDoc(doc(sup, 'tracking_sessions/s2')));
  const aud = as('aud1', 'a@x.com').db;
  await assertFails(getDocs(pts(aud)));                                                 // no movement history
  await assertFails(getDoc(doc(aud, 'worker_location_updates/p1')));
  await assertSucceeds(getDocs(collection(aud, 'tracking_sessions')));                  // duty summaries
  await assertFails(setDoc(doc(aud, 'tracking_sessions/s9'), sess('aud1')));
  const a = as('admin1', ADMIN_EMAIL).db;
  await assertSucceeds(getDocs(pts(a)));
  await assertSucceeds(getDocs(collection(a, 'tracking_sessions')));
});

test('panchayat coverage: admins save reports; admins and auditors read; others cannot', async () => {
  const report = (by, extra = {}) => ({ boundaryId: 'b1', date: istToday(), name: 'Zone', block: 'B', panchayat: 'P',
    sessions: 2, workers: 2, points: 40, insidePoints: 35, distanceM: 1200, covered: true, synthetic: false,
    generatedBy: by, generatedAt: serverTimestamp(), ...extra });
  const id = `b1_${istToday()}`;
  const a = as('admin1', ADMIN_EMAIL).db;
  await assertFails(setDoc(doc(a, 'panchayat_coverage/wrong-id'), report('admin1')));
  await assertFails(setDoc(doc(a, `panchayat_coverage/${id}`), report('someone-else')));
  await assertSucceeds(setDoc(doc(a, `panchayat_coverage/${id}`), report('admin1')));
  await assertFails(setDoc(doc(as('sup1', 's@x.com').db, `panchayat_coverage/${id}`), report('sup1')));
  await assertFails(setDoc(doc(as('w1', 'w1@x.com').db, `panchayat_coverage/${id}`), report('w1')));
  await assertSucceeds(getDocs(collection(as('aud1', 'a@x.com').db, 'panchayat_coverage')));
  await assertFails(getDocs(collection(as('sup1', 's@x.com').db, 'panchayat_coverage')));
  await assertFails(getDocs(collection(as('w1', 'w1@x.com').db, 'panchayat_coverage')));
});

// ------------------------------------------------------------------ activity evidence metadata
test('activity evidence: only own photo paths for this activity, assigned task required', async () => {
  const w1 = as('w1', 'w1@x.com').db;
  const a = (id, extra = {}) => ({
    taskId: 't1', taskTitle: 'T', uid: 'w1', name: 'W1', visitType: 'inspection', description: 'Done',
    measurement: '', lat: 12.69, lng: 79.97, accuracy: 8, geoStatus: 'inside',
    images: [`evidence/w1/${id}/0.jpg`, `evidence/w1/${id}/1.jpg`],
    reviewStatus: 'pending', synthetic: false, createdAt: serverTimestamp(), ...extra,
  });
  await assertSucceeds(setDoc(doc(w1, 'activities/act1'), a('act1')));
  await assertSucceeds(setDoc(doc(w1, 'activities/act0'), a('act0', { images: [] })));         // no photos (Storage off)
  await assertFails(setDoc(doc(w1, 'activities/act2'), a('act2', { images: ['evidence/w2/act2/0.jpg'] }))); // another worker's photo
  await assertFails(setDoc(doc(w1, 'activities/act3'), a('act3', { images: ['evidence/w1/act1/0.jpg'] }))); // another activity's photo
  await assertFails(setDoc(doc(w1, 'activities/act4'), a('act4', { images: ['evidence/w1/act4/1.jpg'] }))); // wrong order
  await assertFails(setDoc(doc(w1, 'activities/act5'), a('act5', {
    images: ['evidence/w1/act5/0.jpg', 'evidence/w1/act5/1.jpg', 'evidence/w1/act5/2.jpg', 'evidence/w1/act5/3.jpg'] })));
  await assertFails(setDoc(doc(w1, 'activities/act6'), a('act6', { reviewedBy: 'Me' })));        // review fields
  await assertFails(setDoc(doc(w1, 'activities/act7'), a('act7', { reviewedAt: serverTimestamp() })));
  await assertFails(setDoc(doc(w1, 'activities/act8'), { ...a('act8'), images: 'evidence/w1/act8/0.jpg' })); // not a list
  await seed('tasks/t2', { title: 'Other', assignedTo: 'w2', status: 'assigned' });
  await assertFails(setDoc(doc(w1, 'activities/act9'), a('act9', { taskId: 't2' })));            // not their task
  await assertFails(getDoc(doc(as('w2', 'w2@x.com').db, 'activities/act1')));                     // privacy
});

test('unknown collections are denied', async () => {
  await assertFails(setDoc(doc(as('admin1', ADMIN_EMAIL).db, 'random/x'), { a: 1 }));
});

// ------------------------------------------------------------------ storage
test('storage: owner-only JPEG evidence uploads', async () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  const meta = { contentType: 'image/jpeg' };
  const w1 = as('w1', 'w1@x.com').storage;
  await assertSucceeds(uploadBytes(ref(w1, 'evidence/w1/a1/0.jpg'), jpeg, meta));
  await assertFails(uploadBytes(ref(w1, 'evidence/w2/a1/0.jpg'), jpeg, meta));
  await assertFails(uploadBytes(ref(w1, 'evidence/w1/a1/1.jpg'), jpeg, { contentType: 'image/png' }));
  await assertFails(uploadBytes(ref(w1, 'faces/w1.jpg'), jpeg, meta));
  await assertFails(uploadBytes(ref(as('pending', 'p@x.com').storage, 'evidence/pending/a/0.jpg'), jpeg, meta));
});
