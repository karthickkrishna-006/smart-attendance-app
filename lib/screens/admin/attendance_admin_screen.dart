import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../common/attendance_detail.dart';

/// Daily attendance register for supervisors: who checked in, verification
/// results, and who is absent. Tap a record to review / override.
class AttendanceAdminScreen extends StatefulWidget {
  final AppUser me;
  final DateTime? initialDay;
  const AttendanceAdminScreen({super.key, required this.me, this.initialDay});
  @override
  State<AttendanceAdminScreen> createState() => _AttendanceAdminScreenState();
}

class _AttendanceAdminScreenState extends State<AttendanceAdminScreen> {
  late DateTime _day = widget.initialDay ?? DateTime.now();
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final day = dayKey(_day);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance register'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
              if (d != null) setState(() => _day = d);
            },
          ),
        ],
      ),
      body: LiveQueries(
        queryKey: day,
        queries: [Db.col('attendance').where('date', isEqualTo: day), Db.col('users').where('role', isEqualTo: Roles.worker)],
        builder: (context, d) {
          final att = d[0];
          final byUid = {for (final a in att) a['uid']: a};
          final workers = d[1].where((w) => (w['status'] ?? 'active') == 'active').toList();
          final rows = <Doc>[
            ...att,
            ...workers.where((w) => !byUid.containsKey(w['id'])).map((w) => <String, dynamic>{
                  'uid': w['id'],
                  'name': w['name'],
                  'status': 'absent',
                  'synthetic': w['synthetic'],
                  '_virtual': true,
                }),
          ];
          final shown = rows.where((r) => _filter == 'all' || r['status'] == _filter).toList()
            ..sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
          int c(String s) => rows.where((r) => r['status'] == s).length;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(fmtDate(_day), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy)),
            ),
            SizedBox(
              height: 54,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), children: [
                for (final s in ['all', 'present', 'late', 'pending_verification', 'rejected', 'absent'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('${s == 'all' ? 'All' : titleCase(s)} (${s == 'all' ? rows.length : c(s)})'),
                      selected: _filter == s,
                      onSelected: (_) => setState(() => _filter = s),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: shown.isEmpty
                  ? const EmptyView(icon: Icons.event_note_outlined, title: 'No records')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final a = shown[i];
                        final ci = a['checkIn'] as Map?;
                        final virtual = a['_virtual'] == true;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            child: ListTile(
                              onTap: virtual ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceDetail(a: a, reviewer: widget.me))),
                              leading: AvatarCircle(name: a['name'] ?? ''),
                              title: Row(children: [
                                Flexible(child: Text(a['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                                if (a['synthetic'] == true) ...[const SizedBox(width: 6), const DemoBadge()],
                              ]),
                              subtitle: virtual
                                  ? const Text('No check-in recorded')
                                  : Text('In ${fmtTime(ci?['time'])} · Out ${fmtTime((a['checkOut'] as Map?)?['time'])}\nFace: ${titleCase(ci?['faceStatus'] ?? 'n/a')} · GIS: ${titleCase(ci?['geoStatus'] ?? 'n/a')}'),
                              isThreeLine: !virtual,
                              trailing: StatusChip(a['status'] ?? 'pending'),
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
