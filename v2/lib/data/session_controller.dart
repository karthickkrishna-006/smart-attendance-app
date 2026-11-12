import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../domain/area.dart';
import '../domain/designations.dart';
import '../domain/policy.dart';
import '../domain/roles.dart';
import '../domain/session.dart';
import 'audited_batch.dart';
import 'auth_service.dart';
import 'duty_service.dart';

enum SessionPhase { loading, signedOut, ready, needsEmailVerification, notRegistered, disabled, error }

/// Everything known after sign-in that decides what the person sees.
class _Snapshot {
  _Snapshot({
    required this.account,
    required this.assignments,
    required this.preregistration,
    required this.config,
    required this.bootstrapDone,
  });

  final Map<String, dynamic>? account;
  final List<RoleAssignment> assignments;
  final Preregistration? preregistration;
  final Map<String, dynamic>? config;
  final bool bootstrapDone;
}

/// Signs people in, sets up their account the first time, and keeps their
/// roles current while the app is open (a switched-off role or account takes
/// effect immediately).
class SessionController extends ChangeNotifier {
  SessionController({FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore db;

  SessionPhase phase = SessionPhase.loading;
  User? user;
  Map<String, dynamic>? account;
  List<RoleAssignment> assignments = const [];
  Role? role;
  Policy policy = const Policy();
  Map<String, String> titles = const {};
  Map<String, String> areaNames = const {};
  Map<String, List<String>> areaPaths = const {};
  String? orgName;
  String language = 'en';
  String? error;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _rolesSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _accountSub;
  int _generation = 0;
  String _rolesFingerprint = '';

  void start() {
    _authSub = AuthService.changes().listen((u) {
      user = u;
      _resolve();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _stopWatching();
    super.dispose();
  }

  /// The active assignment for the current role.
  RoleAssignment? get current {
    for (final a in assignments) {
      if (a.role == role && a.active) return a;
    }
    return null;
  }

  List<Role> get activeRoles {
    final roles = assignments.where((a) => a.active).map((a) => a.role).toSet().toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return roles;
  }

  String titleOf(Role r) => titles[r.key] ?? r.defaultTitle;

  /// The job title of the current role (Thoomai Kavalar, BDO, ...), if set.
  Designation? get designation => Designation.fromKey(current?.designation);

  /// The title to show: the designation when set, otherwise the role title.
  String get displayTitle => designation?.title ?? (role == null ? '' : titleOf(role!));

  /// Path of the current role's first area: records made outside every
  /// boundary belong here, so the person's superiors still see them.
  List<String> get homePath {
    final ids = current?.areaIds ?? const <String>[];
    if (ids.isEmpty) return const [];
    return areaPaths[ids.first] ?? [ids.first];
  }

  /// "District › Block › Panchayat" for each area of the current role.
  List<String> get scopeLabels {
    final a = current;
    if (a == null) return const [];
    return [
      for (final id in a.areaIds) areaLabel(areaPaths[id] ?? [id], areaNames),
    ];
  }

  void setRole(Role r) {
    if (activeRoles.contains(r)) {
      role = r;
      notifyListeners();
    }
  }

  Future<void> setLanguage(String lang) async {
    language = lang;
    notifyListeners();
    final u = user;
    if (u != null && account != null) {
      unawaited(db.doc('accounts/${u.uid}').update({'language': lang}).catchError((_) {}));
    }
  }

  Future<void> retry() => _resolve();

  Future<void> recheckEmail() async {
    await AuthService.refresh();
    user = AuthService.current;
    await _resolve();
  }

  Future<void> signOut() async {
    final u = user;
    if (u != null) unawaited(logEvent(db, u, 'sign_out', 'auth'));
    if (DutyService.instance.onDuty) await DutyService.instance.stop();
    _stopWatching();
    await AuthService.signOut();
  }

  // ---------------------------------------------------------------- internals

  void _set(SessionPhase p, {String? err}) {
    phase = p;
    error = err;
    notifyListeners();
  }

  void _stopWatching() {
    _rolesSub?.cancel();
    _accountSub?.cancel();
    _rolesSub = null;
    _accountSub = null;
  }

  Future<void> _resolve() async {
    final gen = ++_generation;
    _stopWatching();
    final u = user;
    if (u == null) {
      assignments = const [];
      role = null;
      _set(SessionPhase.signedOut);
      return;
    }
    _set(SessionPhase.loading);
    try {
      var bootstrapTried = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        final snap = await _load(u);
        if (gen != _generation) return;
        final action = decideEntry(
          accountExists: snap.account != null,
          accountDisabled: snap.account?['status'] == 'disabled',
          assignments: snap.assignments,
          preregistration: snap.preregistration,
          uid: u.uid,
          openWorkerSignUp: snap.config?['openWorkerSignUp'] == true,
          bootstrapDone: snap.bootstrapDone || bootstrapTried,
        );
        switch (action) {
          case EntryAction.ready:
            await _enter(u, snap, gen);
            return;
          case EntryAction.disabled:
            _set(SessionPhase.disabled);
            return;
          case EntryAction.notRegistered:
            final google = u.providerData.any((p) => p.providerId == 'google.com');
            _set(u.emailVerified || google ? SessionPhase.notRegistered : SessionPhase.needsEmailVerification);
            return;
          case EntryAction.claimPreregistration:
            await _claim(u, snap);
            continue;
          case EntryAction.openSignUp:
            await _openSignUp(u, snap);
            continue;
          case EntryAction.tryBootstrap:
            bootstrapTried = true;
            try {
              await _bootstrap(u, snap);
            } on FirebaseException catch (e) {
              // Expected for everyone except the configured first administrator.
              if (e.code != 'permission-denied') rethrow;
            }
            continue;
        }
      }
      throw 'Your account could not be set up. Try again or contact your administrator.';
    } catch (e) {
      if (gen == _generation) _set(SessionPhase.error, err: _describe(e));
    }
  }

  Future<_Snapshot> _load(User u) async {
    final accountDoc = await db.doc('accounts/${u.uid}').get();
    final roles = await db.collection('roleAssignments').where('uid', isEqualTo: u.uid).get();
    Preregistration? prereg;
    final email = u.email;
    if (email != null) {
      try {
        final p = await db.doc('preregistrations/${emailKey(email)}').get();
        if (p.exists) prereg = Preregistration.fromMap(p.data()!);
      } on FirebaseException catch (e) {
        // Unconfirmed e-mail addresses may not read their pre-registration.
        if (e.code != 'permission-denied') rethrow;
      }
    }
    final config = await db.doc('config/app').get();
    final boot = await db.doc('meta/bootstrap').get();
    return _Snapshot(
      account: accountDoc.data(),
      assignments: roles.docs.map((d) => RoleAssignment.fromMap(d.data())).whereType<RoleAssignment>().toList(),
      preregistration: prereg,
      config: config.data(),
      bootstrapDone: boot.exists,
    );
  }

  Map<String, dynamic> _newAccount(User u, {String? name, String? orgId, String? employeeId, bool withOrg = false}) => {
        'email': u.email,
        'displayName': (name != null && name.trim().isNotEmpty) ? name.trim() : (u.displayName ?? ''),
        if (withOrg) 'orgId': orgId,
        if (withOrg) 'employeeId': employeeId,
        'status': 'active',
        'language': language,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLoginAt': FieldValue.serverTimestamp(),
      };

  Future<void> _claim(User u, _Snapshot s) async {
    final p = s.preregistration!;
    final b = AuditedBatch(db, u);
    if (s.account == null) {
      b.batch.set(db.doc('accounts/${u.uid}'),
          _newAccount(u, name: p.name, orgId: p.orgId, employeeId: p.employeeId, withOrg: true));
    }
    final id = RoleAssignment.docId(u.uid, p.role);
    b.batch.set(db.doc('roleAssignments/$id'), {
      'uid': u.uid,
      'role': p.role.key,
      'areaIds': p.areaIds,
      'orgId': p.orgId,
      'active': true,
      'source': 'preregistration',
      'grantedBy': p.createdBy,
      'grantedAt': FieldValue.serverTimestamp(),
      ...b.stamp('account_claimed', 'roleAssignments/$id'),
    });
    b.batch.update(db.doc('preregistrations/${emailKey(p.email)}'), {
      'claimedBy': u.uid,
      'claimedAt': FieldValue.serverTimestamp(),
    });
    await b.commit();
  }

  Future<void> _openSignUp(User u, _Snapshot s) async {
    final b = AuditedBatch(db, u);
    if (s.account == null) b.batch.set(db.doc('accounts/${u.uid}'), _newAccount(u));
    final id = RoleAssignment.docId(u.uid, Role.worker);
    b.batch.set(db.doc('roleAssignments/$id'), {
      'uid': u.uid,
      'role': Role.worker.key,
      'areaIds': const <String>[],
      'active': true,
      'source': 'open_signup',
      'grantedBy': u.uid,
      'grantedAt': FieldValue.serverTimestamp(),
      ...b.stamp('open_signup', 'roleAssignments/$id'),
    });
    await b.commit();
  }

  /// Only the e-mail named in the security rules can succeed; for everyone
  /// else the database refuses and the person is shown "not registered".
  Future<void> _bootstrap(User u, _Snapshot s) async {
    final email = u.email;
    if (email == null) return;
    final b = AuditedBatch(db, u);
    if (s.account == null) b.batch.set(db.doc('accounts/${u.uid}'), _newAccount(u));
    final id = RoleAssignment.docId(u.uid, Role.sysAdmin);
    b.batch.set(db.doc('roleAssignments/$id'), {
      'uid': u.uid,
      'role': Role.sysAdmin.key,
      'areaIds': const <String>[],
      'active': true,
      'source': 'bootstrap',
      'grantedBy': u.uid,
      'grantedAt': FieldValue.serverTimestamp(),
      ...b.stamp('bootstrap_first_admin', 'roleAssignments/$id'),
    });
    b.batch.set(db.doc('meta/bootstrap'), {
      'uid': u.uid,
      'email': emailKey(email),
      'at': FieldValue.serverTimestamp(),
    });
    await b.commit();
  }

  Future<void> _enter(User u, _Snapshot s, int gen) async {
    account = s.account;
    assignments = s.assignments.where((a) => a.active).toList();
    language = (s.account?['language'] as String?) ?? language;
    policy = Policy(PolicyOptions.fromMap(s.config));
    final keep = role != null && assignments.any((a) => a.role == role);
    role = keep ? role : startingRole(assignments);

    final levels = await db.collection('hierarchyLevels').get();
    titles = {for (final d in levels.docs) d.id: (d.data()['title'] as String?) ?? ''}..removeWhere((k, v) => v.isEmpty);

    await _loadAreas(assignments.expand((a) => a.areaIds).toSet());
    final orgId = current?.orgId ?? s.account?['orgId'] as String?;
    orgName = null;
    if (orgId != null) {
      final org = await db.doc('organisations/$orgId').get();
      orgName = org.data()?['name'] as String?;
    }
    if (gen != _generation) return;

    unawaited(db.doc('accounts/${u.uid}').update({'lastLoginAt': FieldValue.serverTimestamp()}).catchError((_) {}));
    unawaited(logEvent(db, u, 'sign_in', 'auth'));
    _watch(u);
    _set(SessionPhase.ready);
  }

  /// Loads only the areas this person needs (their own and the ones above
  /// them), never the whole tree: it keeps database reads low.
  Future<void> _loadAreas(Set<String> ids) async {
    final names = <String, String>{};
    final paths = <String, List<String>>{};
    final ancestors = <String>{};
    for (final chunk in _chunks(ids.toList(), 10)) {
      final snap = await db.collection('areas').where(FieldPath.documentId, whereIn: chunk).get();
      for (final d in snap.docs) {
        final node = AreaNode.fromMap(d.id, d.data());
        if (node == null) continue;
        names[node.id] = node.name;
        paths[node.id] = node.path;
        ancestors.addAll(node.path);
      }
    }
    ancestors.removeAll(names.keys);
    for (final chunk in _chunks(ancestors.toList(), 10)) {
      final snap = await db.collection('areas').where(FieldPath.documentId, whereIn: chunk).get();
      for (final d in snap.docs) {
        names[d.id] = (d.data()['name'] as String?) ?? d.id;
      }
    }
    areaNames = names;
    areaPaths = paths;
  }

  static Iterable<List<String>> _chunks(List<String> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }

  /// A role or account switched off by an administrator takes effect at once.
  void _watch(User u) {
    _rolesFingerprint = _fingerprint(assignments);
    _rolesSub = db.collection('roleAssignments').where('uid', isEqualTo: u.uid).snapshots().listen((snap) {
      final next = snap.docs.map((d) => RoleAssignment.fromMap(d.data())).whereType<RoleAssignment>().where((a) => a.active).toList();
      if (_fingerprint(next) != _rolesFingerprint) _resolve();
    }, onError: (_) {});
    _accountSub = db.doc('accounts/${u.uid}').snapshots().listen((snap) {
      if (snap.data()?['status'] == 'disabled') _resolve();
    }, onError: (_) {});
  }

  static String _fingerprint(List<RoleAssignment> list) {
    final parts = list.map((a) => '${a.role.key}:${a.orgId}:${a.areaIds.join(",")}').toList()..sort();
    return parts.join('|');
  }

  static String _describe(Object e) {
    if (e is FirebaseException) {
      if (e.code == 'unavailable') return 'No internet connection. Connect and try again.';
      if (e.code == 'permission-denied') return 'Access was refused by the server. Contact your administrator.';
      return e.message ?? e.code;
    }
    return e.toString();
  }
}
