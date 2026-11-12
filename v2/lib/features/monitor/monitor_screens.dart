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
import '../../data/street_zones_repo.dart';
import '../../data/work_repository.dart';
import '../../domain/attendance.dart';
import '../../domain/attendance_summary.dart';
import '../../domain/designations.dart';
import '../../domain/geo.dart';
import '../../domain/live_update.dart';
import '../../domain/roles.dart';
import '../../domain/street_zones.dart';
import '../work/worker_work_screens.dart' show shortDateTime;
import 'street_screens.dart' show streetStatusColor, streetStatusLabel, visitStatusOf;

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

const _defaultCentre = LatLng(12.6919, 79.9762);

// ------------------------------------------------------------ live monitoring
Color _stateColor(LiveState st) => switch (st) {
      LiveState.moving => AppColors.success,
      LiveState.stale => AppColors.turmeric,
      LiveState.offDuty => AppColors.muted,
    };

String _stateLabel(LiveState st) => switch (st) {
      LiveState.moving => 'Moving now',
      LiveState.stale => 'No update 10+ min',
      LiveState.offDuty => 'Off duty',
    };

LiveState _stateOf(Map<String, dynamic> p) =>
    liveStateOf(onDuty: p['onDuty'] == true, at: p['at'] is Timestamp ? (p['at'] as Timestamp).toDate() : null, now: DateTime.now());

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
  late final Future<List<Map<String, dynamic>>> _areas = WorkRepository(widget.session).areasInScope();
  late final Future<Map<String, List<CleaningZone>>> _zones =
      _fences.then((f) => StreetZonesRepo().forStreets(f.map((x) => x.id))).catchError((Object _) => <String, List<CleaningZone>>{});
  final _map = MapController();
  List<LatLng> _route = const [];
  String? _selected;
  String? _areaFilter;
  String? _typeFilter;
  LiveState? _stateFilter;

  Future<void> _select(Map<String, dynamic> p, List<Map<String, dynamic>> visits) async {
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
    final st = _stateOf(p);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('${p['workerName'] ?? ''}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          if (Designation.fromKey(p['designation'] as String?) case final Designation d) Text(d.title, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.circle, size: 12, color: _stateColor(st)),
            const SizedBox(width: 6),
            Text('${_stateLabel(st)} · last update ${_ago(p['at'])}'
                '${p['accuracy'] is num ? ' · ±${(p['accuracy'] as num).round()} m' : ''}${p['synthetic'] == true ? ' · demo' : ''}'),
          ]),
          const SizedBox(height: 4),
          Text(_route.length > 1 ? 'Today\'s route is drawn on the map (${_route.length} points).' : 'No route recorded today yet.',
              style: const TextStyle(color: AppColors.muted)),
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

  Widget _legendChip(LiveState st, int n) => FilterChip(
        avatar: Icon(Icons.circle, size: 14, color: _stateColor(st)),
        label: Text('${_stateLabel(st)} ($n)'),
        selected: _stateFilter == st,
        onSelected: (v) => setState(() => _stateFilter = v ? st : null),
      );

  @override
  Widget build(BuildContext context) {
    final problem = scopeProblem(widget.session);
    return FutureBuilder<Map<String, List<CleaningZone>>>(
      future: _zones,
      builder: (context, zoneSnap) => FutureBuilder<List<Map<String, dynamic>>>(
      future: _areas,
      builder: (context, areaSnap) => FutureBuilder<List<Geofence>>(
        future: _fences,
        builder: (context, fenceSnap) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: _visits,
          builder: (context, visitSnap) => StreamBuilder<List<Map<String, dynamic>>>(
            stream: _presence,
            builder: (context, snap) {
              final areas = areaSnap.data ?? const <Map<String, dynamic>>[];
              final fences = fenceSnap.data ?? const <Geofence>[];
              final all = snap.data ?? const <Map<String, dynamic>>[];
              final visits = visitSnap.data ?? const <Map<String, dynamic>>[];
              final names = {for (final f in fences) f.id: f.name};
              final counts = {for (final st in LiveState.values) st: all.where((p) => _stateOf(p) == st).length};
              // Street colours from today's automatic check-ins/check-outs.
              final streetStatus = <String, StreetVisitStatus?>{
                for (final f in fences) f.id: streetStatusToday([for (final v in visits) if (v['geofenceId'] == f.id) visitStatusOf(v)]),
              };
              final zonesDoneToday = <String>{for (final v in visits) ...((v['zonesDone'] as List?) ?? const []).whereType<String>()};
              final zones = [for (final f in fences) ...?zoneSnap.data?[f.id]];
              Color fill(Geofence f) => streetStatusColor(streetStatus[f.id]).withValues(alpha: streetStatus[f.id] == null ? 0.05 : 0.22);
              Color edge(Geofence f) => streetStatusColor(streetStatus[f.id]);
              final people = all.where((p) {
                if (_areaFilter != null && !(((p['areaPath'] as List?) ?? const []).contains(_areaFilter))) return false;
                if (_typeFilter != null && p['designation'] != _typeFilter) return false;
                if (_stateFilter != null && _stateOf(p) != _stateFilter) return false;
                return true;
              }).toList()
                ..sort((a, b) {
                  int rank(LiveState s) => switch (s) { LiveState.stale => 0, LiveState.moving => 1, LiveState.offDuty => 2 };
                  return rank(_stateOf(a)).compareTo(rank(_stateOf(b)));
                });
              final shownFences = _areaFilter == null ? fences : fences.where((f) => f.areaPath.contains(_areaFilter)).toList();
              final located = people.where((p) => p['lat'] is num && p['lng'] is num).toList();
              final centre = located.isNotEmpty
                  ? LatLng((located.first['lat'] as num).toDouble(), (located.first['lng'] as num).toDouble())
                  : shownFences.isNotEmpty
                      ? LatLng(shownFences.first.center?.lat ?? shownFences.first.ring.first.lat,
                          shownFences.first.center?.lng ?? shownFences.first.ring.first.lng)
                      : _defaultCentre;
              return Column(children: [
                if (problem != null) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: NoticeCard(text: problem)),
                if (snap.hasError) Padding(padding: const EdgeInsets.all(12), child: Text('${snap.error}', style: const TextStyle(color: AppColors.danger))),
                // Filters
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        value: _areaFilter,
                        isExpanded: true,
                        isDense: true,
                        decoration: const InputDecoration(labelText: 'Area', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('All areas')),
                          for (final a in areas)
                            DropdownMenuItem<String?>(
                              value: a['id'] as String,
                              child: Text('${'  ' * ((((a['path'] as List?)?.length ?? 1) - 1).clamp(0, 6))}${a['name']}', overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) => setState(() => _areaFilter = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        value: _typeFilter,
                        isExpanded: true,
                        isDense: true,
                        decoration: const InputDecoration(labelText: 'Staff type', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('All staff')),
                          for (final d in Designation.values.where((d) => d.role == Role.worker))
                            DropdownMenuItem<String?>(value: d.key, child: Text(d.title, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) => setState(() => _typeFilter = v),
                      ),
                    ),
                  ]),
                ),
                SizedBox(
                  height: 44,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), children: [
                    for (final st in LiveState.values) Padding(padding: const EdgeInsets.only(right: 6), child: _legendChip(st, counts[st] ?? 0)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                  child: Wrap(spacing: 12, runSpacing: 2, children: [
                    const Text('Streets:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    for (final s in [StreetVisitStatus.completed, StreetVisitStatus.inProgress, StreetVisitStatus.incomplete, null])
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.square_rounded, size: 12, color: streetStatusColor(s)),
                        Text(' ${streetStatusLabel(s)}', style: const TextStyle(fontSize: 12)),
                      ]),
                    const Text('· zone circles turn green when cleaned', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                  ]),
                ),
                SizedBox(
                  height: 320,
                  child: FlutterMap(
                    mapController: _map,
                    options: MapOptions(initialCenter: centre, initialZoom: 15),
                    children: [
                      TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'in.cit.smartattendance.v2'),
                      CircleLayer(circles: [
                        for (final f in shownFences.where((f) => f.kind == GeofenceKind.circle))
                          CircleMarker(
                            point: LatLng(f.center!.lat, f.center!.lng),
                            radius: f.radiusM!,
                            useRadiusInMeter: true,
                            color: fill(f),
                            borderColor: edge(f),
                            borderStrokeWidth: 2.5,
                          ),
                      ]),
                      PolygonLayer(polygons: [
                        for (final f in shownFences.where((f) => f.kind == GeofenceKind.polygon))
                          Polygon(
                            points: [for (final p in f.ring) LatLng(p.lat, p.lng)],
                            color: fill(f),
                            borderColor: edge(f),
                            borderStrokeWidth: 2.5,
                          ),
                      ]),
                      CircleLayer(circles: [
                        for (final z in zones.where((z) => shownFences.any((f) => f.id == z.streetFenceId)))
                          CircleMarker(
                            point: LatLng(z.center.lat, z.center.lng),
                            radius: z.radiusM,
                            useRadiusInMeter: true,
                            color: zonesDoneToday.contains(z.id) ? AppColors.success.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.6),
                            borderColor: zonesDoneToday.contains(z.id) ? AppColors.success : AppColors.indigo,
                            borderStrokeWidth: 1.5,
                          ),
                      ]),
                      if (_route.length > 1) PolylineLayer(polylines: [Polyline(points: _route, strokeWidth: 4, color: AppColors.indigo)]),
                      MarkerLayer(markers: [
                        for (final p in located)
                          Marker(
                            point: LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
                            width: 96,
                            height: 58,
                            child: GestureDetector(
                              onTap: () => _select(p, visits),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.person_pin_circle, size: 34, color: p['uid'] == _selected ? AppColors.indigo : _stateColor(_stateOf(p))),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(4)),
                                  child: Text(
                                    '${(p['workerName'] as String? ?? '').split(' ').first}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, color: AppColors.ink),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                      ]),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(children: [
                    Text('${people.length} shown of ${all.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    const Text('© OpenStreetMap', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                  ]),
                ),
                Expanded(
                  child: people.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Nobody matches. Workers appear here after they tap "Start duty"; change the filters to see more.',
                                textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
                          ),
                        )
                      : ListView(children: [
                          for (final p in people)
                            ListTile(
                              onTap: () {
                                if (p['lat'] is num && p['lng'] is num) {
                                  _map.move(LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()), 17);
                                }
                                _select(p, visits);
                              },
                              leading: Icon(Icons.circle, size: 14, color: _stateColor(_stateOf(p))),
                              title: Text('${p['workerName'] ?? 'Unnamed worker'}${p['synthetic'] == true ? ' (demo)' : ''}'),
                              subtitle: Text([
                                if (Designation.fromKey(p['designation'] as String?) case final Designation d) d.title,
                                if (p['geofenceId'] != null) 'in ${names[p['geofenceId']] ?? 'a street'}',
                                '${_stateLabel(_stateOf(p))} · ${_ago(p['at'])}',
                              ].join(' · ')),
                              trailing: const Icon(Icons.route),
                            ),
                        ]),
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
