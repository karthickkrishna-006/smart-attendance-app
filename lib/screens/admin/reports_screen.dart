import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';

/// Attendance analytics report with date range, worker and location filters.
class ReportsScreen extends StatefulWidget {
  final AppUser me;
  const ReportsScreen({super.key, required this.me});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTimeRange _range = DateTimeRange(start: DateTime.now().subtract(const Duration(days: 6)), end: DateTime.now());
  String _worker = 'all';
  String _boundary = 'all';

  @override
  Widget build(BuildContext context) {
    final from = dayKey(_range.start), to = dayKey(_range.end);
    return Scaffold(
      appBar: AppBar(title: const Text('Reports & analytics')),
      body: LiveQueries(
        queryKey: '$from$to',
        queries: [
          Db.col('attendance').where('date', isGreaterThanOrEqualTo: from),
          Db.col('users').where('role', isEqualTo: Roles.worker),
          Db.col('boundaries'),
          Db.col('tasks'),
        ],
        builder: (context, d) {
          final workers = d[1].where((w) => _boundary == 'all' || w['boundaryId'] == _boundary).where((w) => _worker == 'all' || w['id'] == _worker).toList()
            ..sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
          final ids = workers.map((w) => w['id']).toSet();
          final att = d[0].where((a) => (a['date'] as String? ?? '').compareTo(to) <= 0 && ids.contains(a['uid'])).toList();
          final days = _range.end.difference(DateTime(_range.start.year, _range.start.month, _range.start.day)).inDays + 1;

          final rows = workers.map((w) {
            final mine = att.where((a) => a['uid'] == w['id']).toList();
            int c(String s) => mine.where((a) => a['status'] == s).length;
            final faceOk = mine.where((a) => (a['checkIn'] as Map?)?['faceStatus'] == 'verified').length;
            final geoOk = mine.where((a) => (a['checkIn'] as Map?)?['geoStatus'] == 'inside').length;
            final present = c('present') + c('late');
            final tasks = d[3].where((t) => t['assignedTo'] == w['id']).toList();
            return {
              'name': w['name'],
              'emp': w['employeeId'] ?? '',
              'synthetic': w['synthetic'] == true,
              'present': c('present'),
              'late': c('late'),
              'pending': c('pending_verification'),
              'rejected': c('rejected'),
              'absent': (days - mine.length).clamp(0, days),
              'rate': days == 0 ? 0.0 : present * 100 / days,
              'face': mine.isEmpty ? 0.0 : faceOk * 100 / mine.length,
              'geo': mine.isEmpty ? 0.0 : geoOk * 100 / mine.length,
              'tasksDone': tasks.where((t) => t['status'] == 'completed').length,
              'tasks': tasks.length,
            };
          }).toList();

          final totalPresent = att.where((a) => a['status'] == 'present' || a['status'] == 'late').length;
          final possible = workers.length * days;
          final overall = possible == 0 ? 0.0 : totalPresent * 100 / possible;

          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.date_range, color: AppColors.navy),
                    title: Text('${fmtDate(_range.start)} – ${fmtDate(_range.end)}'),
                    subtitle: Text('$days days'),
                    trailing: const Icon(Icons.edit_calendar_outlined),
                    onTap: () async {
                      final r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now(), initialDateRange: _range);
                      if (r != null) setState(() => _range = r);
                    },
                  ),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _boundary,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Location'),
                        items: [
                          const DropdownMenuItem(value: 'all', child: Text('All')),
                          ...d[2].map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] ?? '', overflow: TextOverflow.ellipsis))),
                        ],
                        onChanged: (v) => setState(() {
                          _boundary = v ?? 'all';
                          _worker = 'all';
                        }),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _worker,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Worker'),
                        items: [
                          const DropdownMenuItem(value: 'all', child: Text('All')),
                          ...d[1]
                              .where((w) => _boundary == 'all' || w['boundaryId'] == _boundary)
                              .map((w) => DropdownMenuItem(value: w['id'] as String, child: Text(w['name'] ?? '', overflow: TextOverflow.ellipsis))),
                        ],
                        onChanged: (v) => setState(() => _worker = v ?? 'all'),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: StatCard(label: 'Attendance rate', value: '${overall.toStringAsFixed(1)}%', icon: Icons.percent, color: AppColors.success)),
              const SizedBox(width: 10),
              Expanded(child: StatCard(label: 'Present-days', value: '$totalPresent / $possible', icon: Icons.event_available, color: AppColors.info)),
            ]),
            const SectionTitle('Daily attendance'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 18, 16, 8),
                child: SizedBox(height: 190, child: _daily(att, days)),
              ),
            ),
            SectionTitle('Per-worker summary',
                trailing: TextButton.icon(
                  onPressed: () {
                    final b = StringBuffer('Name,Employee ID,Present,Late,Pending,Rejected,Absent,Attendance %,Face verified %,Inside boundary %,Tasks done/total\n');
                    for (final r in rows) {
                      b.writeln('"${r['name']}",${r['emp']},${r['present']},${r['late']},${r['pending']},${r['rejected']},${r['absent']},'
                          '${(r['rate'] as double).toStringAsFixed(1)},${(r['face'] as double).toStringAsFixed(1)},${(r['geo'] as double).toStringAsFixed(1)},${r['tasksDone']}/${r['tasks']}');
                    }
                    Clipboard.setData(ClipboardData(text: b.toString()));
                    showSnack(context, 'CSV report copied to clipboard.', success: true);
                    Db.audit('report_exported', 'reports', {'from': from, 'to': to});
                  },
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: const Text('Copy CSV'),
                )),
            if (rows.isEmpty) const EmptyView(icon: Icons.table_chart_outlined, title: 'No workers match the filters'),
            ...rows.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('${r['name']}${(r['emp'] as String).isEmpty ? '' : ' · ${r['emp']}'}', style: const TextStyle(fontWeight: FontWeight.w700))),
                          if (r['synthetic'] == true) const DemoBadge(),
                          const SizedBox(width: 6),
                          Text('${(r['rate'] as double).toStringAsFixed(0)}%', style: TextStyle(fontWeight: FontWeight.w800, color: (r['rate'] as double) >= 75 ? AppColors.success : AppColors.danger)),
                        ]),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(value: ((r['rate'] as double) / 100).clamp(0.0, 1.0), minHeight: 6, color: AppColors.success, backgroundColor: AppColors.surface),
                        ),
                        const SizedBox(height: 8),
                        Wrap(spacing: 12, runSpacing: 4, children: [
                          _kv('Present', r['present']),
                          _kv('Late', r['late']),
                          _kv('Pending', r['pending']),
                          _kv('Rejected', r['rejected']),
                          _kv('Absent', r['absent']),
                          _kv('Face ✓', '${(r['face'] as double).toStringAsFixed(0)}%'),
                          _kv('In-boundary', '${(r['geo'] as double).toStringAsFixed(0)}%'),
                          _kv('Tasks', '${r['tasksDone']}/${r['tasks']}'),
                        ]),
                      ]),
                    ),
                  ),
                )),
          ]);
        },
      ),
    );
  }

  Widget _kv(String k, Object? v) => Text.rich(TextSpan(children: [
        TextSpan(text: '$k ', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        TextSpan(text: '$v', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
      ]));

  Widget _daily(List<Doc> att, int days) {
    final n = days.clamp(1, 31);
    final start = _range.end.subtract(Duration(days: n - 1));
    final groups = <BarChartGroupData>[];
    for (int i = 0; i < n; i++) {
      final k = dayKey(start.add(Duration(days: i)));
      final a = att.where((e) => e['date'] == k);
      final p = a.where((e) => e['status'] == 'present').length.toDouble();
      final l = a.where((e) => e['status'] == 'late').length.toDouble();
      final o = a.where((e) => e['status'] == 'pending_verification' || e['status'] == 'rejected').length.toDouble();
      groups.add(BarChartGroupData(x: i, barRods: [
        BarChartRodData(
          toY: p + l + o,
          width: n > 14 ? 6 : 14,
          borderRadius: BorderRadius.circular(3),
          rodStackItems: [
            BarChartRodStackItem(0, p, AppColors.success),
            BarChartRodStackItem(p, p + l, AppColors.warning),
            BarChartRodStackItem(p + l, p + l + o, AppColors.danger),
          ],
        ),
      ]));
    }
    return BarChart(BarChartData(
      barGroups: groups,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 26)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, m) {
              final i = v.toInt();
              if (n > 10 && i % 3 != 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(DateFormat('d/M').format(start.add(Duration(days: i))), style: const TextStyle(fontSize: 10)),
              );
            },
          ),
        ),
      ),
    ));
  }
}
