import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import '../domain/attendance.dart';
import '../domain/geo.dart';
import 'attendance_repository.dart';
import 'scoped.dart';
import 'session_controller.dart';

/// Tasks (assigned to areas), field activities with photos, and reviews.
class WorkRepository {
  WorkRepository(this.session, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final SessionController session;
  final FirebaseFirestore db;

  static const maxPhotoBytes = 600 * 1024;
  static final _rand = math.Random.secure();

  String get _uid => session.user!.uid;
  String get _myName => (session.account?['displayName'] as String?) ?? '';

  // ------------------------------------------------------------------ tasks
  /// Tasks the current person may see (worker: their areas; officers: scope).
  Stream<List<Map<String, dynamic>>> watchTasks() =>
      watchMerged(scopedQueries(session, 'tasks', orgScoped: false), sort: newestFirst('createdAt'));

  /// Areas inside the officer's scope, for choosing where a task goes.
  Future<List<Map<String, dynamic>>> areasInScope() async {
    final ids = session.current?.areaIds ?? const <String>[];
    final out = <String, Map<String, dynamic>>{};
    if (ids.isEmpty) {
      final all = await db.collection('areas').get();
      for (final d in all.docs) {
        out[d.id] = {...d.data(), 'id': d.id};
      }
    } else {
      for (final id in ids) {
        final snap = await db.collection('areas').where('path', arrayContains: id).get();
        for (final d in snap.docs) {
          out[d.id] = {...d.data(), 'id': d.id};
        }
      }
    }
    final list = out.values.toList()..sort((a, b) => '${(a['path'] as List?)?.join('/')}'.compareTo('${(b['path'] as List?)?.join('/')}'));
    return list;
  }

  Future<void> createTask({
    required String title,
    required String description,
    required Map<String, dynamic> area,
    required String priority,
    required String dueDate,
  }) =>
      db.collection('tasks').add({
        'title': title.trim(),
        'description': description.trim(),
        'areaId': area['id'],
        'areaPath': area['path'],
        'priority': priority,
        'dueDate': dueDate,
        'status': 'assigned',
        'createdBy': _uid,
        'createdByName': _myName,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'synthetic': false,
      });

  Future<void> setTaskStatus(String taskId, String status, {String? note}) => db.doc('tasks/$taskId').update({
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
        if (note != null) 'reviewNote': note,
        if (note != null) 'reviewedBy': _uid,
      });

  // ------------------------------------------------------------- activities
  Stream<List<Map<String, dynamic>>> watchMyActivities() => db
      .collection('activities')
      .where('uid', isEqualTo: _uid)
      .snapshots()
      .map((s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList()..sort(newestFirst('createdAt')));

  Stream<List<Map<String, dynamic>>> watchActivities(String day) =>
      watchMerged(scopedQueries(session, 'activities', day: day), sort: newestFirst('createdAt'));

  Future<Uint8List?> photo(String activityId, int index) async {
    final d = await db.doc('activityPhotos/${activityId}_$index').get();
    final b = d.data()?['jpeg'];
    return b is Blob ? b.bytes : null;
  }

  /// Saves the activity, its photos and (if linked) the task status in one
  /// batch: all or nothing. Waits up to 20 s for the server; after that the
  /// whole batch stays queued on the phone and is reported as such.
  Future<SaveOutcome> submitActivity({
    required String title,
    required String description,
    required List<Uint8List> photos,
    Map<String, dynamic>? task,
    Position? position,
    List<Geofence> fences = const [],
  }) async {
    if (photos.isEmpty || photos.length > 3) throw 'Add 1 to 3 photos.';
    for (final p in photos) {
      if (p.length > maxPhotoBytes) throw 'A photo is too large. Please take it again.';
    }
    final ref = db.collection('activities').doc();
    final batch = db.batch();
    for (var i = 0; i < photos.length; i++) {
      batch.set(db.doc('activityPhotos/${ref.id}_$i'), {
        'uid': _uid,
        'activityId': ref.id,
        'index': i,
        'jpeg': Blob(photos.elementAt(i)),
        'sizeBytes': photos.elementAt(i).length,
        'createdAt': FieldValue.serverTimestamp(),
        'synthetic': false,
      });
    }
    final match = position == null ? null : bestMatch(GeoPoint2(position.latitude, position.longitude), position.accuracy, fences);
    final useFence = task == null && match != null && match.result.placement != Placement.outside;
    batch.set(ref, {
      'uid': _uid,
      'workerName': _myName,
      'date': dayKey(DateTime.now()),
      'orgId': session.current?.orgId,
      'areaPath': task != null ? task['areaPath'] : (useFence ? match.fence.areaPath : const <String>[]),
      'taskId': task?['id'],
      'geofenceId': useFence ? match.fence.id : null,
      'title': title.trim(),
      'description': description.trim(),
      'lat': position?.latitude,
      'lng': position?.longitude,
      'accuracy': position?.accuracy,
      'mocked': position?.isMocked ?? false,
      'placement': match == null ? 'none' : match.result.placement.name,
      'capturedAt': Timestamp.fromDate(position?.timestamp ?? DateTime.now()),
      'photoCount': photos.length,
      'status': 'submitted',
      'evaluatedBy': 'device',
      'createdAt': FieldValue.serverTimestamp(),
      'synthetic': false,
    });
    if (task != null && ['assigned', 'in_progress', 'rework'].contains(task['status'])) {
      batch.update(db.doc('tasks/${task['id']}'), {'status': 'submitted', 'updatedAt': FieldValue.serverTimestamp()});
    }
    final write = batch.commit();
    try {
      await write.timeout(const Duration(seconds: 20));
      return SaveOutcome.saved;
    } on TimeoutException {
      write.catchError((Object _) {});
      return SaveOutcome.waitingForInternet;
    }
  }

  /// Approve, reject or send back for rework. A reason is required unless approving.
  Future<void> review(String activityId, String status, String note) => db.doc('activities/$activityId').update({
        'status': status,
        'reviewNote': note.trim(),
        'reviewedBy': _uid,
        'reviewedByName': _myName,
        'reviewedAt': FieldValue.serverTimestamp(),
      });

  static String newId() => '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 30).toRadixString(36)}';
}
