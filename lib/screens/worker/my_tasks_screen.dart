import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../common/task_detail_screen.dart';

class MyTasksScreen extends StatefulWidget {
  final AppUser me;
  const MyTasksScreen({super.key, required this.me});
  @override
  State<MyTasksScreen> createState() => _MyTasksScreenState();
}

class _MyTasksScreenState extends State<MyTasksScreen> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My tasks')),
      body: LiveQueries(
        queries: [Db.col('tasks').where('assignedTo', isEqualTo: widget.me.uid)],
        builder: (context, d) {
          final all = d[0];
          final list = all.where((t) => taskMatches(t, _filter)).toList()..sort(taskSort);
          return Column(children: [
            TaskFilterBar(value: _filter, onChanged: (v) => setState(() => _filter = v), tasks: all),
            Expanded(
              child: list.isEmpty
                  ? const EmptyView(icon: Icons.assignment_turned_in_outlined, title: 'No tasks here', subtitle: 'Tasks assigned by your supervisor appear here.')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: list.length,
                      itemBuilder: (_, i) => TaskTile(t: list[i], me: widget.me),
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

bool isOverdue(Doc t) {
  final due = toDate(t['dueDate']);
  return due != null && due.isBefore(DateTime.now()) && t['status'] != 'completed';
}

String effectiveStatus(Doc t) => isOverdue(t) ? 'overdue' : (t['status'] as String? ?? 'assigned');

bool taskMatches(Doc t, String f) {
  if (f == 'all') return true;
  if (f == 'overdue') return isOverdue(t);
  if (f == 'pending') return t['status'] == 'assigned' || t['status'] == 'in_progress';
  return t['status'] == f;
}

int taskSort(Doc a, Doc b) {
  final da = toDate(a['dueDate']) ?? DateTime(2100);
  final db = toDate(b['dueDate']) ?? DateTime(2100);
  final ca = a['status'] == 'completed' ? 1 : 0;
  final cb = b['status'] == 'completed' ? 1 : 0;
  if (ca != cb) return ca - cb;
  return da.compareTo(db);
}

class TaskFilterBar extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final List<Doc> tasks;
  const TaskFilterBar({super.key, required this.value, required this.onChanged, required this.tasks});
  @override
  Widget build(BuildContext context) {
    const filters = ['all', 'pending', 'submitted', 'completed', 'overdue'];
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        children: filters
            .map((f) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${titleCase(f)} (${tasks.where((t) => taskMatches(t, f)).length})'),
                    selected: value == f,
                    onSelected: (_) => onChanged(f),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class TaskTile extends StatelessWidget {
  final Doc t;
  final AppUser me;
  final bool showAssignee;
  const TaskTile({super.key, required this.t, required this.me, this.showAssignee = false});
  @override
  Widget build(BuildContext context) {
    final st = effectiveStatus(t);
    final pr = t['priority'] as String? ?? 'medium';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: t['id'], me: me))),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 4, height: 36, decoration: BoxDecoration(color: statusColor(pr == 'medium' ? 'medium' : (pr == 'high' ? 'high' : 'low')), borderRadius: BorderRadius.circular(4))),
                const SizedBox(width: 10),
                Expanded(child: Text(t['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                StatusChip(st),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.event, size: 15, color: AppColors.muted),
                  const SizedBox(width: 4),
                  Text('Due ${fmtDate(t['dueDate'])}', style: TextStyle(fontSize: 12.5, color: st == 'overdue' ? AppColors.danger : AppColors.muted)),
                ]),
                Text('${titleCase(pr)} priority', style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
                if (showAssignee)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.person_outline, size: 15, color: AppColors.muted),
                    const SizedBox(width: 3),
                    Text(t['assignedName'] ?? '—', style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
                  ]),
                if (t['synthetic'] == true) const DemoBadge(),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
