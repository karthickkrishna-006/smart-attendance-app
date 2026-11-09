import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/roles.dart';
import 'session_controller.dart';

/// Queries on area-scoped collections that the security rules accept for the
/// signed-in officer (see firestore.rules `officerSees`):
///  * Collector, auditor: everything (optionally one day).
///  * AD, Zonal Secretary, supervisor: one query per assigned area.
///  * Organisation admin: their organisation (records that carry orgId).
List<Query<Map<String, dynamic>>> scopedQueries(SessionController session, String collection, {String? day, bool orgScoped = true}) {
  final col = FirebaseFirestore.instance.collection(collection);
  Query<Map<String, dynamic>> withDay(Query<Map<String, dynamic>> q) => day == null ? q : q.where('date', isEqualTo: day);
  final a = session.current;
  switch (session.role) {
    case Role.collector:
    case Role.auditor:
      return [withDay(col)];
    case Role.officer:
    case Role.zonalSecretary:
    case Role.supervisor:
      return [for (final id in a?.areaIds ?? const <String>[]) withDay(col.where('areaPath', arrayContains: id))];
    case Role.orgAdmin:
      final org = a?.orgId;
      return (org == null || !orgScoped) ? const [] : [withDay(col.where('orgId', isEqualTo: org))];
    case Role.worker:
      return [for (final id in a?.areaIds ?? const <String>[]) col.where('areaPath', arrayContains: id)];
    default:
      return const [];
  }
}

/// Live, de-duplicated union of several queries.
Stream<List<Map<String, dynamic>>> watchMerged(List<Query<Map<String, dynamic>>> queries,
    {int Function(Map<String, dynamic> a, Map<String, dynamic> b)? sort}) {
  if (queries.isEmpty) return Stream.value(const []);
  final parts = List<Map<String, Map<String, dynamic>>?>.filled(queries.length, null);
  final subs = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
  late final StreamController<List<Map<String, dynamic>>> out;
  out = StreamController(
    onListen: () {
      for (var i = 0; i < queries.length; i++) {
        final index = i;
        subs.add(queries.elementAt(i).snapshots().listen((snap) {
          parts[index] = {for (final d in snap.docs) d.id: {...d.data(), 'id': d.id}};
          if (parts.every((p) => p != null)) {
            final merged = <String, Map<String, dynamic>>{};
            for (final p in parts) {
              merged.addAll(p!);
            }
            final list = merged.values.toList();
            if (sort != null) list.sort(sort);
            out.add(list);
          }
        }, onError: out.addError));
      }
    },
    onCancel: () async {
      for (final s in subs) {
        await s.cancel();
      }
    },
  );
  return out.stream;
}

int millisOf(Object? t) => t is Timestamp ? t.millisecondsSinceEpoch : 0;

/// Newest first by the given timestamp field.
int Function(Map<String, dynamic>, Map<String, dynamic>) newestFirst(String field) =>
    (a, b) => millisOf(b[field]).compareTo(millisOf(a[field]));


/// Why an officer may see nothing: their role has no area (or organisation).
/// Null when the scope is fine. Shown on every officer screen so an empty
/// list is never silent.
String? scopeProblem(SessionController session) {
  final a = session.current;
  switch (session.role) {
    case Role.officer:
    case Role.zonalSecretary:
    case Role.supervisor:
      return (a?.areaIds.isEmpty ?? true)
          ? 'No area is assigned to your role yet, so there is nothing to show. '
              'The System administrator can assign it in Setup → Access (tap your role, tick your block, zone or streets).'
          : null;
    case Role.orgAdmin:
      return a?.orgId == null ? 'No organisation is set for your role. Ask the System administrator (Setup → Access).' : null;
    default:
      return null;
  }
}

/// Like [watchMerged] over [scopedQueries] for one [day], but if Firestore
/// answers "this query requires an index" (area + day queries can need a
/// composite index in production), it switches to area-only queries and
/// filters the day on the phone, so officers always see their data.
Stream<List<Map<String, dynamic>>> watchScoped(SessionController session, String collection,
    {String? day, bool orgScoped = true, int Function(Map<String, dynamic> a, Map<String, dynamic> b)? sort}) {
  final primary = scopedQueries(session, collection, day: day, orgScoped: orgScoped);
  if (day == null) return watchMerged(primary, sort: sort);
  late final StreamController<List<Map<String, dynamic>>> out;
  StreamSubscription<List<Map<String, dynamic>>>? sub;
  var fellBack = false;
  void listenTo(Stream<List<Map<String, dynamic>>> s) {
    sub = s.listen(out.add, onError: (Object e) {
      final needsIndex = e is FirebaseException && e.code == 'failed-precondition';
      if (needsIndex && !fellBack) {
        fellBack = true;
        sub?.cancel();
        final fallback = scopedQueries(session, collection, orgScoped: orgScoped);
        listenTo(watchMerged(fallback, sort: sort).map((list) => list.where((r) => r['date'] == day).toList()));
      } else {
        out.addError(e);
      }
    });
  }

  out = StreamController(
    onListen: () => listenTo(watchMerged(primary, sort: sort)),
    onCancel: () => sub?.cancel(),
  );
  return out.stream;
}
