import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';

const alertIcons = {
  'face_failed': Icons.face_retouching_off,
  'outside_boundary': Icons.wrong_location_outlined,
  'mock_location': Icons.gpp_bad_outlined,
  'late_checkin': Icons.schedule,
  'attendance_missing': Icons.event_busy,
  'task_delayed': Icons.assignment_late_outlined,
  'low_accuracy': Icons.gps_not_fixed,
};

class AlertsScreen extends StatefulWidget {
  final AppUser me;
  const AlertsScreen({super.key, required this.me});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  String _status = 'open';
  String _severity = 'all';

  Future<void> _resolve(Doc a) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Resolve alert'),
        content: TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Action taken / remarks')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Resolve')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Db.col('alerts').doc(a['id']).update({
        'status': 'resolved',
        'resolution': note.text.trim(),
        'resolvedBy': widget.me.name,
        'resolvedAt': FieldValue.serverTimestamp(),
      });
      await Db.audit('alert_resolved', 'alerts/${a['id']}');
      if (mounted) showSnack(context, 'Alert resolved.', success: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _runChecks() async {
    try {
      final n = await Db.runAlertChecks();
      if (mounted) showSnack(context, n == 0 ? 'Rules evaluated – no new alerts.' : '$n new alert(s) generated.', success: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me;
    final q = me.canViewAll ? Db.col('alerts') : Db.col('alerts').where('uid', isEqualTo: me.uid);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts & notifications'),
        actions: [
          if (me.isStaff) IconButton(tooltip: 'Run alert rules now', onPressed: _runChecks, icon: const Icon(Icons.rule)),
        ],
      ),
      body: LiveQueries(
        queries: [q],
        builder: (context, d) {
          final all = d[0]..sort((a, b) => (toDate(b['createdAt']) ?? DateTime(0)).compareTo(toDate(a['createdAt']) ?? DateTime(0)));
          final list = all
              .where((a) => _status == 'all' || a['status'] == _status)
              .where((a) => _severity == 'all' || a['severity'] == _severity)
              .toList();
          int cnt(String s) => all.where((a) => a['status'] == s).length;
          final critical = all.where((a) => a['status'] == 'open' && a['severity'] == 'critical').length;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(children: [
                Expanded(child: _pill('Open', cnt('open'), AppColors.danger)),
                const SizedBox(width: 8),
                Expanded(child: _pill('Critical', critical, AppColors.demo)),
                const SizedBox(width: 8),
                Expanded(child: _pill('Resolved', cnt('resolved'), AppColors.success)),
              ]),
            ),
            SizedBox(
              height: 54,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), children: [
                for (final s in ['open', 'resolved', 'all'])
                  Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(titleCase(s)), selected: _status == s, onSelected: (_) => setState(() => _status = s))),
                const VerticalDivider(),
                for (final s in ['all', 'critical', 'high', 'medium', 'low'])
                  Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(s == 'all' ? 'Any severity' : titleCase(s)), selected: _severity == s, onSelected: (_) => setState(() => _severity = s))),
              ]),
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyView(icon: Icons.notifications_off_outlined, title: 'No alerts', subtitle: 'Everything looks fine.')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _tile(list[i]),
                    ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _pill(String l, int n, Color c) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: c.withOpacity(0.09), borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Text('$n', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c)),
          Text(l, style: TextStyle(fontSize: 12, color: c)),
        ]),
      );

  Widget _tile(Doc a) {
    final sev = a['severity'] as String? ?? 'medium';
    final open = a['status'] == 'open';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: statusColor(sev).withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(alertIcons[a['type']] ?? Icons.notifications_active_outlined, color: statusColor(sev)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(titleCase(a['type'] ?? 'alert'), style: const TextStyle(fontWeight: FontWeight.w700))),
                  StatusChip(sev),
                ]),
                const SizedBox(height: 4),
                Text(a['description'] ?? ''),
                const SizedBox(height: 6),
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(ago(a['createdAt']), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                  StatusChip(a['status'] ?? 'open'),
                  if (a['synthetic'] == true) const DemoBadge(),
                ]),
                if (!open && a['resolution'] != null && (a['resolution'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Resolved by ${a['resolvedBy'] ?? ''}: ${a['resolution']}', style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                  ),
                if (open && widget.me.isStaff)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(onPressed: () => _resolve(a), icon: const Icon(Icons.done_all, size: 18), label: const Text('Resolve')),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
