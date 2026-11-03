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

const ADMIN_EMAIL = 'admin.test@example.com';
const PROJECT = 'demo-smart-attendance';

const rules = readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8')
  .replace('REPLACE_WITH_ADMIN_EMAIL@gmail.com', ADMIN_EMAIL);
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
  await seed('users/w1', { name: 'W1', role: 'worker', status: 'active', boundaryId: 'b1', faceEnrolled: true });
  await seed('users/w2', { name: 'W2', role: 'worker', status: 'active', boundaryId: 'b1' });
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

test('self sign-up cannot choose role, status or employee ID', async () => {
  const c = as('new1', 'new1@gmail.com');
  const base = { name: 'N', email: 'new1@gmail.com', phone: '', role: 'worker', status: 'pending_approval',
    employeeId: '', category: '', hasLogin: true, synthetic: false, faceEnrolled: false, createdAt: serverTimestamp() };
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, role: 'admin' }));
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, status: 'active' }));
  await assertFails(setDoc(doc(c.db, 'users/new1'), { ...base, employeeId: 'EMP-1' }));
  await assertSucceeds(setDoc(doc(c.db, 'users/new1'), base));
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
