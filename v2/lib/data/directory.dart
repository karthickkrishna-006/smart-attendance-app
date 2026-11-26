import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/area.dart';
import '../domain/geo.dart';
import '../domain/roles.dart';
import '../domain/session.dart';
import '../domain/staff_import.dart';
import 'audited_batch.dart';

/// Master data and access management (System administrator; organisation
/// administrators for their own workers). Every write is audited in the same
/// batch, as the security rules require.
class Directory {
  Directory(this.user, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final User user;
  final FirebaseFirestore db;

  // ------------------------------------------------------------------ areas
  Stream<List<AreaNode>> areas() => db.collection('areas').snapshots().map((s) {
        final list = s.docs.map((d) => AreaNode.fromMap(d.id, d.data())).whereType<AreaNode>().toList();
        list.sort((a, b) => a.path.join('/').compareTo(b.path.join('/')));
        return list;
      });

  Future<void> addArea({required String name, required AreaLevel level, AreaNode? parent}) async {
    final ref = db.collection('areas').doc();
    final path = parent == null ? [ref.id] : parent.childPath(ref.id);
    final b = AuditedBatch(db, user);
    b.batch.set(ref, {
      'name': name.trim(),
      'level': level.key,
      'parentId': parent?.id,
      'path': path,
      'provisional': true,
      ...b.stamp('area_created', 'areas/${ref.id}', details: name.trim()),
    });
    await b.commit();
  }

  // -------------------------------------------------------------- geofences
  Stream<List<Map<String, dynamic>>> geofences() => db.collection('geofences').snapshots().map(
        (s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}')),
      );

  Future<void> addCircleGeofence({required AreaNode area, required String name, required GeoPoint2 center, required double radiusM}) async {
    final ref = db.collection('geofences').doc();
    final b = AuditedBatch(db, user);
    b.batch.set(ref, {
      'name': name.trim(),
      'areaId': area.id,
      'areaPath': area.path,
      'kind': 'circle',
      'center': GeoPoint(center.lat, center.lng),
      'radiusM': radiusM,
      'provisional': true,
      ...b.stamp('geofence_created', 'geofences/${ref.id}', details: 'circle ${radiusM.round()} m'),
    });
    await b.commit();
  }

  /// Saves imported boundaries (already simplified) as polygon geofences.
  /// [official] marks them as coming from official GIS data.
  Future<int> addPolygonGeofences({
    required AreaNode area,
    required List<({String name, List<GeoPoint2> ring})> rings,
    required bool official,
  }) async {
    var saved = 0;
    for (var i = 0; i < rings.length; i += 200) {
      final b = AuditedBatch(db, user);
      for (final r in rings.skip(i).take(200)) {
        final ref = db.collection('geofences').doc();
        b.batch.set(ref, {
          'name': r.name,
          'areaId': area.id,
          'areaPath': area.path,
          'kind': 'polygon',
          'ring': [for (final p in r.ring) GeoPoint(p.lat, p.lng)],
          'provisional': !official,
          ...b.stamp('geofence_imported', 'geofences/${ref.id}', details: '${r.ring.length} points'),
        });
        saved++;
      }
      await b.commit();
    }
    return saved;
  }

  // ---------------------------------------------------------- organisations
  Stream<List<Map<String, dynamic>>> organisations() => db.collection('organisations').snapshots().map(
        (s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}')),
      );

  Future<void> addOrganisation({required String name, required bool thirdParty}) async {
    final ref = db.collection('organisations').doc();
    final b = AuditedBatch(db, user);
    b.batch.set(ref, {
      'name': name.trim(),
      'type': thirdParty ? 'third_party' : 'department',
      'active': true,
      ...b.stamp('organisation_created', 'organisations/${ref.id}', details: name.trim()),
    });
    await b.commit();
  }

  // -------------------------------------------------------- pre-registrations
  Stream<List<Map<String, dynamic>>> preregistrations({String? orgId}) {
    Query<Map<String, dynamic>> q = db.collection('preregistrations');
    if (orgId != null) q = q.where('orgId', isEqualTo: orgId);
    return q.snapshots().map((s) => s.docs.map((d) => d.data()).toList()..sort((a, b) => '${a['email']}'.compareTo('${b['email']}')));
  }

  Future<void> addPreregistration({
    required String email,
    required Role role,
    required List<String> areaIds,
    String? name,
    String? employeeId,
    String? orgId,
    String? designation,
  }) async {
    final key = emailKey(email);
    final ref = db.doc('preregistrations/$key');
    final existing = await ref.get();
    if (existing.exists) {
      final signedIn = existing.data()?['claimedBy'] != null;
      throw signedIn
          ? '$key has already signed in. To change their staff type, role or area, use Setup → Access and tap their role.'
          : '$key is already added (not signed in yet). Remove them from this list first, then add them again with the new details.';
    }
    final b = AuditedBatch(db, user);
    b.batch.set(ref, {
      'email': key,
      'role': role.key,
      'areaIds': areaIds,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (employeeId != null && employeeId.trim().isNotEmpty) 'employeeId': employeeId.trim(),
      if (orgId != null) 'orgId': orgId,
      if (designation != null) 'designation': designation,
      'createdBy': user.uid,
      'createdAt': FieldValue.serverTimestamp(),
      ...b.stamp('person_added', 'preregistrations/$key', details: role.key),
    });
    await b.commit();
  }

  /// Adds many people from a staff sheet. Each person is written with their
  /// own audit entry; the security rules may read only ~20 documents per
  /// batch, so people go in small batches, a few batches at a time.
  /// Returns how many were added; [onProgress] gets (done, total).
  Future<int> bulkPreregister(List<ImportRow> rows, {void Function(int done, int total)? onProgress}) async {
    const perBatch = 6, parallel = 8;
    final chunks = <List<ImportRow>>[
      for (var i = 0; i < rows.length; i += perBatch) rows.sublist(i, math.min(i + perBatch, rows.length)),
    ];
    var done = 0;
    final failed = <String>[];
    Future<void> write(List<ImportRow> chunk) async {
      final b = AuditedBatch(db, user);
      for (final r in chunk) {
        final key = emailKey(r.email);
        b.batch.set(db.doc('preregistrations/$key'), {
          'email': key,
          'role': r.designation.role.key,
          'designation': r.designation.key,
          'areaIds': r.areaIds,
          if (r.name.trim().isNotEmpty) 'name': r.name.trim(),
          if (r.employeeId.trim().isNotEmpty) 'employeeId': r.employeeId.trim(),
          'createdBy': user.uid,
          'createdAt': FieldValue.serverTimestamp(),
          ...b.stamp('person_added', 'preregistrations/$key', details: '${r.designation.role.key} (sheet)'),
        });
      }
      try {
        await b.commit();
        done += chunk.length;
      } catch (_) {
        failed.addAll(chunk.map((r) => 'line ${r.line} (${r.email})'));
      }
      onProgress?.call(done, rows.length);
    }

    for (var i = 0; i < chunks.length; i += parallel) {
      await Future.wait(chunks.sublist(i, math.min(i + parallel, chunks.length)).map(write));
    }
    if (failed.isNotEmpty) {
      throw '$done added. Not saved: ${failed.take(10).join(', ')}${failed.length > 10 ? ' and ${failed.length - 10} more' : ''}. '
          'They may have been added by someone else meanwhile; check the list and import those lines again.';
    }
    return done;
  }

  Future<void> removePreregistration(String email) => db.doc('preregistrations/${emailKey(email)}').delete();

  // --------------------------------------------------------------- access
  Stream<List<Map<String, dynamic>>> roleAssignments() => db.collection('roleAssignments').snapshots().map(
        (s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList()..sort((a, b) => '${a['id']}'.compareTo('${b['id']}')),
      );

  Stream<Map<String, String>> accountEmails() => db.collection('accounts').snapshots().map(
        (s) => {for (final d in s.docs) d.id: (d.data()['email'] as String?) ?? d.id},
      );

  Future<void> setRoleActive(String assignmentId, bool active) async {
    final b = AuditedBatch(db, user);
    b.batch.update(db.doc('roleAssignments/$assignmentId'), {
      'active': active,
      ...b.stamp(active ? 'role_switched_on' : 'role_switched_off', 'roleAssignments/$assignmentId'),
    });
    await b.commit();
  }

  /// Changes which areas (and organisation) an existing role covers.
  Future<void> updateRoleScope(String assignmentId, {required List<String> areaIds, String? orgId, String? designation}) async {
    final b = AuditedBatch(db, user);
    b.batch.update(db.doc('roleAssignments/$assignmentId'), {
      'areaIds': areaIds,
      'orgId': orgId,
      'designation': designation,
      ...b.stamp('role_scope_changed', 'roleAssignments/$assignmentId', details: areaIds.join(',')),
    });
    await b.commit();
  }

  /// Grants a role to someone who already has an account (found by e-mail).
  /// People without an account are added through a pre-registration instead.
  Future<bool> grantRole({required String email, required Role role, required List<String> areaIds, String? orgId}) async {
    final typed = email.trim();
    var found = await db.collection('accounts').where('email', isEqualTo: typed).limit(1).get();
    if (found.docs.isEmpty && typed != typed.toLowerCase()) {
      found = await db.collection('accounts').where('email', isEqualTo: typed.toLowerCase()).limit(1).get();
    }
    if (found.docs.isEmpty) return false;
    final uid = found.docs.first.id;
    final id = RoleAssignment.docId(uid, role);
    final b = AuditedBatch(db, user);
    b.batch.set(db.doc('roleAssignments/$id'), {
      'uid': uid,
      'role': role.key,
      'areaIds': areaIds,
      if (orgId != null) 'orgId': orgId,
      'active': true,
      'source': 'admin',
      'grantedBy': user.uid,
      'grantedAt': FieldValue.serverTimestamp(),
      ...b.stamp('role_granted', 'roleAssignments/$id', details: role.key),
    });
    await b.commit();
    return true;
  }

  // ------------------------------------------------------------ configuration
  Stream<Map<String, dynamic>> config() => db.doc('config/app').snapshots().map((d) => d.data() ?? const {});

  Future<void> saveConfig({
    required bool openWorkerSignUp,
    required bool supervisorsMayCreateTasks,
    required bool collectorMayAssignTasks,
    bool zonePhotoOnly = false,
  }) async {
    final b = AuditedBatch(db, user);
    b.batch.set(db.doc('config/app'), {
      'openWorkerSignUp': openWorkerSignUp,
      'supervisorsMayCreateTasks': supervisorsMayCreateTasks,
      'collectorMayAssignTasks': collectorMayAssignTasks,
      'zonePhotoOnly': zonePhotoOnly,
      ...b.stamp('settings_changed', 'config/app'),
    });
    await b.commit();
  }

  Stream<Map<String, String>> titles() => db.collection('hierarchyLevels').snapshots().map(
        (s) => {for (final d in s.docs) d.id: (d.data()['title'] as String?) ?? ''},
      );

  Future<void> setTitle(Role role, String title) async {
    final b = AuditedBatch(db, user);
    b.batch.set(db.doc('hierarchyLevels/${role.key}'), {
      'title': title.trim(),
      ...b.stamp('role_title_changed', 'hierarchyLevels/${role.key}', details: title.trim()),
    });
    await b.commit();
  }

  // --------------------------------------------------------------- messages
  Future<void> sendMessage({
    required String title,
    required String body,
    required bool urgent,
    required List<String> designations,
    required List<String> roles,
    required String senderName,
  }) =>
      db.collection('messages').add({
        'title': title.trim(),
        'body': body.trim(),
        'priority': urgent ? 'urgent' : 'normal',
        'designations': designations,
        'roles': roles,
        'createdBy': user.uid,
        'createdByName': senderName,
        'createdAt': FieldValue.serverTimestamp(),
      });

  Future<void> deleteMessage(String id) => db.doc('messages/$id').delete();

  // ----------------------------------------------------------- deletions
  void _deleteRoleInto(AuditedBatch b, String assignmentId, Object? grantedAt, {String details = ''}) {
    if (grantedAt is! Timestamp) {
      throw 'This role has no grant time recorded and cannot be deleted. Switch it off instead.';
    }
    b.stampWithId('del_${assignmentId}_${grantedAt.millisecondsSinceEpoch}', 'role_deleted', 'roleAssignments/$assignmentId', details: details);
    b.batch.delete(db.doc('roleAssignments/$assignmentId'));
  }

  /// Deletes one role (audited). Never the administrator's own role.
  Future<void> deleteRole(Map<String, dynamic> assignment) async {
    if (assignment['uid'] == user.uid) throw 'You cannot delete your own role.';
    final b = AuditedBatch(db, user);
    _deleteRoleInto(b, assignment['id'] as String, assignment['grantedAt'], details: '${assignment['role']}');
    await b.commit();
  }

  /// Removes a person: before sign-in, their registration; after sign-in,
  /// also every role they hold (audited), so they lose access at once.
  /// Their past records stay for audit.
  Future<int> removePerson(Map<String, dynamic> prereg) async {
    final email = '${prereg['email']}';
    final uid = prereg['claimedBy'] as String?;
    if (uid == user.uid) throw 'You cannot remove yourself.';
    final b = AuditedBatch(db, user);
    var roles = 0;
    if (uid != null) {
      final snap = await db.collection('roleAssignments').where('uid', isEqualTo: uid).get();
      for (final d in snap.docs) {
        _deleteRoleInto(b, d.id, d.data()['grantedAt'], details: 'person removed: $email');
        roles++;
      }
    }
    b.batch.delete(db.doc('preregistrations/${emailKey(email)}'));
    await b.commit();
    return roles;
  }
}
