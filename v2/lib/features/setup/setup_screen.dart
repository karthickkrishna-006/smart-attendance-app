import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../data/session_controller.dart';
import '../../domain/area.dart';
import '../../domain/roles.dart';
import '../../domain/designations.dart';
import 'demo_tab.dart';
import 'district_admin.dart';
import 'geofences_tab.dart';
import 'scope_picker.dart';

/// System administrator setup: the area tree, organisations, who holds which
/// role, and the switches. Every change is written with its audit entry.
/// (Administrator screens are English-only in this build.)
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final dir = Directory(session.user!);
    return DefaultTabController(
      length: 7,
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
    showToast('Not saved: $e', kind: ToastKind.error);
  }
}

// ---------------------------------------------------------------- areas
class _AreasTab extends StatelessWidget {
  const _AreasTab({required this.dir});
  final Directory dir;

  Future<void> _add(BuildContext context, List<AreaNode> all) async {
    final name = TextEditingController();
    var level = all.any((a) => a.level == AreaLevel.district) ? AreaLevel.block : AreaLevel.district;
    AreaNode? parent;
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
            body: all.isEmpty
                ? const MessageView(
                    icon: Icons.account_tree_outlined,
                    title: 'No areas yet',
                    body: 'Start with the district, then add its blocks, zones and panchayats. Use official names only.',
                  )
                : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
                    for (final a in all)
                      ListTile(
                        contentPadding: EdgeInsets.only(left: 12.0 + 20.0 * (a.path.length - 1), right: 12),
                        leading: Icon(a.level == AreaLevel.district ? Icons.public : Icons.subdirectory_arrow_right, color: AppColors.green),
                        title: Text(a.name),
                        subtitle: Text('${a.level.key}${a.provisional ? ' · provisional' : ''}'),
                      ),
                  ]),
          );
        },
      );
}

// --------------------------------------------------------- organisations
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
              body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
                for (final a in list)
                  ListTile(
                    title: Text(names[a['uid']] ?? '${a['uid']}'),
                    subtitle: Text(
                      '${Designation.fromKey(a['designation'] as String?)?.title ?? Role.fromKey(a['role'] as String?)?.defaultTitle ?? a['role']} · '
                      '${((a['areaIds'] as List?) ?? const []).length} area(s) · tap to edit',
                    ),
                    onTap: () => _editScope(context, a),
                    trailing: Switch(
                      value: a['active'] == true,
                      onChanged: (v) => runWrite(() => dir.setRoleActive(a['id'] as String, v), done: v ? 'Role switched on.' : 'Role switched off.'),
                    ),
                  ),
              ]),
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
          Future<void> save({bool? o, bool? s, bool? k}) => runWrite(
                () => dir.saveConfig(openWorkerSignUp: o ?? open, supervisorsMayCreateTasks: s ?? sup, collectorMayAssignTasks: k ?? col),
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
