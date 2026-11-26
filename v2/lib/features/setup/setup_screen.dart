import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../data/session_controller.dart';
import '../../domain/area.dart';
import '../../domain/roles.dart';
import '../../domain/designations.dart';
import 'demo_tab.dart';
import 'lgd_import_card.dart';
import 'district_admin.dart';
import 'geofences_tab.dart';
import 'scope_picker.dart';

/// System administrator setup: the area tree, organisations, who holds which
/// role, and the switches. Every change is written with its audit entry.
/// (Administrator screens are English-only in this build.)
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.session, this.initialTab = 0});
  final int initialTab;
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final dir = Directory(session.user!);
    return DefaultTabController(
      length: 7,
      initialIndex: initialTab.clamp(0, 6),
      child: Column(children: [
        const TabBar(isScrollable: true, tabs: [
          Tab(text: 'Areas'),
          Tab(text: 'Boundaries'),
          Tab(text: 'Organisations'),
          Tab(text: 'Access'),
          Tab(text: 'Settings'),
          Tab(text: 'Messages'),
          Tab(text: 'Demo'),
        ]),
        Expanded(
          child: TabBarView(children: [
            _AreasTab(dir: dir),
            GeofencesTab(dir: dir),
            _OrganisationsTab(dir: dir),
            _AccessTab(dir: dir),
            _SettingsTab(dir: dir),
            MessagesAdminTab(session: session),
            DemoTab(session: session),
          ]),
        ),
      ]),
    );
  }
}

/// Runs a write and reports the real outcome.
Future<void> runWrite(Future<void> Function() write, {required String done}) async {
  try {
    await write();
    showToast(done, kind: ToastKind.success);
  } catch (e) {
    final refused = '$e'.contains('permission-denied');
    showToast(
      refused
          ? 'Not saved: Firebase refused it. Usually the Firestore rules in Firebase are older than this app: '
              'publish v2/firestore.rules from GitHub (Firestore → Rules → Publish) and try again.'
          : 'Not saved: $e',
      kind: ToastKind.error,
    );
  }
}

// ---------------------------------------------------------------- areas
class _AreasTab extends StatelessWidget {
  const _AreasTab({required this.dir});
  final Directory dir;

  Future<void> _add(BuildContext context, List<AreaNode> all, {AreaNode? under}) async {
    final name = TextEditingController();
    var level = under != null
        ? AreaLevel.values[(under.level.index + 1).clamp(0, AreaLevel.values.length - 1)]
        : (all.any((a) => a.level == AreaLevel.district) ? AreaLevel.block : AreaLevel.district);
    AreaNode? parent = under;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        // Any higher level can be the parent: a habitation under a village
        // panchayat, a panchayat under a zone or directly under a block.
        final parents = level == AreaLevel.district ? <AreaNode>[] : all.where((a) => a.level.index < level.index).toList();
        if (parent != null && !parents.contains(parent)) parent = null;
        return AlertDialog(
          title: const Text('Add area'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<AreaLevel>(
              value: level,
              decoration: const InputDecoration(labelText: 'Level'),
              items: [for (final l in AreaLevel.values) DropdownMenuItem(value: l, child: Text(l.key))],
              onChanged: (v) => set(() => level = v ?? level),
            ),
            const SizedBox(height: 12),
            if (level != AreaLevel.district)
              DropdownButtonFormField<AreaNode>(
                value: parent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Inside which area?'),
                items: [for (final p in parents) DropdownMenuItem(value: p, child: Text('${p.name} (${p.level.key})'))],
                onChanged: (v) => set(() => parent = v),
              ),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            const Text('Marked provisional until official GIS boundaries are imported.', style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Add area'),
            ),
          ],
        );
      }),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty || (level != AreaLevel.district && parent == null)) {
      showToast('Enter a name and choose where the area belongs.', kind: ToastKind.error);
      return;
    }
    await runWrite(() => dir.addArea(name: name.text, level: level, parent: parent), done: 'Area added.');
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<AreaNode>>(
        stream: dir.areas(),
        builder: (context, snap) {
          if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load areas', body: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!;
          return Scaffold(
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _add(context, all),
              icon: const Icon(Icons.add),
              label: const Text('Add area'),
            ),
            body: _AreaTree(all: all, dir: dir, onAdd: (under) => _add(context, all, under: under)),
          );
        },
      );
}

/// Areas as a folding tree (district → blocks → panchayats → habitations →
/// streets) with search, so 1000+ official areas stay easy to work with.
class _AreaTree extends StatefulWidget {
  const _AreaTree({required this.all, required this.dir, required this.onAdd});
  final List<AreaNode> all;
  final Directory dir;
  final void Function(AreaNode under) onAdd;
  @override
  State<_AreaTree> createState() => _AreaTreeState();
}

class _AreaTreeState extends State<_AreaTree> {
  final _q = TextEditingController();
  final _open = <String>{};

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.all;
    final byId = {for (final a in all) a.id: a};
    final kids = <String?, List<AreaNode>>{};
    for (final a in all) {
      kids.putIfAbsent(a.parentId, () => []).add(a);
    }
    for (final l in kids.values) {
      l.sort((a, b) => a.name.compareTo(b.name));
    }
    int below(AreaNode a) => (kids[a.id] ?? const []).fold(0, (n, k) => n + 1 + below(k));
    final q = _q.text.trim().toLowerCase();
    final loaded = all.length >= 1000;

    Widget node(AreaNode a, int depth) {
      final children = kids[a.id] ?? const <AreaNode>[];
      final open = _open.contains(a.id);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: children.isEmpty ? null : () => setState(() => open ? _open.remove(a.id) : _open.add(a.id)),
          child: Padding(
            padding: EdgeInsets.fromLTRB(8.0 + depth * 18, 6, 4, 6),
            child: Row(children: [
              Icon(children.isEmpty ? Icons.circle : (open ? Icons.expand_more : Icons.chevron_right),
                  size: children.isEmpty ? 8 : 22, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.name, style: TextStyle(fontWeight: depth < 2 ? FontWeight.w700 : FontWeight.w500)),
                  Text('${a.level.key}${children.isEmpty ? '' : ' · ${children.length} inside'}',
                      style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                ]),
              ),
              if (a.level != AreaLevel.location)
                IconButton(tooltip: 'Add an area inside', icon: const Icon(Icons.add_circle_outline, size: 20), onPressed: () => widget.onAdd(a)),
            ]),
          ),
        ),
        if (open) for (final c in children) node(c, depth + 1),
      ]);
    }

    final roots = kids[null] ?? const <AreaNode>[];
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
      if (!loaded)
        LgdImportCard(dir: widget.dir)
      else
        Card(
          color: const Color(0xFFE8F1EC),
          child: ListTile(
            leading: const Icon(Icons.check_circle, color: AppColors.success),
            title: const Text('Official Chengalpattu areas loaded'),
            subtitle: Text('${all.length} areas · tap a block to open it'),
            trailing: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => Padding(padding: const EdgeInsets.all(16), child: LgdImportCard(dir: widget.dir)),
              ),
              child: const Text('Reload'),
            ),
          ),
        ),
      const SizedBox(height: 8),
      TextField(
        controller: _q,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search a block, panchayat, habitation or street', isDense: true),
      ),
      const SizedBox(height: 8),
      if (all.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No areas yet. Load the official areas above, or add them one by one with "Add area".', style: TextStyle(color: AppColors.muted)),
        )
      else if (q.isNotEmpty)
        // Search: matches with their full path.
        for (final a in all.where((a) => a.name.toLowerCase().contains(q)).take(80))
          ListTile(
            dense: true,
            title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${a.level.key} · ${[for (final id in a.path.take(a.path.length - 1)) byId[id]?.name ?? ''].where((x) => x.isNotEmpty).join(' › ')}'),
            trailing: a.level == AreaLevel.location
                ? null
                : IconButton(tooltip: 'Add an area inside', icon: const Icon(Icons.add_circle_outline, size: 20), onPressed: () => widget.onAdd(a)),
          )
      else
        for (final r in roots) ...[
          node(r, 0),
          if (roots.length == 1 && !_open.contains(r.id))
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 2),
              child: Text('${below(r)} areas inside · tap to open', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            ),
        ],
    ]);
  }
}

class _OrganisationsTab extends StatelessWidget {
  const _OrganisationsTab({required this.dir});
  final Directory dir;

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController();
    var thirdParty = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Add organisation'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Third-party firm'),
              subtitle: const Text('Off for the government department itself'),
              value: thirdParty,
              onChanged: (v) => set(() => thirdParty = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await runWrite(() => dir.addOrganisation(name: name.text, thirdParty: thirdParty), done: 'Organisation added.');
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: dir.organisations(),
        builder: (context, snap) {
          if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load organisations', body: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final orgs = snap.data!;
          return Scaffold(
            floatingActionButton: FloatingActionButton.extended(onPressed: () => _add(context), icon: const Icon(Icons.add), label: const Text('Add organisation')),
            body: orgs.isEmpty
                ? const MessageView(icon: Icons.apartment_outlined, title: 'No organisations yet', body: 'Add the department and each third-party firm.')
                : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
                    for (final o in orgs)
                      ListTile(
                        leading: const Icon(Icons.apartment_outlined, color: AppColors.indigo),
                        title: Text('${o['name']}'),
                        subtitle: Text(o['type'] == 'third_party' ? 'Third-party firm' : 'Department'),
                      ),
                  ]),
          );
        },
      );
}

// ---------------------------------------------------------------- access
class _AccessTab extends StatelessWidget {
  const _AccessTab({required this.dir});
  final Directory dir;

  Future<void> _grant(BuildContext context) async {
    final email = TextEditingController();
    var role = Role.supervisor;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Give a role to an existing account'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Their sign-in email')),
            const SizedBox(height: 12),
            DropdownButtonFormField<Role>(
              value: role,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Role'),
              items: [for (final r in Role.values) DropdownMenuItem(value: r, child: Text(r.defaultTitle))],
              onChanged: (v) => set(() => role = v ?? role),
            ),
            const SizedBox(height: 8),
            const Text('Set its areas afterwards by tapping the role in this list. People who have never signed in are added under Employees.',
                style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Give role')),
          ],
        ),
      ),
    );
    if (ok != true || email.text.trim().isEmpty) return;
    try {
      final found = await dir.grantRole(email: email.text, role: role, areaIds: const []);
      showToast(found ? 'Role given.' : 'No account with that email has signed in yet. Add them under Employees instead.',
          kind: found ? ToastKind.success : ToastKind.error);
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    }
  }

  Future<void> _editScope(BuildContext context, Map<String, dynamic> a) async {
    final picked = await pickScope(
      context,
      dir,
      title: 'Areas and organisation',
      areaIds: ((a['areaIds'] as List?) ?? const []).whereType<String>().toList(),
      orgId: a['orgId'] as String?,
    );
    if (picked == null) return;
    if (!context.mounted) return;
    final designation = await pickDesignation(context,
        current: Designation.fromKey(a['designation'] as String?), forRole: Role.fromKey(a['role'] as String?));
    final keep = a['designation'] as String?;
    await runWrite(
      () => dir.updateRoleScope(a['id'] as String,
          areaIds: picked.areaIds, orgId: picked.orgId, designation: designation.ok ? designation.value?.key : keep),
      done: 'Role updated.',
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, String>>(
        stream: dir.accountEmails(),
        builder: (context, emails) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: dir.roleAssignments(),
          builder: (context, snap) {
            if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load roles', body: '${snap.error}');
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            final names = emails.data ?? const <String, String>{};
            return Scaffold(
              floatingActionButton: FloatingActionButton.extended(onPressed: () => _grant(context), icon: const Icon(Icons.add_moderator_outlined), label: const Text('Give role')),
              body: SearchableList<Map<String, dynamic>>(
                items: list,
                textOf: (a) => '${names[a['uid']] ?? a['uid']} ${a['designation'] ?? ''} ${a['role'] ?? ''}',
                hint: 'Search name, email or staff type',
                itemBuilder: (context, a) =>

                  ListTile(
                    title: Text(names[a['uid']] ?? '${a['uid']}'),
                    subtitle: Text(
                      '${Designation.fromKey(a['designation'] as String?)?.title ?? Role.fromKey(a['role'] as String?)?.defaultTitle ?? a['role']} · '
                      '${((a['areaIds'] as List?) ?? const []).length} area(s) · tap to edit',
                    ),
                    onTap: () => _editScope(context, a),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (a['uid'] == dir.user.uid && a['role'] == 'sys_admin')
                        // Your own administrator role can never be switched
                        // off here, so the district is never left without one.
                        const Tooltip(
                          message: 'Your own administrator role cannot be switched off',
                          child: Padding(padding: EdgeInsets.all(12), child: Icon(Icons.lock_outline, color: AppColors.muted)),
                        )
                      else
                        Switch(
                          value: a['active'] == true,
                          onChanged: (v) async {
                            if (!v) {
                              final who = names[a['uid']] ?? 'this person';
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('Switch off this role?'),
                                  content: Text('$who will lose this role at once and cannot use what it allows until it is switched on again.'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Switch off')),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                            }
                            runWrite(() => dir.setRoleActive(a['id'] as String, v), done: v ? 'Role switched on.' : 'Role switched off.');
                          },
                        ),
                      if (a['uid'] != dir.user.uid)
                        IconButton(
                          tooltip: 'Delete role',
                          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Delete this role?'),
                                content: Text('${names[a['uid']] ?? a['uid']} loses the role '
                                    '"${Role.fromKey(a['role'] as String?)?.defaultTitle ?? a['role']}" immediately. '
                                    'Their past records are kept. This is recorded in the audit log.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                  FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: AppColors.danger, minimumSize: const Size(96, 44)),
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) await runWrite(() => dir.deleteRole(a), done: 'Role deleted.');
                          },
                        ),
                    ]),
                  ),
              ),
            );
          },
        ),
      );
}

// -------------------------------------------------------------- settings
class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.dir});
  final Directory dir;

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>>(
        stream: dir.config(),
        builder: (context, snap) {
          if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load settings', body: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final c = snap.data!;
          final open = c['openWorkerSignUp'] == true;
          final sup = c['supervisorsMayCreateTasks'] == true;
          final col = c['collectorMayAssignTasks'] == true;
          final zoneOnly = c['zonePhotoOnly'] == true;
          Future<void> save({bool? o, bool? s, bool? k, bool? z}) => runWrite(
                () => dir.saveConfig(
                  openWorkerSignUp: o ?? open,
                  supervisorsMayCreateTasks: s ?? sup,
                  collectorMayAssignTasks: k ?? col,
                  zonePhotoOnly: z ?? zoneOnly,
                ),
                done: 'Settings saved.',
              );
          return ListView(padding: const EdgeInsets.all(12), children: [
            Card(
              child: Column(children: [
                SwitchListTile(
                  title: const Text('Anyone can sign up as a field worker'),
                  subtitle: const Text('Off: only people added in advance can sign in. On: anyone with Google becomes a worker with no area until assigned.'),
                  value: open,
                  onChanged: (v) => save(o: v),
                ),
                SwitchListTile(
                  title: const Text('Supervisors may create and assign tasks'),
                  value: sup,
                  onChanged: (v) => save(s: v),
                ),
                SwitchListTile(
                  title: const Text('Camera only inside a cleaning zone'),
                  subtitle: const Text('On: field workers can take proof photos only while they are at one of their street\'s cleaning '
                      'zones, and each photo report becomes the proof for that zone. Off (demonstrations): the camera always works.'),
                  value: zoneOnly,
                  onChanged: (v) => save(z: v),
                ),
                SwitchListTile(
                  title: const Text('The Collector may create and assign tasks'),
                  subtitle: const Text('Off by default: the Collector monitors.'),
                  value: col,
                  onChanged: (v) => save(k: v),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('Role titles used in this district', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            StreamBuilder<Map<String, String>>(
              stream: dir.titles(),
              builder: (context, t) => Card(
                child: Column(children: [
                  for (final r in Role.values)
                    ListTile(
                      title: Text((t.data?[r.key]?.isNotEmpty ?? false) ? t.data![r.key]! : r.defaultTitle),
                      subtitle: Text(r.key),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final ctrl = TextEditingController(text: t.data?[r.key] ?? r.defaultTitle);
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text('Title for ${r.defaultTitle}'),
                            content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Title')),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                              FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
                            ],
                          ),
                        );
                        if (ok == true && ctrl.text.trim().isNotEmpty) await runWrite(() => dir.setTitle(r, ctrl.text), done: 'Title saved.');
                      },
                    ),
                ]),
              ),
            ),
          ]);
        },
      );
}


/// A search box over a long list that is built lazily, so thousands of staff
/// stay smooth.
class SearchableList<T> extends StatefulWidget {
  const SearchableList({super.key, required this.items, required this.textOf, required this.itemBuilder, this.hint = 'Search'});
  final List<T> items;
  final String Function(T) textOf;
  final Widget Function(BuildContext, T) itemBuilder;
  final String hint;

  @override
  State<SearchableList<T>> createState() => _SearchableListState<T>();
}

class _SearchableListState<T> extends State<SearchableList<T>> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toLowerCase();
    final shown = q.isEmpty ? widget.items : widget.items.where((x) => widget.textOf(x).toLowerCase().contains(q)).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          controller: _q,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: widget.hint, isDense: true),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('${shown.length} of ${widget.items.length}', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        ),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
          itemCount: shown.length,
          itemBuilder: (context, i) => widget.itemBuilder(context, shown[i]),
        ),
      ),
    ]);
  }
}
