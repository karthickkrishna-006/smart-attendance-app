import 'package:flutter/material.dart';

import '../../app/theme.dart';
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
Future<PickedScope?> pickScope(
  BuildContext context,
  Directory dir, {
  required String title,
  List<String> areaIds = const [],
  String? orgId,
  String? fixedOrgId,
}) {
  final chosen = {...areaIds};
  var org = fixedOrgId ?? orgId;
  return showDialog<PickedScope>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          height: 420,
          child: Column(children: [
            if (fixedOrgId == null)
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: dir.organisations(),
                builder: (context, snap) => DropdownButtonFormField<String?>(
                  value: org,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Organisation'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('None')),
                    for (final o in snap.data ?? const <Map<String, dynamic>>[])
                      DropdownMenuItem<String?>(value: o['id'] as String, child: Text('${o['name']}')),
                  ],
                  onChanged: (v) => set(() => org = v),
                ),
              ),
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Areas (a block includes everything inside it)', style: TextStyle(color: AppColors.muted)),
            ),
            Expanded(
              child: StreamBuilder<List<AreaNode>>(
                stream: dir.areas(),
                builder: (context, snap) {
                  final all = snap.data;
                  if (all == null) return const Center(child: CircularProgressIndicator());
                  if (all.isEmpty) return const Center(child: Text('No areas yet. Add them under Setup.'));
                  return ListView(children: [
                    for (final a in all)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.only(left: 16.0 * (a.path.length - 1)),
                        value: chosen.contains(a.id),
                        title: Text(a.name),
                        subtitle: Text(a.level.key),
                        onChanged: (v) => set(() => v == true ? chosen.add(a.id) : chosen.remove(a.id)),
                      ),
                  ]);
                },
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
            onPressed: () => Navigator.pop(c, PickedScope(chosen.toList(), org)),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}
