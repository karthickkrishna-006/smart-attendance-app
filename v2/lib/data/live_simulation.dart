import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../domain/attendance.dart';
import '../domain/geo.dart';
import '../domain/street_zones.dart';
import '../domain/visits.dart';
import 'attendance_repository.dart';
import 'demo_data.dart';
import 'street_zones_repo.dart';

class _SimWorker {
  _SimWorker(this.uid, this.name, this.path, this.streets);
  final String uid;
  final String name;
  final List<String> path;
  final List<Geofence> streets;
  final tracker = VisitTracker();
  final zones = ZoneTracker();
  String? openVisit;
  int street = 0;
  double along = -0.15; // < 0 or > 1: walking between streets
  GeoPoint2 at = const GeoPoint2(0, 0);
}

/// Demonstration only: sample Thoomai Kavalars walk along their sample
/// streets for a limited time, so the live map, street check-in/check-out and
/// cleaning zones can be seen working. Writes synthetic records only, from
/// the administrator's phone; real workers' phones do the same for real.
class LiveSimulation extends ChangeNotifier {
  LiveSimulation._();
  static final instance = LiveSimulation._();

  static const _tick = Duration(seconds: 15);
  static const _speedMps = 1.1;

  final _db = FirebaseFirestore.instance;
  Timer? _timer;
  DateTime? endsAt;
  final _workers = <_SimWorker>[];
  Map<String, List<CleaningZone>> _zones = const {};
  int writes = 0;
  String? lastError;

  bool get running => _timer != null;

  static GeoPoint2 _mid(GeoPoint2 a, GeoPoint2 b) => GeoPoint2((a.lat + b.lat) / 2, (a.lng + b.lng) / 2);
  static GeoPoint2 _lerp(GeoPoint2 a, GeoPoint2 b, double t) => GeoPoint2(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
  // Sample street rings are start-left, end-left, end-right, start-right.
  static GeoPoint2 _start(Geofence f) => _mid(f.ring.first, f.ring[3]);
  static GeoPoint2 _end(Geofence f) => _mid(f.ring[1], f.ring[2]);

  Future<int> start({int minutes = 15, int maxWorkers = 12}) async {
    if (running) return _workers.length;
    lastError = null;
    writes = 0;
    final fenceSnap = await _db.collection('geofences').where('areaPath', arrayContains: DemoData.blockId).get();
    final fences = [
      for (final d in fenceSnap.docs)
        if (AttendanceRepository.geofenceFromMap(d.id, d.data()) case final Geofence f when f.kind == GeofenceKind.polygon && f.ring.length == 4) f,
    ];
    if (fences.isEmpty) throw 'Create the sample district first (Setup → Demo).';
    _zones = await StreetZonesRepo().forStreets(fences.map((f) => f.id));
    final people = await _db.collection('presence').where('synthetic', isEqualTo: true).get();
    _workers.clear();
    for (final p in people.docs) {
      final m = p.data();
      if (m['designation'] != 'thoomai_kavalar') continue;
      final path = ((m['areaPath'] as List?) ?? const []).whereType<String>().toList();
      if (path.isEmpty) continue;
      final mine = fences.where((f) => f.areaPath.contains(path.last)).toList()..sort((a, b) => a.id.compareTo(b.id));
      if (mine.isEmpty) continue;
      final w = _SimWorker(p.id, (m['workerName'] as String?) ?? p.id, path, mine);
      w.at = _start(mine.first);
      _workers.add(w);
      if (_workers.length >= maxWorkers) break;
    }
    if (_workers.isEmpty) throw 'No sample Thoomai Kavalars found. Create the sample district first.';
    endsAt = DateTime.now().add(Duration(minutes: minutes));
    _timer = Timer.periodic(_tick, (_) => _step());
    notifyListeners();
    unawaited(_step());
    return _workers.length;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final now = DateTime.now();
    for (final w in _workers) {
      final e = w.tracker.close(now);
      if (e != null) await _close(w, e);
      await _write(() => _db.doc('presence/${w.uid}').update({'onDuty': false, 'at': Timestamp.fromDate(now)}));
    }
    endsAt = null;
    notifyListeners();
  }

  Future<void> _write(Future<void> Function() f) async {
    try {
      await f();
      writes++;
    } catch (e) {
      lastError = '$e';
    }
  }

  Future<void> _step() async {
    final now = DateTime.now();
    if (endsAt != null && now.isAfter(endsAt!)) {
      await stop();
      return;
    }
    final stepM = _speedMps * _tick.inSeconds;
    for (final w in _workers) {
      final f = w.streets[w.street];
      final a = _start(f), e = _end(f);
      final len = math.max(1.0, distanceM(a, e));
      w.along += stepM / len;
      if (w.along > 1.35) {
        // Leave this street and walk to the next one.
        w.street = (w.street + 1) % w.streets.length;
        w.along = -0.35;
      }
      final t = w.along.clamp(0.0, 1.0);
      final nf = w.streets[w.street];
      // Outside the street (between streets): stand 60 m off the street line.
      w.at = (w.along < 0 || w.along > 1)
          ? GeoPoint2(_lerp(a, e, t).lat + 60 / 111195.0, _lerp(a, e, t).lng)
          : _lerp(_start(nf), _end(nf), t);
      for (final ev in w.tracker.update(w.at, 6, now, w.streets)) {
        if (ev.kind == VisitEventKind.entered) {
          final ref = _db.collection('visits').doc();
          w.openVisit = ref.id;
          w.zones.reset();
          await _write(() => ref.set({
                'uid': w.uid, 'workerName': w.name, 'date': dayKey(now), 'orgId': null, 'areaPath': ev.fence.areaPath,
                'geofenceId': ev.fence.id, 'geofenceName': ev.fence.name, 'enteredAt': Timestamp.fromDate(ev.enteredAt),
                'exitedAt': null, 'durationMin': null, 'createdAt': Timestamp.fromDate(now), 'closedAt': null,
                'zonesTotal': (_zones[ev.fence.id] ?? const []).length, 'zonesDone': const <String>[], 'synthetic': true,
              }));
        } else {
          await _close(w, ev);
        }
      }
      final cur = w.tracker.current;
      if (cur != null && w.openVisit != null) {
        final reached = w.zones.update(w.at, 6, _zones[cur.id] ?? const []);
        if (reached.isNotEmpty) {
          final id = w.openVisit!;
          await _write(() => _db.doc('visits/$id').update({
                'zonesDone': FieldValue.arrayUnion([for (final z in reached) z.id]),
                'updatedAt': Timestamp.fromDate(now),
                'synthetic': true,
              }));
        }
      }
      await _write(() => _db.doc('presence/${w.uid}').set({
            'uid': w.uid, 'workerName': w.name, 'orgId': null, 'areaPath': w.path, 'designation': 'thoomai_kavalar',
            'lat': w.at.lat, 'lng': w.at.lng, 'accuracy': 6.0, 'onDuty': true, 'geofenceId': cur?.id,
            'at': Timestamp.fromDate(now), 'synthetic': true,
          }));
    }
    notifyListeners();
  }

  Future<void> _close(_SimWorker w, VisitEvent e) async {
    final id = w.openVisit;
    w.openVisit = null;
    if (id == null || e.exitedAt == null) return;
    await _write(() => _db.doc('visits/$id').update({
          'exitedAt': Timestamp.fromDate(e.exitedAt!),
          'durationMin': e.duration!.inMinutes,
          'closedAt': Timestamp.fromDate(DateTime.now()),
          'zonesDone': w.zones.done.toList(),
          'synthetic': true,
        }));
  }
}
