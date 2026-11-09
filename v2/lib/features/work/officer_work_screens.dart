import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/officer_attendance.dart';
import '../../data/session_controller.dart';
import '../../data/work_repository.dart';
import '../../domain/attendance.dart';
import '../../domain/policy.dart';
import 'worker_work_screens.dart';

Widget _dayBar(BuildContext context, DateTime day, ValueChanged<DateTime> onChange) {
  final s = Strings.of(context);
  final today = dayKey(DateTime.now()) == dayKey(day);
  return Row(children: [
    IconButton(tooltip: s.t('previousDay'), onPressed: () => onChange(day.subtract(const Duration(days: 1))), icon: const Icon(Icons.chevron_left)),
    Expanded(
      child: Text(today ? '${s.t('today')} · ${dayKey(day)}' : dayKey(day),
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    ),
    IconButton(
      tooltip: s.t('nextDay'),
      onPressed: today ? null : () => onChange(day.add(const Duration(days: 1))),
      icon: const Icon(Icons.chevron_right),
    ),
  ]);
}

Future<String?> askReason(BuildContext context, String title) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, maxLines: 3, maxLength: 500, decoration: const InputDecoration(labelText: 'Reason (shown to the worker)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
          onPressed: () => Navigator.pop(d, c.text.trim().isEmpty ? null : c.text.trim()),
          child: const Text('Send'),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------ activities
class OfficerActivitiesScreen extends StatefulWidget {
  const OfficerActivitiesScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<OfficerActivitiesScreen> createState() => _OfficerActivitiesScreenState();
}

class _OfficerActivitiesScreenState extends State<OfficerActivitiesScreen> {
  late final repo = WorkRepository(widget.session);
  DateTime _day = DateTime.now();
  late Stream<List<Map<String, dynamic>>> _stream = repo.watchActivities(dayKey(_day));
  String _filter = 'all';

  bool get _canReview => widget.session.policy.can(widget.session.role!, Capability.reviewActivities);

  Future<void> _decide(Map<String, dynamic> a, String status) async {
    String note = '';
    if (status != 'approved') {
      final r = await askReason(context, status == 'rework' ? 'Ask for the work to be redone' : 'Reject this report');
      if (r == null) return;
      note = r;
    }
    try {
      await repo.review(a['id'] as String, status, note);
      showToast(status == 'approved' ? 'Approved.' : 'Sent to the worker.', kind: ToastKind.success);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    }
  }

  void _open(Map<String, dynamic> a) {
    final s = Strings.of(context);
    final n = (a['photoCount'] as num?)?.toInt() ?? 0;
    final mine = a['uid'] == widget.session.user?.uid;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('${a['title']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          Text('${(a['workerName'] ?? '').toString().isEmpty ? 'Unnamed worker' : a['workerName']} · ${shortDateTime(a['createdAt'])}'
              '${a['synthetic'] == true ? ' · demo data' : ''}', style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          if (n > 0)
            SizedBox(
              height: 200,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (var i = 0; i < n; i++)
                  Padding(padding: const EdgeInsets.only(right: 10), child: ActivityPhoto(repo: repo, activityId: a['id'] as String, index: i, size: 200)),
              ]),
            )
          else
            const Text('No photo (demo record).', style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          if ((a['description'] ?? '').toString().isNotEmpty) Text('${a['description']}'),
          const SizedBox(height: 8),
          Text('Location: ${switch (a['placement']) { 'inside' => 'inside the work area', 'outside' => 'outside the work area', 'uncertain' => 'at the boundary edge', _ => 'no boundary to compare' }}'
              '${a['accuracy'] is num ? ' (±${(a['accuracy'] as num).round()} m)' : ''}'),
          Text('Status: ${s.t('st_${a['status']}')}', style: TextStyle(color: statusColor(a['status'] as String?), fontWeight: FontWeight.w600)),
          if ((a['reviewNote'] ?? '').toString().isNotEmpty) Text('Note: ${a['reviewNote']}'),
          const SizedBox(height: 16),
          if (_canReview && !mine && a['synthetic'] != true) ...[
            FilledButton.icon(onPressed: () => _decide(a, 'approved'), icon: const Icon(Icons.check), label: const Text('Approve')),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => _decide(a, 'rework'), icon: const Icon(Icons.replay), label: const Text('Ask to redo')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () => _decide(a, 'rejected'),
              icon: const Icon(Icons.close),
              label: const Text('Reject'),
            ),
          ],
          if (a['synthetic'] == true) const Text('Demo records cannot be reviewed.', style: TextStyle(color: AppColors.muted)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final all = snap.data;
        final shown = (all ?? const <Map<String, dynamic>>[]).where((a) => _filter == 'all' || a['status'] == _filter).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          _dayBar(context, _day, (d) => setState(() {
                _day = d;
                _stream = repo.watchActivities(dayKey(d));
              })),
          Wrap(spacing: 8, children: [
            for (final f in const ['all', 'submitted', 'approved', 'rework', 'rejected'])
              ChoiceChip(
                label: Text(f == 'all' ? s.t('filterAll') : s.t('st_$f')),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
          ]),
          const SizedBox(height: 10),
          if (snap.hasError)
            Text('${snap.error}', style: const TextStyle(color: AppColors.danger))
          else if (all == null)
            const LinearProgressIndicator()
          else if (shown.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Text('No field reports for this day in your area.', textAlign: TextAlign.center))
          else
            Card(
              child: Column(children: [
                for (final a in shown)
                  ListTile(
                    onTap: () => _open(a),
                    leading: (a['photoCount'] as num? ?? 0) > 0
                        ? ActivityPhoto(repo: repo, activityId: a['id'] as String, size: 52)
                        : const CircleAvatar(child: Icon(Icons.photo_outlined)),
                    title: Text('${a['title']}'),
                    subtitle: Text('${a['workerName'] ?? ''} · ${shortDateTime(a['createdAt'])} · ${s.t('st_${a['status']}')}'),
                    trailing: Icon(Icons.circle, size: 12, color: statusColor(a['status'] as String?)),
                  ),
              ]),
            ),
        ]);
      },
    );
  }
}

// ----------------------------------------------------------------- tasks
class OfficerTasksScreen extends StatefulWidget {
  const OfficerTasksScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<OfficerTasksScreen> createState() => _OfficerTasksScreenState();
}

class _OfficerTasksScreenState extends State<OfficerTasksScreen> {
  late final repo = WorkRepository(widget.session);
  late final _stream = repo.watchTasks();
  String _filter = 'open';

  bool get _canCreate => widget.session.policy.can(widget.session.role!, Capability.createTasks);
  bool get _canReview => widget.session.policy.can(widget.session.role!, Capability.reviewActivities);

  Future<void> _create() async {
    final areas = await repo.areasInScope();
    if (!mounted) return;
    if (areas.isEmpty) {
      showToast('No areas in your scope yet. Ask the administrator to assign your area.', kind: ToastKind.error);
      return;
    }
    final title = TextEditingController();
    final details = TextEditingController();
    var area = areas.first;
    var priority = 'normal';
    var due = DateTime.now().add(const Duration(days: 1));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('New task'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Task (for example: Clean Street 4)')),
              const SizedBox(height: 10),
              TextField(controller: details, maxLines: 3, decoration: const InputDecoration(labelText: 'Instructions')),
              const SizedBox(height: 10),
              DropdownButtonFormField<Map<String, dynamic>>(
                value: area,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Street / area (all workers there see it)'),
                items: [
                  for (final a in areas)
                    DropdownMenuItem(
                      value: a,
                      child: Padding(
                        padding: EdgeInsets.only(left: 10.0 * (((a['path'] as List?)?.length ?? 1) - 1)),
                        child: Text('${a['name']} (${a['level']})', overflow: TextOverflow.ellipsis),
                      ),
                    ),
                ],
                onChanged: (v) => set(() => area = v ?? area),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: priority,
                decoration: const InputDecoration(labelText: 'Priority'),
                items: const [
                  DropdownMenuItem(value: 'low', child: Text('Low')),
                  DropdownMenuItem(value: 'normal', child: Text('Normal')),
                  DropdownMenuItem(value: 'high', child: Text('High')),
                ],
                onChanged: (v) => set(() => priority = v ?? priority),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Due ${dayKey(due)}'),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final d = await showDatePicker(context: c, initialDate: due, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) set(() => due = d);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Assign')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (title.text.trim().isEmpty) {
      showToast('Write what needs to be done.', kind: ToastKind.error);
      return;
    }
    try {
      await repo.createTask(title: title.text, description: details.text, area: area, priority: priority, dueDate: dayKey(due));
      showToast('Task assigned to ${area['name']}.', kind: ToastKind.success);
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    }
  }

  Future<void> _act(Map<String, dynamic> t, String status) async {
    String? note;
    if (status == 'rework' || status == 'cancelled') {
      note = await askReason(context, status == 'rework' ? 'Ask for the work to be redone' : 'Cancel this task');
      if (note == null) return;
    }
    try {
      await repo.setTaskStatus(t['id'] as String, status, note: note ?? (status == 'approved' ? '' : null));
      showToast('Task updated.', kind: ToastKind.success);
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final today = dayKey(DateTime.now());
    return Scaffold(
      floatingActionButton: _canCreate
          ? FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_task), label: const Text('New task'))
          : null,
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return MessageView(icon: Icons.cloud_off_outlined, title: s.t('errorTitle'), body: '${snap.error}');
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          bool keep(Map<String, dynamic> t) => switch (_filter) {
                'open' => ['assigned', 'in_progress', 'rework'].contains(t['status']),
                'review' => t['status'] == 'submitted',
                _ => ['approved', 'cancelled'].contains(t['status']),
              };
          final shown = all.where(keep).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
            Wrap(spacing: 8, children: [
              for (final f in const [('open', 'Open'), ('review', 'Waiting for review'), ('done', 'Done / cancelled')])
                ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
            ]),
            const SizedBox(height: 10),
            if (shown.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('No tasks here.', textAlign: TextAlign.center)),
            for (final t in shown)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('${t['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                      Text(s.t('ts_${t['status']}'), style: TextStyle(color: statusColor(t['status'] as String?), fontWeight: FontWeight.w600)),
                    ]),
                    if ((t['description'] ?? '').toString().isNotEmpty) Text('${t['description']}'),
                    const SizedBox(height: 4),
                    Text(
                      'Due ${t['dueDate']}${(t['dueDate'] as String? ?? '').compareTo(today) < 0 && keep(t) && _filter == 'open' ? ' · OVERDUE' : ''}'
                      ' · ${s.t('pr_${t['priority'] ?? 'normal'}')} · by ${t['createdByName'] ?? ''}'
                      '${t['synthetic'] == true ? ' · demo' : ''}',
                      style: const TextStyle(color: AppColors.muted, fontSize: 13),
                    ),
                    if (_canReview && t['synthetic'] != true) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        if (t['status'] == 'submitted') FilledButton(onPressed: () => _act(t, 'approved'), child: const Text('Approve')),
                        if (t['status'] == 'submitted') OutlinedButton(onPressed: () => _act(t, 'rework'), child: const Text('Ask to redo')),
                        if (!['approved', 'cancelled'].contains(t['status']))
                          TextButton(onPressed: () => _act(t, 'cancelled'), child: const Text('Cancel task')),
                      ]),
                    ],
                  ]),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- alerts
/// Things needing attention, worked out from the officer's own scope.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late final today = dayKey(DateTime.now());
  late final _attendance = OfficerAttendance(widget.session).watch(today);
  late final _activities = WorkRepository(widget.session).watchActivities(today);
  late final _tasks = WorkRepository(widget.session).watchTasks();

  Widget _section(String title, IconData icon, Color color, List<String> lines) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text('$title (${lines.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
            ]),
            const SizedBox(height: 6),
            if (lines.isEmpty) const Text('Nothing right now.', style: TextStyle(color: AppColors.muted)),
            for (final l in lines.take(20)) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $l')),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _attendance,
      builder: (context, att) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _activities,
        builder: (context, act) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: _tasks,
          builder: (context, tasks) {
            final err = att.error ?? act.error ?? tasks.error;
            if (err != null) return MessageView(icon: Icons.cloud_off_outlined, title: s.t('errorTitle'), body: '$err');
            if (!att.hasData || !act.hasData || !tasks.hasData) return const Center(child: CircularProgressIndicator());
            final flagged = [
              for (final r in att.data!)
                if ((r['checkIn'] as Map?)?['status'] == 'flagged')
                  '${r['workerName'] ?? 'Unnamed worker'}: ${(((r['checkIn'] as Map)['reasons'] as List?) ?? const []).map((x) => s.t('reason_$x')).join(' ')}',
            ];
            final waiting = [
              for (final a in act.data!)
                if (a['status'] == 'submitted') '${a['workerName'] ?? ''}: ${a['title']} (${shortDateTime(a['createdAt'])})',
            ];
            final overdue = [
              for (final t in tasks.data!)
                if (['assigned', 'in_progress', 'rework'].contains(t['status']) && (t['dueDate'] as String? ?? '9999').compareTo(today) < 0)
                  '${t['title']}: due ${t['dueDate']}',
            ];
            return ListView(padding: const EdgeInsets.all(16), children: [
              _section('Attendance to check today', Icons.flag_outlined, AppColors.turmeric, flagged),
              _section('Field reports waiting for review', Icons.photo_library_outlined, AppColors.indigo, waiting),
              _section('Overdue tasks', Icons.schedule, AppColors.danger, overdue),
            ]);
          },
        ),
      ),
    );
  }
}
