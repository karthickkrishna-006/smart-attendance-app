import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/attendance_repository.dart';
import '../../data/directory.dart';
import '../monitor/street_screens.dart';
import '../../data/location.dart';
import '../../domain/area.dart';
import '../../domain/geo.dart';
import 'district_admin.dart';
import 'setup_screen.dart' show runWrite;

/// Work-area boundaries: circles drawn here, or official boundaries imported
/// as GeoJSON (pasted text). Large boundaries are simplified to at most
/// 1,000 points so each fits in one document.
class GeofencesTab extends StatelessWidget {
  const GeofencesTab({super.key, required this.dir});
  final Directory dir;

  static List<GeoPoint2> fitRing(List<GeoPoint2> ring) {
    var tolerance = 2.0;
    var out = simplifyRing(ring, toleranceM: tolerance);
    while (out.length > 1000 && tolerance < 200) {
      tolerance *= 2;
      out = simplifyRing(ring, toleranceM: tolerance);
    }
    return out;
  }

  Future<AreaNode?> _pickArea(BuildContext context, List<AreaNode> areas) => showDialog<AreaNode>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Which area is this boundary for?'),
          children: [
            for (final a in areas)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, a),
                child: Padding(
                  padding: EdgeInsets.only(left: 12.0 * (a.path.length - 1)),
                  child: Text('${a.name}  (${a.level.key})'),
                ),
              ),
          ],
        ),
      );

  Future<void> _addCircle(BuildContext context, List<AreaNode> areas) async {
    final area = await _pickArea(context, areas);
    if (area == null || !context.mounted) return;
    final name = TextEditingController(text: area.name);
    final lat = TextEditingController();
    final lng = TextEditingController();
    final radius = TextEditingController(text: '200');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Circle boundary'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 10),
              TextField(controller: lat, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Centre latitude')),
              const SizedBox(height: 10),
              TextField(controller: lng, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Centre longitude')),
              TextButton.icon(
                icon: const Icon(Icons.my_location),
                label: const Text('Use my current location'),
                onPressed: () async {
                  try {
                    final p = await Location.current();
                    set(() {
                      lat.text = p.latitude.toStringAsFixed(6);
                      lng.text = p.longitude.toStringAsFixed(6);
                    });
                  } catch (e) {
                    showToast('$e', kind: ToastKind.error);
                  }
                },
              ),
              TextField(controller: radius, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Radius in metres (20 to 5,000)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final centre = GeoPoint2(double.tryParse(lat.text.trim()) ?? double.nan, double.tryParse(lng.text.trim()) ?? double.nan);
    final r = double.tryParse(radius.text.trim()) ?? 0;
    if (!centre.valid || r < 20 || r > 5000 || name.text.trim().isEmpty) {
      showToast('Check the name, coordinates and radius (20 to 5,000 m).', kind: ToastKind.error);
      return;
    }
    await runWrite(() => dir.addCircleGeofence(area: area, name: name.text, center: centre, radiusM: r), done: 'Boundary saved.');
  }

  Future<void> _import(BuildContext context, List<AreaNode> areas) async {
    final area = await _pickArea(context, areas);
    if (area == null || !context.mounted) return;
    final text = TextEditingController();
    var official = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Import GeoJSON'),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Paste a GeoJSON Polygon, MultiPolygon, Feature or FeatureCollection. Use only officially supplied boundaries.',
                  style: TextStyle(color: AppColors.muted)),
              const SizedBox(height: 10),
              TextField(controller: text, maxLines: 8, decoration: const InputDecoration(hintText: '{"type": "FeatureCollection", ...}')),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: official,
                onChanged: (v) => set(() => official = v == true),
                title: const Text('This is official government boundary data'),
                subtitle: const Text('Leave unticked to keep it marked provisional.'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Import')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final GeoJsonImport parsed;
    try {
      parsed = parseGeoJson(text.text);
    } on FormatException catch (e) {
      showToast(e.message, kind: ToastKind.error);
      return;
    }
    final rings = [for (final r in parsed.rings) (name: r.name, ring: fitRing(r.ring))];
    await runWrite(
      () async {
        final n = await dir.addPolygonGeofences(area: area, rings: rings, official: official);
        if (parsed.warnings.isNotEmpty) showToast('$n saved. ${parsed.warnings.join(' ')}');
      },
      done: '${rings.length} boundary(ies) imported.',
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<AreaNode>>(
        stream: dir.areas(),
        builder: (context, areaSnap) => StreamBuilder<List<Map<String, dynamic>>>(
          stream: dir.geofences(),
          builder: (context, snap) {
            if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load boundaries', body: '${snap.error}');
            final areas = areaSnap.data ?? const <AreaNode>[];
            final fences = snap.data;
            if (fences == null) return const Center(child: CircularProgressIndicator());
            final names = {for (final a in areas) a.id: a.name};
            return Scaffold(
              floatingActionButton: areas.isEmpty
                  ? null
                  : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      FloatingActionButton.extended(
                        heroTag: 'draw',
                        onPressed: () async {
                          final area = await _pickArea(context, areas);
                          if (area == null || !context.mounted) return;
                          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BoundaryDrawPage(dir: dir, area: area)));
                        },
                        icon: const Icon(Icons.draw_outlined),
                        label: const Text('Draw on map'),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton.extended(
                        heroTag: 'import',
                        onPressed: () => _import(context, areas),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Import GeoJSON'),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton.extended(
                        heroTag: 'circle',
                        onPressed: () => _addCircle(context, areas),
                        icon: const Icon(Icons.radio_button_unchecked),
                        label: const Text('Add circle'),
                      ),
                    ]),
              body: fences.isEmpty
                  ? MessageView(
                      icon: Icons.fence_outlined,
                      title: 'No boundaries yet',
                      body: areas.isEmpty
                          ? 'Add areas first, then draw or import their boundaries.'
                          : 'Import official boundaries, or add a circle around a work site.',
                    )
                  : ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 160), children: [
                      for (final f in fences)
                        ListTile(
                          onTap: () {
                            final fence = AttendanceRepository.geofenceFromMap(f['id'] as String, f);
                            if (fence == null) return;
                            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CleaningZonesPage(admin: dir.user, street: fence)));
                          },
                          trailing: const Icon(Icons.edit_location_alt_outlined),
                          leading: Icon(f['kind'] == 'circle' ? Icons.radio_button_unchecked : Icons.pentagon_outlined, color: AppColors.green),
                          title: Text('${f['name']}'),
                          subtitle: Text(
                            '${names[f['areaId']] ?? f['areaId']} · '
                            '${f['kind'] == 'circle' ? 'circle ${(f['radiusM'] as num?)?.round()} m' : '${(f['ring'] as List?)?.length ?? 0} points'}'
                            '${f['provisional'] == true ? ' · provisional' : ' · official'}',
                          ),
                        ),
                    ]),
            );
          },
        ),
      );
}
