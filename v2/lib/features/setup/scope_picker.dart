import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../domain/area.dart';

class PickedScope {
  const PickedScope(this.areaIds, this.orgId);
  final List<String> areaIds;
  final String? orgId;
}

/// Chooses areas (any level) and, optionally, an organisation. Returns null
/// when cancelled. With [fixedOrgId] the organisation cannot be changed
/// (organisation administrators add people to their own organisation only).
///
/// The areas are shown as the same folding tree as Setup → Areas (district →
/// blocks → panchayats → habitations → streets), with search, so the 1,000+
/// official areas stay easy to pick from.
Future<PickedScope?> pickScope(
  BuildContext context,
  Directory dir, {
  required String title,
  List<String> areaIds = const [],
  String? orgId,
  String? fixedOrgId,
}) {
  return Navigator.of(context).push<PickedScope>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ScopePicker(dir: dir, title: title, areaIds: areaIds, orgId: orgId, fixedOrgId: fixedOrgId),
    ),
  );
}

class _ScopePicker extends StatefulWidget {
  const _ScopePicker({required this.dir, required this.title, required this.areaIds, this.orgId, this.fixedOrgId});
  final Directory dir;
  final String title;
  final List<String> areaIds;
  final String? orgId;
  final String? fixedOrgId;

  @override
  State<_ScopePicker> createState() => _ScopePickerState();
}

class _ScopePickerState extends State<_ScopePicker> {
  // The security rules allow at most 10 areas per role.
  static const _max = 10;

  final _q = TextEditingController();
  final _open = <String>{};
  late final Set<String> _chosen = {...widget.areaIds};
  late String? _org = widget.fixedOrgId ?? widget.orgId;
  late final Stream<List<AreaNode>> _areas = widget.dir.areas();
  late final Stream<List<Map<String, dynamic>>> _orgs = widget.dir.organisations();
  bool _openedChosen = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _done() {
    if (_chosen.length > _max) {
      showToast('Choose at most $_max areas. To cover more, choose the block or panchayat above them.', kind: ToastKind.error);
      return;
    }
    Navigator.pop(context, PickedScope(_chosen.toList(), _org));
  }

  void _toggle(AreaNode a, bool on) {
    setState(() {
      if (!on) {
        _chosen.remove(a.id);
        return;
      }
      if (_chosen.length >= _max) {
        showToast('At most $_max areas. Choose the block or panchayat above them to cover more.', kind: ToastKind.error);
        return;
      }
      // A higher area already includes everything inside it, so drop any
      // chosen areas below this one.
      _chosen.removeWhere((id) => id != a.id && _pathOf[id]?.contains(a.id) == true);
      _chosen.add(a.id);
    });
  }

  Map<String, List<String>> _pathOf = const {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.line))),
          child: Row(children: [
            Expanded(
              child: Text(_chosen.isEmpty ? 'Nothing chosen' : '${_chosen.length} area${_chosen.length == 1 ? '' : 's'} chosen',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(110, 48)), onPressed: _done, child: const Text('Done')),
          ]),
        ),
      ),
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cancel', onPressed: () => Navigator.pop(context)),
        title: Text(widget.title, style: const TextStyle(color: AppColors.ink, fontSize: 20, fontWeight: FontWeight.w600)),
      ),
      body: StreamBuilder<List<AreaNode>>(
        stream: _areas,
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());

          final byId = {for (final a in all) a.id: a};
          _pathOf = {for (final a in all) a.id: a.path};
          final kids = <String?, List<AreaNode>>{};
          for (final a in all) {
            kids.putIfAbsent(a.parentId, () => []).add(a);
          }
          for (final l in kids.values) {
            l.sort((a, b) => a.name.compareTo(b.name));
          }

          // Open the tree down to areas that are already chosen, once.
          if (!_openedChosen) {
            _openedChosen = true;
            for (final id in _chosen) {
              final p = byId[id]?.path ?? const <String>[];
              _open.addAll(p.take(p.length - 1));
            }
            for (final r in kids[null] ?? const <AreaNode>[]) {
              _open.add(r.id); // the district is always open
            }
          }

          // Chosen higher up → this area is already covered.
          String? coveredBy(AreaNode a) {
            for (final id in a.path.take(a.path.length - 1)) {
              if (_chosen.contains(id)) return id;
            }
            return null;
          }

          String placeOf(AreaNode a) =>
              [for (final id in a.path.take(a.path.length - 1)) byId[id]?.name ?? ''].where((x) => x.isNotEmpty).join(' › ');

          Widget box(AreaNode a) {
            final cover = coveredBy(a);
            if (cover != null) {
              return Tooltip(
                message: 'Included in ${byId[cover]?.name ?? 'an area above'}',
                child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.check_box, color: AppColors.line)),
              );
            }
            return Checkbox(value: _chosen.contains(a.id), onChanged: (v) => _toggle(a, v == true));
          }

          Widget node(AreaNode a, int depth) {
            final children = kids[a.id] ?? const <AreaNode>[];
            final open = _open.contains(a.id);
            final picked = _chosen.contains(a.id);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InkWell(
                onTap: children.isEmpty
                    ? (coveredBy(a) == null ? () => _toggle(a, !picked) : null)
                    : () => setState(() => open ? _open.remove(a.id) : _open.add(a.id)),
                child: Container(
                  color: picked ? const Color(0xFFE8F1EC) : null,
                  padding: EdgeInsets.fromLTRB(8.0 + depth * 18, 4, 4, 4),
                  child: Row(children: [
                    SizedBox(
                      width: 24,
                      child: children.isEmpty
                          ? const Icon(Icons.circle, size: 6, color: AppColors.muted)
                          : Icon(open ? Icons.expand_more : Icons.chevron_right, size: 22, color: AppColors.muted),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(a.name, style: TextStyle(fontWeight: depth < 2 ? FontWeight.w700 : FontWeight.w500)),
                        Text('${a.level.key}${children.isEmpty ? '' : ' · ${children.length} inside'}',
                            style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                      ]),
                    ),
                    box(a),
                  ]),
                ),
              ),
              if (open) for (final c in children) node(c, depth + 1),
            ]);
          }

          final q = _q.text.trim().toLowerCase();
          final roots = kids[null] ?? const <AreaNode>[];
          final chosenList = [for (final id in _chosen) byId[id]].whereType<AreaNode>().toList();

          return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
            if (widget.fixedOrgId == null)
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _orgs,
                builder: (context, snap) => DropdownButtonFormField<String?>(
                  value: _org,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Organisation', isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('None')),
                    for (final o in snap.data ?? const <Map<String, dynamic>>[])
                      DropdownMenuItem<String?>(value: o['id'] as String, child: Text('${o['name']}')),
                  ],
                  onChanged: (v) => setState(() => _org = v),
                ),
              ),
            const SizedBox(height: 12),
            // What is chosen so far, always visible at the top.
            Text('Chosen: ${_chosen.length} of $_max', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (chosenList.isEmpty)
              const Text('Nothing chosen yet. Tick an area below. A block or panchayat includes everything inside it.',
                  style: TextStyle(color: AppColors.muted, fontSize: 13))
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final a in chosenList)
                  InputChip(
                    label: Text('${a.name} (${a.level.key})'),
                    onDeleted: () => setState(() => _chosen.remove(a.id)),
                  ),
              ]),
            const SizedBox(height: 12),
            TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search a block, panchayat, habitation or street',
                isDense: true,
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), tooltip: 'Clear search', onPressed: () => setState(_q.clear)),
              ),
            ),
            const SizedBox(height: 8),
            if (all.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No areas yet. Add them under Setup → Areas.', style: TextStyle(color: AppColors.muted)),
              )
            else if (q.isNotEmpty) ...[
              // Search: matches with where they are.
              for (final a in all.where((a) => a.name.toLowerCase().contains(q)).take(80))
                ListTile(
                  dense: true,
                  tileColor: _chosen.contains(a.id) ? const Color(0xFFE8F1EC) : null,
                  title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${a.level.key} · ${placeOf(a)}'),
                  trailing: box(a),
                  onTap: coveredBy(a) == null ? () => _toggle(a, !_chosen.contains(a.id)) : null,
                ),
              if (!all.any((a) => a.name.toLowerCase().contains(q)))
                const Padding(padding: EdgeInsets.all(16), child: Text('No area with that name.', style: TextStyle(color: AppColors.muted))),
            ] else
              for (final r in roots) node(r, 0),
          ]);
        },
      ),
    );
  }
}
