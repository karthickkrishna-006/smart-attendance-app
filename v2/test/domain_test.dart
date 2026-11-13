import 'package:field_monitor/domain/area.dart';
import 'package:field_monitor/domain/navigation.dart';
import 'package:field_monitor/domain/policy.dart';
import 'package:field_monitor/domain/roles.dart';
import 'package:field_monitor/domain/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = Policy();

  group('permission matrix (Phase 1, section 3)', () {
    test('workers see only their own records', () {
      for (final c in Capability.values) {
        final s = policy.scopeFor(Role.worker, c);
        expect(s == Scope.none || s == Scope.self, true, reason: '$c');
      }
    });

    test('auditors never get live location or route history', () {
      expect(policy.scopeFor(Role.auditor, Capability.liveMap), Scope.none);
      expect(policy.scopeFor(Role.auditor, Capability.routeHistory), Scope.none);
      expect(policy.scopeFor(Role.auditor, Capability.attendanceRecords), Scope.history);
    });

    test('the Collector monitors the district but changes nothing by default', () {
      expect(policy.scopeFor(Role.collector, Capability.dashboard), Scope.district);
      expect(policy.scopeFor(Role.collector, Capability.liveMap), Scope.district);
      for (final c in [
        Capability.createTasks,
        Capability.assignTasks,
        Capability.reviewActivities,
        Capability.manageEmployees,
        Capability.approveAttendanceCorrection,
        Capability.manageRolesAndSettings,
      ]) {
        expect(policy.can(Role.collector, c), false, reason: '$c');
      }
    });

    test('the System administrator configures but sees no operational data', () {
      for (final c in [
        Capability.dashboard,
        Capability.liveMap,
        Capability.routeHistory,
        Capability.attendanceRecords,
        Capability.activityEvidence,
      ]) {
        expect(policy.can(Role.sysAdmin, c), false, reason: '$c');
      }
      expect(policy.scopeFor(Role.sysAdmin, Capability.manageRolesAndSettings), Scope.district);
      expect(policy.scopeFor(Role.sysAdmin, Capability.auditLogs), Scope.district);
    });

    test('third-party admins stay inside their organisation (live map: own workers only)', () {
      for (final c in Capability.values) {
        final s = policy.scopeFor(Role.orgAdmin, c);
        expect(s == Scope.none || s == Scope.org, true, reason: '$c');
      }
      expect(policy.scopeFor(Role.orgAdmin, Capability.liveMap), Scope.org);
      expect(policy.can(Role.auditor, Capability.liveMap), false);
    });

    test('only AD and Zonal Secretary create tasks by default; switches widen it', () {
      expect(policy.can(Role.officer, Capability.createTasks), true);
      expect(policy.can(Role.zonalSecretary, Capability.createTasks), true);
      expect(policy.can(Role.supervisor, Capability.createTasks), false);
      const widened = Policy(PolicyOptions(supervisorsMayCreateTasks: true, collectorMayAssignTasks: true));
      expect(widened.scopeFor(Role.supervisor, Capability.createTasks), Scope.assigned);
      expect(widened.scopeFor(Role.collector, Capability.assignTasks), Scope.district);
      expect(widened.can(Role.worker, Capability.createTasks), false);
    });

    test('only workers track their own duty', () {
      for (final r in Role.values) {
        expect(policy.can(r, Capability.ownDutyTracking), r == Role.worker, reason: '$r');
      }
    });
  });

  group('navigation follows the policy', () {
    test('workers get exactly the five-tab app', () {
      expect(sectionsFor(Role.worker, policy), [
        Section.workerHome,
        Section.workerAttendance,
        Section.workerActivity,
        Section.workerTasks,
        Section.profile,
      ]);
    });

    test('no officer menu offers a section the role cannot use', () {
      for (final r in Role.values.where((r) => !r.isFieldWorker)) {
        final s = sectionsFor(r, policy);
        expect(s.contains(Section.liveMonitoring), policy.can(r, Capability.liveMap), reason: '$r live');
        expect(s.contains(Section.setup), r == Role.sysAdmin, reason: '$r setup');
        expect(s.contains(Section.auditLog), r == Role.auditor || r == Role.sysAdmin, reason: '$r audit');
        expect(s.last, Section.profile, reason: '$r profile last');
      }
    });

    test('the System administrator menu is administration only, no monitoring', () {
      // Employees = registering people (matrix: "Register and edit employees: District").
      expect(sectionsFor(Role.sysAdmin, policy), [Section.employees, Section.setup, Section.auditLog, Section.profile]);
    });
  });

  group('area scope', () {
    const d = AreaNode(id: 'd1', name: 'District', level: AreaLevel.district, path: ['d1']);
    final b = AreaNode.fromMap('b1', {'name': 'Block', 'level': 'block', 'parentId': 'd1', 'path': ['d1', 'b1']});

    test('records inside an officer area are covered; others are not', () {
      expect(areaCovers(['b1'], ['d1', 'b1', 'p7']), true);
      expect(areaCovers(['b2'], ['d1', 'b1', 'p7']), false);
      expect(areaCovers(['d1'], ['d1', 'b9', 'p1']), true);
      expect(areaCovers(const [], ['d1']), false);
    });

    test('a node is accepted only when its path ends with its own id', () {
      expect(b?.path, ['d1', 'b1']);
      expect(AreaNode.fromMap('b1', {'level': 'block', 'path': ['d1']}), null);
      expect(AreaNode.fromMap('x', {'level': 'planet', 'path': ['x']}), null);
      expect(d.childPath('b2'), ['d1', 'b2']);
      expect(AreaLevel.district.childLevel, AreaLevel.block);
      expect(AreaLevel.location.childLevel, null);
    });

    test('area label uses names and marks unknown ids', () {
      expect(areaLabel(['d1', 'b1'], {'d1': 'Chengalpattu', 'b1': 'Block A'}), 'Chengalpattu › Block A');
      expect(areaLabel(['d1', 'zz'], {'d1': 'Chengalpattu'}), 'Chengalpattu › …');
    });
  });

  group('sign-in decision (no approval screen for added workers)', () {
    RoleAssignment ra(Role r, {bool active = true}) => RoleAssignment(uid: 'u1', role: r, areaIds: const [], active: active);
    const pre = Preregistration(email: 'w@x.in', role: Role.worker, areaIds: ['p1']);
    EntryAction decide({
      bool exists = false,
      bool disabled = false,
      List<RoleAssignment> roles = const [],
      Preregistration? prereg,
      bool open = false,
      bool boot = true,
    }) =>
        decideEntry(
          accountExists: exists,
          accountDisabled: disabled,
          assignments: roles,
          preregistration: prereg,
          uid: 'u1',
          openWorkerSignUp: open,
          bootstrapDone: boot,
        );

    test('an active role opens the app', () => expect(decide(exists: true, roles: [ra(Role.worker)]), EntryAction.ready));
    test('a disabled account is stopped even with roles',
        () => expect(decide(exists: true, disabled: true, roles: [ra(Role.worker)]), EntryAction.disabled));
    test('an added person is let in at once', () => expect(decide(prereg: pre), EntryAction.claimPreregistration));
    test('an already-claimed addition is not claimed twice', () {
      const claimed = Preregistration(email: 'w@x.in', role: Role.worker, areaIds: ['p1'], claimedBy: 'other');
      expect(decide(prereg: claimed), EntryAction.notRegistered);
    });
    test('inactive roles do not count', () => expect(decide(exists: true, roles: [ra(Role.worker, active: false)]), EntryAction.notRegistered));
    test('before the first administrator exists, bootstrap is attempted', () => expect(decide(boot: false), EntryAction.tryBootstrap));
    test('open sign-up only when switched on', () {
      expect(decide(open: true), EntryAction.openSignUp);
      expect(decide(open: false), EntryAction.notRegistered);
    });
    test('the starting role prefers the last used, else the highest', () {
      final both = [ra(Role.worker), ra(Role.auditor)];
      expect(startingRole(both), Role.auditor);
      expect(startingRole(both, lastUsed: Role.worker), Role.worker);
      expect(startingRole([ra(Role.worker, active: false)]), null);
    });
    test('e-mail keys are normalised', () => expect(emailKey('  Krish@Example.COM '), 'krish@example.com'));
  });

  test('role keys round-trip and are unique', () {
    expect(Role.values.map((r) => r.key).toSet().length, Role.values.length);
    for (final r in Role.values) {
      expect(Role.fromKey(r.key), r);
    }
    expect(Role.fromKey('admin'), null);
  });
}
