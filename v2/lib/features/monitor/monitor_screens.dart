import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import 'live_map_view.dart';
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


// ------------------------------------------------------------ live monitoring
Color _stateColor(LiveState st) => switch (st) {
      LiveState.moving => AppColors.success,
      LiveState.stale => AppColors.turmeric,
      LiveState.offDuty => AppColors.muted,
    };

String _stateLabel(LiveState st) => switch (st) {
      LiveState.moving => 'Working',
      LiveState.stale => 'No update (10+ min)',
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
  final _map = LiveMapController();
  final _search = TextEditingController();
  List<GeoPoint2> _route = const [];
  Map<String, List<GeoPoint2>> _trails = const {};
  String? _selected;
  String? _areaFilter;
  String? _typeFilter;
  LiveState? _stateFilter;
  bool _live = true;
  bool _showTrails = true;
  DateTime? _lastData;
  DateTime _trailsAt = DateTime(2000);
  Timer? _ticker;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    // Keeps "… ago", colours and trails current between updates.
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && _live) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Recent path (last 30 min) of the visible workers, refreshed every minute.
  Future<void> _loadTrails(List<Map<String, dynamic>> people) async {
    if (!_showTrails || DateTime.now().difference(_trailsAt) < const Duration(seconds: 60)) return;
    _trailsAt = DateTime.now();
    final day = dayKey(DateTime.now());
    final since = DateTime.now().subtract(const Duration(minutes: 30));
    final out = <String, List<GeoPoint2>>{};
    for (final p in people.where((p) => p['onDuty'] == true).take(40)) {
      try {
        final r = await FirebaseFirestore.instance.doc('routes/${p['uid']}_$day').get();
        final pts = ((r.data()?['points'] as List?) ?? const []).whereType<Map>().toList();
        final recent = pts.where((m) => m['t'] is Timestamp && (m['t'] as Timestamp).toDate().isAfter(since)).toList();
        final use = recent.length > 1 ? recent : pts.skip(pts.length > 12 ? pts.length - 12 : 0).toList();
        out[p['uid'] as String] = [
          for (final m in use)
            if (m['lat'] is num && m['lng'] is num) GeoPoint2((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
          GeoPoint2((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
        ];
      } catch (_) {}
    }
    if (mounted) setState(() => _trails = out);
  }

  /// "Sri Ram Nagar · Zone 5": the street and the nearest cleaning zone.
  String _whereText(Map<String, dynamic> p, Map<String, String> fenceNames, Map<String, List<CleaningZone>> zones, List<Map<String, dynamic>> visits) {
    final fid = p['geofenceId'] as String?;
    if (fid == null) return p['onDuty'] == true ? 'Between streets' : 'Off duty';
    final here = (p['lat'] is num && p['lng'] is num) ? GeoPoint2((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()) : null;
    String zone = '';
    if (here != null) {
      CleaningZone? best;
      var bestD = 40.0;
      for (final z in zones[fid] ?? const <CleaningZone>[]) {
        final d = distanceM(here, z.center);
        if (d < bestD) {
          bestD = d;
          best = z;
        }
      }
      if (best != null) zone = ' · Zone ${best.order + 1}';
    }
    final open = visits.where((v) => v['uid'] == p['uid'] && v['geofenceId'] == fid && v['exitedAt'] == null).firstOrNull;
    final progress = open != null && (open['zonesTotal'] as num? ?? 0) > 0
        ? ' · ${((open['zonesDone'] as List?) ?? const []).length}/${open['zonesTotal']} zones'
        : '';
    return '${fenceNames[fid] ?? 'Street'}$zone$progress';
  }

  Future<void> _select(Map<String, dynamic> p, List<Map<String, dynamic>> visits, String where) async {
    final uid = p['uid'] as String;
    setState(() => _selected = uid);
    if (p['lat'] is num && p['lng'] is num) _map.moveTo(GeoPoint2((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()));
    try {
      final r = await FirebaseFirestore.instance.doc('routes/${uid}_${dayKey(DateTime.now())}').get();
      final pts = ((r.data()?['points'] as List?) ?? const [])
          .whereType<Map>()
          .where((m) => m['lat'] is num && m['lng'] is num)
          .map((m) => GeoPoint2((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()))
          .toList();
      if (mounted) setState(() => _route = pts);
    } catch (_) {}
    if (!mounted) return;
    final mine = visits.where((v) => v['uid'] == uid).toList();
    final st = _stateOf(p);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Row(children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: _stateColor(st),
              child: Text(initialsOf('${p['workerName'] ?? ''}'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['workerName'] ?? ''}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                if (Designation.fromKey(p['designation'] as String?) case final Designation d) Text(d.title, style: const TextStyle(color: AppColors.muted)),
              ]),
            ),
            _chip(st),
          ]),
          const SizedBox(height: 12),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.place_outlined), title: Text(where), subtitle: Text('Updated ${_ago(p['at'])}'
              '${p['accuracy'] is num ? ' · GPS ±${(p['accuracy'] as num).round()} m' : ''}${p['synthetic'] == true ? ' · sample' : ''}')),
          Text(_route.length > 1 ? 'Today\'s route is drawn on the map in blue.' : 'No route recorded today yet.', style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          const Text('Streets today (automatic check-in / check-out)', style: TextStyle(fontWeight: FontWeight.w700)),
          if (mine.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: Text('No street visits today yet.')),
          for (final v in mine)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.circle, size: 14, color: streetStatusColor(visitStatusOf(v))),
              title: Text('${v['geofenceName'] ?? v['geofenceId']}'),
              subtitle: Text('In ${shortDateTime(v['enteredAt'])} · '
                  '${v['exitedAt'] == null ? 'still there' : 'out ${shortDateTime(v['exitedAt'])} (${v['durationMin']} min)'}'
                  '${(v['zonesTotal'] as num? ?? 0) > 0 ? ' · zones ${((v['zonesDone'] as List?) ?? const []).length}/${v['zonesTotal']}' : ''}'),
            ),
        ]),
      ),
    );
  }

  Widget _chip(LiveState st) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: _stateColor(st).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
        child: Text(_stateLabel(st).split(' (').first, style: TextStyle(color: _stateColor(st), fontSize: 12, fontWeight: FontWeight.w700)),
      );

  Widget _kpi(String label, String value, IconData icon, Color color, String sub) => Container(
        width: 150,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppColors.ink)),
          Text(sub, style: TextStyle(fontSize: 11.5, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
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
                final zonesBy = zoneSnap.data ?? const <String, List<CleaningZone>>{};
                final all = snap.data ?? const <Map<String, dynamic>>[];
                final visits = visitSnap.data ?? const <Map<String, dynamic>>[];
                final newest = all.map((p) => p['at']).whereType<Timestamp>().map((t) => t.toDate()).fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
                if (newest != null) _lastData = newest;
                final fenceNames = {for (final f in fences) f.id: f.name};
                final counts = {for (final st in LiveState.values) st: all.where((p) => _stateOf(p) == st).length};
                final liveNow = all.where((p) => p['at'] is Timestamp && DateTime.now().difference((p['at'] as Timestamp).toDate()).inMinutes < 10).length;
                final streetStatus = <String, StreetVisitStatus?>{
                  for (final f in fences) f.id: streetStatusToday([for (final v in visits) if (v['geofenceId'] == f.id) visitStatusOf(v)]),
                };
                final zonesDoneToday = <String>{for (final v in visits) ...((v['zonesDone'] as List?) ?? const []).whereType<String>()};
                final q = _search.text.trim().toLowerCase();
                final people = all.where((p) {
                  if (_areaFilter != null && !(((p['areaPath'] as List?) ?? const []).contains(_areaFilter))) return false;
                  if (_typeFilter != null && p['designation'] != _typeFilter) return false;
                  if (_stateFilter != null && _stateOf(p) != _stateFilter) return false;
                  if (q.isNotEmpty) {
                    final hay = '${p['workerName'] ?? ''} ${fenceNames[p['geofenceId']] ?? ''}'.toLowerCase();
                    if (!hay.contains(q)) return false;
                  }
                  return p['lat'] is num && p['lng'] is num;
                }).toList()
                  ..sort((a, b) {
                    int rank(LiveState s) => switch (s) { LiveState.moving => 0, LiveState.stale => 1, LiveState.offDuty => 2 };
                    return rank(_stateOf(a)).compareTo(rank(_stateOf(b)));
                  });
                if (_showTrails && people.isNotEmpty) _loadTrails(people);
                final shownFences = _areaFilter == null ? fences : fences.where((f) => f.areaPath.contains(_areaFilter)).toList();
                final zones = [for (final f in shownFences) ...?zonesBy[f.id]];
                final points = [for (final p in people) GeoPoint2((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble())];
                if (!_fitted && points.isNotEmpty) {
                  _fitted = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) => _map.fitAll(points));
                }
                final GeoPoint2 centre = points.isNotEmpty
                    ? points.first
                    : shownFences.isNotEmpty
                        ? (shownFences.first.center ?? shownFences.first.ring.first)
                        : const GeoPoint2(12.6919, 79.9762);
                final whereBy = {for (final p in people) p['uid'] as String: _whereText(p, fenceNames, zonesBy, visits)};
                final secs = _lastData == null ? null : DateTime.now().difference(_lastData!).inSeconds;

                final map = ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(children: [
                    LiveMapView(
                      center: centre,
                      controller: _map,
                      route: _route,
                      onPinTap: (id) {
                        final p = people.where((x) => x['uid'] == id).firstOrNull;
                        if (p != null) _select(p, visits, whereBy[id] ?? '');
                      },
                      areas: [
                        for (final f in shownFences)
                          MapArea(
                            id: f.id,
                            ring: f.ring,
                            center: f.center,
                            radiusM: f.radiusM,
                            stroke: streetStatusColor(streetStatus[f.id]),
                            fill: streetStatusColor(streetStatus[f.id]).withValues(alpha: streetStatus[f.id] == null ? 0.06 : 0.22),
                          ),
                      ],
                      dots: [
                        for (final z in zones)
                          MapDot(
                            id: z.id,
                            at: z.center,
                            radiusM: z.radiusM,
                            fill: zonesDoneToday.contains(z.id) ? AppColors.success.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.7),
                            stroke: zonesDoneToday.contains(z.id) ? AppColors.success : AppColors.indigo,
                          ),
                      ],
                      pins: [
                        for (final p in people)
                          MapPin(
                            id: p['uid'] as String,
                            at: GeoPoint2((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
                            initials: initialsOf('${p['workerName'] ?? ''}'),
                            title: '${p['workerName'] ?? ''}',
                            snippet: '${whereBy[p['uid']]} · ${_ago(p['at'])}',
                            color: _stateColor(_stateOf(p)),
                            selected: p['uid'] == _selected,
                            trail: _showTrails ? (_trails[p['uid']] ?? const []) : const [],
                          ),
                      ],
                    ),
                    Positioned(
                      right: 10,
                      top: kGoogleMaps ? 60 : 10,
                      child: Column(children: [
                        _mapButton(Icons.fit_screen, 'Show everyone', () => _map.fitAll(points)),
                        const SizedBox(height: 8),
                        _mapButton(_showTrails ? Icons.timeline : Icons.timeline_outlined, _showTrails ? 'Hide routes' : 'Show routes', () {
                          setState(() {
                            _showTrails = !_showTrails;
                            _trailsAt = DateTime(2000);
                          });
                        }, active: _showTrails),
                      ]),
                    ),
                  ]),
                );

                final team = Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Text('Team status (${people.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    if (people.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('Nobody here yet. Workers appear after they tap "Start duty"; change the filters to see more.',
                            style: TextStyle(color: AppColors.muted)),
                      ),
                    for (final p in people)
                      ListTile(
                        onTap: () => _select(p, visits, whereBy[p['uid']] ?? ''),
                        leading: CircleAvatar(
                          backgroundColor: _stateColor(_stateOf(p)),
                          child: Text(initialsOf('${p['workerName'] ?? ''}'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                        title: Text('${p['workerName'] ?? 'Unnamed worker'}${p['synthetic'] == true ? ' (sample)' : ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${whereBy[p['uid']]}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          _chip(_stateOf(p)),
                          const SizedBox(height: 4),
                          Text(_ago(p['at']), style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                        ]),
                      ),
                  ]),
                );

                final filters = Wrap(spacing: 8, runSpacing: 8, children: [
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: 'Search worker or street',
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 180,
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
                      onChanged: (v) => setState(() {
                        _areaFilter = v;
                        _fitted = false;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<LiveState?>(
                      value: _stateFilter,
                      isExpanded: true,
                      isDense: true,
                      decoration: const InputDecoration(labelText: 'Status', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                      items: [
                        const DropdownMenuItem<LiveState?>(value: null, child: Text('All statuses')),
                        for (final st in LiveState.values) DropdownMenuItem<LiveState?>(value: st, child: Text(_stateLabel(st))),
                      ],
                      onChanged: (v) => setState(() => _stateFilter = v),
                    ),
                  ),
                  SizedBox(
                    width: 200,
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
                ]);

                final kpis = SizedBox(
                  height: 122,
                  child: ListView(scrollDirection: Axis.horizontal, children: [
                    _kpi('Working', '${counts[LiveState.moving]}', Icons.directions_walk, AppColors.success, 'on duty, updated < 10 min'),
                    _kpi('No update', '${counts[LiveState.stale]}', Icons.signal_wifi_statusbar_connected_no_internet_4, AppColors.turmeric, 'on duty, silent 10+ min'),
                    _kpi('Off duty', '${counts[LiveState.offDuty]}', Icons.pause_circle_outline, AppColors.muted, 'duty stopped'),
                    _kpi('Live now', '$liveNow', Icons.monitor_heart_outlined, AppColors.indigo, secs == null ? 'waiting for updates' : 'last update ${secs < 60 ? '$secs s' : '${secs ~/ 60} min'} ago'),
                    Container(
                      width: 170,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Expanded(child: Text('Live tracking', style: TextStyle(fontWeight: FontWeight.w600))),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: (_live ? AppColors.success : AppColors.muted).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                            child: Text(_live ? '● LIVE' : 'PAUSED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _live ? AppColors.success : AppColors.muted)),
                          ),
                        ]),
                        const Spacer(),
                        Row(children: [
                          const Expanded(child: Text('Auto-refresh every 10 s', style: TextStyle(fontSize: 11.5, color: AppColors.muted))),
                          Switch(value: _live, onChanged: (v) => setState(() => _live = v)),
                        ]),
                      ]),
                    ),
                  ]),
                );

                final summary = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
                  child: Wrap(spacing: 18, runSpacing: 6, alignment: WrapAlignment.spaceAround, children: [
                    for (final st in LiveState.values)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.circle, size: 10, color: _stateColor(st)),
                        Text(' ${_stateLabel(st).split(' (').first}  ', style: const TextStyle(fontSize: 13)),
                        Text('${counts[st]}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.groups_outlined, size: 16, color: AppColors.indigo),
                      const Text(' Total  ', style: TextStyle(fontSize: 13)),
                      Text('${all.length}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                  ]),
                );

                final legend = Wrap(spacing: 10, children: [
                  const Text('Streets:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  for (final s in [StreetVisitStatus.completed, StreetVisitStatus.inProgress, StreetVisitStatus.incomplete, null])
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.square_rounded, size: 12, color: streetStatusColor(s)),
                      Text(' ${streetStatusLabel(s)}', style: const TextStyle(fontSize: 12)),
                    ]),
                ]);

                return LayoutBuilder(builder: (context, box) {
                  final wide = box.maxWidth >= 900;
                  final header = <Widget>[
                    if (problem != null) NoticeCard(text: problem),
                    kpis,
                    const SizedBox(height: 12),
                    filters,
                    const SizedBox(height: 8),
                    legend,
                    const SizedBox(height: 8),
                  ];
                  if (wide) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        ...header,
                        Expanded(
                          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Expanded(child: map),
                            const SizedBox(width: 12),
                            SizedBox(width: 340, child: SingleChildScrollView(child: team)),
                          ]),
                        ),
                        const SizedBox(height: 10),
                        summary,
                      ]),
                    );
                  }
                  return ListView(padding: const EdgeInsets.all(12), children: [
                    ...header,
                    SizedBox(height: 380, child: map),
                    const SizedBox(height: 10),
                    summary,
                    const SizedBox(height: 10),
                    team,
                  ]);
                });
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _mapButton(IconData icon, String tip, VoidCallback onTap, {bool active = false}) => Material(
        color: active ? AppColors.green : Colors.white,
        elevation: 2,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Tooltip(
            message: tip,
            child: Padding(padding: const EdgeInsets.all(9), child: Icon(icon, size: 22, color: active ? Colors.white : AppColors.ink)),
          ),
        ),
      );
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
