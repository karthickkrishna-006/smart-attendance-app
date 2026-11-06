import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/face_service.dart';
import '../../services/models.dart';
import '../common/route_screen.dart';
import '../worker/face_enroll_screen.dart';
import '../worker/my_attendance_screen.dart';
import '../worker/my_tasks_screen.dart';
import 'worker_edit_screen.dart';

class WorkerDetailScreen extends StatelessWidget {
  final String uid;
  final AppUser me;
  const WorkerDetailScreen({super.key, required this.uid, required this.me});

  Future<void> _resetFace(BuildContext context, AppUser w) async {
    if (!await confirm(context, 'Delete face reference', 'This deletes the stored biometric reference for ${w.name}. They must re-enrol before face verification.', ok: 'Delete', danger: true)) return;
    try {
      await FaceTemplates.delete(w.uid);
      await Db.audit('face_reference_deleted', 'users/${w.uid}');
      if (context.mounted) showSnack(context, 'Face reference deleted.', success: true);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: Db.col('users').doc(uid).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Scaffold(appBar: AppBar(), body: ErrorView(message: friendlyError(snap.error!)));
        if (!snap.hasData) return Scaffold(appBar: AppBar(), body: const LoadingView());
        if (!snap.data!.exists) return Scaffold(appBar: AppBar(), body: const EmptyView(icon: Icons.person_off, title: 'User not found'));
        final w = AppUser(uid, snap.data!.data()!);
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(w.name),
              actions: [
                if (me.isStaff)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => WorkerEditScreen(me: me, existing: w))),
                  ),
              ],
              bottom: const TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: AppColors.teal,
                tabs: [Tab(text: 'Profile'), Tab(text: 'Attendance'), Tab(text: 'Tasks')],
              ),
            ),
            body: TabBarView(children: [
              ListView(padding: const EdgeInsets.all(16), children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(children: [
                      AvatarCircle(name: w.name, radius: 38),
                      const SizedBox(height: 10),
                      Text(w.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, children: [
                        StatusChip('assigned', label: Roles.label(w.role)),
                        StatusChip(w.status),
                        if (w.synthetic) const DemoBadge(),
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: StreamBuilder(
                      stream: w.boundaryId == null ? null : Db.col('boundaries').doc(w.boundaryId).snapshots(),
                      builder: (context, b) => Column(children: [
                        InfoRow(Icons.badge_outlined, 'Employee ID', w.employeeId.isEmpty ? 'Not assigned' : w.employeeId),
                        InfoRow(Icons.key_outlined, 'Database ID', w.uid),
                        InfoRow(Icons.mail_outline, 'Email', w.email.isEmpty ? '—' : w.email),
                        InfoRow(Icons.phone_outlined, 'Phone', w.phone.isEmpty ? '—' : w.phone),
                        InfoRow(Icons.category_outlined, 'Category', w.category.isEmpty ? '—' : w.category),
                        InfoRow(Icons.layers_outlined, 'Boundary', b.data?.data()?['name'] ?? 'Not assigned'),
                        InfoRow(Icons.account_tree_outlined, 'Block › Panchayat',
                            b.data?.data() == null ? '—' : '${b.data!.data()!['block'] ?? ''} › ${b.data!.data()!['panchayat'] ?? ''}'),
                        InfoRow(Icons.login, 'App login', w.hasLogin ? 'Yes' : 'No (record only)'),
                        InfoRow(Icons.face, 'Face reference', !w.faceEnrolled ? 'Not enrolled' : 'Enrolled ${fmtDate(w.raw['faceEnrolledAt'])}',
                            color: !w.faceEnrolled ? AppColors.warning : AppColors.success),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RouteScreen(me: me, workerUid: uid, workerName: w.name)),
                  ),
                  icon: const Icon(Icons.route_outlined),
                  label: Text(me.role == Roles.auditor ? 'Field duty records' : 'Movement route & duty history'),
                ),
                if (me.isStaff && !w.faceEnrolled && w.hasLogin)
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FaceEnrollScreen(target: w))),
                    icon: const Icon(Icons.face_retouching_natural),
                    label: const Text('Enrol face (worker present with this phone)'),
                  ),
                if (me.isAdmin && w.faceEnrolled)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                    onPressed: () => _resetFace(context, w),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete face reference'),
                  ),
              ]),
              AttendanceHistory(uid: uid),
              LiveQueries(
                queries: [Db.col('tasks').where('assignedTo', isEqualTo: uid)],
                builder: (context, d) {
                  final list = d[0]..sort(taskSort);
                  if (list.isEmpty) return const EmptyView(icon: Icons.assignment_outlined, title: 'No tasks assigned');
                  return ListView(padding: const EdgeInsets.all(16), children: list.map((t) => TaskTile(t: t, me: me)).toList());
                },
              ),
            ]),
          ),
        );
      },
    );
  }
}
