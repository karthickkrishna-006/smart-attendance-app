import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/session_controller.dart';

/// Who you are, which roles you hold, over which area, and your language.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final name = (session.account?['displayName'] as String?)?.trim() ?? '';
    final email = session.user?.email ?? '';
    final employeeId = session.account?['employeeId'] as String?;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        CircleAvatar(
          radius: 30,
          backgroundColor: const Color(0xFFE3EFE9),
          child: Text(
            (name.isNotEmpty ? name : (email.isNotEmpty ? email : '?')).characters.first.toUpperCase(),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.green),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isNotEmpty ? name : email, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink)),
            if (name.isNotEmpty) Text(email, style: const TextStyle(color: AppColors.muted)),
          ]),
        ),
      ]),
      const SizedBox(height: 20),
      Card(
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(s.t('role')),
            subtitle: Text(session.activeRoles.map(session.titleOf).join(', ')),
          ),
          if (session.designation != null)
            ListTile(
              leading: const Icon(Icons.work_outline),
              title: Text(s.t('staffType')),
              subtitle: Text(s.t('d_${session.designation!.key}')),
            ),
          if (session.activeRoles.length > 1)
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: Text(s.t('switchRole')),
              trailing: DropdownButton(
                value: session.role,
                underline: const SizedBox.shrink(),
                items: [for (final r in session.activeRoles) DropdownMenuItem(value: r, child: Text(session.titleOf(r)))],
                onChanged: (r) {
                  if (r != null) session.setRole(r);
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.apartment_outlined),
            title: Text(s.t('organisation')),
            subtitle: Text(session.orgName ?? s.t('none')),
          ),
          if (employeeId != null && employeeId.isNotEmpty)
            ListTile(leading: const Icon(Icons.numbers), title: const Text('Employee ID'), subtitle: Text(employeeId)),
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text(s.t('yourArea')),
            subtitle: Text(session.scopeLabels.isEmpty ? s.t('notAssigned') : session.scopeLabels.join('\n')),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Text(s.t('language'), style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'en', label: Text(s.t('english'))),
          ButtonSegment(value: 'ta', label: Text(s.t('tamil'))),
        ],
        selected: {session.language},
        onSelectionChanged: (v) => session.setLanguage(v.first),
      ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: () async {
          await session.signOut();
          showToast(s.t('signOut'));
        },
        icon: const Icon(Icons.logout),
        label: Text(s.t('signOut')),
      ),
    ]);
  }
}
