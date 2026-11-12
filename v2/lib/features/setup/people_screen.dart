import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../data/session_controller.dart';
import '../../domain/designations.dart';
import '../../domain/roles.dart';
import 'scope_picker.dart';
import 'setup_screen.dart' show runWrite;

/// Add people in advance by their sign-in e-mail. When they first sign in they
/// get exactly this role and area at once: no approval step.
/// System administrators add anyone; organisation administrators add field
/// workers to their own organisation (the security rules enforce both).
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key, required this.session});
  final SessionController session;

  bool get _isOrgAdmin => session.role == Role.orgAdmin;
  String? get _myOrg => session.current?.orgId;

  Future<void> _add(BuildContext context, Directory dir) async {
    final email = TextEditingController();
    final name = TextEditingController();
    final employeeId = TextEditingController();
    var role = Role.worker;
    Designation? designation = _isOrgAdmin ? Designation.thoomaiKavalar : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Add a person'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Sign-in email (Gmail)')),
              const SizedBox(height: 12),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
              const SizedBox(height: 12),
              TextField(controller: employeeId, decoration: const InputDecoration(labelText: 'Employee ID (optional)')),
              const SizedBox(height: 12),
              // Staff type first: it presets the right role (still changeable).
              DropdownButtonFormField<Designation?>(
                value: designation,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Staff type'),
                items: [
                  if (!_isOrgAdmin) const DropdownMenuItem<Designation?>(value: null, child: Text('None / other')),
                  for (final d in Designation.values.where((d) => !_isOrgAdmin || d.role == Role.worker))
                    DropdownMenuItem<Designation?>(value: d, child: Text(d.title, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => set(() {
                  designation = v;
                  if (v != null && !_isOrgAdmin) role = v.role;
                }),
              ),
              const SizedBox(height: 12),
              if (!_isOrgAdmin)
                DropdownButtonFormField<Role>(
                  value: role,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: [for (final r in Role.values) DropdownMenuItem(value: r, child: Text(session.titleOf(r)))],
                  onChanged: (v) => set(() => role = v ?? role),
                )
              else
                const Align(alignment: Alignment.centerLeft, child: Text('Role: Field worker in your organisation')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Next: areas')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.text.trim())) {
      showToast('Enter a valid email address.', kind: ToastKind.error);
      return;
    }
    final scope = await pickScope(context, dir, title: 'Where will they work?', fixedOrgId: _isOrgAdmin ? _myOrg : null);
    if (scope == null) return;
    await runWrite(
      () => dir.addPreregistration(
        email: email.text,
        role: role,
        areaIds: scope.areaIds,
        name: name.text,
        employeeId: employeeId.text,
        orgId: scope.orgId,
        designation: designation?.key,
      ),
      done: '${email.text.trim()} can now sign in.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final dir = Directory(session.user!);
    if (_isOrgAdmin && _myOrg == null) {
      return const MessageView(
        icon: Icons.apartment_outlined,
        title: 'No organisation set for your role',
        body: 'Ask the System administrator to set your organisation.',
      );
    }
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: dir.preregistrations(orgId: _isOrgAdmin ? _myOrg : null),
      builder: (context, snap) {
        if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load people', body: '${snap.error}');
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final people = snap.data!;
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _add(context, dir),
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Add a person'),
          ),
          body: people.isEmpty
              ? const MessageView(
                  icon: Icons.groups_outlined,
                  title: 'Nobody added yet',
                  body: 'Add people by the email they sign in with. They get access the first time they sign in.',
                )
              : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
                  for (final p in people)
                    ListTile(
                      leading: Icon(p['claimedBy'] != null ? Icons.verified_user_outlined : Icons.schedule, color: p['claimedBy'] != null ? AppColors.success : AppColors.turmeric),
                      title: Text('${p['name'] ?? p['email']}'),
                      subtitle: Text(
                        '${p['email']} · ${Designation.fromKey(p['designation'] as String?)?.title ?? session.titleOf(Role.fromKey(p['role'] as String?) ?? Role.worker)} · '
                        '${p['claimedBy'] != null ? 'signed in' : 'not signed in yet'}',
                      ),
                      trailing: p['claimedBy'] == null
                          ? IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => runWrite(() => dir.removePreregistration('${p['email']}'), done: 'Removed.'),
                            )
                          : null,
                    ),
                ]),
        );
      },
    );
  }
}
