import 'roles.dart';

/// What a role may do (Phase 1, section 3: one row of the permission matrix
/// per capability).
enum Capability {
  dashboard,
  liveMap,
  routeHistory,
  attendanceRecords,
  requestAttendanceCorrection,
  approveAttendanceCorrection,
  activityEvidence,
  reviewActivities,
  createTasks,
  assignTasks,
  updateTaskProgress,
  escalate,
  manageEmployees,
  mapEmployeesToAreas,
  manageGeofences,
  manageRolesAndSettings,
  auditLogs,
  exportReports,
  ownDutyTracking,
}

/// Over which records a capability applies.
enum Scope {
  /// No access.
  none,

  /// Own records only.
  self,

  /// Workers and panchayats assigned to this officer.
  assigned,

  /// The panchayats of the officer's zone.
  zone,

  /// The blocks or zones configured for the officer.
  area,

  /// The officer's own third-party organisation.
  org,

  /// The whole district.
  district,

  /// Past records only; never live data.
  history;

  bool get allowed => this != Scope.none;
}

/// Switches the System administrator can change (Phase 1, section 3:
/// "monitoring is not management" unless switched on).
class PolicyOptions {
  const PolicyOptions({this.supervisorsMayCreateTasks = false, this.collectorMayAssignTasks = false});

  final bool supervisorsMayCreateTasks;
  final bool collectorMayAssignTasks;

  factory PolicyOptions.fromMap(Map<String, dynamic>? m) => PolicyOptions(
        supervisorsMayCreateTasks: m?['supervisorsMayCreateTasks'] == true,
        collectorMayAssignTasks: m?['collectorMayAssignTasks'] == true,
      );
}

/// The permission matrix from Phase 1, section 3, as code.
///
/// This decides what the app SHOWS. What the database ALLOWS is decided
/// separately by the security rules (v2/firestore.rules); both are tested.
class Policy {
  const Policy([this.options = const PolicyOptions()]);

  final PolicyOptions options;

  static const _n = Scope.none;

  static const Map<Capability, List<Scope>> _matrix = {
    //                                   collector       officer        zonal          supervisor      orgAdmin    worker       auditor        sysAdmin
    Capability.dashboard: [Scope.district, Scope.area, Scope.zone, Scope.assigned, Scope.org, Scope.self, Scope.history, _n],
    Capability.liveMap: [Scope.district, Scope.area, Scope.zone, Scope.assigned, Scope.org, Scope.self, _n, _n],
    Capability.routeHistory: [Scope.district, Scope.area, Scope.zone, Scope.assigned, Scope.org, Scope.self, _n, _n],
    Capability.attendanceRecords: [Scope.district, Scope.area, Scope.zone, Scope.assigned, Scope.org, Scope.self, Scope.history, _n],
    Capability.requestAttendanceCorrection: [_n, _n, _n, Scope.assigned, _n, Scope.self, _n, _n],
    Capability.approveAttendanceCorrection: [_n, Scope.area, Scope.zone, _n, _n, _n, _n, _n],
    Capability.activityEvidence: [Scope.district, Scope.area, Scope.zone, Scope.assigned, Scope.org, Scope.self, Scope.history, _n],
    Capability.reviewActivities: [_n, Scope.area, Scope.zone, Scope.assigned, _n, _n, _n, _n],
    Capability.createTasks: [_n, Scope.area, Scope.zone, _n, _n, _n, _n, _n],
    Capability.assignTasks: [_n, Scope.area, Scope.zone, _n, _n, _n, _n, _n],
    Capability.updateTaskProgress: [_n, _n, Scope.zone, Scope.assigned, _n, Scope.self, _n, _n],
    Capability.escalate: [_n, Scope.area, Scope.zone, Scope.assigned, Scope.org, Scope.self, _n, _n],
    Capability.manageEmployees: [_n, _n, _n, _n, Scope.org, _n, _n, Scope.district],
    Capability.mapEmployeesToAreas: [_n, _n, Scope.zone, _n, Scope.org, _n, _n, Scope.district],
    Capability.manageGeofences: [_n, _n, _n, _n, _n, _n, _n, Scope.district],
    Capability.manageRolesAndSettings: [_n, _n, _n, _n, _n, _n, _n, Scope.district],
    Capability.auditLogs: [_n, _n, _n, _n, _n, _n, Scope.district, Scope.district],
    Capability.exportReports: [Scope.district, Scope.area, Scope.zone, Scope.assigned, Scope.org, _n, Scope.history, _n],
    Capability.ownDutyTracking: [_n, _n, _n, _n, _n, Scope.self, _n, _n],
  };

  static const _columns = [
    Role.collector,
    Role.officer,
    Role.zonalSecretary,
    Role.supervisor,
    Role.orgAdmin,
    Role.worker,
    Role.auditor,
    Role.sysAdmin,
  ];

  /// The scope over which [role] may use [capability].
  Scope scopeFor(Role role, Capability capability) {
    final row = _matrix[capability];
    if (row == null) return Scope.none;
    var scope = row.elementAt(_columns.indexOf(role));
    // Switches that widen the defaults.
    if (role == Role.supervisor && options.supervisorsMayCreateTasks &&
        (capability == Capability.createTasks || capability == Capability.assignTasks)) {
      scope = Scope.assigned;
    }
    if (role == Role.collector && options.collectorMayAssignTasks &&
        (capability == Capability.createTasks || capability == Capability.assignTasks)) {
      scope = Scope.district;
    }
    return scope;
  }

  bool can(Role role, Capability capability) => scopeFor(role, capability).allowed;

  /// Every capability this role has, with its scope (for "what you can do").
  Map<Capability, Scope> capabilitiesOf(Role role) => {
        for (final c in Capability.values)
          if (can(role, c)) c: scopeFor(role, c),
      };
}
