import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/session_controller.dart';
import '../attendance/worker_attendance_screen.dart';
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
      _WorkerHome(session: widget.session),
      WorkerAttendanceScreen(session: widget.session),
      NotYetBuilt(icon: Icons.photo_camera_outlined, title: s.t('activity'), text: s.t('sectionNext')),
      NotYetBuilt(icon: Icons.assignment_outlined, title: s.t('tasks'), text: s.t('sectionNext')),
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

class _WorkerHome extends StatelessWidget {
  const _WorkerHome({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final name = (session.account?['displayName'] as String?)?.trim();
    final first = (name == null || name.isEmpty) ? (session.user?.email ?? '') : name.split(RegExp(r'\s+')).first;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
      Text(s.t('hello', {'name': first}), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppColors.ink)),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: ScopeChip(labels: session.scopeLabels, emptyText: s.t('notAssigned')),
      ),
      if (session.orgName != null) ...[
        const SizedBox(height: 8),
        Text('${s.t('organisation')}: ${session.orgName}', style: const TextStyle(color: AppColors.muted, fontSize: 15)),
      ],
      const SizedBox(height: 24),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.construction_outlined, color: AppColors.turmeric, size: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(s.t('previewBanner'), style: const TextStyle(fontSize: 15.5, height: 1.4))),
          ]),
        ),
      ),
    ]);
  }
}
