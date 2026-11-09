import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/attendance_repository.dart';
import '../../data/officer_attendance.dart';
import '../../data/scoped.dart';
import '../../data/session_controller.dart';
import '../../data/work_repository.dart';
import '../../domain/attendance.dart';
import '../../domain/attendance_summary.dart';
import '../../domain/geo.dart';
import '../../domain/roles.dart';
import '../work/worker_work_screens.dart' show shortDateTime;

/// Boundaries inside the officer's scope.
Future<List<Geofence>> geofencesInScope(SessionController session) async {
  final col = FirebaseFirestore.instance.collection('geofences');
  final ids = session.current?.areaIds ?? const <String>[];
  final wide = session.role == Role.collector || session.role == Role.auditor || ids.isEmpty;
  final docs = <String, Map<String, dynamic>>{};
  if (wide) {
    for (final d in (await col.get()).docs) {
      docs[d.id] = d.data();
    }
  } else {
    for (final id in ids) {
      for (final d in (await col.where('areaPath', arrayContains: id).get()).docs) {
        docs[d.id] = d.data();
      }
    }
  }
  return [
    for (final e in docs.entries)
      if (AttendanceRepository.geofenceFromMap(e.key, e.value) case final Geofence f) f,
  ];
}

String _ago(Object? t) {
  if (t is! Timestamp) return 'never';
  final m = DateTime.now().difference(t.toDate()).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  return '${m ~/ 60} h ${m % 60} min ago';
}

bool _fresh(Map<String, dynamic> p) =>
    p['onDuty'] == true && p['at'] is Timestamp && DateTime.now().difference((p['at'] as Timestamp).toDate()).inMinutes < 10;

const _defaultCentre = LatLng(12.6919, 79.9762);

// ------------------------------------------------------------ live monitoring
class LiveMonitoringScreen extends StatefulWidget {
  const LiveMonitoringScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<LiveMonitoringScreen> createState() => _LiveMonitoringScreenState();
}

class _LiveMonitoringScreenState extends State<LiveMonitoringScreen> {
  late final _presence = watchMerged(scopedQueries(widget.session, 'presence'), sort: newestFirst('at'));
  late final _visits = watchScoped(widget.session, 'visits', day: dayKey(DateTime.now()), sort: newestFirst('enteredAt'));
  late final Future<List<Geofence>> _fences = geofencesInScope(widget.session);
  final _map = MapController();
  List<LatLng> _route = const [];
  String? _selected;

  Future<void> _select(Map<String, dynamic> p, List<Map<String, dynamic>> visits, List<Geofence> fences) async {
    final uid = p['uid'] as String;
    setState(() => _selected = uid);
    try {
      final r = await FirebaseFirestore.instance.doc('routes/${uid}_${dayKey(DateTime.now())}').get();
      final pts = ((r.data()?['points'] as List?) ?? const [])
          .whereType<Map>()
          .where((m) => m['lat'] is num && m['lng'] is num)
          .map((m) => LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()))
          .toList();
      if (mounted) setState(() => _route = pts);
    } catch (e) {
      showToast('Route not available: $e', kind: ToastKind.error);
    }
    if (!mounted) return;
    final mine = visits.where((v) => v['uid'] == uid).toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('${p['workerName'] ?? ''}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          Text('${p['onDuty'] == true ? 'On duty' : 'Off duty'} · last update ${_ago(p['at'])}'
              '${p['accuracy'] is num ? ' · ±${(p['accuracy'] as num).round()} m' : ''}'
              '${p['synthetic'] == true ? ' · demo' : ''}', style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          const Text('Streets today (automatic entry and exit)', style: TextStyle(fontWeight: FontWeight.w700)),
          if (mine.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: Text('No street visits recorded today.')),
          for (final v in mine)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(v['exitedAt'] == null ? Icons.login : Icons.check_circle_outline,
                  color: v['exitedAt'] == null ? AppColors.success : AppColors.indigo),
              title: Text('${v['geofenceName'] ?? v['geofenceId']}'),
              subtitle: Text('In ${shortDateTime(v['enteredAt'])} · '
                  '${v['exitedAt'] == null ? 'still there' : 'out ${shortDateTime(v['exitedAt'])} (${v['durationMin']} min)'}'),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final problem = scopeProblem(widget.session);
    return FutureBuilder<List<Geofence>>(
      future: _fences,
      builder: (context, fenceSnap) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _visits,
        builder: (context, visitSnap) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: _presence,
          builder: (context, snap) {
            final fences = fenceSnap.data ?? const <Geofence>[];
            final people = snap.data ?? const <Map<String, dynamic>>[];
            final visits = visitSnap.data ?? const <Map<String, dynamic>>[];
            final names = {for (final f in fences) f.id: f.name};
            final located = people.where((p) => p['lat'] is num && p['lng'] is num).toList();
            final centre = located.isNotEmpty
                ? LatLng((located.first['lat'] as num).toDouble(), (located.first['lng'] as num).toDouble())
                : fences.isNotEmpty
                    ? LatLng(fences.first.center?.lat ?? fences.first.ring.first.lat, fences.first.center?.lng ?? fences.first.ring.first.lng)
                    : _defaultCentre;
            final onDuty = people.where(_fresh).length;
            return Column(children: [
              if (problem != null) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: NoticeCard(text: problem)),
              if (snap.hasError) Padding(padding: const EdgeInsets.all(12), child: Text('${snap.error}', style: const TextStyle(color: AppColors.danger))),
              SizedBox(
                height: 340,
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(initialCenter: centre, initialZoom: 15),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'in.cit.smartattendance.v2'),
                    CircleLayer(circles: [
                      for (final f in fences.where((f) => f.kind == GeofenceKind.circle))
                        CircleMarker(
                          point: LatLng(f.center!.lat, f.center!.lng),
                          radius: f.radiusM!,
                          useRadiusInMeter: true,
                          color: AppColors.green.withValues(alpha: 0.12),
                          borderColor: AppColors.green,
                          borderStrokeWidth: 2,
                        ),
                    ]),
                    PolygonLayer(polygons: [
                      for (final f in fences.where((f) => f.kind == GeofenceKind.polygon))
                        Polygon(
                          points: [for (final p in f.ring) LatLng(p.lat, p.lng)],
                          color: AppColors.green.withValues(alpha: 0.12),
                          borderColor: AppColors.green,
                          borderStrokeWidth: 2,
                        ),
                    ]),
                    if (_route.length > 1) PolylineLayer(polylines: [Polyline(points: _route, strokeWidth: 4, color: AppColors.indigo)]),
                    MarkerLayer(markers: [
                      for (final p in located)
                        Marker(
                          point: LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
                          width: 44,
                          height: 44,
                          child: GestureDetector(
                            onTap: () => _select(p, visits, fences),
                            child: Icon(Icons.person_pin_circle,
                                size: 40, color: p['uid'] == _selected ? AppColors.indigo : (_fresh(p) ? AppColors.success : AppColors.muted)),
                          ),
                        ),
                    ]),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(children: [
                  Text('$onDuty on duty now · ${people.length} seen', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  const Text('© OpenStreetMap', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                ]),
              ),
              Expanded(
                child: people.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No worker has started duty in your area yet. Workers appear here after they tap "Start duty".',
                              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
                        ),
                      )
                    : ListView(children: [
                        for (final p in people)
                          ListTile(
                            onTap: () {
                              if (p['lat'] is num && p['lng'] is num) {
                                _map.move(LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()), 16);
                              }
                              _select(p, visits, fences);
                            },
                            leading: Icon(Icons.circle, size: 14, color: _fresh(p) ? AppColors.success : AppColors.muted),
                            title: Text('${p['workerName'] ?? 'Unnamed worker'}${p['synthetic'] == true ? ' (demo)' : ''}'),
                            subtitle: Text('${p['geofenceId'] != null ? 'In ${names[p['geofenceId']] ?? 'a street'} · ' : ''}'
                                '${p['onDuty'] == true ? 'on duty' : 'off duty'} · ${_ago(p['at'])}'),
                            trailing: const Icon(Icons.route),
                          ),
                      ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- coverage
class CoverageScreen extends StatefulWidget {
  const CoverageScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<CoverageScreen> createState() => _CoverageScreenState();
}

class _CoverageScreenState extends State<CoverageScreen> {
  late final day = dayKey(DateTime.now());
  late final Future<List<Geofence>> _fences = geofencesInScope(widget.session);
  late final _att = OfficerAttendance(widget.session).watch(day);
  late final _visits = watchScoped(widget.session, 'visits', day: day);
  late final _acts = WorkRepository(widget.session).watchActivities(day);
  late final _tasks = WorkRepository(widget.session).watchTasks();

  @override
  Widget build(BuildContext context) {
    final problem = scopeProblem(widget.session);
    return FutureBuilder<List<Geofence>>(
      future: _fences,
      builder: (context, f) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _att,
        builder: (context, att) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: _visits,
          builder: (context, vis) => StreamBuilder<List<Map<String, dynamic>>>(
            stream: _acts,
            builder: (context, act) => StreamBuilder<List<Map<String, dynamic>>>(
              stream: _tasks,
              builder: (context, tasks) {
                final err = f.error ?? att.error ?? vis.error ?? act.error ?? tasks.error;
                if (err != null) return MessageView(icon: Icons.cloud_off_outlined, title: 'Could not load coverage', body: '$err');
                if (!f.hasData || !att.hasData || !vis.hasData || !act.hasData || !tasks.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final fences = f.data!;
                final rows = [
                  for (final fence in fences)
                    (
                      fence: fence,
                      present: att.data!.where((r) => (r['checkIn'] as Map?)?['geofenceId'] == fence.id).length,
                      visits: vis.data!.where((v) => v['geofenceId'] == fence.id).length,
                      workers: vis.data!.where((v) => v['geofenceId'] == fence.id).map((v) => v['uid']).toSet().length,
                      reports: act.data!.where((a) => a['geofenceId'] == fence.id || (a['areaPath'] as List?)?.lastOrNull == fence.areaId).length,
                      openTasks: tasks.data!
                          .where((t) => (t['areaPath'] as List?)?.lastOrNull == fence.areaId && ['assigned', 'in_progress', 'rework'].contains(t['status']))
                          .length,
                    ),
                ];
                final covered = rows.where((r) => r.visits > 0 || r.present > 0).length;
                return ListView(padding: const EdgeInsets.all(16), children: [
                  if (problem != null) NoticeCard(text: problem),
                  Text('Today · $covered of ${rows.length} streets covered', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Covered = at least one worker marked attendance or entered the street boundary today.',
                      style: TextStyle(color: AppColors.muted, fontSize: 13)),
                  const SizedBox(height: 12),
                  if (rows.isEmpty) const Text('No street boundaries in your scope yet (Setup → Boundaries).'),
                  for (final r in rows)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: Icon(r.visits > 0 || r.present > 0 ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: r.visits > 0 || r.present > 0 ? AppColors.success : AppColors.turmeric),
                        title: Text(r.fence.name),
                        subtitle: Text('${r.present} attendance · ${r.workers} worker(s), ${r.visits} visit(s) · ${r.reports} report(s) · ${r.openTasks} open task(s)'),
                      ),
                    ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- reports
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _DayRow {
  _DayRow(this.day, this.att, this.reports, this.approved, this.visits);
  final String day;
  final AttendanceSummary att;
  final int reports;
  final int approved;
  final int visits;
}

class _ReportsScreenState extends State<ReportsScreen> {
  late final Future<List<_DayRow>> _rows = _load();

  Future<List<_DayRow>> _load() async {
    final out = <_DayRow>[];
    final seesVisits = widget.session.role != Role.sysAdmin;
    for (var i = 0; i < 7; i++) {
      final day = dayKey(DateTime.now().subtract(Duration(days: i)));
      final att = await OfficerAttendance(widget.session).watch(day).first;
      final acts = await WorkRepository(widget.session).watchActivities(day).first;
      final visits = seesVisits ? await watchScoped(widget.session, 'visits', day: day).first : const <Map<String, dynamic>>[];
      out.add(_DayRow(day, AttendanceSummary.of(att), acts.length, acts.where((a) => a['status'] == 'approved').length, visits.length));
    }
    return out;
  }

  String _asText(List<_DayRow> rows) => [
        'Date,Present,Verified,To check,Late,Reports,Approved reports,Street visits',
        for (final r in rows)
          '${r.day},${r.att.present},${r.att.verified},${r.att.flagged},${r.att.late},${r.reports},${r.approved},${r.visits}',
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    final problem = scopeProblem(widget.session);
    return FutureBuilder<List<_DayRow>>(
      future: _rows,
      builder: (context, snap) {
        if (snap.hasError) return MessageView(icon: Icons.cloud_off_outlined, title: 'Could not build the report', body: '${snap.error}');
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final rows = snap.data!;
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (problem != null) NoticeCard(text: problem),
          Row(children: [
            const Expanded(child: Text('Last 7 days (your scope)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _asText(rows)));
                showToast('Copied as a table (CSV). Paste it into a spreadsheet, email or message.', kind: ToastKind.success);
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
          ]),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Date')),
                DataColumn(label: Text('Present'), numeric: true),
                DataColumn(label: Text('Verified'), numeric: true),
                DataColumn(label: Text('To check'), numeric: true),
                DataColumn(label: Text('Late'), numeric: true),
                DataColumn(label: Text('Reports'), numeric: true),
                DataColumn(label: Text('Approved'), numeric: true),
                DataColumn(label: Text('Visits'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(cells: [
                    DataCell(Text(r.day)),
                    DataCell(Text('${r.att.present}')),
                    DataCell(Text('${r.att.verified}')),
                    DataCell(Text('${r.att.flagged}')),
                    DataCell(Text('${r.att.late}')),
                    DataCell(Text('${r.reports}')),
                    DataCell(Text('${r.approved}')),
                    DataCell(Text('${r.visits}')),
                  ]),
              ],
            ),
          ),
        ]);
      },
    );
  }
}
