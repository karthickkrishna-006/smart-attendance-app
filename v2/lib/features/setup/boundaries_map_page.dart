import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/attendance_repository.dart';
import '../../data/directory.dart';
import '../../data/my_location.dart';
import '../../data/street_zones_repo.dart';
import '../../domain/geo.dart';
import '../../domain/street_zones.dart';
import '../monitor/live_map_view.dart';
import '../monitor/street_screens.dart' show CleaningZonesPage;

/// All boundaries on one map, with the phone's own live position, so the
/// person fixing boundaries can see exactly where they are, in real time.
class BoundariesMapPage extends StatefulWidget {
  const BoundariesMapPage({super.key, required this.dir});
  final Directory dir;
  @override
  State<BoundariesMapPage> createState() => _BoundariesMapPageState();
}

class _BoundariesMapPageState extends State<BoundariesMapPage> {
  final _map = LiveMapController();
  final _me = MyLocation.instance;
  late final _fences = widget.dir.geofences();
  Map<String, List<CleaningZone>> _zones = const {};
  String _zonesFor = '';
  bool _centred = false;

  @override
  void initState() {
    super.initState();
    _me.addListener(_onMove);
    _me.acquire().catchError((Object e) => showToast('$e', kind: ToastKind.error));
  }

  @override
  void dispose() {
    _me.removeListener(_onMove);
    _me.release();
    super.dispose();
  }

  void _onMove() {
    if (!mounted) return;
    if (!_centred && _me.at != null) {
      _centred = true;
      _map.moveTo(_me.at!, zoom: 17);
    }
    setState(() {});
  }

  Future<void> _loadZones(List<Geofence> fences) async {
    final key = fences.map((f) => f.id).join(',');
    if (key == _zonesFor) return;
    _zonesFor = key;
    try {
      final z = await StreetZonesRepo().forStreets(fences.map((f) => f.id));
      if (mounted) setState(() => _zones = z);
    } catch (_) {}
  }

  void _tapped(GeoPoint2 at, List<Geofence> fences) {
    final hit = fences.where((f) => f.check(at, 0).placement != Placement.outside).toList();
    if (hit.isEmpty) return;
    final f = hit.first;
    final zones = _zones[f.id] ?? const <CleaningZone>[];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(f.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${f.kind == GeofenceKind.circle ? 'Circle, ${f.radiusM?.round()} m' : '${f.ring.length} corners'} · '
                '${zones.length} cleaning zone(s)', style: const TextStyle(color: AppColors.muted)),
            if (_me.at != null) ...[
              const SizedBox(height: 6),
              Text(_statusText(_me.at!, _me.accuracyM ?? 0, [f]), style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(c);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CleaningZonesPage(admin: widget.dir.user, street: f)));
              },
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('Cleaning zones of this street'),
            ),
          ]),
        ),
      ),
    );
  }

  /// "You are inside X" / "Outside all boundaries, nearest: Y (45 m)".
  String _statusText(GeoPoint2 me, double acc, List<Geofence> fences) {
    final m = bestMatch(me, acc, fences);
    if (m == null) return 'No boundaries yet.';
    return switch (m.result.placement) {
      Placement.inside => 'You are inside: ${m.fence.name}',
      Placement.uncertain => 'You are at the edge of: ${m.fence.name} (GPS ±${acc.round()} m)',
      Placement.outside => 'Outside all boundaries · nearest: ${m.fence.name}, ${(-m.result.edgeDistanceM).round()} m away',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Boundaries map')),
        body: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _fences,
          builder: (context, snap) {
            final fences = [
              for (final f in snap.data ?? const <Map<String, dynamic>>[])
                if (AttendanceRepository.geofenceFromMap(f['id'] as String, f) case final Geofence g) g,
            ];
            if (fences.isNotEmpty) _loadZones(fences);
            final me = _me.at;
            final acc = _me.accuracyM ?? 0;
            final inside = me == null ? null : bestMatch(me, acc, fences);
            final allPoints = [for (final f in fences) ...(f.kind == GeofenceKind.circle ? [f.center!] : f.ring)];
            return Column(children: [
              // Live status: where am I, relative to the boundaries.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                color: inside != null && inside.result.placement == Placement.inside ? const Color(0xFFE3EFE9) : Colors.white,
                child: Row(children: [
                  Icon(Icons.my_location, color: me == null ? AppColors.muted : const Color(0xFF1A73E8)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        me == null ? (_me.problem ?? 'Finding your location…') : _statusText(me, acc, fences),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (me != null)
                        Text('LIVE · your position updates as you move · GPS ±${acc.round()} m',
                            style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                    ]),
                  ),
                ]),
              ),
              Expanded(
                child: Stack(children: [
                  LiveMapView(
                    center: me ?? (allPoints.isNotEmpty ? allPoints.first : const GeoPoint2(12.6919, 79.9762)),
                    zoom: 16,
                    controller: _map,
                    me: me,
                    meAccuracyM: acc,
                    onMapTap: (p) => _tapped(p, fences),
                    areas: [
                      for (final f in fences)
                        MapArea(
                          id: f.id,
                          ring: f.ring,
                          center: f.center,
                          radiusM: f.radiusM,
                          stroke: inside?.fence.id == f.id && inside!.result.placement != Placement.outside ? AppColors.success : AppColors.indigo,
                          fill: (inside?.fence.id == f.id && inside!.result.placement != Placement.outside ? AppColors.success : AppColors.indigo)
                              .withValues(alpha: 0.12),
                        ),
                    ],
                    dots: [
                      for (final z in _zones.values.expand((l) => l))
                        MapDot(id: z.id, at: z.center, radiusM: z.radiusM, fill: Colors.white.withValues(alpha: 0.6), stroke: AppColors.indigo),
                    ],
                  ),
                  Positioned(
                    right: 12,
                    bottom: 24,
                    child: Column(children: [
                      FloatingActionButton.small(
                        heroTag: 'fit',
                        tooltip: 'Show all boundaries',
                        onPressed: allPoints.isEmpty ? null : () => _map.fitAll(allPoints),
                        child: const Icon(Icons.fit_screen),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton(
                        heroTag: 'me',
                        tooltip: 'Centre on me',
                        onPressed: me == null ? null : () => _map.moveTo(me, zoom: 18),
                        child: const Icon(Icons.my_location),
                      ),
                    ]),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Text('${fences.length} boundaries · tap a boundary for details · green = the one you are in',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ),
            ]);
          },
        ),
      );
}
