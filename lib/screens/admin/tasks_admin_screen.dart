import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../../core/fmt.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../worker/my_tasks_screen.dart';

class TasksAdminScreen extends StatefulWidget {
  final AppUser me;
  const TasksAdminScreen({super.key, required this.me});
  @override
  State<TasksAdminScreen> createState() => _TasksAdminScreenState();
}

class _TasksAdminScreenState extends State<TasksAdminScreen> {
  // The floating button shrinks to an icon while scrolling down, so it
  // does not hide list content, and expands again when scrolling up.
  bool _fabExtended = true;

  bool _onScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final extended = n.direction != ScrollDirection.reverse;
    if (extended != _fabExtended) setState(() => _fabExtended = extended);
    return false;
  }

  String _filter = 'all';
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Task management')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newTask',
              isExtended: _fabExtended,
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TaskFormScreen(me: widget.me))),
        icon: const Icon(Icons.add_task),
        label: const Text('New task'),
      ),
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: LiveQueries(
        queries: [Db.col('tasks')],
        builder: (context, d) {
          final all = d[0];
          final q = _q.toLowerCase();
          final list = all
              .where((t) => taskMatches(t, _filter))
              .where((t) => q.isEmpty || '${t['title']} ${t['assignedName']}'.toLowerCase().contains(q))
              .toList()
            ..sort(taskSort);
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search task or worker'),
              ),
            ),
            TaskFilterBar(value: _filter, onChanged: (v) => setState(() => _filter = v), tasks: all),
            Expanded(
              child: list.isEmpty
                  ? const EmptyView(icon: Icons.assignment_outlined, title: 'No tasks', subtitle: 'Create a task and assign it to a field worker.')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                      itemCount: list.length,
                      itemBuilder: (_, i) => TaskTile(t: list[i], me: widget.me, showAssignee: true),
                    ),
            ),
          ]);
        },
      ),
      ),
    );
  }
}

class TaskFormScreen extends StatefulWidget {
  final AppUser me;
  const TaskFormScreen({super.key, required this.me});
  @override
  State<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends State<TaskFormScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  String? _worker;
  String _priority = 'medium';
  DateTime _due = DateTime.now().add(const Duration(days: 2));
  bool _busy = false;

  Future<void> _save(List<Doc> workers) async {
    if (!_form.currentState!.validate()) return;
    if (_worker == null) {
      showSnack(context, 'Select a worker.', error: true);
      return;
    }
    setState(() => _busy = true);
    final w = workers.firstWhere((e) => e['id'] == _worker);
    try {
      final r = await Db.col('tasks').add({
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'assignedTo': _worker,
        'assignedName': w['name'],
        'boundaryId': w['boundaryId'],
        'priority': _priority,
        'status': 'assigned',
        'dueDate': Timestamp.fromDate(DateTime(_due.year, _due.month, _due.day, 18)),
        'createdBy': widget.me.uid,
        'createdByName': widget.me.name,
        'synthetic': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await Db.audit('task_created', 'tasks/${r.id}', {'assignedTo': _worker});
      if (mounted) {
        showSnack(context, 'Task assigned to ${w['name']}.', success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create task')),
      body: LiveQueries(
        queries: [Db.col('users').where('role', isEqualTo: Roles.worker)],
        builder: (context, d) {
          final workers = d[0].where((w) => (w['status'] ?? 'active') == 'active').toList()
            ..sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Task title'),
                validator: (v) => (v ?? '').trim().length < 4 ? 'Enter a task title' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _desc, maxLines: 4, decoration: const InputDecoration(labelText: 'Instructions', alignLabelWithHint: true)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _worker,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assign to worker'),
                items: workers
                    .map((w) => DropdownMenuItem(
                          value: w['id'] as String,
                          child: Text('${w['name']}${(w['employeeId'] ?? '').toString().isEmpty ? '' : ' · ${w['employeeId']}'}${w['synthetic'] == true ? ' (DEMO)' : ''}',
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _worker = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _priority,
                decoration: const InputDecoration(labelText: 'Priority'),
                items: const ['low', 'medium', 'high'].map((p) => DropdownMenuItem(value: p, child: Text(p[0].toUpperCase() + p.substring(1)))).toList(),
                onChanged: (v) => setState(() => _priority = v!),
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFD5DCE6))),
                tileColor: Colors.white,
                leading: const Icon(Icons.event),
                title: const Text('Due date'),
                subtitle: Text(fmtDate(_due)),
                onTap: () async {
                  final d = await showDatePicker(context: context, initialDate: _due, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) setState(() => _due = d);
                },
              ),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: _busy ? null : () => _save(workers), icon: const Icon(Icons.send), label: const Text('Assign task')),
            ]),
          );
        },
      ),
    );
  }
}
