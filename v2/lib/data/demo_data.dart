import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/attendance.dart';
import 'audited_batch.dart';

/// Synthetic demo records so every role sees realistic data before real
/// workers use the app. Everything is marked `synthetic: true`, belongs to
/// "Demo …" areas, uses worker ids starting with "demo-", and can be removed.
/// Officers outside the demo areas only see it if given the demo block
/// (Setup → Access); the Collector and auditors see it straight away.
class DemoData {
  DemoData(this.user, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;
  final User user;
  final FirebaseFirestore db;

  static const _collections = ['attendanceSessions', 'tasks', 'activities', 'presence', 'routes', 'visits', 'photoAttendance'];
  static const _designations = ['thoomai_kavalar', 'thoomai_kavalar', 'oht_operator', 'mnp', 'vp_secretary', 'dy_bdo_panchayats'];
  // Photo times (hour, minute) per demo worker: some complete, some missing.
  static const _photoTimes = [
    [(9, 5), (13, 10)],
    [(9, 20)],
    [(6, 30)],
    [(8, 40), (12, 15), (16, 5)],
    [(10, 2), (13, 5)],
    [(10, 15), (18, 3)],
  ];

  Future<String> generate({double lat = 12.6919, double lng = 79.9762}) async {
    // 1. Demo areas under the first district (or a demo district).
    // Saved ONE LEVEL PER BATCH: the security rules check each area against
    // its parent with get(), which sees the database as it was before the
    // batch, so a parent must already be saved before its children.
    var stage = 0;
    Future<void> save(void Function(AuditedBatch b) fill) async {
      stage++;
      final b = AuditedBatch(db, user);
      fill(b);
      await _step('Saving demo areas and boundaries (part $stage)', b.commit);
    }

    void area(AuditedBatch b, String id, String name, String level, String? parent, List<String> path) =>
        b.batch.set(db.doc('areas/$id'), {
          'name': name, 'level': level, 'parentId': parent, 'path': path, 'provisional': true,
          ...b.stamp('demo_area', 'areas/$id'),
        });

    final districts = await db.collection('areas').where('level', isEqualTo: 'district').limit(1).get();
    final String districtId;
    final List<String> districtPath;
    if (districts.docs.isEmpty) {
      districtId = 'demo-district';
      districtPath = [districtId];
      await save((b) => area(b, districtId, 'Demo District', 'district', null, districtPath));
    } else {
      districtId = districts.docs.first.id;
      districtPath = ((districts.docs.first.data()['path'] as List?) ?? [districtId]).whereType<String>().toList();
    }
    final block = [...districtPath, 'demo-block'];
    final panchayat = [...block, 'demo-panchayat'];
    final streets = [
      [...panchayat, 'demo-street-1'],
      [...panchayat, 'demo-street-2'],
    ];
    await save((b) => area(b, 'demo-block', 'Demo Block (synthetic)', 'block', districtId, block));
    await save((b) => area(b, 'demo-panchayat', 'Demo Panchayat', 'panchayat', 'demo-block', panchayat));
    await save((b) {
      area(b, 'demo-street-1', 'Demo Street 1', 'location', 'demo-panchayat', streets.first);
      area(b, 'demo-street-2', 'Demo Street 2', 'location', 'demo-panchayat', streets.last);
    });
    // Boundaries are checked against their (now saved) street areas.
    await save((b) {
      for (var i = 0; i < 2; i++) {
        final id = 'demo-fence-${i + 1}';
        b.batch.set(db.doc('geofences/$id'), {
          'name': 'Demo Street ${i + 1} boundary', 'areaId': 'demo-street-${i + 1}', 'areaPath': streets.elementAt(i),
          'kind': 'circle', 'center': GeoPoint(lat + i * 0.004, lng + i * 0.004), 'radiusM': 150.0, 'provisional': true,
          ...b.stamp('demo_geofence', 'geofences/$id'),
        });
      }
    });

    // 2. Remove earlier demo records first. The security rules never allow a
    //    created record (attendance, task, report, visit) to be overwritten, so
    //    pressing "Create" again must replace them, not update them.
    await _step('Removing earlier demo records', clear);

    // 3. Today's attendance, tasks and field reports (synthetic).
    final now = DateTime.now();
    final day = dayKey(now);
    Timestamp at(int h, int m) => Timestamp.fromDate(DateTime(now.year, now.month, now.day, h, m));
    final w = db.batch();
    final people = [
      ('Demo Worker 1', 0, 'verified', <String>[], false, true),
      ('Demo Worker 2', 0, 'verified', <String>[], true, false),
      ('Demo Worker 3', 1, 'flagged', ['outside_area'], false, false),
      ('Demo Worker 4', 1, 'verified', <String>[], false, true),
      ('Demo Worker 5', 0, 'flagged', ['low_accuracy'], true, false),
      ('Demo Worker 6', 1, 'verified', <String>[], false, false),
    ];
    for (var i = 0; i < people.length; i++) {
      final p = people.elementAt(i);
      final uid = 'demo-w${i + 1}';
      final path = streets.elementAt(p.$2);
      w.set(db.doc('attendanceSessions/${uid}_$day'), {
        'uid': uid, 'workerName': p.$1, 'designation': _designations.elementAt(i), 'date': day, 'orgId': null, 'areaPath': path, 'evaluatedBy': 'device',
        'createdAt': at(8, 50 + i), 'synthetic': true,
        'checkIn': {
          'at': at(p.$5 ? 9 : 8, p.$5 ? 40 : 50 + i), 'deviceAt': at(8, 50 + i),
          'lat': lat + p.$2 * 0.004 + 0.0004 * i, 'lng': lng + p.$2 * 0.004, 'accuracy': p.$4.contains('low_accuracy') ? 85.0 : 9.0,
          'mocked': false, 'geofenceId': 'demo-fence-${p.$2 + 1}', 'placement': p.$4.contains('outside_area') ? 'outside' : 'inside',
          'edgeDistanceM': p.$4.contains('outside_area') ? -60.0 : 90.0, 'status': p.$3, 'late': p.$5, 'reasons': p.$4, 'eventId': 'demo-$i',
        },
        if (p.$6) 'checkOut': {'at': at(13, 10 + i), 'deviceAt': at(13, 10 + i), 'lat': lat, 'lng': lng, 'accuracy': 10.0, 'mocked': false, 'eventId': 'demo-out-$i'},
      });
    }
    for (var i = 0; i < people.length; i++) {
      final p = people.elementAt(i);
      var k = 0;
      for (final (h, m) in _photoTimes.elementAt(i)) {
        final when = DateTime(now.year, now.month, now.day, h, m);
        if (when.isAfter(now)) continue;
        w.set(db.doc('photoAttendance/demo-photo-${i + 1}-${k++}'), {
          'uid': 'demo-w${i + 1}', 'workerName': p.$1, 'role': 'worker', 'designation': _designations.elementAt(i),
          'date': day, 'orgId': null, 'areaPath': streets.elementAt(p.$2), 'slot': null,
          'lat': lat + p.$2 * 0.004, 'lng': lng + p.$2 * 0.004, 'accuracy': 9.0, 'mocked': false,
          'placement': p.$4.contains('outside_area') ? 'outside' : 'inside', 'geofenceId': 'demo-fence-${p.$2 + 1}',
          'status': p.$3, 'reasons': p.$4, 'note': null,
          'capturedAt': Timestamp.fromDate(when), 'createdAt': Timestamp.fromDate(when), 'synthetic': true,
        });
      }
    }
    final tasks = [
      ('Clean Demo Street 1 drains', 0, 'assigned', 'high', 0),
      ('Sweep Demo Street 2', 1, 'in_progress', 'normal', 0),
      ('Remove garbage heap near school', 0, 'submitted', 'high', -1),
      ('Paint road-side bins', 1, 'approved', 'low', -2),
    ];
    for (var i = 0; i < tasks.length; i++) {
      final t = tasks.elementAt(i);
      w.set(db.doc('tasks/demo-task-${i + 1}'), {
        'title': t.$1, 'description': 'Demo task (synthetic).', 'areaId': 'demo-street-${t.$2 + 1}', 'areaPath': streets.elementAt(t.$2),
        'priority': t.$4, 'dueDate': dayKey(now.add(Duration(days: t.$5))), 'status': t.$3,
        'createdBy': user.uid, 'createdByName': 'Demo Zonal Secretary', 'createdAt': at(8, 0), 'updatedAt': at(9, 0), 'synthetic': true,
      });
    }
    final reports = [
      ('Drain cleared', 0, 'submitted', 'demo-task-1', 1),
      ('Street swept', 1, 'approved', 'demo-task-2', 2),
      ('Garbage heap removed', 0, 'submitted', 'demo-task-3', 3),
      ('Bins painted', 1, 'approved', 'demo-task-4', 4),
      ('Fallen branch moved', 0, 'rework', null, 5),
    ];
    for (var i = 0; i < reports.length; i++) {
      final r = reports.elementAt(i);
      w.set(db.doc('activities/demo-activity-${i + 1}'), {
        'uid': 'demo-w${r.$5}', 'workerName': 'Demo Worker ${r.$5}', 'date': day, 'orgId': null, 'areaPath': streets.elementAt(r.$2),
        'taskId': r.$4, 'geofenceId': 'demo-fence-${r.$2 + 1}', 'title': r.$1, 'description': 'Demo report (synthetic).',
        'lat': lat + r.$2 * 0.004, 'lng': lng + r.$2 * 0.004, 'accuracy': 8.0, 'mocked': false, 'placement': 'inside',
        'capturedAt': at(10 + i, 15), 'photoCount': 0, 'status': r.$3, 'evaluatedBy': 'device', 'createdAt': at(10 + i, 20), 'synthetic': true,
        if (r.$3 == 'rework') 'reviewNote': 'Photo does not show the street (demo).',
      });
    }
    await _step('Saving demo attendance, tasks and reports', w.commit);
    final live = db.batch();
    // Live positions, today's routes and street visits for the demo workers.
    for (var i = 0; i < people.length; i++) {
      final p = people.elementAt(i);
      final uid = 'demo-w${i + 1}';
      final path = streets.elementAt(p.$2);
      final baseLat = lat + p.$2 * 0.004, baseLng = lng + p.$2 * 0.004;
      live.set(db.doc('presence/$uid'), {
        'uid': uid, 'workerName': p.$1, 'orgId': null, 'areaPath': path,
        'lat': baseLat + 0.0003 * (i - 2), 'lng': baseLng + 0.0002 * (i - 2), 'accuracy': 8.0,
        'onDuty': !p.$6, 'designation': _designations.elementAt(i), 'geofenceId': p.$6 ? null : 'demo-fence-${p.$2 + 1}',
        'at': Timestamp.fromDate(now.subtract(Duration(minutes: p.$6 ? 90 : 2 + i))), 'synthetic': true,
      });
      live.set(db.doc('routes/${uid}_$day'), {
        'uid': uid, 'workerName': p.$1, 'date': day, 'orgId': null, 'areaPath': path, 'synthetic': true,
        'updatedAt': Timestamp.fromDate(now),
        'points': [
          for (var k = 0; k < 12; k++)
            {'lat': baseLat - 0.003 + k * 0.00025 + 0.0003 * (i - 2), 'lng': baseLng - 0.002 + k * 0.00018, 't': at(9, k * 5)},
        ],
      });
      live.set(db.doc('visits/demo-visit-${i + 1}'), {
        'uid': uid, 'workerName': p.$1, 'date': day, 'orgId': null, 'areaPath': path,
        'geofenceId': 'demo-fence-${p.$2 + 1}', 'geofenceName': 'Demo Street ${p.$2 + 1} boundary',
        'enteredAt': at(9, 5 + i), 'exitedAt': p.$6 ? at(12, 40 + i) : null, 'durationMin': p.$6 ? 215 : null,
        'createdAt': at(9, 6 + i), 'closedAt': p.$6 ? at(12, 41 + i) : null, 'synthetic': true,
      });
    }
    await _step('Saving demo live positions, routes and street visits', live.commit);
    return 'Demo data created: 4 areas, 2 boundaries, ${people.length} attendance records, ${tasks.length} tasks, '
        '${reports.length} field reports, ${people.length} live positions, routes and street visits.';
  }

  /// Runs one step; on failure, says which step failed (shown to the admin).
  static Future<T> _step<T>(String name, Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw 'Step "$name" failed: $e';
    }
  }

  /// Removes the synthetic records. Demo areas and boundaries stay (areas
  /// cannot be deleted); their names start with "Demo".
  Future<int> clear() async {
    var n = 0;
    for (final c in _collections) {
      final snap = await db.collection(c).where('synthetic', isEqualTo: true).get();
      for (var i = 0; i < snap.docs.length; i += 400) {
        final batch = db.batch();
        for (final d in snap.docs.skip(i).take(400)) {
          batch.delete(d.reference);
          n++;
        }
        await batch.commit();
      }
    }
    return n;
  }
}
