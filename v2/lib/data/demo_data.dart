import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/attendance.dart';
import '../domain/designations.dart';
import 'audited_batch.dart';
import 'sample_district_data.dart';

/// Loads the SAMPLE district (Smart-Attendance-SAMPLE-Data.xlsx): one block,
/// zones, village panchayats, habitations, streets with boundaries and
/// cleaning zones, and today's activity of 43 sample staff.
///
/// * Master data (areas, boundaries, cleaning zones) is saved like real data,
///   audited, in small batches (Firestore lets the security rules look up at
///   most 20 documents per batch, and every audited write needs one).
/// * Activity records are synthetic (worker ids "demo-…", marked synthetic)
///   and can be removed with [clear].
class DemoData {
  DemoData(this.user, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;
  final User user;
  final FirebaseFirestore db;

  static const _collections = ['attendanceSessions', 'tasks', 'activities', 'presence', 'routes', 'visits', 'photoAttendance'];
  static const blockId = 'smp-block';

  static final _designationByTitle = {for (final d in Designation.values) d.title: d};
  static Designation designationOf(SampleStaff s) =>
      _designationByTitle[s.designation] ??
      Designation.values.firstWhere((d) => d.title.startsWith(s.designation.split(' (').first), orElse: () => Designation.thoomaiKavalar);

  static String staffUid(int i) => 'demo-s${(i + 1).toString().padLeft(2, '0')}';
  static String panchayatId(int p) => 'smp-p${p + 1}';
  static String habitationId(int p, int h) => 'smp-p${p + 1}-h${h + 1}';
  static String streetId(int p, int h, int s) => 'smp-p${p + 1}-h${h + 1}-s${s + 1}';
  static String fenceId(int p, int h, int s) => 'smp-f${p + 1}-${h + 1}-${s + 1}';
  static String zoneAreaId(String zone) => 'smp-${zone.toLowerCase().replaceAll(' ', '-')}';

  static Future<T> _step<T>(String name, Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw 'Step "$name" failed: $e';
    }
  }

  /// Saves audited writes in batches of 5 (one level at a time).
  Future<void> _audited(String step, List<void Function(AuditedBatch b)> writes) async {
    for (var i = 0; i < writes.length; i += 5) {
      final b = AuditedBatch(db, user);
      for (final w in writes.skip(i).take(5)) {
        w(b);
      }
      await _step('$step (${i ~/ 5 + 1}/${(writes.length / 5).ceil()})', b.commit);
    }
  }

  /// [lat]/[lng]: move the whole sample so its block centre is there
  /// (to walk into sample streets for testing). Null = Thirukazhukundram.
  Future<String> generate({double? lat, double? lng, void Function(String)? progress}) async {
    // Shift so the sample's centre lands on the given point (if any).
    final all = [for (final p in samplePanchayats) for (final h in p.habitations) for (final s in h.streets) ...[s.start, s.end]];
    final cLat = all.map((x) => x.first).reduce((a, b) => a + b) / all.length;
    final cLng = all.map((x) => x.last).reduce((a, b) => a + b) / all.length;
    final dLat = lat == null ? 0.0 : lat - cLat;
    final dLng = lng == null ? 0.0 : lng - cLng;
    List<double> mv(List<double> p) => [p.first + dLat, p.last + dLng];

    void area(AuditedBatch b, String id, String name, String level, String? parent, List<String> path) => b.batch.set(db.doc('areas/$id'), {
          'name': name, 'level': level, 'parentId': parent, 'path': path, 'provisional': true,
          ...b.stamp('sample_area', 'areas/$id'),
        });

    // 1. Areas, parents first.
    progress?.call('Areas');
    final districts = await db.collection('areas').where('level', isEqualTo: 'district').limit(1).get();
    final String districtId;
    final List<String> districtPath;
    if (districts.docs.isEmpty) {
      districtId = 'smp-district';
      districtPath = [districtId];
      await _audited('Saving the district', [(b) => area(b, districtId, 'Chengalpattu', 'district', null, districtPath)]);
    } else {
      districtId = districts.docs.first.id;
      districtPath = ((districts.docs.first.data()['path'] as List?) ?? [districtId]).whereType<String>().toList();
    }
    final blockPath = [...districtPath, blockId];
    await _audited('Saving the block', [(b) => area(b, blockId, '$sampleBlockName (sample)', 'block', districtId, blockPath)]);
    final zonePath = {for (final z in sampleZones) z: [...blockPath, zoneAreaId(z)]};
    await _audited('Saving zones', [
      for (final z in sampleZones) (b) => area(b, zoneAreaId(z), z, 'zone', blockId, zonePath[z]!),
    ]);
    final pPath = <int, List<String>>{};
    final hPath = <String, List<String>>{};
    final sPath = <String, List<String>>{};
    for (var p = 0; p < samplePanchayats.length; p++) {
      pPath[p] = [...zonePath[samplePanchayats[p].zone]!, panchayatId(p)];
    }
    await _audited('Saving village panchayats', [
      for (var p = 0; p < samplePanchayats.length; p++)
        (b) => area(b, panchayatId(p), samplePanchayats[p].name, 'panchayat', zoneAreaId(samplePanchayats[p].zone), pPath[p]!),
    ]);
    final habWrites = <void Function(AuditedBatch)>[];
    final streetWrites = <void Function(AuditedBatch)>[];
    for (var p = 0; p < samplePanchayats.length; p++) {
      for (var h = 0; h < samplePanchayats[p].habitations.length; h++) {
        final hid = habitationId(p, h);
        hPath[hid] = [...pPath[p]!, hid];
        habWrites.add((b) => area(b, hid, samplePanchayats[p].habitations[h].name, 'habitation', panchayatId(p), hPath[hid]!));
        for (var s = 0; s < samplePanchayats[p].habitations[h].streets.length; s++) {
          final sid = streetId(p, h, s);
          sPath[sid] = [...hPath[hid]!, sid];
          streetWrites.add((b) => area(b, sid, samplePanchayats[p].habitations[h].streets[s].name, 'location', hid, sPath[sid]!));
        }
      }
    }
    progress?.call('Habitations');
    await _audited('Saving habitations', habWrites);
    progress?.call('Streets');
    await _audited('Saving streets', streetWrites);

    // 2. Street boundaries (rectangle 25 m each side of the street line) and
    //    cleaning zones evenly along it. Ring order: start-left, end-left,
    //    end-right, start-right (the simulation relies on it).
    progress?.call('Street boundaries and cleaning zones');
    final fenceWrites = <void Function(AuditedBatch)>[];
    final zoneWrites = <void Function(AuditedBatch)>[];
    for (var p = 0; p < samplePanchayats.length; p++) {
      for (var h = 0; h < samplePanchayats[p].habitations.length; h++) {
        for (var s = 0; s < samplePanchayats[p].habitations[h].streets.length; s++) {
          final st = samplePanchayats[p].habitations[h].streets[s];
          final a = mv(st.start), e = mv(st.end);
          final ring = streetRing(a, e, halfWidthM: 25, extendM: 15);
          final fid = fenceId(p, h, s);
          final sid = streetId(p, h, s);
          final name = '${st.name}, ${samplePanchayats[p].name.replaceAll('Sample ', '')}';
          fenceWrites.add((b) => b.batch.set(db.doc('geofences/$fid'), {
                'name': name, 'areaId': sid, 'areaPath': sPath[sid], 'kind': 'polygon',
                'ring': [for (final q in ring) GeoPoint(q.first, q.last)], 'provisional': true,
                ...b.stamp('sample_boundary', 'geofences/$fid'),
              }));
          for (var k = 0; k < st.zones; k++) {
            final t = (k + 0.5) / st.zones;
            final c = [a.first + (e.first - a.first) * t, a.last + (e.last - a.last) * t];
            final zid = '$fid-z${k + 1}';
            zoneWrites.add((b) => b.batch.set(db.doc('cleaningZones/$zid'), {
                  'name': '${st.name} Zone ${k + 1}', 'streetFenceId': fid, 'areaPath': sPath[sid],
                  'center': GeoPoint(c.first, c.last), 'radiusM': 20.0, 'order': k,
                  ...b.stamp('sample_cleaning_zone', 'cleaningZones/$zid'),
                }));
          }
        }
      }
    }
    await _audited('Saving street boundaries', fenceWrites);
    progress?.call('Cleaning zones (${zoneWrites.length})');
    await _audited('Saving cleaning zones', zoneWrites);

    // 3. Replace earlier synthetic activity, then today's activity of the staff.
    progress?.call('Today\'s activity');
    await _step('Removing earlier sample records', clear);
    final n = await _step('Saving today\'s sample activity', () => _activity(districtPath, blockPath, zonePath, pPath, hPath, sPath, mv));
    return 'Sample district created: 1 block, ${sampleZones.length} zones, ${samplePanchayats.length} village panchayats, '
        '${hPath.length} habitations, ${sPath.length} streets, ${zoneWrites.length} cleaning zones, ${sampleStaff.length} staff '
        '($n activity records).';
  }

  /// Rectangle around the street line [a] → [e] (lat/lng pairs).
  static List<List<double>> streetRing(List<double> a, List<double> e, {required double halfWidthM, required double extendM}) {
    final lat0 = a.first * math.pi / 180;
    final mLat = 111195.0, mLng = 111195.0 * math.cos(lat0);
    final dx = (e.last - a.last) * mLng, dy = (e.first - a.first) * mLat;
    final len = math.sqrt(dx * dx + dy * dy);
    final ux = dx / len, uy = dy / len; // along the street
    final px = -uy, py = ux; // left of the street
    List<double> at(List<double> base, double along, double side) =>
        [base.first + (uy * along + py * side) / mLat, base.last + (ux * along + px * side) / mLng];
    return [at(a, -extendM, halfWidthM), at(e, extendM, halfWidthM), at(e, extendM, -halfWidthM), at(a, -extendM, -halfWidthM)];
  }

  Future<int> _activity(
    List<String> districtPath,
    List<String> blockPath,
    Map<String, List<String>> zonePath,
    Map<int, List<String>> pPath,
    Map<String, List<String>> hPath,
    Map<String, List<String>> sPath,
    List<double> Function(List<double>) mv,
  ) async {
    final now = DateTime.now();
    final day = dayKey(now);
    Timestamp ago(int minutes) => Timestamp.fromDate(now.subtract(Duration(minutes: minutes)));
    final writes = <(String, Map<String, dynamic>)>[];
    final rnd = math.Random(now.day);
    var taskNo = 0, actNo = 0;

    for (var i = 0; i < sampleStaff.length; i++) {
      final st = sampleStaff[i];
      final d = designationOf(st);
      if (!d.schedule.required) continue; // district monitoring takes no photos
      final uid = staffUid(i);
      final p = samplePanchayats.indexWhere((x) => x.name == st.panchayat);
      final h = p < 0 ? -1 : samplePanchayats[p].habitations.indexWhere((x) => x.name == st.habitation);
      final List<String> path = switch (st.area) {
        'habitation' when p >= 0 && h >= 0 => hPath[habitationId(p, h)]!,
        'panchayat' when p >= 0 => pPath[p]!,
        final a when a.startsWith('zone:') => zonePath[a.substring(5)]!,
        'block' => blockPath,
        _ => districtPath,
      };
      final role = d.role.key;
      final flagged = i % 7 == 3;
      final late = i % 5 == 2;
      // Start of duty: Thoomai Kavalars early, others mid-morning (never in the future).
      final startMin = math.max(5, (d == Designation.thoomaiKavalar ? 6 * 60 : 10 * 60) - 0);
      final nowMin = now.hour * 60 + now.minute;
      final minutesSinceStart = math.max(5, nowMin - startMin - (late ? 25 : 2));
      final firstStreet = (p >= 0 && h >= 0) ? samplePanchayats[p].habitations[h].streets.first : null;
      final base = firstStreet != null
          ? mv(firstStreet.start)
          : p >= 0
              ? mv(samplePanchayats[p].habitations.first.streets.first.start)
              : mv(samplePanchayats.first.habitations.first.streets.first.start);

      writes.add(('attendanceSessions/${uid}_$day', {
        'uid': uid, 'workerName': st.name, 'role': role, 'designation': d.key, 'date': day, 'orgId': null, 'areaPath': path,
        'evaluatedBy': 'device', 'createdAt': ago(minutesSinceStart), 'synthetic': true,
        'checkIn': {
          'at': ago(minutesSinceStart), 'deviceAt': ago(minutesSinceStart), 'lat': base.first, 'lng': base.last,
          'accuracy': flagged ? 80.0 : 8.0 + rnd.nextInt(6), 'mocked': false, 'geofenceId': null,
          'placement': flagged ? 'uncertain' : 'inside', 'edgeDistanceM': 20.0, 'status': flagged ? 'flagged' : 'verified',
          'late': late, 'reasons': flagged ? ['low_accuracy'] : <String>[], 'eventId': 'smp-$i',
        },
      }));

      // GPS photos per the schedule (only times already passed; some missed on purpose).
      final slots = d.schedule.slotMinutes.isNotEmpty
          ? d.schedule.slotMinutes
          : [for (var k = 0; k < d.schedule.minPhotos; k++) startMin + 45 + k * 120];
      var k = 0;
      for (final slot in slots) {
        if (slot + 8 > nowMin) continue;
        if (i % 6 == 5 && slot == slots.last) continue; // missed photo time
        final when = DateTime(now.year, now.month, now.day, slot ~/ 60, slot % 60).add(Duration(minutes: rnd.nextInt(14) - 4));
        writes.add(('photoAttendance/smp-ph-$i-${k++}', {
          'uid': uid, 'workerName': st.name, 'role': role, 'designation': d.key, 'date': day, 'orgId': null, 'areaPath': path,
          'slot': d.schedule.slotMinutes.isEmpty ? null : '${(slot ~/ 60).toString().padLeft(2, '0')}:${(slot % 60).toString().padLeft(2, '0')}',
          'lat': base.first, 'lng': base.last, 'accuracy': 9.0, 'mocked': false, 'placement': flagged ? 'uncertain' : 'inside',
          'geofenceId': null, 'status': flagged ? 'flagged' : 'verified', 'reasons': flagged ? ['near_edge'] : <String>[],
          'note': d == Designation.ohtOperator ? 'Water opened' : null,
          'capturedAt': Timestamp.fromDate(when), 'createdAt': Timestamp.fromDate(when), 'synthetic': true,
        }));
      }

      // Thoomai Kavalars: live position, route and street visits with zones.
      if (d == Designation.thoomaiKavalar && p >= 0 && h >= 0) {
        final streets = samplePanchayats[p].habitations[h].streets;
        final s1 = streets.first, s2 = streets.length > 1 ? streets[1] : streets.first;
        final f1 = fenceId(p, h, 0), f2 = fenceId(p, h, streets.length > 1 ? 1 : 0);
        final a1 = mv(s1.start), e1 = mv(s1.end), a2 = mv(s2.start), e2 = mv(s2.end);
        final done1 = i % 4 == 1 ? s1.zones - 2 : s1.zones; // some streets left incomplete
        final progress2 = 0.35 + (i % 3) * 0.2;
        final finished2 = i % 5 == 0;
        writes.add(('visits/smp-v-$i-1', {
          'uid': uid, 'workerName': st.name, 'date': day, 'orgId': null, 'areaPath': sPath[streetId(p, h, 0)],
          'geofenceId': f1, 'geofenceName': '${s1.name}, ${samplePanchayats[p].name.replaceAll('Sample ', '')}',
          'enteredAt': ago(95), 'exitedAt': ago(62), 'durationMin': 33, 'createdAt': ago(94), 'closedAt': ago(61),
          'zonesTotal': s1.zones, 'zonesDone': [for (var z = 1; z <= done1; z++) '$f1-z$z'], 'synthetic': true,
        }));
        writes.add(('visits/smp-v-$i-2', {
          'uid': uid, 'workerName': st.name, 'date': day, 'orgId': null, 'areaPath': sPath[streetId(p, h, streets.length > 1 ? 1 : 0)],
          'geofenceId': f2, 'geofenceName': '${s2.name}, ${samplePanchayats[p].name.replaceAll('Sample ', '')}',
          'enteredAt': ago(55), 'exitedAt': finished2 ? ago(12) : null, 'durationMin': finished2 ? 43 : null,
          'createdAt': ago(54), 'closedAt': finished2 ? ago(11) : null, 'zonesTotal': s2.zones,
          'zonesDone': [for (var z = 1; z <= (finished2 ? s2.zones : (s2.zones * progress2).floor()); z++) '$f2-z$z'], 'synthetic': true,
        }));
        final pos = finished2 ? e2 : [a2.first + (e2.first - a2.first) * progress2, a2.last + (e2.last - a2.last) * progress2];
        writes.add(('presence/$uid', {
          'uid': uid, 'workerName': st.name, 'orgId': null, 'areaPath': path, 'designation': d.key,
          'lat': pos.first, 'lng': pos.last, 'accuracy': 7.0 + rnd.nextInt(8), 'onDuty': i % 9 != 8,
          'geofenceId': finished2 ? null : f2, 'at': ago(i % 6 == 4 ? 14 : 1 + rnd.nextInt(4)), 'synthetic': true,
        }));
        writes.add(('routes/${uid}_$day', {
          'uid': uid, 'workerName': st.name, 'date': day, 'orgId': null, 'areaPath': path, 'updatedAt': ago(1), 'synthetic': true,
          'points': [
            for (var q = 0; q <= 10; q++)
              {'lat': a1.first + (e1.first - a1.first) * q / 10, 'lng': a1.last + (e1.last - a1.last) * q / 10, 't': ago(95 - q * 3)},
            for (var q = 0; q <= 10; q++)
              {'lat': a2.first + (pos.first - a2.first) * q / 10, 'lng': a2.last + (pos.last - a2.last) * q / 10, 't': ago(55 - q * 4)},
          ],
        }));
        if (i % 2 == 0) {
          writes.add(('activities/smp-a-${actNo++}', {
            'uid': uid, 'workerName': st.name, 'date': day, 'orgId': null, 'areaPath': sPath[streetId(p, h, 0)], 'taskId': null,
            'geofenceId': f1, 'title': 'Household garbage collected: ${s1.name}', 'description': 'Sample report.',
            'lat': e1.first, 'lng': e1.last, 'accuracy': 8.0, 'mocked': false, 'placement': 'inside', 'capturedAt': ago(63),
            'photoCount': 0, 'status': ['submitted', 'approved', 'rework'][i % 3], 'evaluatedBy': 'device', 'createdAt': ago(62),
            'synthetic': true, if (i % 3 == 2) 'reviewNote': 'Bins near the school not cleared (sample).',
          }));
        }
      }
      // OHT operator: live position at the tank (panchayat start).
      if (d == Designation.ohtOperator) {
        writes.add(('presence/$uid', {
          'uid': uid, 'workerName': st.name, 'orgId': null, 'areaPath': path, 'designation': d.key,
          'lat': base.first + 0.0006, 'lng': base.last - 0.0004, 'accuracy': 10.0, 'onDuty': true, 'geofenceId': null,
          'at': ago(3 + rnd.nextInt(10)), 'synthetic': true,
        }));
      }
    }
    // Tasks: two per village panchayat.
    for (var p = 0; p < samplePanchayats.length; p++) {
      for (var t = 0; t < 2; t++) {
        final hab = samplePanchayats[p].habitations[t];
        final sid = streetId(p, t, 0);
        writes.add(('tasks/smp-t-${taskNo++}', {
          'title': t == 0 ? 'Clear garbage heap: ${hab.streets.first.name}' : 'Clean drains: ${hab.streets.first.name}',
          'description': 'Sample task.', 'areaId': sid, 'areaPath': sPath[sid], 'priority': t == 0 ? 'high' : 'normal',
          'dueDate': dayKey(now.add(Duration(days: t))), 'status': ['assigned', 'in_progress', 'submitted', 'approved'][(p + t) % 4],
          'createdBy': user.uid, 'createdByName': 'Zonal Deputy BDO (sample)', 'createdAt': ago(240), 'updatedAt': ago(60), 'synthetic': true,
        }));
      }
    }
    for (var i = 0; i < writes.length; i += 400) {
      final batch = db.batch();
      for (final w in writes.skip(i).take(400)) {
        batch.set(db.doc(w.$1), w.$2);
      }
      await batch.commit();
    }
    return writes.length;
  }

  /// Removes the synthetic activity records. Sample areas, boundaries and
  /// cleaning zones stay (areas cannot be deleted; names say "sample").
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
