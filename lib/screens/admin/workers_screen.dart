import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import 'worker_detail_screen.dart';
import 'worker_edit_screen.dart';

class WorkersScreen extends StatefulWidget {
  final AppUser me;
  const WorkersScreen({super.key, required this.me});
  @override
  State<WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends State<WorkersScreen> {
  String _q = '';
  String _role = 'all';
  String _status = 'all';

  @override
  Widget build(BuildContext context) {
    final today = dayKey(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('Workers & users')),
      floatingActionButton: widget.me.isAdmin
          ? FloatingActionButton.extended(
              heroTag: 'addWorker',
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => WorkerEditScreen(me: widget.me))),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Add worker'),
            )
          : null,
      body: LiveQueries(
        queries: [Db.col('users'), Db.col('attendance').where('date', isEqualTo: today), Db.col('boundaries')],
        builder: (context, d) {
          final att = {for (final a in d[1]) a['uid']: a};
          final bNames = {for (final b in d[2]) b['id']: b['name']};
          final q = _q.toLowerCase();
          final list = d[0].where((u) {
            if (_role != 'all' && (u['role'] ?? 'worker') != _role) return false;
            if (_status != 'all' && (u['status'] ?? 'active') != _status) return false;
            if (q.isEmpty) return true;
            return '${u['name']} ${u['email']} ${u['employeeId']} ${u['phone']}'.toLowerCase().contains(q);
          }).toList()
            ..sort((a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo((b['name'] ?? '').toString().toLowerCase()));
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name, employee ID, email, phone'),
              ),
            ),
            SizedBox(
              height: 52,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
                for (final r in ['all', ...Roles.all])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(r == 'all' ? 'All roles' : Roles.label(r)),
                      selected: _role == r,
                      onSelected: (_) => setState(() => _role = r),
                    ),
                  ),
                const VerticalDivider(),
                for (final s in ['all', 'pending_approval', 'active', 'inactive', 'suspended'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(label: Text(s == 'all' ? 'Any status' : titleCase(s)), selected: _status == s, onSelected: (_) => setState(() => _status = s)),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(children: [Text('${list.length} records', style: const TextStyle(color: AppColors.muted, fontSize: 12.5))]),
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyView(icon: Icons.person_search_outlined, title: 'No matching users')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 90),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final u = list[i];
                        final a = att[u['id']];
                        final role = u['role'] ?? 'worker';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            child: ListTile(
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => WorkerDetailScreen(uid: u['id'], me: widget.me))),
                              leading: AvatarCircle(name: u['name'] ?? ''),
                              title: Row(children: [
                                Flexible(child: Text(u['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                                if (u['synthetic'] == true) ...[const SizedBox(width: 6), const DemoBadge()],
                              ]),
                              subtitle: Text(
                                [
                                  Roles.label(role),
                                  if ((u['employeeId'] ?? '').toString().isNotEmpty) u['employeeId'],
                                  if (bNames[u['boundaryId']] != null) bNames[u['boundaryId']],
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: role == 'worker'
                                  ? StatusChip(a?['status'] ?? ((u['status'] ?? 'active') == 'active' ? 'absent' : u['status']),
                                      label: a == null ? ((u['status'] ?? 'active') == 'active' ? 'Not marked' : titleCase(u['status'])) : null)
                                  : StatusChip(u['status'] ?? 'active'),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
