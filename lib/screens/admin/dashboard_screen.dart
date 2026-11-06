import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import '../../core/fmt.dart';
import '../../core/geo.dart';
import '../../core/osm_map.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../common/alerts_screen.dart';
import 'attendance_admin_screen.dart';
import 'live_map_screen.dart';

/// Dynamic admin/supervisor/auditor dashboard. Every value is computed from
/// live Firestore snapshots – nothing is hard-coded.
class DashboardScreen extends StatefulWidget {
  final AppUser me;
  const DashboardScreen({super.key, required this.me});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DateTime _day = DateTime.now();
  String _block = 'all';
  String _panchayat = 'all';
  bool _ranChecks = false;

  @override
  void initState() {
    super.initState();
    if (widget.me.isStaff && !_ranChecks) {
      _ranChecks = true;
      Db.runAlertChecks().catchError((_) => 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = dayKey(_day);
    final weekStart = dayKey(_day.subtract(const Duration(days: 6)));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.me.role == Roles.auditor ? 'Analytics overview' : 'Admin dashboard'),
        actions: [
          IconButton(
            tooltip: 'Pick date',
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
        queries: [
          Db.col('users'),
          Db.col('attendance').where('date', isGreaterThanOrEqualTo: weekStart),
          Db.col('tasks'),
          Db.col('alerts'),
          Db.col('boundaries'),
          Db.col('activities').where('reviewStatus', isEqualTo: 'pending'),
          // Live positions, scoped by role (none for auditors).
          Db.trackingQuery('locations', widget.me),
        ],
        builder: (context, d) => _body(context, d, day),
      ),
    );
  }

  Widget _body(BuildContext context, List<List<Doc>> d, String day) {
    final boundaries = d[4].map(Boundary.fromDoc).toList();
    final bById = {for (final b in boundaries) b.id: b};
    bool inScope(String? boundaryId) {
      if (_block == 'all' && _panchayat == 'all') return true;
      final b = bById[boundaryId];
      if (b == null) return false;
      if (_block != 'all' && b.block != _block) return false;
      if (_panchayat != 'all' && b.panchayat != _panchayat) return false;
      return true;
    }

    final workers = d[0].where((u) => (u['role'] ?? 'worker') == 'worker' && inScope(u['boundaryId'])).toList();
    final ids = workers.map((w) => w['id']).toSet();
    final active = workers.where((w) => (w['status'] ?? 'active') == 'active').toList();
    final allAtt = d[1].where((a) => ids.contains(a['uid'])).toList();
    final att = allAtt.where((a) => a['date'] == day).toList();
    final tasks = d[2].where((t) => ids.contains(t['assignedTo'])).toList();
    final alerts = d[3];
    final pendingActs = d[5].where((a) => ids.contains(a['uid'])).length;
    final locs = d[6].where((l) => ids.contains(l['id'])).toList();

    int st(String s) => att.where((a) => a['status'] == s).length;
    final present = st('present'), late = st('late'), pending = st('pending_verification'), rejected = st('rejected');
    final absent = (active.length - att.length).clamp(0, 1 << 30);
    final pct = active.isEmpty ? 0.0 : (present + late) * 100 / active.length;

    final faceV = att.where((a) => (a['checkIn'] as Map?)?['faceStatus'] == 'verified').length;
    final faceF = att.where((a) => (a['checkIn'] as Map?)?['faceStatus'] == 'failed').length;
    final faceO = att.length - faceV - faceF;
    final locIn = att.where((a) => (a['checkIn'] as Map?)?['geoStatus'] == 'inside').length;
    final locOut = att.where((a) => (a['checkIn'] as Map?)?['geoStatus'] == 'outside').length;
    final locO = att.length - locIn - locOut;

    int ts(String s) => tasks.where((t) => t['status'] == s).length;
    final overdue = tasks.where((t) {
      final due = toDate(t['dueDate']);
      return due != null && due.isBefore(DateTime.now()) && t['status'] != 'completed';
    }).length;

    final openAlerts = alerts.where((a) => a['status'] == 'open').length;
    final critical = alerts.where((a) => a['status'] == 'open' && (a['severity'] == 'critical' || a['severity'] == 'high')).length;
    final resolved = alerts.where((a) => a['status'] == 'resolved').length;
    final pendingApproval = d[0].where((u) => u['status'] == 'pending_approval').length;
    final synthetic = d[0].any((u) => u['synthetic'] == true) || boundaries.any((b) => b.synthetic);

    final blocks = boundaries.map((b) => b.block).where((e) => e.isNotEmpty).toSet().toList()..sort();
    final pans = boundaries.where((b) => _block == 'all' || b.block == _block).map((b) => b.panchayat).where((e) => e.isNotEmpty).toSet().toList()..sort();

    return RefreshIndicator(
      onRefresh: () async {
        await Db.runAlertChecks();
      },
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(
            child: Text(
              DateUtils.isSameDay(_day, DateTime.now()) ? 'Today · ${fmtDate(_day)}' : fmtDate(_day),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.navy),
            ),
          ),
          const Icon(Icons.circle, size: 9, color: AppColors.success),
          const SizedBox(width: 4),
          const Text('Live', style: TextStyle(fontSize: 12, color: AppColors.success, fontWeight: FontWeight.w700)),
        ]),
        if (synthetic)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(children: [DemoBadge(), SizedBox(width: 8), Expanded(child: Text('Dashboard includes synthetic demo records.', style: TextStyle(fontSize: 12, color: AppColors.muted)))]),
          ),
        // Approval was removed (Revision 5): accounts created before that
        // still say pending_approval and activate themselves at next sign-in.
        if (pendingApproval > 0 && widget.me.isStaff)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 16, color: AppColors.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$pendingApproval older account${pendingApproval == 1 ? '' : 's'} will activate automatically at the next sign-in. No action needed.',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _drop('Block', _block, blocks, (v) => setState(() {
                _block = v;
                _panchayat = 'all';
              }))),
          const SizedBox(width: 10),
          Expanded(child: _drop('Panchayat', _panchayat, pans, (v) => setState(() => _panchayat = v))),
        ]),
        const SizedBox(height: 14),
        StatGrid(children: [
            StatCard(label: 'Total workers', value: '${workers.length}', icon: Icons.groups_outlined, color: AppColors.navy, sub: '${active.length} active · ${workers.length - active.length} inactive'),
            StatCard(
              label: 'Attendance',
              value: '${pct.toStringAsFixed(0)}%',
              icon: Icons.how_to_reg_outlined,
              color: AppColors.success,
              sub: '${present + late} of ${active.length} present',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceAdminScreen(me: widget.me, initialDay: _day))),
            ),
            StatCard(
              label: 'On duty now',
              value: '${locs.where((l) => l['onDuty'] == true).length}',
              icon: Icons.gps_fixed,
              color: AppColors.info,
              sub: '${locs.where((l) => l['geoStatus'] == 'outside').length} outside boundary',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveMapScreen(me: widget.me, standalone: true))),
            ),
            StatCard(
              label: 'Open alerts',
              value: '$openAlerts',
              icon: Icons.notification_important_outlined,
              color: AppColors.danger,
              sub: '$critical high/critical · $resolved resolved',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlertsScreen(me: widget.me))),
            ),
          ],
        ),
        const SectionTitle('Attendance status'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              SizedBox(
                width: 130,
                height: 130,
                child: (att.isEmpty && absent == 0)
                    ? const Center(child: Text('No data', style: TextStyle(color: AppColors.muted)))
                    : PieChart(PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 34,
                        sections: [
                          _sec(present.toDouble(), AppColors.success),
                          _sec(late.toDouble(), AppColors.warning),
                          _sec(pending.toDouble(), AppColors.info),
                          _sec(rejected.toDouble(), AppColors.danger),
                          _sec(absent.toDouble(), const Color(0xFFB8C2CF)),
                        ],
                      )),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _legendRow(AppColors.success, 'Present', present),
                  _legendRow(AppColors.warning, 'Late', late),
                  _legendRow(AppColors.info, 'Pending verification', pending),
                  _legendRow(AppColors.danger, 'Rejected', rejected),
                  _legendRow(const Color(0xFFB8C2CF), 'Absent / not marked', absent),
                ]),
              ),
            ]),
          ),
        ),
        const SectionTitle('7-day attendance trend'),
        Card(child: Padding(padding: const EdgeInsets.fromLTRB(8, 18, 16, 8), child: SizedBox(height: 180, child: _trend(allAtt, active.length)))),
        const SectionTitle('Verification outcomes (check-in)'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              _stackBar('AI face verification', [(faceV, AppColors.success, 'Verified'), (faceF, AppColors.danger, 'Failed'), (faceO, AppColors.warning, 'Unavailable/other')]),
              const SizedBox(height: 16),
              _stackBar('GIS location', [(locIn, AppColors.success, 'Inside'), (locOut, AppColors.danger, 'Outside'), (locO, AppColors.warning, 'Unverified')]),
            ]),
          ),
        ),
        const SectionTitle('Tasks & field activities'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 18, 16, 8),
            child: SizedBox(
              height: 170,
              child: BarChart(BarChartData(
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 26)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, m) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(const ['Assigned', 'Progress', 'Submitted', 'Done', 'Overdue'][v.toInt()], style: const TextStyle(fontSize: 10.5)),
                      ),
                    ),
                  ),
                ),
                barGroups: [
                  _bar(0, ts('assigned'), AppColors.info),
                  _bar(1, ts('in_progress'), AppColors.warning),
                  _bar(2, ts('submitted'), AppColors.teal),
                  _bar(3, ts('completed'), AppColors.success),
                  _bar(4, overdue, AppColors.danger),
                ],
              )),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${tasks.isEmpty ? 0 : (ts('completed') * 100 / tasks.length).toStringAsFixed(0)}% of ${tasks.length} tasks completed · $pendingActs field activities awaiting review',
          style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        const SectionTitle('Live field map'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 220,
            child: Stack(children: [
              OsmMap(
                key: ValueKey('dash${boundaries.length}${locs.length}'),
                center: locs.isNotEmpty
                    ? LatLng(asDouble(locs.first['lat']), asDouble(locs.first['lng']))
                    : (boundaries.isNotEmpty ? centroid(boundaries.first.points) : const LatLng(12.6919, 79.9762)),
                zoom: 13,
                interactive: false,
                layers: [
                  PolygonLayer(polygons: boundaries.where((b) => b.points.length >= 3).map((b) => boundaryPolygon(b)).toList()),
                  MarkerLayer(
                    markers: locs
                        .map((l) => Marker(
                              point: LatLng(asDouble(l['lat']), asDouble(l['lng'])),
                              width: 16,
                              height: 16,
                              child: MyLocationDot(color: l['geoStatus'] == 'outside' ? AppColors.danger : AppColors.success),
                            ))
                        .toList(),
                  ),
                ],
              ),
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveMapScreen(me: widget.me, standalone: true)))),
                ),
              ),
            ]),
          ),
        ),
        const SectionTitle('Recent alerts'),
        ..._recentAlerts(alerts),
        const SizedBox(height: 20),
      ]),
    );
  }

  /// Up to 5 most recent open alerts, or a single "No open alerts" card.
  /// Explicit List<Widget> return type so the spread in build() is typed
  /// (an inline closure with mixed List/Iterable branches infers `Object`).
  List<Widget> _recentAlerts(List<Doc> alerts) {
    final recent = alerts.where((a) => a['status'] == 'open').toList()
      ..sort((a, b) => (toDate(b['createdAt']) ?? DateTime(0)).compareTo(toDate(a['createdAt']) ?? DateTime(0)));
    if (recent.isEmpty) {
      return const <Widget>[
        Card(child: ListTile(leading: Icon(Icons.check_circle, color: AppColors.success), title: Text('No open alerts'))),
      ];
    }
    return recent
        .take(5)
        .map<Widget>((a) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: Icon(alertIcons[a['type']] ?? Icons.warning_amber, color: statusColor(a['severity'])),
                  title: Text(a['description'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${titleCase(a['severity'] ?? '')} · ${ago(a['createdAt'])}'),
                ),
              ),
            ))
        .toList();
  }

  Widget _drop(String label, String value, List<String> items, ValueChanged<String> on) => DropdownButtonFormField<String>(
        value: items.contains(value) ? value : 'all',
        isExpanded: true,
        decoration: InputDecoration(labelText: label, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
        items: [const DropdownMenuItem(value: 'all', child: Text('All')), ...items.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis)))],
        onChanged: (v) => on(v ?? 'all'),
      );

  PieChartSectionData _sec(double v, Color c) => PieChartSectionData(
        value: v,
        color: c,
        radius: 26,
        title: v == 0 ? '' : v.toInt().toString(),
        titleStyle: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
      );

  Widget _legendRow(Color c, String l, int n) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(l, style: const TextStyle(fontSize: 12.5))),
          Text('$n', style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  BarChartGroupData _bar(int x, int y, Color c) => BarChartGroupData(x: x, barRods: [
        BarChartRodData(toY: y.toDouble(), color: c, width: 22, borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
      ]);

  Widget _stackBar(String title, List<(int, Color, String)> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.$1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
        Text('$total checks', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 14,
          child: total == 0
              ? Container(color: AppColors.surface)
              : Row(children: parts.where((p) => p.$1 > 0).map((p) => Expanded(flex: p.$1, child: Container(color: p.$2))).toList()),
        ),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 14, children: parts.map((p) => Legend(p.$2, '${p.$3}: ${p.$1}')).toList()),
    ]);
  }

  Widget _trend(List<Doc> att, int activeCount) {
    final days = List.generate(7, (i) => _day.subtract(Duration(days: 6 - i)));
    final spots = <FlSpot>[];
    final lateSpots = <FlSpot>[];
    for (int i = 0; i < 7; i++) {
      final k = dayKey(days[i]);
      final dayAtt = att.where((a) => a['date'] == k);
      spots.add(FlSpot(i.toDouble(), dayAtt.where((a) => a['status'] == 'present' || a['status'] == 'late').length.toDouble()));
      lateSpots.add(FlSpot(i.toDouble(), dayAtt.where((a) => a['status'] == 'late').length.toDouble()));
    }
    return LineChart(LineChartData(
      minY: 0,
      maxY: (activeCount < 1 ? 1 : activeCount).toDouble() + 1,
      gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFFEDF0F5), strokeWidth: 1)),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 26, interval: 1)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 1,
            getTitlesWidget: (v, m) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(DateFormat('E').format(days[v.toInt().clamp(0, 6)]), style: const TextStyle(fontSize: 11)),
            ),
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: AppColors.success,
          barWidth: 3,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(show: true, color: AppColors.success.withValues(alpha: 0.1)),
        ),
        LineChartBarData(spots: lateSpots, isCurved: true, color: AppColors.warning, barWidth: 2, dotData: const FlDotData(show: false)),
      ],
    ));
  }
}
