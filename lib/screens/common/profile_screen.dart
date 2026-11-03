import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/auth_service.dart';
import '../../services/db.dart';
import '../../services/face_service.dart';
import '../../services/models.dart';
import '../worker/face_enroll_screen.dart';

class ProfileScreen extends StatelessWidget {
  final AppUser me;
  const ProfileScreen({super.key, required this.me});

  Future<void> _edit(BuildContext context) async {
    final name = TextEditingController(text: me.name);
    final phone = TextEditingController(text: me.phone);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 10),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    if (name.text.trim().length < 3) {
      if (context.mounted) showSnack(context, 'Name is too short.', error: true);
      return;
    }
    try {
      await Db.col('users').doc(me.uid).update({'name': name.text.trim(), 'phone': phone.text.trim()});
      if (context.mounted) showSnack(context, 'Profile updated.', success: true);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fb = AuthService.current;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile'), actions: [IconButton(onPressed: () => _edit(context), icon: const Icon(Icons.edit_outlined))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              AvatarCircle(name: me.name, photo: me.photo, radius: 42),
              const SizedBox(height: 12),
              Text(me.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              Text(me.email, style: const TextStyle(color: AppColors.muted)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [StatusChip('assigned', label: Roles.label(me.role)), StatusChip(me.status)]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              InfoRow(Icons.badge_outlined, 'Employee ID', me.employeeId.isEmpty ? 'Not assigned' : me.employeeId),
              InfoRow(Icons.fingerprint, 'User ID', me.uid),
              InfoRow(Icons.phone_outlined, 'Phone', me.phone.isEmpty ? '—' : me.phone),
              InfoRow(Icons.category_outlined, 'Category', me.category.isEmpty ? '—' : me.category),
              InfoRow(Icons.login, 'Sign-in method', fb?.providerData.map((p) => p.providerId == 'google.com' ? 'Google' : 'Email/Password').join(', ') ?? '—'),
              InfoRow(Icons.verified_outlined, 'Email verified', fb?.emailVerified == true ? 'Yes' : 'No'),
              InfoRow(Icons.face, 'Face enrolled', me.faceEmbedding == null ? 'No' : 'Yes · ${fmtDate(me.raw['faceEnrolledAt'])}',
                  color: me.faceEmbedding == null ? AppColors.warning : AppColors.success),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        if (me.faceEmbedding == null)
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FaceEnrollScreen(target: me))),
            icon: const Icon(Icons.face_retouching_natural),
            label: const Text('Enrol my face'),
          ),
        if (fb != null && !fb.emailVerified && fb.providerData.any((p) => p.providerId == 'password'))
          TextButton(
            onPressed: () async {
              await fb.sendEmailVerification();
              if (context.mounted) showSnack(context, 'Verification email sent.', success: true);
            },
            child: const Text('Resend email verification'),
          ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: Text('Smart Attendance v1.0 · Firebase Auth + Cloud Firestore\nFace AI: ${FaceService.modelName}\nMaps: © OpenStreetMap contributors'),
            isThreeLine: true,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () async {
            if (await confirm(context, 'Sign out', 'Do you want to sign out?', ok: 'Sign out', danger: true)) {
              await AuthService.signOut();
            }
          },
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ]),
    );
  }
}
