import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
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

/// GIS boundary management: list, draw on map, import GeoJSON (official data).
class BoundariesScreen extends StatelessWidget {
  final AppUser me;
  const BoundariesScreen({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GIS boundaries'),
        actions: [
          if (me.isStaff)
            IconButton(
              tooltip: 'Import GeoJSON',
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GeoJsonImportScreen())),
            ),
        ],
      ),
      floatingActionButton: me.isStaff
          ? FloatingActionButton.extended(
              heroTag: 'newBoundary',
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BoundaryEditor())),
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Draw boundary'),
            )
          : null,
      body: LiveQueries(
        queries: [Db.col('boundaries'), Db.col('users').where('role', isEqualTo: 'worker')],
        builder: (context, d) {
          final list = d[0].map(Boundary.fromDoc).toList()..sort((a, b) => a.name.compareTo(b.name));
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.layers_clear_outlined,
              title: 'No boundaries yet',
              subtitle: 'Import official GeoJSON from the GIS team, draw a boundary on the map, or load synthetic demo data from Settings.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final b = list[i];
              final assigned = d[1].where((w) => w['boundaryId'] == b.id).length;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: me.isStaff ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => BoundaryEditor(existing: b))) : null,
                    child: Row(children: [
                      SizedBox(
                        width: 110,
                        height: 110,
                        child: b.points.length < 3
                            ? const Icon(Icons.layers_clear)
                            : IgnorePointer(
                                child: OsmMap(center: centroid(b.points), zoom: 14, interactive: false, layers: [PolygonLayer(polygons: [boundaryPolygon(b)])]),
                              ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                              if (b.synthetic) const DemoBadge() else const StatusChip('verified', label: 'OFFICIAL'),
                            ]),
                            const SizedBox(height: 4),
                            Text('${b.district} › ${b.block.isEmpty ? '—' : b.block} › ${b.panchayat.isEmpty ? '—' : b.panchayat}',
                                style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
                            const SizedBox(height: 4),
                            Text('${(areaSqM(b.points) / 10000).toStringAsFixed(1)} ha · ${b.points.length} vertices · $assigned workers',
                                style: const TextStyle(fontSize: 12.5)),
                            if (b.layer.isNotEmpty)
                              Text('Layer: ${b.layer}${b.attributeColumn.isNotEmpty ? ' · ${b.attributeColumn}=${b.attributeValue}' : ''}',
                                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class BoundaryEditor extends StatefulWidget {
  final Boundary? existing;
  const BoundaryEditor({super.key, this.existing});
  @override
  State<BoundaryEditor> createState() => _BoundaryEditorState();
}

class _BoundaryEditorState extends State<BoundaryEditor> {
  final _map = MapController();
  late final List<LatLng> _pts = [...?widget.existing?.points];
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _district = TextEditingController(text: widget.existing?.district ?? 'Chengalpattu');
  late final _block = TextEditingController(text: widget.existing?.block ?? '');
  late final _pan = TextEditingController(text: widget.existing?.panchayat ?? '');
  late final _layer = TextEditingController(text: widget.existing?.layer ?? '');
  late final _attrCol = TextEditingController(text: widget.existing?.attributeColumn ?? '');
  late final _attrVal = TextEditingController(text: widget.existing?.attributeValue ?? '');
  late final _source = TextEditingController(text: widget.existing?.source ?? '');
  late bool _synthetic = widget.existing?.synthetic ?? true;
  LatLng _center = const LatLng(12.6919, 79.9762);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_pts.isNotEmpty) {
      _center = centroid(_pts);
    } else {
      LocationService.current().then((p) {
        if (!mounted) return;
        final ll = LatLng(p.latitude, p.longitude);
        setState(() => _center = ll);
        _map.move(ll, 16);
      }).catchError((_) {});
    }
  }

  Future<void> _save() async {
    if (_pts.length < 3) {
      showSnack(context, 'Tap at least 3 points on the map to form a polygon.', error: true);
      return;
    }
    if (_name.text.trim().isEmpty) {
      showSnack(context, 'Enter a boundary name.', error: true);
      return;
    }
    if (!_synthetic && _source.text.trim().isEmpty) {
      showSnack(context, 'Official boundaries must cite their authorised source.', error: true);
      return;
    }
    setState(() => _busy = true);
    final data = {
      'name': _name.text.trim(),
      'district': _district.text.trim(),
      'block': _block.text.trim(),
      'panchayat': _pan.text.trim(),
      'layer': _layer.text.trim(),
      'attributeColumn': _attrCol.text.trim(),
      'attributeValue': _attrVal.text.trim(),
      'source': _synthetic ? 'Synthetic – drawn in app for demonstration. NOT official GIS data.' : _source.text.trim(),
      'synthetic': _synthetic,
      'points': Boundary.encode(_pts),
      'updatedAt': Timestamp.now(),
    };
    try {
      if (widget.existing == null) {
        final r = await Db.col('boundaries').add({...data, 'createdAt': Timestamp.now()});
        await Db.audit('boundary_created', 'boundaries/${r.id}');
      } else {
        await Db.col('boundaries').doc(widget.existing!.id).update(data);
        await Db.audit('boundary_updated', 'boundaries/${widget.existing!.id}');
      }
      if (mounted) {
        showSnack(context, 'Boundary saved.', success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete boundary', 'Workers assigned to this boundary will become unassigned.', ok: 'Delete', danger: true)) return;
    try {
      await Db.col('boundaries').doc(widget.existing!.id).delete();
      await Db.audit('boundary_deleted', 'boundaries/${widget.existing!.id}');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = Boundary('preview', {'name': _name.text.isEmpty ? 'New boundary' : _name.text, 'synthetic': _synthetic, 'points': Boundary.encode(_pts)});
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Draw boundary' : 'Edit boundary'),
        actions: [if (widget.existing != null) IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline))],
      ),
      body: ListView(children: [
        SizedBox(
          height: 340,
          child: Stack(children: [
            OsmMap(
              controller: _map,
              center: _center,
              zoom: 16,
              onTap: (_, ll) => setState(() => _pts.add(ll)),
              layers: [
                if (_pts.length >= 3) PolygonLayer(polygons: [boundaryPolygon(preview, highlight: true)]),
                if (_pts.length == 2) PolylineLayer(polylines: [Polyline(points: _pts, color: AppColors.teal, strokeWidth: 3)]),
                MarkerLayer(
                  markers: _pts
                      .asMap()
                      .entries
                      .map((e) => Marker(
                            point: e.value,
                            width: 22,
                            height: 22,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: AppColors.navy, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                              child: Text('${e.key + 1}', style: const TextStyle(color: Colors.white, fontSize: 9)),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
            Positioned(
              top: 10,
              left: 10,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    _pts.length < 3 ? 'Tap the map to add vertices (${_pts.length})' : '${_pts.length} vertices · ${(areaSqM(_pts) / 10000).toStringAsFixed(2)} ha',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 24,
              child: Column(children: [
                FloatingActionButton.small(heroTag: 'undo', onPressed: _pts.isEmpty ? null : () => setState(() => _pts.removeLast()), child: const Icon(Icons.undo)),
                const SizedBox(height: 8),
                FloatingActionButton.small(heroTag: 'clear', onPressed: _pts.isEmpty ? null : () => setState(_pts.clear), child: const Icon(Icons.clear_all)),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Boundary / location name'), onChanged: (_) => setState(() {})),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _district, decoration: const InputDecoration(labelText: 'District'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _block, decoration: const InputDecoration(labelText: 'Block'))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _pan, decoration: const InputDecoration(labelText: 'Village Panchayat')),
            const SizedBox(height: 10),
            TextField(controller: _layer, decoration: const InputDecoration(labelText: 'GIS layer (boundary_layer / layer_id)')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _attrCol, decoration: const InputDecoration(labelText: 'Attribute column'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _attrVal, decoration: const InputDecoration(labelText: 'Attribute value'))),
            ]),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _synthetic,
              onChanged: (v) => setState(() => _synthetic = v),
              title: const Text('Synthetic / demo boundary'),
              subtitle: const Text('Turn off only for boundaries supplied by an authorised GIS source.'),
            ),
            if (!_synthetic) TextField(controller: _source, decoration: const InputDecoration(labelText: 'Official source (dataset / authority)')),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save boundary'),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Imports Polygon / MultiPolygon features from GeoJSON (e.g. exported from QGIS
/// by the GIS team). Feature properties fill name/block/panchayat/attributes.
class GeoJsonImportScreen extends StatefulWidget {
  const GeoJsonImportScreen({super.key});
  @override
  State<GeoJsonImportScreen> createState() => _GeoJsonImportScreenState();
}

class _GeoJsonImportScreenState extends State<GeoJsonImportScreen> {
  final _text = TextEditingController();
  final _nameKey = TextEditingController(text: 'name');
  final _blockKey = TextEditingController(text: 'block');
  final _panKey = TextEditingController(text: 'panchayat');
  final _layer = TextEditingController();
  final _attrCol = TextEditingController();
  final _source = TextEditingController();
  bool _official = false;
  bool _busy = false;
  List<Map<String, dynamic>>? _parsed;
  String? _error;

  void _parse() {
    try {
      final j = jsonDecode(_text.text);
      final feats = <Map<String, dynamic>>[];
      final list = j['type'] == 'FeatureCollection' ? (j['features'] as List) : [j];
      for (final f in list) {
        final g = f['type'] == 'Feature' ? f['geometry'] : f;
        final props = (f['properties'] as Map?)?.cast<String, dynamic>() ?? {};
        List? ring;
        if (g['type'] == 'Polygon') ring = (g['coordinates'] as List).first as List;
        if (g['type'] == 'MultiPolygon') ring = ((g['coordinates'] as List).first as List).first as List;
        if (ring == null) continue;
        final pts = ring.map((c) => LatLng(asDouble((c as List)[1]), asDouble(c[0]))).toList();
        if (pts.length > 3 && pts.first == pts.last) pts.removeLast();
        feats.add({'props': props, 'points': pts});
      }
      setState(() {
        _parsed = feats;
        _error = feats.isEmpty ? 'No Polygon/MultiPolygon features found.' : null;
      });
    } catch (e) {
      setState(() {
        _parsed = null;
        _error = 'Invalid GeoJSON: $e';
      });
    }
  }

  Future<void> _import() async {
    if (_parsed == null || _parsed!.isEmpty) return;
    if (_official && _source.text.trim().isEmpty) {
      showSnack(context, 'Enter the authorised source for official data.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      int i = 0;
      for (final f in _parsed!) {
        final p = f['props'] as Map<String, dynamic>;
        i++;
        await Db.col('boundaries').add({
          'name': (p[_nameKey.text] ?? 'Imported boundary $i').toString(),
          'district': (p['district'] ?? 'Chengalpattu').toString(),
          'block': (p[_blockKey.text] ?? '').toString(),
          'panchayat': (p[_panKey.text] ?? '').toString(),
          'layer': _layer.text.trim(),
          'attributeColumn': _attrCol.text.trim(),
          'attributeValue': _attrCol.text.trim().isEmpty ? '' : (p[_attrCol.text.trim()] ?? '').toString(),
          'source': _official ? _source.text.trim() : 'Imported without official source – treated as SYNTHETIC.',
          'synthetic': !_official,
          'points': Boundary.encode(f['points'] as List<LatLng>),
          'createdAt': Timestamp.now(),
        });
      }
      await Db.audit('geojson_import', 'boundaries', {'count': _parsed!.length, 'official': _official});
      if (mounted) {
        showSnack(context, 'Imported ${_parsed!.length} boundaries.', success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import GeoJSON')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Paste a GeoJSON FeatureCollection (WGS84 / EPSG:4326) exported from QGIS or provided by the GIS team.'),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          maxLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(hintText: '{"type":"FeatureCollection","features":[...]}'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _nameKey, decoration: const InputDecoration(labelText: 'Name property'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _blockKey, decoration: const InputDecoration(labelText: 'Block property'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _panKey, decoration: const InputDecoration(labelText: 'Panchayat prop.'))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _layer, decoration: const InputDecoration(labelText: 'Layer name'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _attrCol, decoration: const InputDecoration(labelText: 'Attribute column'))),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _official,
          onChanged: (v) => setState(() => _official = v),
          title: const Text('This is official GIS data'),
        ),
        if (_official) TextField(controller: _source, decoration: const InputDecoration(labelText: 'Authorised source')),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: _parse, icon: const Icon(Icons.search), label: const Text('Validate & preview')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.danger))),
        if (_parsed != null && _parsed!.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: OsmMap(
                center: centroid(_parsed!.first['points'] as List<LatLng>),
                zoom: 12,
                layers: [
                  PolygonLayer(
                    polygons: _parsed!
                        .map((f) => Polygon(points: f['points'] as List<LatLng>, color: AppColors.teal.withOpacity(0.2), borderColor: AppColors.teal, borderStrokeWidth: 2))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.download_done),
            label: Text('Import ${_parsed!.length} boundaries'),
          ),
        ],
      ]),
    );
  }
}
