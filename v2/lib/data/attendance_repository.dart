import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import '../domain/attendance.dart';
import '../domain/geo.dart';

/// What happened to a write: confirmed by the server, or kept on the phone
/// (no internet) to be sent automatically later.
enum SaveOutcome { saved, waitingForInternet }

/// The result of checking a fix against the worker's geofences, shown to
/// the worker BEFORE they confirm.
class CheckInPreview {
  const CheckInPreview({required this.position, required this.match, required this.verdict, required this.hasAssignedArea});
  final Position position;
  final ({Geofence fence, GeoCheck result})? match;
  final Verdict verdict;
  final bool hasAssignedArea;
}

class AttendanceRepository {
  AttendanceRepository(this.uid, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore db;

  static final _rand = math.Random.secure();

  /// A unique id made on the phone, so a record sent twice is never counted twice.
  String newEventId() =>
      '${DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36)}-${_rand.nextInt(1 << 32).toRadixString(36)}';

  DocumentReference<Map<String, dynamic>> today() => db.doc('attendanceSessions/${sessionId(uid, dayKey(DateTime.now()))}');

  Stream<Map<String, dynamic>?> watchToday() => today().snapshots().map((d) => d.data());

  /// The worker's own geofences (inside their assigned areas).
  Future<List<Geofence>> geofencesFor(List<String> areaIds) async {
    if (areaIds.isEmpty) return const [];
    final out = <Geofence>[];
    for (var i = 0; i < areaIds.length; i += 30) {
      final chunk = areaIds.sublist(i, math.min(i + 30, areaIds.length));
      final snap = await db.collection('geofences').where('areaPath', arrayContainsAny: chunk).get();
      for (final d in snap.docs) {
        final f = geofenceFromMap(d.id, d.data());
        if (f != null) out.add(f);
      }
    }
    return out;
  }

  static Geofence? geofenceFromMap(String id, Map<String, dynamic> m) {
    final path = ((m['areaPath'] as List?) ?? const []).whereType<String>().toList();
    final name = (m['name'] as String?) ?? id;
    final areaId = (m['areaId'] as String?) ?? '';
    if (m['kind'] == 'circle' && m['center'] is GeoPoint && m['radiusM'] is num) {
      final c = m['center'] as GeoPoint;
      return Geofence.circle(
        id: id, name: name, areaId: areaId, areaPath: path,
        center: GeoPoint2(c.latitude, c.longitude), radiusM: (m['radiusM'] as num).toDouble(),
      );
    }
    if (m['kind'] == 'polygon' && m['ring'] is List) {
      final ring = (m['ring'] as List).whereType<GeoPoint>().map((g) => GeoPoint2(g.latitude, g.longitude)).toList();
      if (ring.length >= 3) return Geofence.polygon(id: id, name: name, areaId: areaId, areaPath: path, ring: ring);
    }
    return null;
  }

  CheckInPreview preview(Position p, List<Geofence> fences, {required bool hasAssignedArea, AttendancePolicy policy = const AttendancePolicy()}) {
    final match = bestMatch(GeoPoint2(p.latitude, p.longitude), p.accuracy, fences);
    final verdict = evaluateCheckIn(
      hasAssignedArea: hasAssignedArea,
      placement: match?.result.placement,
      accuracyM: p.accuracy,
      mocked: p.isMocked,
      localTime: DateTime.now(),
      policy: policy,
    );
    return CheckInPreview(position: p, match: match, verdict: verdict, hasAssignedArea: hasAssignedArea);
  }

  /// Writes today's check-in. Waits up to 20 seconds for the server; after
  /// that the write stays queued on the phone and is reported as such.
  /// [workerName] must be exactly the name on the worker's account (the
  /// security rules compare them), so officers see a trustworthy name.
  Future<SaveOutcome> checkIn(
    CheckInPreview c, {
    String? orgId,
    required String workerName,
    String role = 'worker',
    String? designation,
    List<String> homePath = const [],
  }) {
    final m = c.match;
    final placement = m == null ? 'none' : m.result.placement.name;
    final data = {
      'uid': uid,
      'workerName': workerName,
      'role': role,
      'designation': designation,
      'date': dayKey(DateTime.now()),
      'orgId': orgId,
      'areaPath': m?.fence.areaPath ?? homePath,
      'evaluatedBy': 'device',
      'createdAt': FieldValue.serverTimestamp(),
      'checkIn': {
        'at': FieldValue.serverTimestamp(),
        'deviceAt': Timestamp.fromDate(c.position.timestamp),
        'lat': c.position.latitude,
        'lng': c.position.longitude,
        'accuracy': c.position.accuracy,
        'mocked': c.position.isMocked,
        'geofenceId': m?.fence.id,
        'placement': placement,
        'edgeDistanceM': m == null ? null : double.parse(m.result.edgeDistanceM.toStringAsFixed(1)),
        'status': c.verdict.status.name,
        'late': c.verdict.late,
        'reasons': c.verdict.reasons.map((r) => r.code).toList(),
        'eventId': newEventId(),
      },
    };
    return _settle(today().set(data));
  }

  Future<SaveOutcome> checkOut(Position? p) => _settle(today().update({
        'checkOut': {
          'at': FieldValue.serverTimestamp(),
          'deviceAt': Timestamp.fromDate(p?.timestamp ?? DateTime.now()),
          'lat': p?.latitude,
          'lng': p?.longitude,
          'accuracy': p?.accuracy,
          'mocked': p?.isMocked ?? false,
          'eventId': newEventId(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }));

  static Future<SaveOutcome> _settle(Future<void> write) async {
    try {
      await write.timeout(const Duration(seconds: 20));
      return SaveOutcome.saved;
    } on TimeoutException {
      write.catchError((Object _) {});
      return SaveOutcome.waitingForInternet;
    }
  }
}
