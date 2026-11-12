// Security-rules tests for Smart Attendance v2 (Phase 4, Foundation), run
// against the Firestore emulator:
//   cd v2/tests/rules && npm install
//   npx firebase emulators:exec --only firestore --project demo-field-monitor --config ../../firebase.json "npm test"
// The emulator uses fake sign-in tokens; no real account is involved.

import { test, before, after, beforeEach } from 'node:test';
import { readFileSync } from 'node:fs';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, serverTimestamp, writeBatch,
} from 'firebase/firestore';

const ADMIN_EMAIL = 'krish.sep2006@gmail.com';
const rules = readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8');
if (!rules.includes(`bootstrapEmail() { return '${ADMIN_EMAIL}'; }`)) {
  throw new Error('ADMIN_EMAIL in this test does not match bootstrapEmail() in firestore.rules');
}

let env;
let auditSeq = 0;

// One context per test user; its Firestore handle is created once and reused.
function as(uid, email, verified = true) {
  const c = env.authenticatedContext(uid, { email, email_verified: verified });
  let db;
  return { uid, email, get db() { return (db ??= c.firestore()); } };
}
async function seed(path, data) {
  await env.withSecurityRulesDisabled(async (c) => setDoc(doc(c.firestore(), path), data));
}

// Adds the matching audit entry to a batch and returns its id.
function audit(b, who, target, action = 'test') {
  const id = `a${++auditSeq}`;
  b.set(doc(who.db, `auditLog/${id}`), {
    actorUid: who.uid, actorEmail: who.email, action, target, details: '', at: serverTimestamp(),
  });
  return id;
}

const account = (email, extra = {}) => ({ email, displayName: 'X', status: 'active', createdAt: serverTimestamp(), ...extra });
const assignment = (uid, role, extra = {}) => ({
  uid, role, areaIds: [], active: true, source: 'admin', grantedBy: 'adm', grantedAt: serverTimestamp(), ...extra,
});

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-field-monitor',
    firestore: { rules, host: '127.0.0.1', port: 8080 },
  });
});
after(async () => { await env.cleanup(); });

beforeEach(async () => {
  await env.clearFirestore();
  const ra = (uid, role, extra = {}) => ({ uid, role, areaIds: [], active: true, source: 'admin', grantedBy: 'adm', ...extra });
  await seed('meta/bootstrap', { uid: 'adm', email: ADMIN_EMAIL });
  await seed('accounts/adm', { email: ADMIN_EMAIL, status: 'active' });
  await seed('roleAssignments/adm__sys_admin', ra('adm', 'sys_admin'));
  await seed('accounts/oa', { email: 'oa@firm-a.in', status: 'active', orgId: 'orgA' });
  await seed('roleAssignments/oa__org_admin', ra('oa', 'org_admin', { orgId: 'orgA' }));
  await seed('accounts/w1', { email: 'w1@x.in', status: 'active', orgId: 'orgA' });
  await seed('roleAssignments/w1__worker', ra('w1', 'worker', { orgId: 'orgA', areaIds: ['b1'] }));
  await seed('accounts/w2', { email: 'w2@x.in', status: 'active', orgId: 'orgB' });
  await seed('roleAssignments/w2__worker', ra('w2', 'worker', { orgId: 'orgB' }));
  await seed('accounts/aud', { email: 'aud@x.in', status: 'active' });
  await seed('roleAssignments/aud__auditor', ra('aud', 'auditor'));
  await seed('accounts/dis', { email: 'dis@x.in', status: 'disabled' });
  await seed('roleAssignments/dis__sys_admin', ra('dis', 'sys_admin'));
  await seed('areas/d1', { name: 'District', level: 'district', parentId: null, path: ['d1'], provisional: true });
  await seed('areas/b1', { name: 'Block 1', level: 'block', parentId: 'd1', path: ['d1', 'b1'], provisional: true });
  await seed('organisations/orgA', { name: 'Firm A', type: 'third_party', active: true });
  await seed('organisations/orgB', { name: 'Firm B', type: 'third_party', active: true });
  await seed('preregistrations/other@firm-b.in', { email: 'other@firm-b.in', role: 'worker', areaIds: [], orgId: 'orgB', createdBy: 'adm' });
});

const admin = () => as('adm', ADMIN_EMAIL);

// ---------------------------------------------------------------- bootstrap
async function bootstrap(who, role = 'sys_admin') {
  const b = writeBatch(who.db);
  const id = `${who.uid}__${role}`;
  b.set(doc(who.db, `accounts/${who.uid}`), account(who.email));
  b.set(doc(who.db, `roleAssignments/${id}`), assignment(who.uid, role, {
    source: 'bootstrap', grantedBy: who.uid, auditId: audit(b, who, `roleAssignments/${id}`, 'bootstrap'),
  }));
  b.set(doc(who.db, 'meta/bootstrap'), { uid: who.uid, email: who.email.toLowerCase(), at: serverTimestamp() });
  return b.commit();
}

test('bootstrap: only the configured e-mail, only once, only as a batch with meta/bootstrap', async () => {
  await env.withSecurityRulesDisabled(async (c) => deleteDoc(doc(c.firestore(), 'meta/bootstrap')));
  await assertFails(bootstrap(as('x1', 'someone@gmail.com')));
  await assertFails(bootstrap(as('x2', ADMIN_EMAIL, false)));            // unverified e-mail
  await assertFails(bootstrap(as('x3', ADMIN_EMAIL), 'collector'));      // bootstrap gives sys_admin only
  await assertSucceeds(bootstrap(as('first', ADMIN_EMAIL)));
  await assertFails(bootstrap(as('second', ADMIN_EMAIL)));               // already done
});

// ------------------------------------------------------- no self-promotion
test('nobody can give themselves a role', async () => {
  const w = as('w1', 'w1@x.in');
  for (const [role, source] of [['sys_admin', 'admin'], ['collector', 'admin'], ['supervisor', 'preregistration'], ['worker', 'admin']]) {
    const b = writeBatch(w.db);
    const id = `w1__${role}`;
    b.set(doc(w.db, `roleAssignments/${id}`), assignment('w1', role, { source, grantedBy: 'w1', auditId: audit(b, w, `roleAssignments/${id}`) }));
    await assertFails(b.commit());
  }
  await assertFails(updateDoc(doc(w.db, 'roleAssignments/w1__worker'), { areaIds: ['d1'] }));
  await assertFails(updateDoc(doc(w.db, 'accounts/w1'), { status: 'active', orgId: 'orgB' }));
});

// -------------------------------------------------------- pre-registration
async function addPrereg(who, email, data, withAudit = true) {
  const b = writeBatch(who.db);
  const payload = { email, role: 'worker', areaIds: [], createdBy: who.uid, createdAt: serverTimestamp(), ...data };
  if (withAudit) payload.auditId = audit(b, who, `preregistrations/${email}`);
  b.set(doc(who.db, `preregistrations/${email}`), payload);
  return b.commit();
}

test('pre-registration: admins add anyone; organisation admins add only workers to their own organisation', async () => {
  await assertSucceeds(addPrereg(admin(), 'off@x.in', { role: 'officer', areaIds: ['b1'] }));
  await assertFails(addPrereg(admin(), 'noaudit@x.in', {}, false));                         // no audit entry
  const oa = as('oa', 'oa@firm-a.in');
  await assertSucceeds(addPrereg(oa, 'new@firm-a.in', { orgId: 'orgA', employeeId: 'E1' }));
  await assertFails(addPrereg(oa, 'x@firm-b.in', { orgId: 'orgB' }));                       // other organisation
  await assertFails(addPrereg(oa, 'boss@firm-a.in', { orgId: 'orgA', role: 'supervisor' }));  // not a worker
  await assertFails(addPrereg(oa, 'Upper@Firm-a.in', { orgId: 'orgA' }));                   // key must be lower case
  await assertFails(addPrereg(as('w1', 'w1@x.in'), 'pal@x.in', { orgId: 'orgA' }));         // workers cannot add people
  await assertFails(addPrereg(as('dis', 'dis@x.in'), 'z@x.in', {}));                        // disabled admin
  // Organisation admins see only their own organisation's list.
  await assertSucceeds(getDocs(query(collection(oa.db, 'preregistrations'), where('orgId', '==', 'orgA'))));
  await assertFails(getDocs(query(collection(oa.db, 'preregistrations'), where('orgId', '==', 'orgB'))));
  await assertFails(getDoc(doc(oa.db, 'preregistrations/other@firm-b.in')));
});

// ------------------------------------------------------------------- claim
async function claim(who, { role = 'worker', areaIds = ['b1'], orgId = 'orgA', employeeId = 'E1', grantedBy = 'oa' } = {}) {
  const b = writeBatch(who.db);
  const id = `${who.uid}__${role}`;
  b.set(doc(who.db, `accounts/${who.uid}`), account(who.email, { orgId, employeeId }));
  b.set(doc(who.db, `roleAssignments/${id}`), assignment(who.uid, role, {
    areaIds, orgId, source: 'preregistration', grantedBy, auditId: audit(b, who, `roleAssignments/${id}`, 'account_claimed'),
  }));
  b.update(doc(who.db, `preregistrations/${who.email}`), { claimedBy: who.uid, claimedAt: serverTimestamp() });
  return b.commit();
}

test('claim: a pre-registered person gets exactly what was prepared, once, with no approval step', async () => {
  await seed('preregistrations/new@firm-a.in', {
    email: 'new@firm-a.in', role: 'worker', areaIds: ['b1'], orgId: 'orgA', employeeId: 'E1', createdBy: 'oa',
  });
  await assertFails(claim(as('n1', 'new@firm-a.in'), { role: 'supervisor' }));     // different role
  await assertFails(claim(as('n1', 'new@firm-a.in'), { areaIds: ['d1'] }));       // wider area
  await assertFails(claim(as('n1', 'new@firm-a.in'), { orgId: 'orgB' }));          // other organisation
  await assertFails(claim(as('n1', 'new@firm-a.in', false)));                      // unverified e-mail
  await assertFails(claim(as('n1', 'stranger@x.in')));                             // not the registered e-mail
  await assertSucceeds(claim(as('n1', 'new@firm-a.in')));
  await assertFails(claim(as('n2', 'new@firm-a.in')));                             // already claimed
});

// ---------------------------------------------------------- open sign-up
async function openSignUp(who, { role = 'worker', areaIds = [] } = {}) {
  const b = writeBatch(who.db);
  const id = `${who.uid}__${role}`;
  b.set(doc(who.db, `accounts/${who.uid}`), account(who.email));
  b.set(doc(who.db, `roleAssignments/${id}`), assignment(who.uid, role, {
    areaIds, source: 'open_signup', grantedBy: who.uid, auditId: audit(b, who, `roleAssignments/${id}`, 'open_signup'),
  }));
  return b.commit();
}

test('open sign-up: off by default; when on, only an unassigned field worker', async () => {
  await assertFails(openSignUp(as('o1', 'o1@gmail.com')));
  await seed('config/app', { openWorkerSignUp: true });
  await assertFails(openSignUp(as('o1', 'o1@gmail.com'), { role: 'supervisor' }));
  await assertFails(openSignUp(as('o1', 'o1@gmail.com'), { areaIds: ['b1'] }));
  await assertSucceeds(openSignUp(as('o1', 'o1@gmail.com')));
});

// ------------------------------------------------------------- isolation
test('people read only their own account and roles', async () => {
  const w = as('w1', 'w1@x.in');
  await assertSucceeds(getDoc(doc(w.db, 'accounts/w1')));
  await assertFails(getDoc(doc(w.db, 'accounts/w2')));
  await assertFails(getDocs(collection(w.db, 'accounts')));
  await assertSucceeds(getDocs(query(collection(w.db, 'roleAssignments'), where('uid', '==', 'w1'))));
  await assertFails(getDocs(query(collection(w.db, 'roleAssignments'), where('uid', '==', 'w2'))));
  await assertSucceeds(getDocs(collection(admin().db, 'accounts')));
});

test('a disabled account loses its roles immediately', async () => {
  const d = as('dis', 'dis@x.in');
  const b = writeBatch(d.db);
  b.set(doc(d.db, 'organisations/orgC'), { name: 'Firm C', type: 'third_party', active: true, auditId: audit(b, d, 'organisations/orgC') });
  await assertFails(b.commit());
  await assertFails(getDocs(collection(d.db, 'accounts')));
});

// -------------------------------------------------- administrator changes
test('admin changes need an audit entry naming the exact target', async () => {
  const a = admin();
  const ok = writeBatch(a.db);
  ok.update(doc(a.db, 'roleAssignments/w1__worker'), { areaIds: ['d1'], auditId: audit(ok, a, 'roleAssignments/w1__worker') });
  await assertSucceeds(ok.commit());
  await assertFails(updateDoc(doc(a.db, 'roleAssignments/w1__worker'), { active: false }));            // no new audit entry (old one reused)
  const reuse = writeBatch(a.db);                                                                      // explicitly reusing an existing entry
  const old = (await getDoc(doc(a.db, 'roleAssignments/w1__worker'))).data().auditId;
  reuse.update(doc(a.db, 'roleAssignments/w1__worker'), { active: false, auditId: old });
  await assertFails(reuse.commit());
  const wrong = writeBatch(a.db);
  wrong.update(doc(a.db, 'roleAssignments/w1__worker'), { active: false, auditId: audit(wrong, a, 'roleAssignments/w2__worker') });
  await assertFails(wrong.commit());                                                                  // audit names another target
  const swap = writeBatch(a.db);
  swap.update(doc(a.db, 'roleAssignments/w1__worker'), { role: 'collector', auditId: audit(swap, a, 'roleAssignments/w1__worker') });
  await assertFails(swap.commit());                                                                   // role never changes
  const off = writeBatch(a.db);
  off.update(doc(a.db, 'accounts/w2'), { status: 'disabled', auditId: audit(off, a, 'accounts/w2') });
  await assertSucceeds(off.commit());
  await assertFails(deleteDoc(doc(a.db, 'roleAssignments/w1__worker')));                              // never deleted
});

test('the audit log is append-only and readable only by administrators and auditors', async () => {
  const w = as('w1', 'w1@x.in');
  await assertSucceeds(setDoc(doc(w.db, 'auditLog/l1'), { actorUid: 'w1', actorEmail: 'w1@x.in', action: 'login', target: 'auth', details: '', at: serverTimestamp() }));
  await assertFails(setDoc(doc(w.db, 'auditLog/l2'), { actorUid: 'w2', actorEmail: 'w1@x.in', action: 'login', target: 'auth', details: '', at: serverTimestamp() }));
  await assertFails(updateDoc(doc(w.db, 'auditLog/l1'), { action: 'nothing' }));
  await assertFails(deleteDoc(doc(admin().db, 'auditLog/l1')));
  await assertFails(getDocs(collection(w.db, 'auditLog')));
  await assertSucceeds(getDocs(collection(as('aud', 'aud@x.in').db, 'auditLog')));
  await assertSucceeds(getDocs(collection(admin().db, 'auditLog')));
});

// ------------------------------------------------------------ master data
test('areas: administrators only, and each path must extend its parent', async () => {
  const a = admin();
  const area = (id, data) => { const b = writeBatch(a.db); b.set(doc(a.db, `areas/${id}`), { provisional: true, ...data, auditId: audit(b, a, `areas/${id}`) }); return b.commit(); };
  await assertSucceeds(area('p1', { name: 'Panchayat 1', level: 'panchayat', parentId: 'b1', path: ['d1', 'b1', 'p1'] }));
  await assertFails(area('p2', { name: 'Panchayat 2', level: 'panchayat', parentId: 'b1', path: ['d1', 'p2'] }));
  await assertFails(area('d2', { name: 'District 2', level: 'district', parentId: 'd1', path: ['d2'] }));
  await assertFails(area('p3', { name: '', level: 'panchayat', parentId: 'b1', path: ['d1', 'b1', 'p3'] }));
  const w = as('w1', 'w1@x.in');
  const b = writeBatch(w.db);
  b.set(doc(w.db, 'areas/p9'), { name: 'P9', level: 'panchayat', parentId: 'b1', path: ['d1', 'b1', 'p9'], provisional: true, auditId: audit(b, w, 'areas/p9') });
  await assertFails(b.commit());
  await assertSucceeds(getDoc(doc(w.db, 'areas/b1')));
});

test('configuration and role titles: administrators only, audited', async () => {
  const a = admin();
  const ok = writeBatch(a.db);
  ok.set(doc(a.db, 'config/app'), { openWorkerSignUp: false, supervisorsMayCreateTasks: true, collectorMayAssignTasks: false, auditId: audit(ok, a, 'config/app') });
  await assertSucceeds(ok.commit());
  const t = writeBatch(a.db);
  t.set(doc(a.db, 'hierarchyLevels/zonal_secretary'), { title: 'Block Development Officer', auditId: audit(t, a, 'hierarchyLevels/zonal_secretary') });
  await assertSucceeds(t.commit());
  const w = as('w1', 'w1@x.in');
  const no = writeBatch(w.db);
  no.set(doc(w.db, 'config/app'), { openWorkerSignUp: true, auditId: audit(no, w, 'config/app') });
  await assertFails(no.commit());
  await assertSucceeds(getDoc(doc(w.db, 'config/app')));
});

test('people can edit only their own contact details', async () => {
  const w = as('w1', 'w1@x.in');
  await assertSucceeds(updateDoc(doc(w.db, 'accounts/w1'), { phone: '9000000000', language: 'ta' }));
  await assertFails(updateDoc(doc(w.db, 'accounts/w1'), { status: 'disabled' }));
  await assertFails(updateDoc(doc(w.db, 'accounts/w1'), { employeeId: 'E9' }));
  await assertFails(updateDoc(doc(w.db, 'accounts/w2'), { phone: '1' }));
});

// =============================================================== Phase 5.1–5.2
import { GeoPoint, Timestamp } from 'firebase/firestore';

function istToday(offsetDays = 0) {
  const d = new Date(Date.now() + 330 * 60 * 1000 - offsetDays * 86400000);
  return d.toISOString().slice(0, 10);
}

beforeEach(async () => {
  const ra = (uid, role, extra = {}) => ({ uid, role, areaIds: [], active: true, source: 'admin', grantedBy: 'adm', ...extra });
  await seed('areas/b2', { name: 'Block 2', level: 'block', parentId: 'd1', path: ['d1', 'b2'], provisional: true });
  await seed('accounts/w1', { email: 'w1@x.in', status: 'active', orgId: 'orgA', displayName: 'Worker One' });
  await seed('accounts/sup1', { email: 'sup1@x.in', status: 'active' });
  await seed('roleAssignments/sup1__supervisor', ra('sup1', 'supervisor', { areaIds: ['b1'] }));
  await seed('accounts/sup2', { email: 'sup2@x.in', status: 'active' });
  await seed('roleAssignments/sup2__supervisor', ra('sup2', 'supervisor', { areaIds: ['b2'] }));
  await seed('accounts/col', { email: 'col@x.in', status: 'active' });
  await seed('roleAssignments/col__collector', ra('col', 'collector', { areaIds: ['d1'] }));
  await seed('geofences/g1', { name: 'Test fence 1', areaId: 'b1', areaPath: ['d1', 'b1'], kind: 'circle', center: new GeoPoint(12.69, 79.97), radiusM: 200, provisional: true });
  await seed('geofences/g2', { name: 'Test fence 2', areaId: 'b2', areaPath: ['d1', 'b2'], kind: 'circle', center: new GeoPoint(12.70, 79.98), radiusM: 200, provisional: true });
});

const checkIn = (extra = {}) => ({
  at: serverTimestamp(), deviceAt: Timestamp.now(), lat: 12.69, lng: 79.97, accuracy: 8, mocked: false,
  geofenceId: 'g1', placement: 'inside', edgeDistanceM: 150, status: 'verified', late: false, reasons: [], eventId: 'e1', ...extra,
});
const workerNames = { w1: 'Worker One', w2: '' };
const session = (uid, extra = {}, ci = {}) => ({
  uid, workerName: workerNames[uid] ?? '', role: 'worker', date: istToday(), orgId: 'orgA', areaPath: ['d1', 'b1'], evaluatedBy: 'device', createdAt: serverTimestamp(),
  checkIn: checkIn(ci), ...extra,
});

test('geofences: administrators only, valid shape, tied to a real area, audited', async () => {
  const a = admin();
  const fence = (id, data) => { const b = writeBatch(a.db); b.set(doc(a.db, `geofences/${id}`), { provisional: true, ...data, auditId: audit(b, a, `geofences/${id}`) }); return b.commit(); };
  await assertSucceeds(fence('n1', { name: 'Circle', areaId: 'b1', areaPath: ['d1', 'b1'], kind: 'circle', center: new GeoPoint(12.69, 79.97), radiusM: 150 }));
  await assertSucceeds(fence('n2', { name: 'Polygon', areaId: 'b1', areaPath: ['d1', 'b1'], kind: 'polygon',
    ring: [new GeoPoint(12.69, 79.97), new GeoPoint(12.69, 79.98), new GeoPoint(12.70, 79.98)] }));
  await assertFails(fence('n3', { name: 'Wrong path', areaId: 'b1', areaPath: ['d1', 'b2'], kind: 'circle', center: new GeoPoint(12.69, 79.97), radiusM: 150 }));
  await assertFails(fence('n4', { name: 'Tiny', areaId: 'b1', areaPath: ['d1', 'b1'], kind: 'circle', center: new GeoPoint(12.69, 79.97), radiusM: 5 }));
  await assertFails(fence('n5', { name: 'Two points', areaId: 'b1', areaPath: ['d1', 'b1'], kind: 'polygon', ring: [new GeoPoint(1, 1), new GeoPoint(2, 2)] }));
  const w = as('w1', 'w1@x.in');
  const b = writeBatch(w.db);
  b.set(doc(w.db, 'geofences/n6'), { name: 'Mine', areaId: 'b1', areaPath: ['d1', 'b1'], kind: 'circle', center: new GeoPoint(12.69, 79.97), radiusM: 150, provisional: true, auditId: audit(b, w, 'geofences/n6') });
  await assertFails(b.commit());
  await assertSucceeds(getDoc(doc(w.db, 'geofences/g1')));
});

test('attendance: one honest record per worker per day', async () => {
  const w = as('w1', 'w1@x.in');
  const id = `w1_${istToday()}`;
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', {}, { reasons: ['outside_area'] })));     // "verified" with a reason
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', {}, { mocked: true })));                 // "verified" with mock GPS
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', {}, { placement: 'uncertain' })));       // "verified" but not proven inside
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', { areaPath: ['d1', 'b2'] }, { geofenceId: 'g2' }))); // not their area
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', { orgId: 'orgB' })));                    // other organisation
  await assertFails(setDoc(doc(w.db, `attendanceSessions/w1_2020-01-01`), session('w1', { date: '2020-01-01' })));      // old date
  await assertFails(setDoc(doc(w.db, `attendanceSessions/w2_${istToday()}`), session('w2')));                          // someone else
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', {}, { at: Timestamp.fromDate(new Date(2020, 0, 1)) }))); // client time
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1', { workerName: 'Someone Else' })));       // fake name
  await assertSucceeds(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1')));
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1')));                                     // duplicate
  // Flagged records are accepted: failed checks never block attendance.
  await assertSucceeds(setDoc(doc(w.db, `attendanceSessions/w1_${istToday(1)}`), session('w1', { date: istToday(1) },
    { status: 'flagged', placement: 'outside', reasons: ['outside_area'], edgeDistanceM: -300 })));
});

test('attendance: workers without an area are recorded and flagged, not refused', async () => {
  const w = as('w2', 'w2@x.in');
  const id = `w2_${istToday()}`;
  await assertFails(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w2', { orgId: 'orgB', areaPath: [] }, { geofenceId: null, placement: 'none' })));
  await assertSucceeds(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w2', { orgId: 'orgB', areaPath: [] },
    { geofenceId: null, placement: 'none', status: 'flagged', reasons: ['no_assigned_area'] })));
});

test('attendance: check-out once; the check-in can never be edited', async () => {
  const w = as('w1', 'w1@x.in');
  const id = `w1_${istToday()}`;
  await assertSucceeds(setDoc(doc(w.db, `attendanceSessions/${id}`), session('w1')));
  const out = { at: serverTimestamp(), deviceAt: Timestamp.now(), lat: 12.69, lng: 79.97, accuracy: 9, mocked: false, eventId: 'e2' };
  await assertFails(updateDoc(doc(w.db, `attendanceSessions/${id}`), { 'checkIn.status': 'verified', 'checkIn.late': true }));
  await assertSucceeds(updateDoc(doc(w.db, `attendanceSessions/${id}`), { checkOut: out, updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w.db, `attendanceSessions/${id}`), { checkOut: { ...out, eventId: 'e3' }, updatedAt: serverTimestamp() }));
  await assertFails(deleteDoc(doc(w.db, `attendanceSessions/${id}`)));
});

test('attendance: who can read it', async () => {
  await seed(`attendanceSessions/w1_${istToday()}`, { ...session('w1'), createdAt: Timestamp.now(), checkIn: { ...checkIn(), at: Timestamp.now() } });
  const id = `w1_${istToday()}`;
  await assertSucceeds(getDoc(doc(as('w1', 'w1@x.in').db, `attendanceSessions/${id}`)));
  await assertFails(getDoc(doc(as('w2', 'w2@x.in').db, `attendanceSessions/${id}`)));       // another worker
  await assertSucceeds(getDoc(doc(as('sup1', 'sup1@x.in').db, `attendanceSessions/${id}`)));  // supervisor of b1
  await assertFails(getDoc(doc(as('sup2', 'sup2@x.in').db, `attendanceSessions/${id}`)));     // supervisor of b2
  await assertSucceeds(getDoc(doc(as('oa', 'oa@firm-a.in').db, `attendanceSessions/${id}`))); // organisation A admin
  await assertSucceeds(getDoc(doc(as('col', 'col@x.in').db, `attendanceSessions/${id}`)));    // Collector
  await assertSucceeds(getDoc(doc(as('aud', 'aud@x.in').db, `attendanceSessions/${id}`)));    // auditor (history)
  await assertFails(getDoc(doc(admin().db, `attendanceSessions/${id}`)));                     // System administrator: no operational data
  // Area-filtered queries, as the officer dashboards run them: one area id
  // per query with array-contains.
  const sup = as('sup1', 'sup1@x.in').db;
  await assertSucceeds(getDocs(query(collection(sup, 'attendanceSessions'), where('areaPath', 'array-contains', 'b1'))));
  await assertFails(getDocs(query(collection(sup, 'attendanceSessions'), where('areaPath', 'array-contains', 'd1'))));   // whole district
  await assertFails(getDocs(query(collection(sup, 'attendanceSessions'), where('areaPath', 'array-contains', 'b2'))));
  await assertFails(getDocs(collection(sup, 'attendanceSessions')));
  // The officer attendance screen filters by area AND day.
  await assertSucceeds(getDocs(query(collection(sup, 'attendanceSessions'), where('areaPath', 'array-contains', 'b1'), where('date', '==', istToday()))));
  await assertFails(getDocs(query(collection(sup, 'attendanceSessions'), where('areaPath', 'array-contains', 'b2'), where('date', '==', istToday()))));
  await assertSucceeds(getDocs(query(collection(as('oa', 'oa@firm-a.in').db, 'attendanceSessions'), where('orgId', '==', 'orgA'), where('date', '==', istToday()))));
  await assertSucceeds(getDocs(query(collection(as('col', 'col@x.in').db, 'attendanceSessions'), where('date', '==', istToday()))));
  // An officer with several areas can query each of them (not only the first).
  await seed('accounts/sup3', { email: 'sup3@x.in', status: 'active' });
  await seed('roleAssignments/sup3__supervisor', { uid: 'sup3', role: 'supervisor', areaIds: ['b9', 'b1'], active: true, source: 'admin', grantedBy: 'adm' });
  await assertSucceeds(getDocs(query(collection(as('sup3', 'sup3@x.in').db, 'attendanceSessions'), where('areaPath', 'array-contains', 'b1'))));
  // Organisation admins query their own organisation; the Collector the district; auditors history.
  await assertSucceeds(getDocs(query(collection(as('oa', 'oa@firm-a.in').db, 'attendanceSessions'), where('orgId', '==', 'orgA'))));
  await assertFails(getDocs(query(collection(as('oa', 'oa@firm-a.in').db, 'attendanceSessions'), where('orgId', '==', 'orgB'))));
  await assertSucceeds(getDocs(collection(as('col', 'col@x.in').db, 'attendanceSessions')));
  await assertSucceeds(getDocs(collection(as('aud', 'aud@x.in').db, 'attendanceSessions')));
  await assertFails(getDocs(collection(admin().db, 'attendanceSessions')));
  // A record without an owner never becomes readable through the ownership check.
  await seed('attendanceSessions/orphan', { date: istToday(), areaPath: ['d1', 'b2'], evaluatedBy: 'device' });
  await assertFails(getDoc(doc(as('w1', 'w1@x.in').db, 'attendanceSessions/orphan')));
  await assertFails(getDoc(doc(as('sup1', 'sup1@x.in').db, 'attendanceSessions/orphan')));
  const w = as('w1', 'w1@x.in').db;
  await assertSucceeds(getDocs(query(collection(w, 'attendanceSessions'), where('uid', '==', 'w1'))));
  await assertFails(getDocs(query(collection(w, 'attendanceSessions'), where('uid', '==', 'w2'))));
});

test('a role or pre-registration covers at most 15 areas', async () => {
  const a = admin();
  const eleven = Array.from({ length: 16 }, (_, i) => `a${i}`);   // 16: one too many
  const ten = eleven.slice(0, 15);                                 // 15: the limit
  const grant = (areaIds) => {
    const b = writeBatch(a.db);
    b.update(doc(a.db, 'roleAssignments/w1__worker'), { areaIds, auditId: audit(b, a, 'roleAssignments/w1__worker') });
    return b.commit();
  };
  await assertFails(grant(eleven));
  await assertSucceeds(grant(ten));
  await assertFails(addPrereg(a, 'many@x.in', { role: 'supervisor', areaIds: eleven }));
  await assertSucceeds(addPrereg(a, 'ten@x.in', { role: 'supervisor', areaIds: ten }));
});

// =============================================================== Module 2: tasks, activities, demo data
import { Bytes } from 'firebase/firestore';

beforeEach(async () => {
  const ra = (uid, role, extra = {}) => ({ uid, role, areaIds: [], active: true, source: 'admin', grantedBy: 'adm', ...extra });
  await seed('areas/p1', { name: 'Street 1', level: 'panchayat', parentId: 'b1', path: ['d1', 'b1', 'p1'], provisional: true });
  await seed('accounts/zs1', { email: 'zs1@x.in', status: 'active', displayName: 'Zonal One' });
  await seed('roleAssignments/zs1__zonal_secretary', ra('zs1', 'zonal_secretary', { areaIds: ['b1'] }));
});

const task = (extra = {}) => ({
  title: 'Clean Street 1', description: 'Remove waste', areaId: 'p1', areaPath: ['d1', 'b1', 'p1'], priority: 'normal',
  dueDate: istToday(), status: 'assigned', createdBy: 'zs1', createdByName: 'Zonal One',
  createdAt: serverTimestamp(), updatedAt: serverTimestamp(), synthetic: false, ...extra,
});

test('attendance: a worker may look up today\'s own record before it exists', async () => {
  const w = as('w1', 'w1@x.in').db;
  await assertSucceeds(getDoc(doc(w, `attendanceSessions/w1_${istToday()}`)));     // not created yet
  await assertFails(getDoc(doc(w, `attendanceSessions/w2_${istToday()}`)));        // someone else's day
  await assertFails(getDoc(doc(w, 'attendanceSessions/w1_anything')));              // not a day id
});

test('tasks: created by area officers inside their area; workers there see and work on them', async () => {
  const zs = as('zs1', 'zs1@x.in').db;
  await assertSucceeds(setDoc(doc(zs, 'tasks/t1'), task()));
  await assertFails(setDoc(doc(zs, 'tasks/t2'), task({ areaId: 'b2', areaPath: ['d1', 'b2'] })));      // outside their zone
  await assertFails(setDoc(doc(zs, 'tasks/t3'), task({ areaPath: ['d1', 'b1'] })));                      // wrong path
  await assertFails(setDoc(doc(zs, 'tasks/t4'), task({ status: 'approved' })));
  await assertFails(setDoc(doc(as('sup1', 'sup1@x.in').db, 'tasks/t5'), task({ createdBy: 'sup1' })));  // supervisors: off by default
  await seed('config/app', { supervisorsMayCreateTasks: true });
  await assertSucceeds(setDoc(doc(as('sup1', 'sup1@x.in').db, 'tasks/t6'), task({ createdBy: 'sup1' })));
  await assertFails(setDoc(doc(as('w1', 'w1@x.in').db, 'tasks/t7'), task({ createdBy: 'w1' })));       // workers never create

  const w1 = as('w1', 'w1@x.in').db;
  await assertSucceeds(getDocs(query(collection(w1, 'tasks'), where('areaPath', 'array-contains', 'b1'))));
  await assertFails(getDocs(query(collection(as('w2', 'w2@x.in').db, 'tasks'), where('areaPath', 'array-contains', 'b1'))));
  await assertSucceeds(updateDoc(doc(w1, 'tasks/t1'), { status: 'in_progress', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'tasks/t1'), { status: 'approved', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'tasks/t1'), { title: 'Easier task', updatedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(as('sup1', 'sup1@x.in').db, 'tasks/t1'), { status: 'cancelled', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(as('sup2', 'sup2@x.in').db, 'tasks/t6'), { status: 'cancelled', updatedAt: serverTimestamp() }));
});

const jpeg = (n = 2000) => Bytes.fromUint8Array(new Uint8Array(n).fill(7));
const photo = (uid, activityId, index, extra = {}) => ({
  uid, activityId, index, jpeg: jpeg(), sizeBytes: 2000, createdAt: serverTimestamp(), synthetic: false, ...extra,
});
const activity = (extra = {}) => ({
  uid: 'w1', workerName: 'Worker One', date: istToday(), orgId: 'orgA', areaPath: ['d1', 'b1', 'p1'], taskId: 'tA',
  geofenceId: null, title: 'Street swept', description: 'Done', lat: 12.69, lng: 79.97, accuracy: 9, mocked: false,
  placement: 'inside', capturedAt: Timestamp.now(), photoCount: 1, status: 'submitted', evaluatedBy: 'device',
  createdAt: serverTimestamp(), synthetic: false, ...extra,
});
async function submit(who, id, act, photos = 1) {
  const b = writeBatch(who);
  for (let i = 0; i < photos; i++) b.set(doc(who, `activityPhotos/${id}_${i}`), photo('w1', id, i));
  b.set(doc(who, `activities/${id}`), act);
  return b.commit();
}

test('activities: photo proof for own work in own area; reviewed by area officers only', async () => {
  await seed('tasks/tA', { ...task(), createdAt: Timestamp.now(), updatedAt: Timestamp.now() });
  const w1 = as('w1', 'w1@x.in').db;
  await assertFails(submit(w1, 'a0', activity(), 0));                                   // no photo
  await assertFails(submit(w1, 'a1', activity({ photoCount: 2 }), 1));                  // claims a photo it did not save
  await assertFails(submit(w1, 'a2', activity({ workerName: 'Someone' })));             // fake name
  await assertFails(submit(w1, 'a3', activity({ areaPath: ['d1', 'b2'] })));            // not the task's area
  await assertFails(submit(w1, 'a4', activity({ status: 'approved' })));
  await assertSucceeds(submit(w1, 'a5', activity()));
  await assertFails(setDoc(doc(w1, 'activityPhotos/a5_1'), photo('w1', 'a5', 1)));     // no photos added later

  await assertFails(updateDoc(doc(w1, 'activities/a5'), { status: 'approved', reviewNote: '', reviewedBy: 'w1', reviewedAt: serverTimestamp() }));
  const sup1 = as('sup1', 'sup1@x.in').db;
  await assertFails(updateDoc(doc(sup1, 'activities/a5'), { status: 'rejected', reviewNote: '', reviewedBy: 'sup1', reviewedAt: serverTimestamp() })); // reason required
  await assertSucceeds(updateDoc(doc(sup1, 'activities/a5'), { status: 'approved', reviewNote: '', reviewedBy: 'sup1', reviewedByName: 'Sup', reviewedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(as('sup2', 'sup2@x.in').db, 'activities/a5'), { status: 'rework', reviewNote: 'x', reviewedBy: 'sup2', reviewedAt: serverTimestamp() }));

  // Who can read the activity and its photo.
  await assertSucceeds(getDocs(query(collection(sup1, 'activities'), where('areaPath', 'array-contains', 'b1'), where('date', '==', istToday()))));
  await assertFails(getDoc(doc(as('sup2', 'sup2@x.in').db, 'activities/a5')));
  await assertSucceeds(getDocs(query(collection(w1, 'activities'), where('uid', '==', 'w1'))));
  await assertSucceeds(getDoc(doc(sup1, 'activityPhotos/a5_0')));
  await assertSucceeds(getDoc(doc(w1, 'activityPhotos/a5_0')));
  await assertFails(getDoc(doc(as('w2', 'w2@x.in').db, 'activityPhotos/a5_0')));
  await assertFails(getDoc(doc(as('sup2', 'sup2@x.in').db, 'activityPhotos/a5_0')));
});

test('demo data: synthetic only, removable, never disguised as a real worker', async () => {
  const a = admin().db;
  const demo = { ...session('w1'), uid: 'demo-1', workerName: 'Demo Worker 1', synthetic: true };
  await assertSucceeds(setDoc(doc(a, `attendanceSessions/demo-1_${istToday()}`), demo));
  await assertFails(setDoc(doc(a, `attendanceSessions/w1_${istToday()}`), { ...demo, uid: 'w1' }));                 // real worker id
  await assertFails(setDoc(doc(a, 'attendanceSessions/demo-2_x'), { ...demo, uid: 'demo-2', synthetic: false }));
  await assertSucceeds(getDocs(query(collection(a, 'attendanceSessions'), where('synthetic', '==', true))));
  await assertSucceeds(getDocs(query(collection(as('sup1', 'sup1@x.in').db, 'attendanceSessions'), where('areaPath', 'array-contains', 'b1'))));
  await assertSucceeds(deleteDoc(doc(a, `attendanceSessions/demo-1_${istToday()}`)));
  await assertSucceeds(setDoc(doc(a, 'tasks/demoT'), { ...task(), synthetic: true }));
  await assertFails(setDoc(doc(as('zs1', 'zs1@x.in').db, 'tasks/fakeDemo'), task({ synthetic: true })));
});

// =============================================================== Module 3: live tracking, routes, street visits
const presence = (uid, extra = {}) => ({
  uid, workerName: workerNames[uid] ?? '', orgId: uid === 'w1' ? 'orgA' : 'orgB', areaPath: uid === 'w1' ? ['d1', 'b1'] : [],
  lat: 12.69, lng: 79.97, accuracy: 9, onDuty: true, designation: null, geofenceId: null, at: serverTimestamp(), synthetic: false, ...extra,
});

test('live location: own record only; seen by Collector and area officers, not org admins or auditors', async () => {
  const w1 = as('w1', 'w1@x.in').db;
  await assertFails(setDoc(doc(w1, 'presence/w1'), presence('w1', { workerName: 'Fake' })));
  await assertFails(setDoc(doc(w1, 'presence/w1'), presence('w1', { areaPath: ['d1', 'b2'] })));      // not their home area
  await assertFails(setDoc(doc(w1, 'presence/w1'), presence('w1', { designation: 'bdo_block' })));   // not their staff type
  await assertFails(setDoc(doc(w1, 'presence/w2'), presence('w2')));                                  // someone else
  await assertSucceeds(setDoc(doc(w1, 'presence/w1'), presence('w1')));
  await assertSucceeds(setDoc(doc(as('w2', 'w2@x.in').db, 'presence/w2'), presence('w2')));        // no area: empty path
  await assertSucceeds(getDocs(query(collection(as('sup1', 'sup1@x.in').db, 'presence'), where('areaPath', 'array-contains', 'b1'))));
  await assertFails(getDocs(query(collection(as('sup2', 'sup2@x.in').db, 'presence'), where('areaPath', 'array-contains', 'b1'))));
  await assertSucceeds(getDocs(collection(as('col', 'col@x.in').db, 'presence')));
  await assertFails(getDoc(doc(as('oa', 'oa@firm-a.in').db, 'presence/w1')));
  await assertFails(getDoc(doc(as('aud', 'aud@x.in').db, 'presence/w1')));
  await assertFails(getDoc(doc(admin().db, 'presence/w1')));
});

test('routes: own day only; same visibility as live location', async () => {
  const w1 = as('w1', 'w1@x.in').db;
  const id = `w1_${istToday()}`;
  const route = (extra = {}) => ({ uid: 'w1', workerName: 'Worker One', date: istToday(), orgId: 'orgA', areaPath: ['d1', 'b1'],
    points: [{ lat: 12.69, lng: 79.97, t: Timestamp.now() }], updatedAt: serverTimestamp(), synthetic: false, ...extra });
  await assertSucceeds(getDoc(doc(w1, `attendanceSessions/w1_${istToday()}`)));
  await assertSucceeds(getDoc(doc(w1, `routes/${id}`)));                                           // own day, not yet created
  await assertSucceeds(setDoc(doc(w1, `routes/${id}`), route()));
  await assertFails(setDoc(doc(w1, 'routes/w1_2020-01-01'), route({ date: '2020-01-01' })));
  await assertFails(setDoc(doc(w1, `routes/w2_${istToday()}`), route({ uid: 'w2' })));
  await assertSucceeds(getDoc(doc(as('sup1', 'sup1@x.in').db, `routes/${id}`)));
  await assertFails(getDoc(doc(as('aud', 'aud@x.in').db, `routes/${id}`)));
});

test('street visits: entry for own area boundary, exit added once, visible to officers in scope', async () => {
  const w1 = as('w1', 'w1@x.in').db;
  const visit = (extra = {}) => ({ uid: 'w1', workerName: 'Worker One', date: istToday(), orgId: 'orgA', areaPath: ['d1', 'b1'],
    geofenceId: 'g1', geofenceName: 'Test fence 1', enteredAt: Timestamp.fromMillis(Date.now() - 600000), exitedAt: null,
    durationMin: null, createdAt: serverTimestamp(), closedAt: null, synthetic: false, ...extra });
  await assertFails(setDoc(doc(w1, 'visits/v0'), visit({ geofenceId: 'g2', areaPath: ['d1', 'b2'] })));   // not their area
  await assertFails(setDoc(doc(w1, 'visits/v0'), visit({ exitedAt: Timestamp.now() })));                 // exit comes later
  await assertSucceeds(setDoc(doc(w1, 'visits/v1'), visit()));
  await assertFails(updateDoc(doc(w1, 'visits/v1'), { enteredAt: Timestamp.now() }));
  await assertFails(updateDoc(doc(w1, 'visits/v1'), { exitedAt: Timestamp.fromMillis(Date.now() - 900000), durationMin: 0, closedAt: serverTimestamp() })); // before entry
  await assertSucceeds(updateDoc(doc(w1, 'visits/v1'), { exitedAt: Timestamp.now(), durationMin: 10, closedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'visits/v1'), { exitedAt: Timestamp.now(), durationMin: 11, closedAt: serverTimestamp() }));
  await assertSucceeds(getDocs(query(collection(as('sup1', 'sup1@x.in').db, 'visits'), where('areaPath', 'array-contains', 'b1'), where('date', '==', istToday()))));
  await assertSucceeds(getDoc(doc(as('oa', 'oa@firm-a.in').db, 'visits/v1')));
  await assertFails(getDoc(doc(as('sup2', 'sup2@x.in').db, 'visits/v1')));
  await assertFails(getDoc(doc(admin().db, 'visits/v1')));
});

test('demo data: "Create" twice must replace, not overwrite; admin removes synthetic records only', async () => {
  const a = admin().db;
  const id = `demo-1_${istToday()}`;
  const demo = { ...session('w1'), uid: 'demo-1', workerName: 'Demo Worker 1', synthetic: true };
  await assertSucceeds(setDoc(doc(a, `attendanceSessions/${id}`), demo));
  await assertFails(setDoc(doc(a, `attendanceSessions/${id}`), demo));       // overwrite refused (records are immutable)
  await assertSucceeds(deleteDoc(doc(a, `attendanceSessions/${id}`)));       // remove first...
  await assertSucceeds(setDoc(doc(a, `attendanceSessions/${id}`), demo));    // ...then create again
  const synthetic = { uid: 'demo-1', workerName: 'Demo Worker 1', date: istToday(), orgId: null, areaPath: ['d1', 'b1'], synthetic: true };
  for (const [col, docId] of [['presence', 'demo-1'], ['routes', `demo-1_${istToday()}`], ['visits', 'demo-v1'], ['activities', 'demo-a1']]) {
    await seed(`${col}/${docId}`, synthetic);
    await assertSucceeds(getDocs(query(collection(a, col), where('synthetic', '==', true))));
    await assertSucceeds(deleteDoc(doc(a, `${col}/${docId}`)));
  }
  await seed('tasks/demo-t1', { ...synthetic, title: 'x' });
  await assertSucceeds(deleteDoc(doc(a, 'tasks/demo-t1')));
  await seed('visits/real-v1', { ...synthetic, uid: 'w1', synthetic: false });
  await assertFails(deleteDoc(doc(a, 'visits/real-v1')));                     // never a real record
});


// =============================================================== Village panchayat staff, photo attendance, messages
test('designations: prepared by the admin, copied exactly on first sign-in', async () => {
  const a = admin();
  await assertSucceeds(addPrereg(a, 'tk@x.in', { role: 'worker', designation: 'thoomai_kavalar', areaIds: ['b1'] }));
  await assertFails(addPrereg(a, 'bad@x.in', { role: 'worker', designation: 'chief_minister' }));
  await seed('preregistrations/sec@x.in', { email: 'sec@x.in', role: 'supervisor', designation: 'vp_secretary', areaIds: ['b1'], createdBy: 'adm' });
  const claimAs = (designation) => {
    const who = as('sec1', 'sec@x.in');
    const b = writeBatch(who.db);
    b.set(doc(who.db, 'accounts/sec1'), account('sec@x.in'));
    b.set(doc(who.db, 'roleAssignments/sec1__supervisor'), assignment('sec1', 'supervisor', {
      areaIds: ['b1'], source: 'preregistration', grantedBy: 'adm', designation,
      auditId: audit(b, who, 'roleAssignments/sec1__supervisor', 'account_claimed'),
    }));
    b.update(doc(who.db, 'preregistrations/sec@x.in'), { claimedBy: 'sec1', claimedAt: serverTimestamp() });
    return b.commit();
  };
  await assertFails(claimAs('bdo_block'));        // a different designation
  await assertSucceeds(claimAs('vp_secretary'));
});

test('habitation is an area level under the village panchayat', async () => {
  const a = admin();
  const b = writeBatch(a.db);
  b.set(doc(a.db, 'areas/h1'), { name: 'Habitation 1', level: 'habitation', parentId: 'p1', path: ['d1', 'b1', 'p1', 'h1'], provisional: true, auditId: audit(b, a, 'areas/h1') });
  await assertSucceeds(b.commit());
});

test('staff with a monitoring role mark their own attendance in their own area', async () => {
  await seed('roleAssignments/sup1__supervisor', { uid: 'sup1', role: 'supervisor', areaIds: ['b1'], active: true, source: 'admin', grantedBy: 'adm', designation: 'mnp' });
  await seed('accounts/sup1', { email: 'sup1@x.in', status: 'active', displayName: 'Sup One' });
  const s1 = as('sup1', 'sup1@x.in').db;
  const mine = (extra = {}) => ({ ...session('w1'), uid: 'sup1', workerName: 'Sup One', orgId: null, role: 'supervisor', designation: 'mnp', ...extra });
  await assertFails(setDoc(doc(s1, `attendanceSessions/sup1_${istToday()}`), mine({ designation: 'vp_secretary' })));  // not their designation
  await assertFails(setDoc(doc(s1, `attendanceSessions/sup1_${istToday()}`), mine({ role: 'officer' })));               // a role they do not hold
  await assertSucceeds(setDoc(doc(s1, `attendanceSessions/sup1_${istToday()}`), mine()));
  await assertSucceeds(getDoc(doc(as('col', 'col@x.in').db, `attendanceSessions/sup1_${istToday()}`)));
});

const punch = (uid, extra = {}) => ({
  uid, workerName: workerNames[uid] ?? '', role: 'worker', designation: 'thoomai_kavalar', date: istToday(), orgId: 'orgA',
  areaPath: ['d1', 'b1'], slot: '09:00', lat: 12.69, lng: 79.97, accuracy: 9, mocked: false, placement: 'inside', geofenceId: 'g1',
  status: 'verified', reasons: [], note: null, capturedAt: Timestamp.now(), createdAt: serverTimestamp(), synthetic: false, ...extra,
});
async function takePhoto(who, id, data, withPhoto = true) {
  const b = writeBatch(who);
  if (withPhoto) b.set(doc(who, `photoAttendancePhotos/${id}`), { uid: data.uid, jpeg: jpeg(), sizeBytes: 2000, createdAt: serverTimestamp() });
  b.set(doc(who, `photoAttendance/${id}`), data);
  return b.commit();
}

test('GPS photo attendance: own designation, photo required, seen by area officers', async () => {
  await seed('roleAssignments/w1__worker', { uid: 'w1', role: 'worker', areaIds: ['b1'], orgId: 'orgA', active: true, source: 'admin', grantedBy: 'adm', designation: 'thoomai_kavalar' });
  const w1 = as('w1', 'w1@x.in').db;
  await assertFails(takePhoto(w1, 'p0', punch('w1'), false));                                      // no photo
  await assertFails(takePhoto(w1, 'p1', punch('w1', { designation: 'vp_secretary' })));            // not their designation
  await assertFails(takePhoto(w1, 'p2', punch('w1', { workerName: 'Someone' })));                   // fake name
  await assertFails(takePhoto(w1, 'p3', punch('w1', { reasons: ['outside_area'] })));               // "verified" with a reason
  await assertFails(takePhoto(w1, 'p4', punch('w1', { geofenceId: 'g2', areaPath: ['d1', 'b2'] }))); // not their area
  await assertSucceeds(takePhoto(w1, 'p5', punch('w1')));
  await assertSucceeds(takePhoto(w1, 'p6', punch('w1', { geofenceId: null, placement: 'none', status: 'flagged', reasons: ['no_geofence'], areaPath: ['d1', 'b1'] })));
  await assertFails(takePhoto(w1, 'p7', punch('w1', { geofenceId: null, placement: 'none', status: 'flagged', reasons: ['no_geofence'], areaPath: [] })));  // must keep the home area
  await assertFails(updateDoc(doc(w1, 'photoAttendance/p5'), { status: 'verified' }));
  const sup1 = as('sup1', 'sup1@x.in').db;
  await assertSucceeds(getDocs(query(collection(sup1, 'photoAttendance'), where('areaPath', 'array-contains', 'b1'), where('date', '==', istToday()))));
  await assertSucceeds(getDoc(doc(sup1, 'photoAttendancePhotos/p5')));
  await assertFails(getDoc(doc(as('sup2', 'sup2@x.in').db, 'photoAttendancePhotos/p5')));
  await assertFails(getDoc(doc(as('w2', 'w2@x.in').db, 'photoAttendance/p5')));
});

test('messages: the district admin sends, every active account reads', async () => {
  const msg = (uid, extra = {}) => ({ title: 'Meeting', body: 'Block review at 4 pm', priority: 'normal', designations: [], roles: [],
    createdBy: uid, createdByName: 'Admin', createdAt: serverTimestamp(), ...extra });
  await assertSucceeds(setDoc(doc(admin().db, 'messages/m1'), msg('adm')));
  await assertFails(setDoc(doc(as('col', 'col@x.in').db, 'messages/m2'), msg('col')));
  await assertFails(setDoc(doc(as('w1', 'w1@x.in').db, 'messages/m3'), msg('w1')));
  await assertSucceeds(getDoc(doc(as('w1', 'w1@x.in').db, 'messages/m1')));
  await assertFails(getDoc(doc(as('dis', 'dis@x.in').db, 'messages/m1')));                       // disabled account
  await assertFails(updateDoc(doc(admin().db, 'messages/m1'), { body: 'changed' }));
});

test('deleting a role: administrator only, never their own, always recorded in the audit log', async () => {
  const granted = Timestamp.fromMillis(1700000000000);
  await seed('roleAssignments/w1__worker', { uid: 'w1', role: 'worker', areaIds: ['b1'], orgId: 'orgA', active: true, source: 'admin', grantedBy: 'adm', grantedAt: granted });
  await seed('roleAssignments/adm__sys_admin', { uid: 'adm', role: 'sys_admin', areaIds: [], active: true, source: 'bootstrap', grantedBy: 'adm', grantedAt: granted });
  const a = admin();
  const del = (who, id, auditId, target) => {
    const b = writeBatch(who.db);
    b.set(doc(who.db, `auditLog/${auditId}`), { actorUid: who.uid, actorEmail: who.email, action: 'role_deleted', target, details: '', at: serverTimestamp() });
    b.delete(doc(who.db, `roleAssignments/${id}`));
    return b.commit();
  };
  await assertFails(deleteDoc(doc(a.db, 'roleAssignments/w1__worker')));                                                    // no audit entry
  await assertFails(del(a, 'w1__worker', 'del_w1__worker_123', 'roleAssignments/w1__worker'));                             // wrong id
  await assertFails(del(a, 'w1__worker', 'del_w1__worker_1700000000000', 'roleAssignments/w2__worker'));                   // wrong target
  await assertFails(del(as('col', 'col@x.in'), 'w1__worker', 'del_w1__worker_1700000000000', 'roleAssignments/w1__worker')); // not the administrator
  await assertFails(del(a, 'adm__sys_admin', 'del_adm__sys_admin_1700000000000', 'roleAssignments/adm__sys_admin'));       // own role: never
  await assertSucceeds(del(a, 'w1__worker', 'del_w1__worker_1700000000000', 'roleAssignments/w1__worker'));
});

test('removing a signed-in person: administrator only', async () => {
  await seed('preregistrations/gone@x.in', { email: 'gone@x.in', role: 'worker', areaIds: [], orgId: 'orgA', createdBy: 'oa', claimedBy: 'g1' });
  await assertFails(deleteDoc(doc(as('oa', 'oa@firm-a.in').db, 'preregistrations/gone@x.in')));   // organisation admin: only before sign-in
  await assertFails(deleteDoc(doc(as('w1', 'w1@x.in').db, 'preregistrations/gone@x.in')));
  await assertSucceeds(deleteDoc(doc(admin().db, 'preregistrations/gone@x.in')));
});

test('cleaning zones: set by the administrator inside a real street boundary, audited', async () => {
  const a = admin();
  const zone = (who, id, data) => { const b = writeBatch(who.db); b.set(doc(who.db, `cleaningZones/${id}`), { ...data, auditId: audit(b, who, `cleaningZones/${id}`) }); return b.commit(); };
  const ok = { name: 'Sri Ram Nagar Zone 1', streetFenceId: 'g1', areaPath: ['d1', 'b1'], center: new GeoPoint(12.69, 79.97), radiusM: 25, order: 0 };
  await assertSucceeds(zone(a, 'z1', ok));
  await assertFails(zone(a, 'z2', { ...ok, areaPath: ['d1', 'b2'] }));          // not the street's area
  await assertFails(zone(a, 'z3', { ...ok, radiusM: 500 }));
  await assertFails(zone(as('zs1', 'zs1@x.in'), 'z4', ok));                       // only the administrator
  await assertSucceeds(getDoc(doc(as('w1', 'w1@x.in').db, 'cleaningZones/z1')));
});

test('street visits: zones reached are added during the visit, never removed; check-out once', async () => {
  const w1 = as('w1', 'w1@x.in').db;
  const visit = { uid: 'w1', workerName: 'Worker One', date: istToday(), orgId: 'orgA', areaPath: ['d1', 'b1'], geofenceId: 'g1',
    geofenceName: 'Sri Ram Nagar', enteredAt: Timestamp.fromMillis(Date.now() - 1980000), exitedAt: null, durationMin: null,
    createdAt: serverTimestamp(), closedAt: null, synthetic: false, zonesTotal: 8, zonesDone: [] };
  await assertFails(setDoc(doc(w1, 'visits/s0'), { ...visit, zonesDone: ['z1'] }));                      // zones start empty
  await assertSucceeds(setDoc(doc(w1, 'visits/s1'), visit));
  await assertSucceeds(updateDoc(doc(w1, 'visits/s1'), { zonesDone: ['z1', 'z2'], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'visits/s1'), { zonesDone: ['z1'], updatedAt: serverTimestamp() }));        // never removed
  await assertFails(updateDoc(doc(w1, 'visits/s1'), { zonesDone: ['z1', 'z2', 'z3'], enteredAt: Timestamp.now(), updatedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(w1, 'visits/s1'), { zonesDone: ['z1', 'z2', 'z3'], exitedAt: Timestamp.now(), durationMin: 33, closedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(w1, 'visits/s1'), { zonesDone: ['z1', 'z2', 'z3', 'z4'], updatedAt: serverTimestamp() }));  // after check-out: nothing
  await assertSucceeds(getDoc(doc(as('sup1', 'sup1@x.in').db, 'visits/s1')));
});

test('demonstration simulation: the administrator may update synthetic visits only', async () => {
  await seed('visits/sim1', { uid: 'demo-s01', workerName: 'Sample', date: istToday(), areaPath: ['d1', 'b1'], geofenceId: 'g1',
    enteredAt: Timestamp.now(), exitedAt: null, zonesDone: [], synthetic: true });
  await seed('visits/real1', { uid: 'w1', workerName: 'Worker One', date: istToday(), areaPath: ['d1', 'b1'], geofenceId: 'g1',
    enteredAt: Timestamp.now(), exitedAt: null, zonesDone: [], synthetic: false });
  const a = admin().db;
  await assertSucceeds(updateDoc(doc(a, 'visits/sim1'), { zonesDone: ['z1'], synthetic: true }));
  await assertFails(updateDoc(doc(a, 'visits/real1'), { zonesDone: ['z1'] }));                 // never a real worker's visit
  await assertFails(updateDoc(doc(a, 'visits/sim1'), { synthetic: false }));                   // cannot turn demo into "real"
  await assertFails(updateDoc(doc(as('w1', 'w1@x.in').db, 'visits/sim1'), { zonesDone: ['z2'], synthetic: true }));
});
