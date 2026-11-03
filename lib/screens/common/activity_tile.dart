import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../../services/evidence_storage.dart';

class ActivityTile extends StatelessWidget {
  final Doc a;
  final AppUser me;
  final bool showTask;
  const ActivityTile({super.key, required this.a, required this.me, this.showTask = false});

  Future<void> _review(BuildContext context, String status) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(status == 'approved' ? 'Approve activity' : 'Reject activity'),
        content: TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Review remarks')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Db.col('activities').doc(a['id']).update({
        'reviewStatus': status,
        'reviewNote': note.text.trim(),
        'reviewedBy': me.name,
        'reviewedAt': FieldValue.serverTimestamp(),
      });
      if (a['taskId'] != null) {
        await Db.col('tasks').doc(a['taskId']).update({
          'status': status == 'approved' ? 'completed' : 'in_progress',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await Db.audit('activity_review', 'activities/${a['id']}', {'status': status});
      if (context.mounted) showSnack(context, 'Activity ${status == 'approved' ? 'approved' : 'rejected'}.', success: true);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imgs = (a['images'] as List?)?.cast<String>() ?? const <String>[];
    final rs = a['reviewStatus'] as String? ?? 'pending';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AvatarCircle(name: a['name'] ?? '', radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${a['visitType'] ?? 'Activity'} · ${fmtDateTime(a['createdAt'])}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                ]),
              ),
              StatusChip(rs),
            ]),
            if (showTask && a['taskTitle'] != null) ...[
              const SizedBox(height: 8),
              Text('Task: ${a['taskTitle']}', style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy)),
            ],
            const SizedBox(height: 8),
            Text(a['description'] ?? ''),
            if ((a['measurement'] ?? '').toString().isNotEmpty) Text('Measurement: ${a['measurement']}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              StatusChip(a['geoStatus'] ?? 'unavailable', label: 'Location: ${titleCase(a['geoStatus'] ?? 'n/a')}'),
              if (a['accuracy'] != null) StatusChip('info', label: '±${asDouble(a['accuracy']).toStringAsFixed(0)} m'),
              if (a['synthetic'] == true) const DemoBadge(),
            ]),
            if (imgs.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: imgs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => showDialog(
                      context: context,
                      builder: (_) => Dialog(child: InteractiveViewer(child: StorageImage(imgs[i], size: 360))),
                    ),
                    child: StorageImage(imgs[i]),
                  ),
                ),
              ),
            ],
            if (a['reviewNote'] != null && (a['reviewNote'] as String).isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Review (${a['reviewedBy'] ?? ''}): ${a['reviewNote']}', style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12.5)),
            ],
            if (me.isStaff && rs == 'pending') ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, minimumSize: const Size(10, 42)),
                    onPressed: () => _review(context, 'rejected'),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.success, minimumSize: const Size(10, 42)),
                    onPressed: () => _review(context, 'approved'),
                    icon: const Icon(Icons.check),
                    label: const Text('Approve'),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}
