import 'roles.dart';

/// One role a person holds, over a part of the district and (for third-party
/// staff) one organisation. Stored as `roleAssignments/{uid}__{roleKey}`.
class RoleAssignment {
  const RoleAssignment({
    required this.uid,
    required this.role,
    required this.areaIds,
    this.orgId,
    this.active = true,
    this.designation,
  });

  final String uid;
  final Role role;
  final List<String> areaIds;
  final String? orgId;
  final bool active;

  /// Job title key (see designations.dart), or null.
  final String? designation;

  static String docId(String uid, Role role) => '${uid}__${role.key}';

  static RoleAssignment? fromMap(Map<String, dynamic> m) {
    final role = Role.fromKey(m['role'] as String?);
    final uid = m['uid'] as String?;
    if (role == null || uid == null) return null;
    return RoleAssignment(
      uid: uid,
      role: role,
      areaIds: ((m['areaIds'] as List?) ?? const []).whereType<String>().toList(),
      orgId: m['orgId'] as String?,
      active: m['active'] == true,
      designation: m['designation'] as String?,
    );
  }
}

/// A person added in advance by an administrator (or their organisation
/// admin), stored as `preregistrations/{lower-case e-mail}`. Signing in with
/// that e-mail gives access immediately (Phase 1, Q16): no approval screen.
class Preregistration {
  const Preregistration({
    required this.email,
    required this.role,
    required this.areaIds,
    this.name,
    this.employeeId,
    this.orgId,
    this.claimedBy,
    this.createdBy,
    this.designation,
  });

  /// Job title key prepared by the administrator, copied to the role on claim.
  final String? designation;

  final String email;
  final Role role;
  final List<String> areaIds;
  final String? name;
  final String? employeeId;
  final String? orgId;
  final String? claimedBy;

  /// Who added this person; becomes `grantedBy` on the role they claim.
  final String? createdBy;

  bool get claimed => claimedBy != null;

  static Preregistration? fromMap(Map<String, dynamic> m) {
    final role = Role.fromKey(m['role'] as String?);
    final email = m['email'] as String?;
    if (role == null || email == null) return null;
    return Preregistration(
      email: email,
      role: role,
      areaIds: ((m['areaIds'] as List?) ?? const []).whereType<String>().toList(),
      name: m['name'] as String?,
      employeeId: m['employeeId'] as String?,
      orgId: m['orgId'] as String?,
      claimedBy: m['claimedBy'] as String?,
      createdBy: m['createdBy'] as String?,
      designation: m['designation'] as String?,
    );
  }
}

/// What the app must do right after someone signs in.
enum EntryAction {
  /// They have at least one active role: open the app.
  ready,

  /// Their account is switched off by an administrator.
  disabled,

  /// They were added in advance: create their account and role now.
  claimPreregistration,

  /// Open sign-up is switched on: create a field-worker account (no area yet).
  openSignUp,

  /// No role, not added in advance, nothing to claim: they may be the first
  /// administrator (the database decides), otherwise not registered.
  tryBootstrap,

  /// Not added and not allowed to sign up: explain who can add them.
  notRegistered,
}

/// Decides [EntryAction] from what is known about the signed-in person.
///
/// Pure function: no database, so it is unit-tested directly. Access is NOT
/// granted here; it only chooses which write to attempt, and the security
/// rules decide whether that write is allowed.
EntryAction decideEntry({
  required bool accountExists,
  required bool accountDisabled,
  required List<RoleAssignment> assignments,
  required Preregistration? preregistration,
  required String uid,
  required bool openWorkerSignUp,
  required bool bootstrapDone,
}) {
  if (accountExists && accountDisabled) return EntryAction.disabled;
  if (assignments.any((a) => a.active && a.uid == uid)) return EntryAction.ready;
  if (preregistration != null && !preregistration.claimed) return EntryAction.claimPreregistration;
  if (!bootstrapDone) return EntryAction.tryBootstrap;
  if (openWorkerSignUp && !accountExists) return EntryAction.openSignUp;
  return EntryAction.notRegistered;
}

/// The role the app opens with when a person holds several.
Role? startingRole(List<RoleAssignment> assignments, {Role? lastUsed}) {
  final active = assignments.where((a) => a.active).map((a) => a.role).toSet();
  if (active.isEmpty) return null;
  if (lastUsed != null && active.contains(lastUsed)) return lastUsed;
  final sorted = active.toList()..sort((a, b) => a.priority.compareTo(b.priority));
  return sorted.first;
}

/// Normalises an e-mail address the same way the security rules do.
String emailKey(String email) => email.trim().toLowerCase();
