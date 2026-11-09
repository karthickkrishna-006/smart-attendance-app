import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/session_controller.dart';
import '../../data/attendance_repository.dart';
import '../../data/work_repository.dart';
import '../attendance/worker_attendance_screen.dart';
import '../work/worker_work_screens.dart';
import '../profile/profile_screen.dart';

/// The field-worker app: five tabs, large targets, plain words
/// (master prompt §12). Workers never see officer features.
class WorkerShell extends StatefulWidget {
  const WorkerShell({super.key, required this.session});
  final SessionController session;
  @override
  State<WorkerShell> createState() => _WorkerShellState();
}

class _WorkerShellState extends State<WorkerShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final pages = <Widget>[
      _WorkerHome(session: widget.session, onOpenTab: (i) => setState(() => _tab = i)),
      WorkerAttendanceScreen(session: widget.session),
      WorkerActivityScreen(session: widget.session),
      WorkerTasksScreen(session: widget.session),
      ProfileScreen(session: widget.session),
    ];
    return Scaffold(
      body: SafeArea(child: pages.elementAt(_tab)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home), label: s.t('home')),
          NavigationDestination(icon: const Icon(Icons.how_to_reg_outlined), selectedIcon: const Icon(Icons.how_to_reg), label: s.t('attendance')),
          NavigationDestination(icon: const Icon(Icons.photo_camera_outlined), selectedIcon: const Icon(Icons.photo_camera), label: s.t('activity')),
          NavigationDestination(icon: const Icon(Icons.assignment_outlined), selectedIcon: const Icon(Icons.assignment), label: s.t('tasks')),
          NavigationDestination(icon: const Icon(Icons.person_outline), selectedIcon: const Icon(Icons.person), label: s.t('profile')),
        ],
      ),
    );
  }
}

class _WorkerHome extends StatefulWidget {
  const _WorkerHome({required this.session, required this.onOpenTab});
  final SessionController session;
  final ValueChanged<int> onOpenTab;
  @override
  State<_WorkerHome> createState() => _WorkerHomeState();
}

class _WorkerHomeState extends State<_WorkerHome> {
  SessionController get session => widget.session;
  late final _today = AttendanceRepository(session.user!.uid).watchToday();
  late final _work = WorkRepository(session);
  late final _tasks = _work.watchTasks();
  late final _mine = _work.watchMyActivities();

  Widget _tile(IconData icon, String title, String value, Color color, int tab) => Card(
        child: ListTile(
          onTap: () => widget.onOpenTab(tab),
          leading: Icon(icon, color: color, size: 30),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(value),
          trailing: const Icon(Icons.chevron_right),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final name = (session.account?['displayName'] as String?)?.trim();
    final first = (name == null || name.isEmpty) ? (session.user?.email ?? '') : name.split(RegExp(r'\s+')).first;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
      Text(s.t('hello', {'name': first}), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppColors.ink)),
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerLeft, child: ScopeChip(labels: session.scopeLabels, emptyText: s.t('notAssigned'))),
      if (session.orgName != null) ...[
        const SizedBox(height: 8),
        Text('${s.t('organisation')}: ${session.orgName}', style: const TextStyle(color: AppColors.muted, fontSize: 15)),
      ],
      const SizedBox(height: 20),
      Text(s.t('todayAtGlance'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      StreamBuilder<Map<String, dynamic>?>(
        stream: _today,
        builder: (context, snap) {
          final done = snap.data?['checkIn'] != null;
          return _tile(done ? Icons.verified : Icons.how_to_reg_outlined, s.t('attendance'),
              done ? s.t('attendanceDone') : s.t('attendanceNotDone'), done ? AppColors.success : AppColors.turmeric, 1);
        },
      ),
      StreamBuilder<List<Map<String, dynamic>>>(
        stream: _tasks,
        builder: (context, snap) {
          final open = (snap.data ?? const []).where((t) => ['assigned', 'in_progress', 'rework'].contains(t['status'])).length;
          return _tile(Icons.assignment_outlined, s.t('openTasks'), snap.hasData ? '$open' : '…', AppColors.indigo, 3);
        },
      ),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: () => widget.onOpenTab(2), icon: const Icon(Icons.photo_camera), label: Text(s.t('newActivity'))),
      const SizedBox(height: 20),
      Text(s.t('recentWork'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      StreamBuilder<List<Map<String, dynamic>>>(
        stream: _mine,
        builder: (context, snap) {
          final list = snap.data;
          if (list == null) return const LinearProgressIndicator();
          if (list.isEmpty) return Text(s.t('noWorkYet'), style: const TextStyle(color: AppColors.muted));
          return Card(
            child: Column(children: [
              for (final a in list.take(3))
                ListTile(
                  title: Text('${a['title']}'),
                  subtitle: Text('${shortDateTime(a['createdAt'])} · ${s.t('st_${a['status']}')}'),
                  trailing: Icon(Icons.circle, size: 12, color: statusColor(a['status'] as String?)),
                ),
            ]),
          );
        },
      ),
    ]);
  }
}
