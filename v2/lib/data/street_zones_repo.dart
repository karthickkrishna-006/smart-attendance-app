import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/geo.dart';
import '../domain/street_zones.dart';
import 'audited_batch.dart';

/// Cleaning zones of streets (cleaningZones collection).
class StreetZonesRepo {
  StreetZonesRepo({FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore db;

  static CleaningZone? fromMap(String id, Map<String, dynamic> m) {
    final c = m['center'];
    if (c is! GeoPoint || m['streetFenceId'] is! String) return null;
    return CleaningZone(
      id: id,
      streetFenceId: m['streetFenceId'] as String,
      name: (m['name'] as String?) ?? id,
      center: GeoPoint2(c.latitude, c.longitude),
      radiusM: (m['radiusM'] as num?)?.toDouble() ?? 25,
      order: (m['order'] as num?)?.toInt() ?? 0,
    );
  }

  /// Zones of the given streets, grouped by street boundary id, in order.
  Future<Map<String, List<CleaningZone>>> forStreets(Iterable<String> fenceIds) async {
    final ids = fenceIds.toSet().toList();
    final out = <String, List<CleaningZone>>{};
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
      final snap = await db.collection('cleaningZones').where('streetFenceId', whereIn: chunk).get();
      for (final d in snap.docs) {
        final z = fromMap(d.id, d.data());
        if (z != null) out.putIfAbsent(z.streetFenceId, () => []).add(z);
      }
    }
    for (final l in out.values) {
      l.sort((a, b) => a.order.compareTo(b.order));
    }
    return out;
  }

  Stream<List<CleaningZone>> watchStreet(String fenceId) => db
      .collection('cleaningZones')
      .where('streetFenceId', isEqualTo: fenceId)
      .snapshots()
      .map((s) => s.docs.map((d) => fromMap(d.id, d.data())).whereType<CleaningZone>().toList()..sort((a, b) => a.order.compareTo(b.order)));

  /// Administrator: add a zone (audited).
  Future<void> addZone(User admin, {required String streetFenceId, required List<String> areaPath, required String name, required GeoPoint2 at, required int order, double radiusM = 25}) async {
    final ref = db.collection('cleaningZones').doc();
    final b = AuditedBatch(db, admin);
    b.batch.set(ref, {
      'name': name,
      'streetFenceId': streetFenceId,
      'areaPath': areaPath,
      'center': GeoPoint(at.lat, at.lng),
      'radiusM': radiusM,
      'order': order,
      ...b.stamp('cleaning_zone_added', 'cleaningZones/${ref.id}', details: name),
    });
    await b.commit();
  }

  Future<void> deleteZone(String id) => db.doc('cleaningZones/$id').delete();
}
