import 'policy.dart';
import 'roles.dart';

/// Screens of the app. Workers get a fixed five-tab bottom bar (master prompt
/// §12); officers get only the sections their capabilities allow.
enum Section {
  // Worker app (bottom navigation)
  workerHome,
  workerAttendance,
  workerActivity,
  workerTasks,
  // Officer app (menu)
  overview,
  liveMonitoring,
  attendance,
  employees,
  tasks,
  fieldActivities,
  coverage,
  reports,
  alerts,
  setup,
  auditLog,
  // Everyone
  profile,
}

/// Which sections a role sees, in menu order. Derived from the policy, so the
/// menu can never offer something the role is not allowed to do.
List<Section> sectionsFor(Role role, Policy policy) {
  if (role.isFieldWorker) {
    return const [Section.workerHome, Section.workerAttendance, Section.workerActivity, Section.workerTasks, Section.profile];
  }
  bool can(Capability c) => policy.can(role, c);
  return [
    if (can(Capability.dashboard)) Section.overview,
    if (can(Capability.liveMap)) Section.liveMonitoring,
    if (can(Capability.attendanceRecords)) Section.attendance,
    if (can(Capability.manageEmployees) || can(Capability.mapEmployeesToAreas)) Section.employees,
    if (can(Capability.createTasks) || can(Capability.assignTasks) || can(Capability.updateTaskProgress)) Section.tasks,
    if (can(Capability.activityEvidence)) Section.fieldActivities,
    if (can(Capability.dashboard) && role != Role.orgAdmin) Section.coverage,
    if (can(Capability.exportReports)) Section.reports,
    if (can(Capability.dashboard)) Section.alerts,
    if (can(Capability.manageRolesAndSettings) || can(Capability.manageGeofences)) Section.setup,
    if (can(Capability.auditLogs)) Section.auditLog,
    Section.profile,
  ];
}
