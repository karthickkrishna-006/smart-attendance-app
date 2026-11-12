import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/scoped.dart';
import '../../data/session_controller.dart';
import '../../data/street_zones_repo.dart';
import '../../domain/attendance.dart';
import '../../domain/geo.dart';
import '../../domain/street_zones.dart';

String _hm(Object? t) {
  if (t is! Timestamp) return '–';
  final d = t.toDate().toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

StreetVisitStatus visitStatusOf(Map<String, dynamic> v) => streetVisitStatus(
      checkedOut: v['exitedAt'] != null,
      zonesTotal: (v['zonesTotal'] as num?)?.toInt() ?? 0,
      zonesDone: ((v['zonesDone'] as List?) ?? const []).length,
    );

Color streetStatusColor(StreetVisitStatus? s) => switch (s) {
      StreetVisitStatus.completed => AppColors.success,
      StreetVisitStatus.inProgress => AppColors.turmeric,
      StreetVisitStatus.incomplete => AppColors.danger,
      null => AppColors.muted,
    };

String streetStatusLabel(StreetVisitStatus? s) => switch (s) {
      StreetVisitStatus.completed => 'Completed',
      StreetVisitStatus.inProgress => 'In progress',
      StreetVisitStatus.incomplete => 'Left incomplete',
      null => 'Not visited',
    };

/// Officers: automatic street check-in and check-out, with zones reached.
class StreetVisitsScreen extends StatefulWidget {
  const StreetVisitsScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<StreetVisitsScreen> createState() => _StreetVisitsScreenState();
}

class _StreetVisitsScreenState extends State<StreetVisitsScreen> {
  DateTime _day = DateTime.now();
  late Stream<List<Map<String, dynamic>>> _stream = _watch();
  StreetVisitStatus? _filter;

  Stream<List<Map<String, dynamic>>> _watch() => watchScoped(widget.session, 'visits', day: dayKey(_day), sort: newestFirst('enteredAt'));

  void _shift(int d) {
    final next = _day.add(Duration(days: d));
    if (next.isAfter(DateTime.now())) return;
    setState(() {
      _day = next;
      _stream = _watch();
    });
  }

  String _csv(List<Map<String, dynamic>> list) => [
        'Worker,Street,Check-in,Check-out,Minutes,Zones done,Zones total,Status',
        for (final v in list)
          '${v['workerName']},${v['geofenceName']},'
              '${_hm(v['enteredAt'])},${_hm(v['exitedAt'])},${v['durationMin'] ?? ''},'
              '${((v['zonesDone'] as List?) ?? const []).length},${v['zonesTotal'] ?? 0},${streetStatusLabel(visitStatusOf(v))}',
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    final isToday = dayKey(_day) == dayKey(DateTime.now());
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final all = snap.data ?? const <Map<String, dynamic>>[];
        final counts = {for (final s in StreetVisitStatus.values) s: all.where((v) => visitStatusOf(v) == s).length};
        final shown = _filter == null ? all : all.where((v) => visitStatusOf(v) == _filter).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (scopeProblem(widget.session) != null) NoticeCard(text: scopeProblem(widget.session)!),
          Row(children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text(isToday ? 'Today · ${dayKey(_day)}' : dayKey(_day),
                  textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            IconButton(onPressed: isToday ? null : () => _shift(1), icon: const Icon(Icons.chevron_right)),
          ]),
          const Text('Check-in and check-out are recorded automatically: in 1 minute after entering a street boundary, '
              'out 2 minutes after leaving it (the times shown are when they actually entered and left).',
              style: TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final s in StreetVisitStatus.values)
              FilterChip(
                avatar: Icon(Icons.circle, size: 14, color: streetStatusColor(s)),
                label: Text('${streetStatusLabel(s)} (${counts[s]})'),
                selected: _filter == s,
                onSelected: (v) => setState(() => _filter = v ? s : null),
              ),
            if (all.isNotEmpty)
              ActionChip(
                avatar: const Icon(Icons.copy, size: 16),
                label: const Text('Copy table'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _csv(shown)));
                  showToast('Copied (CSV): paste into a spreadsheet, email or message.', kind: ToastKind.success);
                },
              ),
          ]),
          const SizedBox(height: 10),
          if (snap.hasError) Text('${snap.error}', style: const TextStyle(color: AppColors.danger)),
          if (!snap.hasData && !snap.hasError) const LinearProgressIndicator(),
          if (snap.hasData && shown.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No street visits. They appear when workers on duty enter a street boundary.', textAlign: TextAlign.center),
            ),
          for (final v in shown)
            Builder(builder: (context) {
              final st = visitStatusOf(v);
              final total = (v['zonesTotal'] as num?)?.toInt() ?? 0;
              final done = ((v['zonesDone'] as List?) ?? const []).length;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.circle, size: 14, color: streetStatusColor(st)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${v['geofenceName'] ?? v['geofenceId']}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      Text(streetStatusLabel(st), style: TextStyle(color: streetStatusColor(st), fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 4),
                    Text('${v['workerName'] ?? 'Unnamed worker'}${v['synthetic'] == true ? ' (demo)' : ''}'),
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.login, size: 18, color: AppColors.success),
                      Text(' In ${_hm(v['enteredAt'])}   '),
                      Icon(Icons.logout, size: 18, color: v['exitedAt'] == null ? AppColors.muted : AppColors.indigo),
                      Text(v['exitedAt'] == null ? ' Still in the street' : ' Out ${_hm(v['exitedAt'])} (${v['durationMin']} min)'),
                    ]),
                    if (total > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: done / total,
                        minHeight: 6,
                        color: streetStatusColor(st),
                        backgroundColor: AppColors.line,
                      ),
                      const SizedBox(height: 4),
                      Text('Cleaning zones: $done of $total', style: const TextStyle(color: AppColors.muted)),
                    ],
                  ]),
                ),
              );
            }),
        ]);
      },
    );
  }
}

/// Administrator: mark the cleaning zones of one street on the map.
class CleaningZonesPage extends StatefulWidget {
  const CleaningZonesPage({super.key, required this.admin, required this.street});
  final User admin;
  final Geofence street;
  @override
  State<CleaningZonesPage> createState() => _CleaningZonesPageState();
}

class _CleaningZonesPageState extends State<CleaningZonesPage> {
  final repo = StreetZonesRepo();
  late final _stream = repo.watchStreet(widget.street.id);
  bool _saving = false;

  LatLng get _centre => widget.street.kind == GeofenceKind.circle
      ? LatLng(widget.street.center!.lat, widget.street.center!.lng)
      : LatLng(
          widget.street.ring.map((p) => p.lat).reduce((a, b) => a + b) / widget.street.ring.length,
          widget.street.ring.map((p) => p.lng).reduce((a, b) => a + b) / widget.street.ring.length,
        );

  Future<void> _add(LatLng p, int count) async {
    final inside = widget.street.check(GeoPoint2(p.latitude, p.longitude), 0).placement != Placement.outside;
    if (!inside) {
      showToast('Tap inside the street boundary (green).', kind: ToastKind.error);
      return;
    }
    setState(() => _saving = true);
    try {
      await repo.addZone(
        widget.admin,
        streetFenceId: widget.street.id,
        areaPath: widget.street.areaPath,
        name: '${widget.street.name.replaceAll(' boundary', '')} Zone ${count + 1}',
        at: GeoPoint2(p.latitude, p.longitude),
        order: count,
      );
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Zones: ${widget.street.name}')),
        body: StreamBuilder<List<CleaningZone>>(
          stream: _stream,
          builder: (context, snap) {
            final zones = snap.data ?? const <CleaningZone>[];
            return Column(children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Tap inside the street to add a cleaning zone (25 m circle). '
                    'The worker\'s zones are ticked automatically when they reach each one.', style: TextStyle(color: AppColors.muted)),
              ),
              SizedBox(
                height: 360,
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: _centre,
                    initialZoom: 17,
                    onTap: (_, p) => _saving ? null : _add(p, zones.length),
                  ),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'in.cit.smartattendance.v2'),
                    if (widget.street.kind == GeofenceKind.circle)
                      CircleLayer(circles: [
                        CircleMarker(
                          point: _centre,
                          radius: widget.street.radiusM!,
                          useRadiusInMeter: true,
                          color: AppColors.green.withValues(alpha: 0.10),
                          borderColor: AppColors.green,
                          borderStrokeWidth: 2,
                        ),
                      ])
                    else
                      PolygonLayer(polygons: [
                        Polygon(
                          points: [for (final p in widget.street.ring) LatLng(p.lat, p.lng)],
                          color: AppColors.green.withValues(alpha: 0.10),
                          borderColor: AppColors.green,
                          borderStrokeWidth: 2,
                        ),
                      ]),
                    CircleLayer(circles: [
                      for (final z in zones)
                        CircleMarker(
                          point: LatLng(z.center.lat, z.center.lng),
                          radius: z.radiusM,
                          useRadiusInMeter: true,
                          color: AppColors.indigo.withValues(alpha: 0.18),
                          borderColor: AppColors.indigo,
                          borderStrokeWidth: 1.5,
                        ),
                    ]),
                    MarkerLayer(markers: [
                      for (final z in zones)
                        Marker(
                          point: LatLng(z.center.lat, z.center.lng),
                          width: 28,
                          height: 28,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: AppColors.indigo,
                            child: Text('${z.order + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ),
                    ]),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(children: [
                  Text('${zones.length} cleaning zone(s)', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (_saving) const Padding(padding: EdgeInsets.only(left: 10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                ]),
              ),
              Expanded(
                child: ListView(children: [
                  for (final z in zones)
                    ListTile(
                      leading: CircleAvatar(radius: 14, child: Text('${z.order + 1}')),
                      title: Text(z.name),
                      trailing: IconButton(
                        tooltip: 'Delete zone',
                        icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                        onPressed: () => repo.deleteZone(z.id).catchError((Object e) => showToast('$e', kind: ToastKind.error)),
                      ),
                    ),
                ]),
              ),
            ]);
          },
        ),
      );
}
