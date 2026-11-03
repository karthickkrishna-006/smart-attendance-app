import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../worker/my_tasks_screen.dart';
import 'activity_form.dart';
import 'activity_tile.dart';

class TaskDetailScreen extends StatelessWidget {
  final String taskId;
  final AppUser me;
  const TaskDetailScreen({super.key, required this.taskId, required this.me});

  Future<void> _setStatus(BuildContext context, Doc t, String s) async {
    try {
      await Db.col('tasks').doc(taskId).update({'status': s, 'updatedAt': Timestamp.now()});
      await Db.audit('task_status', 'tasks/$taskId', {'to': s});
      if (context.mounted) showSnack(context, 'Task marked ${titleCase(s)}.', success: true);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: Db.col('tasks').doc(taskId).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Scaffold(appBar: AppBar(), body: ErrorView(message: friendlyError(snap.error!)));
        if (!snap.hasData) return Scaffold(appBar: AppBar(), body: const LoadingView());
        if (!snap.data!.exists) return Scaffold(appBar: AppBar(), body: const EmptyView(icon: Icons.delete_outline, title: 'Task was deleted'));
        final t = {...snap.data!.data()!, 'id': taskId};
        final mine = t['assignedTo'] == me.uid;
        final st = t['status'] as String? ?? 'assigned';
        return Scaffold(
          appBar: AppBar(title: const Text('Task details')),
          floatingActionButton: mine && st != 'completed'
              ? FloatingActionButton.extended(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivityForm(me: me, task: t))),
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Submit activity'),
                )
              : null,
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(t['title'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                    StatusChip(effectiveStatus(t)),
                  ]),
                  if (t['synthetic'] == true) const Padding(padding: EdgeInsets.only(top: 6), child: DemoBadge()),
                  const SizedBox(height: 10),
                  Text(t['description'] ?? '', style: const TextStyle(height: 1.4)),
                  const Divider(height: 24),
                  InfoRow(Icons.person_outline, 'Assigned to', t['assignedName'] ?? '—'),
                  InfoRow(Icons.event, 'Due date', fmtDate(t['dueDate']), color: isOverdue(t) ? AppColors.danger : null),
                  InfoRow(Icons.flag_outlined, 'Priority', titleCase(t['priority'] ?? 'medium')),
                  InfoRow(Icons.update, 'Updated', fmtDateTime(t['updatedAt'] ?? t['createdAt'])),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            if (mine && st == 'assigned')
              OutlinedButton.icon(onPressed: () => _setStatus(context, t, 'in_progress'), icon: const Icon(Icons.play_arrow), label: const Text('Start task')),
            if (me.isStaff)
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (st != 'completed')
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.success),
                    onPressed: () => _setStatus(context, t, 'completed'),
                    icon: const Icon(Icons.task_alt),
                    label: const Text('Mark completed'),
                  ),
                if (st == 'submitted' || st == 'completed')
                  OutlinedButton.icon(onPressed: () => _setStatus(context, t, 'in_progress'), icon: const Icon(Icons.undo), label: const Text('Send back')),
              ]),
            const SectionTitle('Field activity submissions'),
            LiveQueries(
              queries: [
                me.canViewAll
                    ? Db.col('activities').where('taskId', isEqualTo: taskId)
                    : Db.col('activities').where('uid', isEqualTo: me.uid),
              ],
              builder: (context, d) {
                final acts = d[0].where((a) => a['taskId'] == taskId).toList()
                  ..sort((a, b) => (toDate(b['createdAt']) ?? DateTime(0)).compareTo(toDate(a['createdAt']) ?? DateTime(0)));
                if (acts.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No activity submitted yet.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
                  );
                }
                return Column(children: acts.map((a) => ActivityTile(a: a, me: me)).toList());
              },
            ),
            const SizedBox(height: 80),
          ]),
        );
      },
    );
  }
}

Widget evidenceImage(String b64, {double size = 90}) {
  try {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.memory(base64Decode(b64), width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
    );
  } catch (_) {
    return SizedBox(width: size, height: size, child: const Icon(Icons.broken_image));
  }
}
