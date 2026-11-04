import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/fmt.dart';
import '../../core/geo.dart';
import '../../core/osm_map.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';
import 'boundaries_screen.dart';
import 'worker_detail_screen.dart';

/// Real-time GIS map: OpenStreetMap + boundary polygons + live worker positions
/// streamed from Firestore `locations` as workers move.
class LiveMapScreen extends StatefulWidget {
  final AppUser me;
  final bool standalone;
  const LiveMapScreen({super.key, required this.me, this.standalone = false});
  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _map = MapController();
  String _filter = 'all';
  bool _showBoundaries = true;
  bool _centered = false;
  LatLng? _me;

  bool _stale(Doc l) {
    final t = toDate(l['updatedAt']);
    return t == null || DateTime.now().difference(t).inMinutes > 15;
  }

  Color _color(Doc l) {
    if (l['onDuty'] != true || _stale(l)) return Colors.grey;
    if (l['mocked'] == true) return AppColors.demo;
    if (l['geoStatus'] == 'outside') return AppColors.danger;
    if (l['geoStatus'] == 'inside') return AppColors.success;
    return AppColors.warning;
  }

  Future<void> _locateMe() async {
    try {
      final p = await LocationService.current();
      final ll = LatLng(p.latitude, p.longitude);
      setState(() => _me = ll);
      _map.move(ll, 16);
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    }
  }

  void _fit(List<LatLng> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, 15);
      return;
    }
    _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(50)));
  }

  void _showWorker(Doc l, Map<String, Boundary> bById) {
    final b = bById[l['boundaryId']];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AvatarCircle(name: l['name'] ?? '', radius: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(l['name'] ?? 'Worker', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            if (l['synthetic'] == true) const DemoBadge(),
          ]),
          const SizedBox(height: 12),
          InfoRow(Icons.circle, 'Status', l['onDuty'] == true ? (_stale(l) ? 'On duty · signal stale' : 'On duty') : 'Off duty', color: _color(l)),
          InfoRow(Icons.layers_outlined, 'Boundary', b?.name ?? 'Not assigned'),
          InfoRow(Icons.rule, 'GIS result', titleCase(l['geoStatus'] ?? 'n/a'), color: statusColor(l['geoStatus'])),
          InfoRow(Icons.gps_fixed, 'Accuracy', '±${asDouble(l['accuracy']).toStringAsFixed(0)} m'),
          InfoRow(Icons.place_outlined, 'Coordinates', '${asDouble(l['lat']).toStringAsFixed(5)}, ${asDouble(l['lng']).toStringAsFixed(5)}'),
          InfoRow(Icons.update, 'Last update', '${fmtDateTime(l['updatedAt'])} (${ago(l['updatedAt'])})'),
          if (l['mocked'] == true) const InfoRow(Icons.gpp_bad_outlined, 'Warning', 'Mock location detected', color: AppColors.danger),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(c);
                Navigator.push(context, MaterialPageRoute(builder: (_) => WorkerDetailScreen(uid: l['id'], me: widget.me)));
              },
              icon: const Icon(Icons.person_search_outlined),
              label: const Text('Open worker profile'),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live GIS map'),
        automaticallyImplyLeading: widget.standalone,
        actions: [
          if (widget.me.isStaff)
            IconButton(
              tooltip: 'Manage boundaries',
              icon: const Icon(Icons.polyline_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BoundariesScreen(me: widget.me))),
            ),
        ],
      ),
      body: LiveQueries(
        queries: [Db.col('locations'), Db.col('boundaries')],
        builder: (context, d) {
          final locs = d[0].where((l) => l['lat'] != null && l['lng'] != null).toList();
          final boundaries = d[1].map(Boundary.fromDoc).where((b) => b.points.length >= 3).toList();
          final bById = {for (final b in boundaries) b.id: b};
          final shown = locs.where((l) {
            switch (_filter) {
              case 'on_duty':
                return l['onDuty'] == true && !_stale(l);
              case 'outside':
                return l['geoStatus'] == 'outside';
              default:
                return true;
            }
          }).toList();
          final allPts = [
            ...shown.map((l) => LatLng(asDouble(l['lat']), asDouble(l['lng']))),
            ...boundaries.expand((b) => b.points),
          ];
          if (!_centered && allPts.isNotEmpty) {
            _centered = true;
            WidgetsBinding.instance.addPostFrameCallback((_) => _fit(allPts));
          }
          final center = allPts.isNotEmpty ? allPts.first : const LatLng(12.6919, 79.9762);
          return Stack(children: [
            OsmMap(
              controller: _map,
              center: center,
              zoom: 13,
              layers: [
                if (_showBoundaries) PolygonLayer(polygons: boundaries.map((b) => boundaryPolygon(b)).toList()),
                CircleLayer(
                  circles: shown
                      .map((l) => CircleMarker(
                            point: LatLng(asDouble(l['lat']), asDouble(l['lng'])),
                            radius: asDouble(l['accuracy'], 10),
                            useRadiusInMeter: true,
                            color: _color(l).withValues(alpha: 0.12),
                          ))
                      .toList(),
                ),
                MarkerLayer(markers: [
                  ...shown.map((l) => Marker(
                        point: LatLng(asDouble(l['lat']), asDouble(l['lng'])),
                        width: 120,
                        height: 58,
                        child: GestureDetector(
                          onTap: () => _showWorker(l, bById),
                          child: Column(children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)]),
                              child: Text((l['name'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
                            ),
                            const SizedBox(height: 2),
                            Icon(Icons.person_pin_circle, color: _color(l), size: 32),
                          ]),
                        ),
                      )),
                  if (_me != null) Marker(point: _me!, width: 20, height: 20, child: const MyLocationDot()),
                ]),
              ],
            ),
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(children: [
                    for (final f in ['all', 'on_duty', 'outside'])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text({'all': 'All (${locs.length})', 'on_duty': 'On duty', 'outside': 'Outside'}[f]!),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Toggle boundaries',
                      onPressed: () => setState(() => _showBoundaries = !_showBoundaries),
                      icon: Icon(_showBoundaries ? Icons.layers : Icons.layers_clear),
                    ),
                  ]),
                ),
              ),
            ),
            Positioned(
              left: 10,
              bottom: 30,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Legend(AppColors.success, 'Inside boundary'),
                    const SizedBox(height: 4),
                    const Legend(AppColors.danger, 'Outside boundary'),
                    const SizedBox(height: 4),
                    const Legend(AppColors.warning, 'Unverified'),
                    const SizedBox(height: 4),
                    const Legend(Colors.grey, 'Off duty / stale'),
                    if (boundaries.any((b) => b.synthetic)) ...[const SizedBox(height: 6), const DemoBadge()],
                  ]),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 30,
              child: Column(children: [
                FloatingActionButton.small(heroTag: 'fit', onPressed: () => _fit(allPts), child: const Icon(Icons.zoom_out_map)),
                const SizedBox(height: 10),
                FloatingActionButton.small(heroTag: 'me', onPressed: _locateMe, child: const Icon(Icons.my_location)),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

LatLng boundaryCenter(Boundary b) => centroid(b.points);
