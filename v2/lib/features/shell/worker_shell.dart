import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/session_controller.dart';
import '../../data/attendance_repository.dart';
import '../../data/duty_service.dart';
import '../../data/location.dart';
import '../../data/work_repository.dart';
import '../attendance/worker_attendance_screen.dart';
import '../staff/staff_screens.dart';
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
      (widget.session.designation?.schedule.required ?? false)
          ? PhotoAttendanceScreen(session: widget.session)
          : WorkerAttendanceScreen(session: widget.session),
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

  Widget _bigTile(IconData icon, String title, String value, Color color, VoidCallback onTap) => Expanded(
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              height: 118,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: color, size: 34),
                const SizedBox(height: 6),
                Text(title, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                Text(value, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 13)),
              ]),
            ),
          ),
        ),
      );

  Future<void> _confirmStop(BuildContext context, Strings s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(s.t('stopDuty')),
        content: Text(s.t('stopDutyConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('stopDuty'))),
        ],
      ),
    );
    if (ok != true) return;
    await DutyService.instance.stop();
    showToast(s.t('dutyStopped'), kind: ToastKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final name = niceName((session.account?['displayName'] as String?)?.trim());
    final first = name.isEmpty ? (session.user?.email ?? '') : name.split(RegExp(r'\s+')).first;
    final noArea = (session.current?.areaIds ?? const []).isEmpty;
    String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
      Text(s.t('hello', {'name': first}), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppColors.ink)),
      if (session.designation != null)
        Text(s.t('d_${session.designation!.key}'), style: const TextStyle(color: AppColors.muted, fontSize: 16)),
      const SizedBox(height: 10),
      if (noArea)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFFFFF4D6), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.turmeric, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(s.t('noAreaWorker'), style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35))),
          ]),
        )
      else
        Align(alignment: Alignment.centerLeft, child: ScopeChip(labels: session.scopeLabels, emptyText: s.t('notAssigned'))),
      const SizedBox(height: 14),
      // Duty first: the one thing a worker does every day.
      ListenableBuilder(
        listenable: DutyService.instance,
        builder: (context, _) {
          final duty = DutyService.instance;
          final since = duty.startedAt;
          final sent = duty.lastSentAt;
          return Card(
            color: duty.onDuty ? const Color(0xFFE3EFE9) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(duty.onDuty ? Icons.directions_walk : Icons.pause_circle_outline, color: duty.onDuty ? AppColors.green : AppColors.muted),
                  const SizedBox(width: 8),
                  Text(s.t('dutyTitle'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 6),
                Text(duty.onDuty && since != null ? s.t('dutyOn', {'time': hm(since)}) : s.t('dutyOff')),
                if (duty.onDuty && sent != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(s.t('locationSent', {'min': '${DateTime.now().difference(sent).inMinutes}'}),
                        style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600)),
                  ),
                if (duty.onDuty && duty.currentStreet != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      const Icon(Icons.place, color: AppColors.green, size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          [
                            duty.zonesTotal > 0
                                ? s.t('inStreetZones', {'street': duty.currentStreet!, 'n': '${duty.zonesDone}', 'm': '${duty.zonesTotal}'})
                                : s.t('inStreet', {'street': duty.currentStreet!}),
                            if (duty.currentZone != null) duty.currentZone!.name,
                          ].join(' · '),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ]),
                  ),
                if (duty.lastError != null)
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text(duty.lastError!, style: const TextStyle(color: AppColors.danger, fontSize: 13))),
                const SizedBox(height: 12),
                SizedBox(
                  height: 56,
                  child: duty.onDuty
                      ? OutlinedButton.icon(
                          onPressed: () => _confirmStop(context, s),
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: Text(s.t('stopDuty'), style: const TextStyle(fontSize: 17)),
                        )
                      : FilledButton.icon(
                          onPressed: noArea
                              ? null
                              : () async {
                                  try {
                                    await duty.start(session);
                                    showToast(s.t('dutyStarted'), kind: ToastKind.success);
                                  } on LocationProblem catch (e) {
                                    showToast(e.message, kind: ToastKind.error);
                                  } catch (e) {
                                    showToast('$e', kind: ToastKind.error);
                                  }
                                },
                          icon: const Icon(Icons.play_arrow),
                          label: Text(s.t('startDuty'), style: const TextStyle(fontSize: 17)),
                        ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.phonelink_setup, size: 18),
                    label: Text(s.t('phoneSetup')),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text(s.t('phoneSetup')),
                        content: SingleChildScrollView(child: Text(s.t('phoneSetupBody'), style: const TextStyle(height: 1.4))),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
                          FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
                            onPressed: () {
                              Navigator.pop(c);
                              Location.openSettings('denied');
                            },
                            child: Text(s.t('openSettings')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
      const SizedBox(height: 14),
      // Three big tiles: attendance photo, report work, tasks.
      StreamBuilder<Map<String, dynamic>?>(
        stream: _today,
        builder: (context, todaySnap) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: _tasks,
          builder: (context, taskSnap) {
            final done = todaySnap.data?['checkIn'] != null;
            final open = (taskSnap.data ?? const []).where((t) => ['assigned', 'in_progress', 'rework'].contains(t['status'])).length;
            return Row(children: [
              _bigTile(done ? Icons.verified : Icons.add_a_photo_outlined, s.t('attendance'),
                  done ? s.t('attendanceDone') : s.t('attendanceNotDone'), done ? AppColors.success : AppColors.turmeric, () => widget.onOpenTab(1)),
              const SizedBox(width: 8),
              _bigTile(Icons.cleaning_services_outlined, s.t('reportWorkShort'), s.t('withPhotos'), AppColors.green, () => widget.onOpenTab(2)),
              const SizedBox(width: 8),
              _bigTile(Icons.assignment_outlined, s.t('tasksShort'), taskSnap.hasData ? '$open ${s.t('openWord')}' : '…', AppColors.indigo,
                  () => widget.onOpenTab(3)),
            ]);
          },
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: const Icon(Icons.mail_outline, color: AppColors.indigo),
          title: Text(s.t('messages'), style: const TextStyle(fontWeight: FontWeight.w600)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MessagesScreen(session: session, standalone: true))),
        ),
      ),
      if (session.orgName != null) ...[
        const SizedBox(height: 8),
        Text('${s.t('organisation')}: ${session.orgName}', style: const TextStyle(color: AppColors.muted, fontSize: 15)),
      ],
      const SizedBox(height: 16),
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
