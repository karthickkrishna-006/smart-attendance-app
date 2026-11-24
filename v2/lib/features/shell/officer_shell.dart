import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/session_controller.dart';
import '../../domain/navigation.dart';
import '../../domain/policy.dart';
import '../../domain/roles.dart';
import '../../data/officer_attendance.dart';
import '../../domain/attendance.dart';
import '../../domain/attendance_summary.dart';
import '../attendance/officer_attendance_screen.dart';
import '../../data/scoped.dart';
import '../audit/audit_log_screen.dart';
import '../../domain/street_zones.dart';
import '../monitor/monitor_screens.dart';
import '../monitor/street_screens.dart';
import '../staff/street_mapping_screen.dart';
import '../staff/staff_screens.dart';
import '../work/officer_work_screens.dart';
import '../profile/profile_screen.dart';
import '../setup/people_screen.dart';
import '../setup/admin_home.dart';
import '../setup/setup_screen.dart';

/// Officer app: a menu with only the sections this role may use (derived from
/// the permission policy), and the role's title and scope always visible.
class OfficerShell extends StatefulWidget {
  const OfficerShell({super.key, required this.session});
  final SessionController session;
  @override
  State<OfficerShell> createState() => _OfficerShellState();
}

class _OfficerShellState extends State<OfficerShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  Section? _section;
  int _setupTab = 0;
  List<Section> _visible = const [];

  /// Opens a section (from Overview / Admin home tiles); for Setup, a tab.
  void _open(Section section, {int? setupTab}) => setState(() {
        _section = section;
        if (setupTab != null) _setupTab = setupTab;
      });

  static const _icons = <Section, IconData>{
    Section.overview: Icons.space_dashboard_outlined,
    Section.liveMonitoring: Icons.map_outlined,
    Section.attendance: Icons.how_to_reg_outlined,
    Section.employees: Icons.groups_outlined,
    Section.tasks: Icons.assignment_outlined,
    Section.fieldActivities: Icons.photo_library_outlined,
    Section.coverage: Icons.grid_view_outlined,
    Section.reports: Icons.insights_outlined,
    Section.alerts: Icons.notifications_outlined,
    Section.setup: Icons.tune,
    Section.auditLog: Icons.policy_outlined,
    Section.myAttendance: Icons.add_a_photo_outlined,
    Section.messages: Icons.mail_outline,
    Section.streetVisits: Icons.alt_route,
    Section.adminHome: Icons.dashboard_outlined,
    Section.streetMapping: Icons.edit_road,
    Section.profile: Icons.person_outline,
  };

  static String _labelKey(Section s) => switch (s) {
        Section.overview => 'overview',
        Section.liveMonitoring => 'liveMonitoring',
        Section.attendance => 'attendance',
        Section.employees => 'employees',
        Section.tasks => 'tasks',
        Section.fieldActivities => 'fieldActivities',
        Section.coverage => 'coverage',
        Section.reports => 'reports',
        Section.alerts => 'alerts',
        Section.setup => 'setup',
        Section.auditLog => 'auditLog',
        Section.myAttendance => 'myAttendance',
        Section.messages => 'messages',
        Section.streetVisits => 'streetVisits',
        Section.adminHome => 'adminHome',
        Section.streetMapping => 'streetMapping',
        Section.profile => 'profile',
        _ => 'home',
      };

  Widget _page(Section section, Strings s) {
    final session = widget.session;
    final role = session.role!;
    switch (section) {
      case Section.overview:
        return _Overview(key: ValueKey(role), session: session, sections: _visible, onOpen: _open);
      case Section.adminHome:
        return AdminHomeScreen(session: session, onOpen: _open);
      case Section.employees:
        if (role == Role.sysAdmin || role == Role.orgAdmin) return PeopleScreen(session: session);
        return const MessageView(
          icon: Icons.groups_outlined,
          title: 'Workers in your zone',
          body: 'In this version the System administrator adds workers and assigns them to streets (Employees and Setup → Access). '
              'You see your zone\'s workers in Attendance, Live monitoring and Coverage, and assign their work in Tasks.',
        );
      case Section.attendance:
        return OfficerAttendanceScreen(key: ValueKey(role), session: session);
      case Section.fieldActivities:
        return OfficerActivitiesScreen(key: ValueKey(role), session: session);
      case Section.tasks:
        return OfficerTasksScreen(key: ValueKey(role), session: session);
      case Section.alerts:
        return AlertsScreen(key: ValueKey(role), session: session);
      case Section.myAttendance:
        return PhotoAttendanceScreen(key: ValueKey(role), session: session);
      case Section.messages:
        return MessagesScreen(key: ValueKey(role), session: session);
      case Section.streetMapping:
        return StreetMappingScreen(key: ValueKey(role), session: session);
      case Section.streetVisits:
        return StreetVisitsScreen(key: ValueKey(role), session: session);
      case Section.liveMonitoring:
        return LiveMonitoringScreen(key: ValueKey(role), session: session);
      case Section.coverage:
        return CoverageScreen(key: ValueKey(role), session: session);
      case Section.reports:
        return ReportsScreen(key: ValueKey(role), session: session);
      case Section.setup:
        return SetupScreen(key: ValueKey('setup$_setupTab'), session: session, initialTab: _setupTab);
      case Section.auditLog:
        return const AuditLogScreen();
      case Section.profile:
        return ProfileScreen(session: session);
      default:
        return NotYetBuilt(icon: _icons[section] ?? Icons.layers_outlined, title: s.t(_labelKey(section)), text: s.t('sectionNext'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final session = widget.session;
    final role = session.role!;
    final base = sectionsFor(role, session.policy);
    final takesPhotos = session.designation?.schedule.required ?? false;
    final sections = <Section>[
      for (final sec in base) ...[
        if (sec == Section.profile) Section.messages,
        sec,
        if (sec == base.first && takesPhotos) Section.myAttendance,
        if (sec == Section.attendance) Section.streetVisits,
        if (role == Role.sysAdmin && sec == base.first) Section.adminHome,
        // VP Secretaries / MNPs map the streets and cleaning zones of their panchayat.
        if (sec == Section.attendance && role == Role.supervisor) Section.streetMapping,
      ],
    ];
    // Menu in groups (each role still sees only its own sections).
    final groups = <(String, List<Section>)>[
      (s.t('menuToday'), [Section.adminHome, Section.overview, Section.liveMonitoring, Section.attendance, Section.streetVisits, Section.alerts]),
      (s.t('menuWork'), [Section.tasks, Section.fieldActivities]),
      (s.t('menuMapping'), [Section.streetMapping, Section.employees, Section.setup]),
      (s.t('menuReports'), [Section.coverage, Section.reports, Section.auditLog]),
      (s.t('menuMe'), [Section.myAttendance, Section.messages, Section.profile]),
    ];
    final grouped = <(String, List<Section>)>[
      for (final g in groups) (g.$1, [for (final x in g.$2) if (sections.contains(x)) x]),
    ]..removeWhere((g) => g.$2.isEmpty);
    final leftover = [for (final x in sections) if (!grouped.any((g) => g.$2.contains(x))) x];
    if (leftover.isNotEmpty) grouped.add(('', leftover));
    final ordered = [for (final g in grouped) ...g.$2];
    _visible = ordered;
    final section = ordered.contains(_section) ? _section! : ordered.first;
    final selected = ordered.indexOf(section);

    final menu = NavigationDrawer(
      backgroundColor: Colors.white,
      selectedIndex: selected,
      onDestinationSelected: (i) {
        setState(() => _section = ordered.elementAt(i));
        _scaffold.currentState?.closeDrawer();
      },
      children: [
        _Header(session: session),
        const SizedBox(height: 8),
        for (final g in grouped) ...[
          if (g.$1.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 14, 16, 6),
              child: Text(g.$1.toUpperCase(),
                  style: const TextStyle(fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: AppColors.muted)),
            ),
          for (final sec in g.$2)
            NavigationDrawerDestination(icon: Icon(_icons[sec] ?? Icons.circle_outlined), label: Text(s.t(_labelKey(sec)))),
        ],
        const Padding(padding: EdgeInsets.fromLTRB(28, 12, 28, 4), child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListTile(
            leading: const Icon(Icons.logout, color: AppColors.danger),
            title: Text(s.t('signOut'), style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600)),
            onTap: session.signOut,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final body = Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: wide
              ? null
              : IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: () => _scaffold.currentState?.openDrawer()),
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.t(_labelKey(section)), style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
            Text(s.t('department'), style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ]),
        ),
        body: _page(section, s),
      );
      return Scaffold(
        key: _scaffold,
        drawer: wide ? null : menu,
        body: wide ? Row(children: [SizedBox(width: 300, child: menu), const VerticalDivider(width: 1), Expanded(child: body)]) : body,
      );
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final role = session.role!;
    final roles = session.activeRoles;
    return Container(
      color: AppColors.indigo,
      padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 20, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          (session.account?['displayName'] as String?)?.trim().isNotEmpty == true
              ? niceName(session.account!['displayName'] as String)
              : (session.user?.email ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        if (roles.length > 1)
          DropdownButton<Role>(
            value: role,
            dropdownColor: AppColors.indigo,
            iconEnabledColor: Colors.white,
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: Colors.white, fontSize: 15),
            items: [for (final r in roles) DropdownMenuItem(value: r, child: Text(session.titleOf(r)))],
            onChanged: (r) {
              if (r != null) session.setRole(r);
            },
          )
        else
          Text(session.displayTitle, style: const TextStyle(color: Colors.white70, fontSize: 15)),
        const SizedBox(height: 10),
        ScopeChip(labels: session.scopeLabels, emptyText: s.t('notAssigned'), dark: true),
      ]),
    );
  }
}

/// What this role may do and over which records, read straight from the
/// permission policy (the same table as Phase 1, section 3).
class _Overview extends StatefulWidget {
  const _Overview({super.key, required this.session, required this.sections, required this.onOpen});
  final List<Section> sections;
  final void Function(Section section, {int? setupTab}) onOpen;
  final SessionController session;
  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  SessionController get session => widget.session;
  late final Stream<List<Map<String, dynamic>>> _today = OfficerAttendance(widget.session).watch(dayKey(DateTime.now()));
  late final Stream<List<Map<String, dynamic>>> _streets = watchScoped(widget.session, 'visits', day: dayKey(DateTime.now()));

  static const _capabilityText = <Capability, String>{
    Capability.dashboard: 'See summary figures',
    Capability.liveMap: 'See workers on the live map',
    Capability.routeHistory: 'See routes travelled',
    Capability.attendanceRecords: 'See attendance records',
    Capability.requestAttendanceCorrection: 'Request an attendance correction',
    Capability.approveAttendanceCorrection: 'Approve attendance corrections',
    Capability.activityEvidence: 'See field activity photos and details',
    Capability.reviewActivities: 'Approve, reject or request rework',
    Capability.createTasks: 'Create tasks',
    Capability.assignTasks: 'Assign tasks',
    Capability.updateTaskProgress: 'Update task progress',
    Capability.escalate: 'Escalate an issue',
    Capability.manageEmployees: 'Register and edit employees',
    Capability.mapEmployeesToAreas: 'Assign employees to work areas',
    Capability.manageGeofences: 'Manage areas and geofences',
    Capability.manageRolesAndSettings: 'Manage roles and settings',
    Capability.auditLogs: 'Read the audit log',
    Capability.exportReports: 'Export reports',
    Capability.ownDutyTracking: 'Start and stop own duty tracking',
  };

  static const _scopeText = <Scope, String>{
    Scope.self: 'your own records',
    Scope.assigned: 'your assigned workers',
    Scope.zone: 'your zone',
    Scope.area: 'your area',
    Scope.org: 'your organisation',
    Scope.district: 'the whole district',
    Scope.history: 'past records only',
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final caps = session.policy.capabilitiesOf(session.role!);
    final seesAttendance = session.policy.can(session.role!, Capability.attendanceRecords);
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text(session.titleOf(session.role!), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.ink)),
      const SizedBox(height: 10),
      Align(alignment: Alignment.centerLeft, child: ScopeChip(labels: session.scopeLabels, emptyText: s.t('notAssigned'))),
      if (scopeProblem(session) != null) ...[const SizedBox(height: 12), NoticeCard(text: scopeProblem(session)!)],
      if (seesAttendance) ...[
        const SizedBox(height: 24),
        Text('${s.t('attendanceTitle')} · ${s.t('today')}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink)),
        const SizedBox(height: 10),
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _today,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: AppColors.danger));
            if (!snap.hasData) return const LinearProgressIndicator();
            return AttendanceSummaryTiles(summary: AttendanceSummary.of(snap.data!));
          },
        ),
        const SizedBox(height: 18),
        const Text('Streets today (automatic check-in / check-out)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink)),
        const SizedBox(height: 10),
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _streets,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: AppColors.danger));
            if (!snap.hasData) return const LinearProgressIndicator();
            final st = snap.data!.map(visitStatusOf).toList();
            Widget tile(StreetVisitStatus s) => Container(
                  constraints: const BoxConstraints(minWidth: 100),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.line)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('${st.where((x) => x == s).length}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: streetStatusColor(s))),
                    Text(streetStatusLabel(s), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  ]),
                );
            return Wrap(spacing: 10, runSpacing: 10, children: [for (final s in StreetVisitStatus.values) tile(s)]);
          },
        ),
      ],
      const SizedBox(height: 24),
      Text(s.t('quickActions'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink)),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 700 ? 4 : 2;
        final w = (box.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final sec in widget.sections.where((x) => x != Section.overview && x != Section.profile))
            SizedBox(
              width: w,
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => widget.onOpen(sec),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
                    child: Row(children: [
                      Icon(_OfficerShellState._icons[sec] ?? Icons.circle_outlined, color: AppColors.green),
                      const SizedBox(width: 10),
                      Expanded(child: Text(s.t(_OfficerShellState._labelKey(sec)), style: const TextStyle(fontWeight: FontWeight.w600))),
                    ]),
                  ),
                ),
              ),
            ),
        ]);
      }),
      const SizedBox(height: 18),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(s.t('whatYouCanDo'), style: const TextStyle(fontWeight: FontWeight.w600)),
        children: [
      Card(
        child: Column(children: [
          for (final e in caps.entries)
            ListTile(
              leading: const Icon(Icons.check_circle_outline, color: AppColors.green),
              title: Text(_capabilityText[e.key] ?? e.key.name),
              subtitle: Text('Scope: ${_scopeText[e.value] ?? e.value.name}'),
            ),
        ]),
      ),
        ],
      ),
      const SizedBox(height: 16),
      Text(s.t('previewBanner'), style: const TextStyle(color: AppColors.muted)),
    ]);
  }
}
