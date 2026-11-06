import 'dart:async';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../services/db.dart';
import '../services/models.dart';
import 'admin/dashboard_screen.dart';
import 'admin/coverage_screen.dart';
import 'admin/live_map_screen.dart';
import 'admin/more_screen.dart';
import 'admin/reports_screen.dart';
import 'admin/tasks_admin_screen.dart';
import 'admin/workers_screen.dart';
import 'admin/audit_screen.dart';
import 'common/alerts_screen.dart';
import 'common/profile_screen.dart';
import 'worker/my_attendance_screen.dart';
import 'worker/my_tasks_screen.dart';
import 'worker/worker_home.dart';

class _Tab {
  final String label;
  final IconData icon;
  final IconData selected;
  final Widget page;
  final int badge;
  _Tab(this.label, this.icon, this.selected, this.page, {this.badge = 0});
}

/// Role-aware navigation (Product Report §6).
class Shell extends StatefulWidget {
  final AppUser me;
  const Shell({super.key, required this.me});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  int _openAlerts = 0;
  StreamSubscription? _alertSub;
  String? _lastAlertId;

  @override
  void initState() {
    super.initState();
    _listenAlerts();
  }

  /// In-app real-time notifications: new alerts arrive as banners.
  void _listenAlerts() {
    final me = widget.me;
    final q = me.canViewAll
        ? Db.col('alerts').where('status', isEqualTo: 'open')
        : Db.col('alerts').where('uid', isEqualTo: me.uid);
    _alertSub = q.snapshots().listen((s) {
      final docs = docsOf(s).where((d) => d['status'] == 'open').toList();
      docs.sort((a, b) => (b['createdAt']?.millisecondsSinceEpoch ?? 0).compareTo(a['createdAt']?.millisecondsSinceEpoch ?? 0));
      if (!mounted) return;
      final newest = docs.isNotEmpty ? docs.first : null;
      if (_lastAlertId != null && newest != null && newest['id'] != _lastAlertId && !s.metadata.isFromCache) {
        final sev = newest['severity'] as String? ?? 'medium';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: statusColor(sev),
          content: Text('New alert: ${newest['description']}'),
          duration: const Duration(seconds: 5),
        ));
      }
      _lastAlertId = newest?['id'] as String? ?? _lastAlertId ?? '';
      setState(() => _openAlerts = docs.length);
    }, onError: (_) {});
  }

  @override
  void didUpdateWidget(covariant Shell old) {
    super.didUpdateWidget(old);
    if (old.me.role != widget.me.role) {
      _alertSub?.cancel();
      _lastAlertId = null;
      _index = 0;
      _listenAlerts();
    }
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  List<_Tab> _tabs() {
    final me = widget.me;
    switch (me.role) {
      case Roles.admin:
      case Roles.supervisor:
        return [
          _Tab('Dashboard', Icons.space_dashboard_outlined, Icons.space_dashboard, DashboardScreen(me: me)),
          _Tab('Live Map', Icons.map_outlined, Icons.map, LiveMapScreen(me: me)),
          _Tab('Workers', Icons.groups_outlined, Icons.groups, WorkersScreen(me: me)),
          _Tab('Tasks', Icons.assignment_outlined, Icons.assignment, TasksAdminScreen(me: me)),
          _Tab('More', Icons.apps_outlined, Icons.apps, MoreScreen(me: me), badge: _openAlerts),
        ];
      case Roles.auditor:
        return [
          _Tab('Dashboard', Icons.space_dashboard_outlined, Icons.space_dashboard, DashboardScreen(me: me)),
          // Auditors review history and coverage; they have no live-location map.
          _Tab('Coverage', Icons.grid_view_outlined, Icons.grid_view, CoverageScreen(me: me)),
          _Tab('Reports', Icons.insights_outlined, Icons.insights, ReportsScreen(me: me)),
          _Tab('Audit', Icons.policy_outlined, Icons.policy, AuditScreen(me: me)),
          _Tab('Profile', Icons.person_outline, Icons.person, ProfileScreen(me: me)),
        ];
      default:
        return [
          _Tab('Home', Icons.home_outlined, Icons.home, WorkerHome(me: me)),
          _Tab('Tasks', Icons.assignment_outlined, Icons.assignment, MyTasksScreen(me: me)),
          _Tab('History', Icons.event_note_outlined, Icons.event_note, MyAttendanceScreen(me: me)),
          _Tab('Alerts', Icons.notifications_outlined, Icons.notifications, AlertsScreen(me: me), badge: _openAlerts),
          _Tab('Profile', Icons.person_outline, Icons.person, ProfileScreen(me: me)),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs();
    if (_index >= tabs.length) _index = 0;
    return Scaffold(
      body: IndexedStack(index: _index, children: tabs.map((t) => t.page).toList()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: tabs
            .map((t) => NavigationDestination(
                  icon: Badge(isLabelVisible: t.badge > 0, label: Text('${t.badge}'), backgroundColor: AppColors.danger, child: Icon(t.icon)),
                  selectedIcon: Badge(isLabelVisible: t.badge > 0, label: Text('${t.badge}'), backgroundColor: AppColors.danger, child: Icon(t.selected)),
                  label: t.label,
                ))
            .toList(),
      ),
    );
  }
}
