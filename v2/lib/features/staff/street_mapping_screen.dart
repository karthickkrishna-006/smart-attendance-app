import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/attendance_repository.dart';
import '../../data/directory.dart';
import '../../data/scoped.dart';
import '../../data/session_controller.dart';
import '../../data/street_zones_repo.dart';
import '../../domain/area.dart';
import '../../domain/geo.dart';
import '../monitor/street_screens.dart' show CleaningZonesPage;
import '../setup/district_admin.dart' show BoundaryDrawPage;

/// VP Secretaries / MNPs (supervisors): add the streets of their own
/// panchayat, draw each street (tap along it) and mark its cleaning zones.
/// The security rules limit them to their own assigned areas.
class StreetMappingScreen extends StatefulWidget {
  const StreetMappingScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<StreetMappingScreen> createState() => _StreetMappingScreenState();
}

class _StreetMappingScreenState extends State<StreetMappingScreen> {
  late final Directory dir = Directory(widget.session.user!);
  late final Stream<List<AreaNode>> _areas = dir.areas();
  late final Stream<List<Map<String, dynamic>>> _fences = dir.geofences();
  Map<String, int> _zoneCounts = const {};
  String _zoneKey = '';

  List<String> get _mine => widget.session.current?.areaIds ?? const [];
  bool _inScope(AreaNode a) => a.path.any(_mine.contains);

  Future<void> _countZones(Iterable<String> fenceIds) async {
    final key = (fenceIds.toList()..sort()).join(',');
    if (key == _zoneKey) return;
    _zoneKey = key;
    try {
      final z = await StreetZonesRepo().forStreets(fenceIds);
      if (mounted) setState(() => _zoneCounts = {for (final e in z.entries) e.key: e.value.length});
    } catch (_) {}
  }

  Future<void> _addStreet(List<AreaNode> parents) async {
    final name = TextEditingController();
    AreaNode? parent = parents.length == 1 ? parents.first : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Add a street'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<AreaNode>(
              value: parent,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Habitation (or village panchayat)'),
              items: [for (final p in parents) DropdownMenuItem(value: p, child: Text(p.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => set(() => parent = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Street name (as in the house-tax register)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (parent == null || name.text.trim().isEmpty) {
      showToast('Choose the habitation and type the street name.', kind: ToastKind.error);
      return;
    }
    try {
      await dir.addArea(name: name.text, level: AreaLevel.location, parent: parent);
      showToast('Street "${name.text.trim()}" added. Now draw it on the map.', kind: ToastKind.success);
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = scopeProblem(widget.session);
    return StreamBuilder<List<AreaNode>>(
      stream: _areas,
      builder: (context, areaSnap) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _fences,
        builder: (context, fenceSnap) {
          if (areaSnap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load areas', body: '${areaSnap.error}');
          if (!areaSnap.hasData) return const Center(child: CircularProgressIndicator());
          final all = areaSnap.data!.where(_inScope).toList();
          final parents = all.where((a) => a.level == AreaLevel.habitation || a.level == AreaLevel.panchayat).toList();
          final streets = all.where((a) => a.level == AreaLevel.location).toList()..sort((a, b) => a.name.compareTo(b.name));
          final fenceByArea = <String, Geofence>{
            for (final f in fenceSnap.data ?? const <Map<String, dynamic>>[])
              if (AttendanceRepository.geofenceFromMap(f['id'] as String, f) case final Geofence g) '${f['areaId']}': g,
          };
          final streetFences = [for (final s in streets) fenceByArea[s.id]].whereType<Geofence>();
          if (streetFences.isNotEmpty) _countZones(streetFences.map((f) => f.id));
          final drawn = streets.where((s) => fenceByArea.containsKey(s.id)).length;
          return Scaffold(
            floatingActionButton: parents.isEmpty
                ? null
                : FloatingActionButton.extended(
                    onPressed: () => _addStreet(parents),
                    icon: const Icon(Icons.add_road),
                    label: const Text('Add street'),
                  ),
            body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
              if (problem != null) NoticeCard(text: problem),
              Card(
                color: const Color(0xFFE8F1EC),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${streets.length} streets · $drawn drawn on the map', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    const Text('1. Add each street (name from the house-tax register).  2. Draw: tap along the street on the map.  '
                        '3. Zones: tap each bin / garbage point, or stand at it and press "Add zone here".',
                        style: TextStyle(color: AppColors.muted, height: 1.35)),
                  ]),
                ),
              ),
              if (streets.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No streets yet. Tap "Add street" to start.', style: TextStyle(color: AppColors.muted)),
                ),
              for (final p in parents.where((p) => streets.any((s) => s.parentId == p.id))) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
                  child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.green)),
                ),
                for (final s in streets.where((s) => s.parentId == p.id))
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      leading: Icon(fenceByArea.containsKey(s.id) ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: fenceByArea.containsKey(s.id) ? AppColors.success : AppColors.muted),
                      title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(fenceByArea.containsKey(s.id)
                          ? 'Drawn · ${_zoneCounts[fenceByArea[s.id]!.id] ?? 0} cleaning zone(s)'
                          : 'Not drawn yet'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Draw the street',
                          icon: const Icon(Icons.edit_road),
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BoundaryDrawPage(dir: dir, area: s))),
                        ),
                        IconButton(
                          tooltip: 'Cleaning zones',
                          icon: const Icon(Icons.add_location_alt_outlined),
                          onPressed: fenceByArea.containsKey(s.id)
                              ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                                  builder: (_) => CleaningZonesPage(admin: widget.session.user!, street: fenceByArea[s.id]!)))
                              : null,
                        ),
                      ]),
                    ),
                  ),
              ],
            ]),
          );
        },
      ),
    );
  }
}
