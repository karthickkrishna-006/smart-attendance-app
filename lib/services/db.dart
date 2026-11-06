import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/fmt.dart';
import 'models.dart';

/// Thin data-access layer over Cloud Firestore.
///
/// Collections:
///  users, boundaries, attendance, verifications, locations, tasks,
///  activities, alerts, audit_logs, settings, meta
class Db {
  static final fs = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> col(String n) => fs.collection(n);

  static String? get uid => FirebaseAuth.instance.currentUser?.uid;

  // ---------------- Settings (configurable business rules) ----------------
  static const Map<String, dynamic> defaultSettings = {
    'lateAfter': '09:30',
    'missingAfter': '11:00',
    'faceThreshold': 0.60,
    'maxGpsAccuracy': 50,
    'requireFace': true,
    'requireBoundary': true,
    'trackingIntervalSec': 30,
    // Field-duty history: save a point after moving this far, or after this
    // long without one (fewer points = less battery and database use).
    'trackMinDistanceM': 50,
    'trackHeartbeatSec': 300,
    // Photo evidence needs Cloud Storage for Firebase, which requires the
    // Blaze (pay-as-you-go) plan. Off by default so the app works on Spark.
    'evidenceStorageEnabled': false,
    'rules': {
      'face_failed': true,
      'outside_boundary': true,
      'mock_location': true,
      'late_checkin': true,
      'missing_attendance': true,
      'overdue_task': true,
      'low_accuracy': true,
    },
  };

  static Map<String, dynamic> mergeSettings(Map<String, dynamic>? s) {
    final m = Map<String, dynamic>.from(defaultSettings);
    m['rules'] = Map<String, dynamic>.from(defaultSettings['rules'] as Map);
    if (s != null) {
      s.forEach((k, v) {
        if (k == 'rules' && v is Map) {
          m['rules'] = <String, dynamic>{...(defaultSettings['rules'] as Map), ...v};
        } else {
          m[k] = v;
        }
      });
    }
    return m;
  }

  static Future<Map<String, dynamic>> getSettings() async {
    try {
      final d = await col('settings').doc('config').get();
      return mergeSettings(d.data());
    } catch (_) {
      return mergeSettings(null);
    }
  }

  static Stream<Map<String, dynamic>> settingsStream() =>
      col('settings').doc('config').snapshots().map((d) => mergeSettings(d.data()));

  static bool ruleOn(Map<String, dynamic> settings, String rule) =>
      ((settings['rules'] as Map?)?[rule] ?? true) == true;

  // ---------------- Users ----------------
  static Future<AppUser?> getUser(String id) async {
    final d = await col('users').doc(id).get();
    if (!d.exists) return null;
    return AppUser(d.id, d.data()!);
  }

  static Future<Boundary?> getBoundary(String? id) async {
    if (id == null || id.isEmpty) return null;
    final d = await col('boundaries').doc(id).get();
    if (!d.exists) return null;
    return Boundary(d.id, {...d.data()!, 'id': d.id});
  }

  // ---------------- Tracking data scope ----------------
  /// Builds a query on tracking data that the security rules will accept for
  /// this person:
  ///  * Administrator: the whole district.
  ///  * Supervisor: only workers assigned to them (`supervisorId`).
  ///  * Field worker: only their own records.
  ///  * Auditor: duty summaries (`tracking_sessions`) only; no live positions
  ///    or movement history, so this returns null for those.
  /// [workerUid] narrows the query to one worker.
  static Query<Map<String, dynamic>>? trackingQuery(String collection, AppUser me, {String? workerUid}) {
    final summariesOnly = collection == 'tracking_sessions';
    if (me.role == Roles.auditor && !summariesOnly) return null;
    Query<Map<String, dynamic>> q = col(collection);
    if (me.role == Roles.supervisor) q = q.where('supervisorId', isEqualTo: me.uid);
    final target = me.role == Roles.worker ? me.uid : workerUid;
    if (target != null) q = q.where('uid', isEqualTo: target);
    return q;
  }

  // ---------------- Audit trail ----------------
  static Future<void> audit(String action, String target, [Map<String, dynamic>? details]) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    try {
      await col('audit_logs').add({
        'action': action,
        'target': target,
        'details': details ?? {},
        'actorUid': u.uid,
        'actorEmail': u.email ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // audit failures must never block the user flow
    }
  }

  // ---------------- Alerts ----------------
  /// Creates an alert. If [dedupId] is given, the alert is only created once.
  static Future<void> raiseAlert({
    required String type,
    required String description,
    required String severity, // low | medium | high | critical
    String? uid,
    String? workerName,
    String? taskId,
    String? dedupId,
    bool synthetic = false,
  }) async {
    final data = {
      'type': type,
      'description': description,
      'severity': severity,
      'uid': uid,
      'workerName': workerName,
      'taskId': taskId,
      'status': 'open',
      'synthetic': synthetic,
      'createdAt': FieldValue.serverTimestamp(),
      'date': dayKey(DateTime.now()),
    };
    try {
      if (dedupId != null) {
        final ref = col('alerts').doc(dedupId);
        final ex = await ref.get();
        if (ex.exists) return;
        await ref.set(data);
      } else {
        await col('alerts').add(data);
      }
    } catch (_) {}
  }

  /// Rule engine run from the staff dashboard: missing attendance & overdue tasks.
  static Future<int> runAlertChecks() async {
    final s = await getSettings();
    int created = 0;
    final now = DateTime.now();
    final today = dayKey(now);
    if (ruleOn(s, 'missing_attendance') && now.hour * 60 + now.minute >= hm(s['missingAfter'] as String)) {
      final workers = await col('users').where('role', isEqualTo: Roles.worker).get();
      final att = await col('attendance').where('date', isEqualTo: today).get();
      final present = att.docs.map((d) => d.data()['uid']).toSet();
      for (final w in workers.docs) {
        final d = w.data();
        if ((d['status'] ?? 'active') != 'active' || present.contains(w.id)) continue;
        final id = 'missing_${w.id}_$today';
        final ex = await col('alerts').doc(id).get();
        if (ex.exists) continue;
        await col('alerts').doc(id).set({
          'type': 'attendance_missing',
          'description': 'Attendance not submitted by ${d['name']} today (after ${s['missingAfter']}).',
          'severity': 'medium',
          'uid': w.id,
          'workerName': d['name'],
          'status': 'open',
          'synthetic': d['synthetic'] == true,
          'createdAt': FieldValue.serverTimestamp(),
          'date': today,
        });
        created++;
      }
    }
    if (ruleOn(s, 'overdue_task')) {
      final tasks = await col('tasks').get();
      for (final t in tasks.docs) {
        final d = t.data();
        final due = toDate(d['dueDate']);
        final st = d['status'] ?? 'assigned';
        if (due == null || st == 'completed' || due.isAfter(now)) continue;
        final id = 'overdue_${t.id}';
        final ex = await col('alerts').doc(id).get();
        if (ex.exists) continue;
        await col('alerts').doc(id).set({
          'type': 'task_delayed',
          'description': 'Task "${d['title']}" assigned to ${d['assignedName'] ?? 'worker'} is past its due date (${fmtDate(due)}).',
          'severity': 'high',
          'uid': d['assignedTo'],
          'workerName': d['assignedName'],
          'taskId': t.id,
          'status': 'open',
          'synthetic': d['synthetic'] == true,
          'createdAt': FieldValue.serverTimestamp(),
          'date': today,
        });
        created++;
      }
    }
    return created;
  }
}
