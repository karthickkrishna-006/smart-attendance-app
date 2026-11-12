import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import '../domain/attendance.dart';
import '../domain/designations.dart';
import '../domain/geo.dart';
import 'attendance_repository.dart';
import 'scoped.dart';
import 'session_controller.dart';

/// GPS photo attendance (photoAttendance + photoAttendancePhotos). The first
/// photo of the day also marks the day's attendance, so every dashboard
/// counts the person as present.
class PhotoAttendanceRepository {
  PhotoAttendanceRepository(this.session, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final SessionController session;
  final FirebaseFirestore db;

  static const maxPhotoBytes = 600 * 1024;

  String get _uid => session.user!.uid;
  String get _name => (session.account?['displayName'] as String?) ?? '';

  Stream<List<Map<String, dynamic>>> watchMine(String day) => db
      .collection('photoAttendance')
      .where('uid', isEqualTo: _uid)
      .where('date', isEqualTo: day)
      .snapshots()
      .map((s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList()..sort(newestFirst('createdAt')));

  /// Officers: everyone's photos in scope for [day].
  Stream<List<Map<String, dynamic>>> watchScope(String day) =>
      watchScoped(session, 'photoAttendance', day: day, sort: newestFirst('createdAt'));

  Future<Uint8List?> photo(String id) async {
    final d = await db.doc('photoAttendancePhotos/$id').get();
    final b = d.data()?['jpeg'];
    return b is Blob ? b.bytes : null;
  }

  /// The scheduled time this photo most likely belongs to ("13:00"), if any.
  static String? slotFor(Designation? d, DateTime t) {
    if (d == null) return null;
    final m = t.hour * 60 + t.minute;
    int? best;
    for (final s in d.schedule.slotMinutes) {
      final diff = (m - s).abs();
      if (diff <= slotToleranceMin && (best == null || diff < (m - best).abs())) best = s;
    }
    if (best == null) return null;
    return '${(best ~/ 60).toString().padLeft(2, '0')}:${(best % 60).toString().padLeft(2, '0')}';
  }

  Future<SaveOutcome> submit({
    required Uint8List jpeg,
    required Position position,
    required List<Geofence> fences,
    String? note,
  }) async {
    if (jpeg.length > maxPhotoBytes) throw 'The photo is too large. Please take it again.';
    final role = session.role!.key;
    final designation = session.designation;
    if (designation == null) throw 'No staff designation is set for your role. Ask the administrator.';
    final preview = AttendanceRepository(_uid).preview(position, fences, hasAssignedArea: (session.current?.areaIds ?? const []).isNotEmpty);
    final m = preview.match;
    final now = DateTime.now();
    final ref = db.collection('photoAttendance').doc();
    final batch = db.batch();
    batch.set(db.doc('photoAttendancePhotos/${ref.id}'), {
      'uid': _uid,
      'jpeg': Blob(jpeg),
      'sizeBytes': jpeg.length,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(ref, {
      'uid': _uid,
      'workerName': _name,
      'role': role,
      'designation': designation.key,
      'date': dayKey(now),
      'orgId': session.current?.orgId,
      'areaPath': m?.fence.areaPath ?? session.homePath,
      'slot': slotFor(designation, now),
      'lat': position.latitude,
      'lng': position.longitude,
      'accuracy': position.accuracy,
      'mocked': position.isMocked,
      'placement': m == null ? 'none' : m.result.placement.name,
      'geofenceId': m?.fence.id,
      'status': preview.verdict.status.name,
      'reasons': preview.verdict.reasons.map((r) => r.code).toList(),
      'note': (note == null || note.trim().isEmpty) ? null : note.trim(),
      'capturedAt': Timestamp.fromDate(position.timestamp),
      'createdAt': FieldValue.serverTimestamp(),
      'synthetic': false,
    });
    final write = batch.commit();
    try {
      await write.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      write.catchError((Object _) {});
      return SaveOutcome.waitingForInternet;
    }
    // The first photo of the day also marks attendance (dashboards count it).
    try {
      final repo = AttendanceRepository(_uid);
      if (!(await repo.today().get()).exists) {
        await repo.checkIn(preview,
            orgId: session.current?.orgId, workerName: _name, role: role, designation: designation.key, homePath: session.homePath);
      }
    } catch (_) {
      // The photo is saved; the daily record can be marked from the Attendance screen.
    }
    return SaveOutcome.saved;
  }

  /// Messages for this person: to everyone, or to their designation or role.
  static bool messageIsFor(Map<String, dynamic> m, SessionController s) {
    final ds = ((m['designations'] as List?) ?? const []).whereType<String>().toList();
    final rs = ((m['roles'] as List?) ?? const []).whereType<String>().toList();
    final okD = ds.isEmpty || (s.current?.designation != null && ds.contains(s.current!.designation));
    final okR = rs.isEmpty || (s.role != null && rs.contains(s.role!.key));
    return okD && okR;
  }
}
