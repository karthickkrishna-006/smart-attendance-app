import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/fmt.dart';
import '../../core/osm_map.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import 'activity_tile.dart';

/// One worker's movement on one day: every field-duty session as a coloured
/// line, with start/end points and the places where activity photos were
/// taken. Reads only what the security rules allow for the viewer's role.
class RouteScreen extends StatefulWidget {
  final AppUser me;
  final String workerUid;
  final String workerName;
  final DateTime? day;
  const RouteScreen({super.key, required this.me, required this.workerUid, required this.workerName, this.day});
  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  late DateTime _day = widget.day ?? DateTime.now();
  final _map = MapController();
  String? _fittedFor;

  static const _palette = [AppColors.info, AppColors.teal, AppColors.demo, AppColors.warning, AppColors.navy];

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    setState(() => _day = next);
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _day = d);
  }

  void _fit(List<LatLng> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, 16);
      return;
    }
    _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(40)));
  }

  Future<void> _showActivity(Doc point) async {
    final id = point['activityId'] as String?;
    if (id == null) return;
    Doc? activity;
    try {
      final d = await Db.col('activities').doc(id).get();
      if (d.exists) activity = {...d.data()!, 'id': d.id};
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: activity == null
              ? const EmptyView(icon: Icons.photo_camera_outlined, title: 'Activity not available')
              : SingleChildScrollView(child: ActivityTile(a: activity, me: widget.me, showTask: true)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final day = dayKey(_day);
    final sessQ = Db.trackingQuery('tracking_sessions', widget.me, workerUid: widget.workerUid)?.where('date', isEqualTo: day);
    final pointsQ = Db.trackingQuery('worker_location_updates', widget.me, workerUid: widget.workerUid)?.where('date', isEqualTo: day);
    final isToday = DateUtils.isSameDay(_day, DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workerUid == widget.me.uid ? 'My route' : 'Route · ${widget.workerName}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Previous day', onPressed: () => _shiftDay(-1), icon: const Icon(Icons.chevron_left, color: Colors.white)),
            TextButton.icon(
              onPressed: _pickDay,
              icon: const Icon(Icons.calendar_today, size: 16, color: Colors.white),
              label: Text(isToday ? 'Today · ${fmtDate(_day)}' : fmtDate(_day), style: const TextStyle(color: Colors.white)),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: isToday ? null : () => _shiftDay(1),
              icon: Icon(Icons.chevron_right, color: isToday ? Colors.white38 : Colors.white),
            ),
          ]),
        ),
      ),
      body: sessQ == null
          ? const EmptyView(icon: Icons.lock_outline, title: 'Not available for your role')
          : LiveQueries(
              queryKey: '$day/${widget.workerUid}',
              queries: [sessQ, pointsQ],
              builder: (context, d) => _body(d[0], d[1], pointsQ != null),
            ),
    );
  }

  Widget _body(List<Doc> sessions, List<Doc> points, bool canSeeRoute) {
    sessions.sort((a, b) => (toDate(a['startedAt']) ?? DateTime(0)).compareTo(toDate(b['startedAt']) ?? DateTime(0)));
    points.sort((a, b) => (toDate(a['gpsTime']) ?? DateTime(0)).compareTo(toDate(b['gpsTime']) ?? DateTime(0)));
    final colorOf = <String, Color>{
      for (int i = 0; i < sessions.length; i++) sessions[i]['id'] as String: _palette[i % _palette.length],
    };
    final track = points.where((p) => p['kind'] != 'activity').toList();
    final activities = points.where((p) => p['kind'] == 'activity').toList();
    final bySession = <String, List<LatLng>>{};
    for (final p in track) {
      bySession.putIfAbsent((p['sessionId'] ?? '') as String, () => []).add(LatLng(asDouble(p['lat']), asDouble(p['lng'])));
    }
    final allPts = points.map((p) => LatLng(asDouble(p['lat']), asDouble(p['lng']))).toList();
    final fitKey = '${dayKey(_day)}/${points.length}';
    if (allPts.isNotEmpty && _fittedFor != fitKey) {
      _fittedFor = fitKey;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit(allPts));
    }
    final boundaryId = sessions.isNotEmpty ? sessions.last['boundaryId'] as String? : null;
    final outside = track.where((p) => p['geoStatus'] == 'outside').length;

    final summary = ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 16), children: [
      if (!canSeeRoute)
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline, color: AppColors.info),
            title: Text('Duty summaries only'),
            subtitle: Text('Auditors can review duty records, but not live positions or movement routes.'),
          ),
        ),
      if (sessions.isEmpty)
        const EmptyView(icon: Icons.route_outlined, title: 'No field duty on this day')
      else ...[
        if (canSeeRoute && track.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${track.length} location points · ${activities.length} activity photos'
              '${outside > 0 ? ' · $outside outside the assigned area' : ''}',
              style: const TextStyle(color: AppColors.muted),
            ),
          ),
        ...sessions.map((s) => _sessionTile(s, colorOf[s['id']] ?? AppColors.info)),
      ],
    ]);

    if (!canSeeRoute) return summary;
    return Column(children: [
      Expanded(
        flex: 3,
        child: OsmMap(
          controller: _map,
          center: allPts.isNotEmpty ? allPts.first : const LatLng(12.6919, 79.9762),
          zoom: 14,
          layers: [
            if (boundaryId != null) _BoundaryLayer(boundaryId: boundaryId),
            PolylineLayer(polylines: [
              for (final e in bySession.entries)
                if (e.value.length >= 2) Polyline(points: e.value, strokeWidth: 4, color: colorOf[e.key] ?? AppColors.info),
            ]),
            MarkerLayer(markers: [
              for (final e in bySession.entries) ...[
                _dot(e.value.first, AppColors.success, Icons.play_arrow),
                if (e.value.length > 1) _dot(e.value.last, AppColors.danger, Icons.stop),
              ],
              for (final a in activities)
                Marker(
                  point: LatLng(asDouble(a['lat']), asDouble(a['lng'])),
                  width: 36,
                  height: 36,
                  child: GestureDetector(
                    onTap: () => _showActivity(a),
                    child: const CircleAvatar(
                      backgroundColor: AppColors.teal,
                      child: Icon(Icons.photo_camera, size: 18, color: Colors.white),
                    ),
                  ),
                ),
            ]),
          ],
        ),
      ),
      Expanded(flex: 2, child: summary),
    ]);
  }

  Marker _dot(LatLng p, Color c, IconData icon) => Marker(
        point: p,
        width: 26,
        height: 26,
        child: Container(
          decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
          child: Icon(icon, size: 14, color: Colors.white),
        ),
      );

  Widget _sessionTile(Doc s, Color c) {
    final points = (s['pointCount'] as num?)?.toInt() ?? 0;
    final inside = (s['insideCount'] as num?)?.toInt() ?? 0;
    final active = s['status'] == 'active';
    return Card(
      child: ListTile(
        leading: CircleAvatar(backgroundColor: c.withValues(alpha: 0.15), child: Icon(Icons.timeline, color: c)),
        title: Text('${fmtTime(s['startedAt'])} – ${active ? 'now' : fmtTime(s['endedAt'])}'),
        subtitle: Text(
          '${(asDouble(s['distanceM']) / 1000).toStringAsFixed(2)} km · $points points'
          '${points > 0 ? ' · ${(inside * 100 / points).round()}% in area' : ''}'
          '${!active && s['endReason'] != null ? ' · ${titleCase(s['endReason'] as String)}' : ''}',
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (s['synthetic'] == true) const DemoBadge(),
          StatusChip(active ? 'active' : 'ended', label: active ? 'On duty' : 'Ended'),
        ]),
      ),
    );
  }
}

/// Draws one boundary polygon (loaded once by ID) on the map.
class _BoundaryLayer extends StatefulWidget {
  final String boundaryId;
  const _BoundaryLayer({required this.boundaryId});
  @override
  State<_BoundaryLayer> createState() => _BoundaryLayerState();
}

class _BoundaryLayerState extends State<_BoundaryLayer> {
  late Future<Boundary?> _future = Db.getBoundary(widget.boundaryId);

  @override
  void didUpdateWidget(covariant _BoundaryLayer old) {
    super.didUpdateWidget(old);
    if (old.boundaryId != widget.boundaryId) _future = Db.getBoundary(widget.boundaryId);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Boundary?>(
        future: _future,
        builder: (context, snap) {
          final b = snap.data;
          if (b == null || b.points.length < 3) return const SizedBox.shrink();
          return PolygonLayer(polygons: [boundaryPolygon(b, highlight: true)]);
        },
      );
}
