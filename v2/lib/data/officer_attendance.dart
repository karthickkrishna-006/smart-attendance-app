import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/roles.dart';
import 'scoped.dart';
import 'session_controller.dart';

/// Attendance records an officer may see for one day, using exactly the
/// queries the security rules allow for that role:
///  * Collector, auditor: the whole district (by date).
///  * AD, Zonal Secretary, supervisor: one query per assigned area.
///  * Organisation admin: their organisation.
class OfficerAttendance {
  OfficerAttendance(this.session, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final SessionController session;
  final FirebaseFirestore db;

  List<Query<Map<String, dynamic>>> queriesFor(String day) {
    final col = db.collection('attendanceSessions');
    final a = session.current;
    switch (session.role) {
      case Role.collector:
      case Role.auditor:
        return [col.where('date', isEqualTo: day)];
      case Role.officer:
      case Role.zonalSecretary:
      case Role.supervisor:
        return [
          for (final id in a?.areaIds ?? const <String>[]) col.where('areaPath', arrayContains: id).where('date', isEqualTo: day),
        ];
      case Role.orgAdmin:
        final org = a?.orgId;
        return org == null ? const [] : [col.where('orgId', isEqualTo: org).where('date', isEqualTo: day)];
      default:
        return const [];
    }
  }

  /// Live list for [day] (falls back without an index; see [watchScoped]),
  /// newest check-in first.
  Stream<List<Map<String, dynamic>>> watch(String day) => watchScoped(session, 'attendanceSessions',
      day: day, sort: (a, b) => _checkInMillis(b).compareTo(_checkInMillis(a)));

  static int _checkInMillis(Map<String, dynamic> s) {
    final ci = s['checkIn'];
    final t = ci is Map ? (ci['at'] ?? ci['deviceAt']) : null;
    return t is Timestamp ? t.millisecondsSinceEpoch : 0;
  }

  /// Names of the areas records were made in (areas are readable by all).
  Future<Map<String, String>> areaNames(Set<String> ids) async {
    final out = <String, String>{};
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 10) {
      final chunk = list.sublist(i, i + 10 > list.length ? list.length : i + 10);
      final snap = await db.collection('areas').where(FieldPath.documentId, whereIn: chunk).get();
      for (final d in snap.docs) {
        out[d.id] = (d.data()['name'] as String?) ?? d.id;
      }
    }
    return out;
  }
}
