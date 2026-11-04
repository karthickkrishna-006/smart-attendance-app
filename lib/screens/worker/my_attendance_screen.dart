import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../common/attendance_detail.dart';

class MyAttendanceScreen extends StatelessWidget {
  final AppUser me;
  const MyAttendanceScreen({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance history')),
      body: AttendanceHistory(uid: me.uid),
    );
  }
}

/// Attendance history list for a single worker (used by worker and staff).
class AttendanceHistory extends StatelessWidget {
  final String uid;
  final bool shrink;
  const AttendanceHistory({super.key, required this.uid, this.shrink = false});

  @override
  Widget build(BuildContext context) {
    return LiveQueries(
      queries: [Db.col('attendance').where('uid', isEqualTo: uid)],
      builder: (context, d) {
        final list = d[0]..sort((a, b) => (b['date'] as String? ?? '').compareTo(a['date'] as String? ?? ''));
        if (list.isEmpty) {
          return const EmptyView(icon: Icons.event_busy, title: 'No attendance records yet', subtitle: 'Check-ins will appear here.');
        }
        final last30 = list.take(30).toList();
        final present = last30.where((e) => e['status'] == 'present' || e['status'] == 'late').length;
        final header = Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _mini('${last30.length}', 'Records'),
              _mini('$present', 'Present/Late'),
              _mini(last30.isEmpty ? '0%' : '${(present * 100 / last30.length).toStringAsFixed(0)}%', 'Rate'),
            ]),
          ),
        );
        final tiles = list.map((a) => _AttTile(a: a)).toList();
        if (shrink) {
          return Column(children: [header, const SizedBox(height: 8), ...tiles.take(10)]);
        }
        return ListView(padding: const EdgeInsets.all(16), children: [header, const SizedBox(height: 10), ...tiles]);
      },
    );
  }

  Widget _mini(String v, String l) => Column(children: [
        Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.navy)),
        Text(l, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
      ]);
}

class _AttTile extends StatelessWidget {
  final Doc a;
  const _AttTile({required this.a});
  @override
  Widget build(BuildContext context) {
    final ci = a['checkIn'] as Map? ?? {};
    final co = a['checkOut'] as Map?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceDetail(a: a))),
          leading: Container(
            width: 48,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(color: statusColor(a['status']).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text((a['date'] as String? ?? '').split('-').last, style: TextStyle(fontWeight: FontWeight.w800, color: statusColor(a['status']))),
              Text(fmtDate(a['date']).split(' ').elementAt(1), style: const TextStyle(fontSize: 11)),
            ]),
          ),
          title: Row(children: [
            Text('${fmtTime(ci['time'])} → ${co == null ? '--' : fmtTime(co['time'])}', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (a['synthetic'] == true) ...[const SizedBox(width: 6), const DemoBadge()],
          ]),
          subtitle: Text('Face: ${titleCase(ci['faceStatus'] ?? 'n/a')} · Location: ${titleCase(ci['geoStatus'] ?? 'n/a')}'),
          trailing: StatusChip(a['status'] ?? 'pending'),
        ),
      ),
    );
  }
}
