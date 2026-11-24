import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/session_controller.dart';
import '../../domain/navigation.dart';

/// District administrator's home: counts, what needs attention, and quick
/// actions that open the right screen (or Setup tab) in one tap.
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key, required this.session, required this.onOpen});
  final SessionController session;
  final void Function(Section section, {int? setupTab}) onOpen;
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _Counts {
  int people = 0, roles = 0, noArea = 0, areas = 0, streets = 0, boundaries = 0, zones = 0;
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final _db = FirebaseFirestore.instance;
  late Future<_Counts> _counts = _load();

  // Roles that must have an area to work or to see anything.
  static const _needsArea = {'worker', 'supervisor', 'zonal_secretary', 'officer'};

  Future<int> _count(Query<Map<String, dynamic>> q) async => (await q.count().get()).count ?? 0;

  Future<_Counts> _load() async {
    final c = _Counts();
    final roles = await _db.collection('roleAssignments').where('active', isEqualTo: true).get();
    c.roles = roles.docs.length;
    c.people = {for (final d in roles.docs) d.data()['uid']}.length;
    c.noArea = roles.docs.where((d) => _needsArea.contains(d.data()['role']) && ((d.data()['areaIds'] as List?) ?? const []).isEmpty).length;
    c.areas = await _count(_db.collection('areas'));
    c.streets = await _count(_db.collection('areas').where('level', isEqualTo: 'location'));
    c.boundaries = await _count(_db.collection('geofences'));
    c.zones = await _count(_db.collection('cleaningZones'));
    return c;
  }

  Widget _tile(String value, String label, IconData icon, Color color) => Container(
        width: 150,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.ink)),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        ]),
      );

  Widget _action(String label, IconData icon, VoidCallback onTap) => SizedBox(
        width: 165,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
              child: Row(children: [
                Icon(icon, color: AppColors.green),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async => setState(() => _counts = _load()),
        child: FutureBuilder<_Counts>(
          future: _counts,
          builder: (context, snap) {
            final c = snap.data;
            final attention = <(String, String, VoidCallback)>[
              if (c != null && c.noArea > 0)
                ('${c.noArea} role(s) have no area: those people cannot work or see anything yet.', 'Assign areas',
                    () => widget.onOpen(Section.setup, setupTab: 3)),
              if (c != null && c.areas < 10)
                ('The official areas are not loaded yet.', 'Load areas', () => widget.onOpen(Section.setup, setupTab: 0)),
              if (c != null && c.streets > 0 && c.boundaries < c.streets)
                ('${c.streets - c.boundaries < 0 ? 0 : c.streets - c.boundaries} street(s) are not drawn on the map yet.', 'Boundaries',
                    () => widget.onOpen(Section.setup, setupTab: 1)),
              if (c != null && c.boundaries > 0 && c.zones == 0)
                ('No cleaning zones marked yet: zone check-in / check-out needs them.', 'Boundaries', () => widget.onOpen(Section.setup, setupTab: 1)),
            ];
            return ListView(padding: const EdgeInsets.all(16), children: [
              const Text('District administration', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.ink)),
              const SizedBox(height: 4),
              const Text('Pull down to refresh.', style: TextStyle(color: AppColors.muted)),
              const SizedBox(height: 14),
              if (snap.hasError) Text('${snap.error}', style: const TextStyle(color: AppColors.danger)),
              if (c == null && !snap.hasError) const LinearProgressIndicator(),
              if (c != null)
                Wrap(spacing: 10, runSpacing: 10, children: [
                  _tile('${c.people}', 'people with access', Icons.groups_outlined, AppColors.green),
                  _tile('${c.areas}', 'areas', Icons.account_tree_outlined, AppColors.indigo),
                  _tile('${c.streets}', 'streets', Icons.signpost_outlined, AppColors.indigo),
                  _tile('${c.boundaries}', 'boundaries drawn', Icons.pentagon_outlined, AppColors.success),
                  _tile('${c.zones}', 'cleaning zones', Icons.place_outlined, AppColors.turmeric),
                ]),
              if (attention.isNotEmpty) ...[
                const SizedBox(height: 18),
                const Text('Needs attention', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink)),
                const SizedBox(height: 8),
                for (final a in attention)
                  Card(
                    color: const Color(0xFFFFF4D6),
                    child: ListTile(
                      leading: const Icon(Icons.warning_amber_rounded, color: AppColors.turmeric),
                      title: Text(a.$1),
                      trailing: TextButton(onPressed: a.$3, child: Text(a.$2)),
                    ),
                  ),
              ],
              const SizedBox(height: 18),
              const Text('Quick actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink)),
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                _action('Add a person', Icons.person_add_alt_1_outlined, () => widget.onOpen(Section.employees)),
                _action('Assign areas', Icons.admin_panel_settings_outlined, () => widget.onOpen(Section.setup, setupTab: 3)),
                _action('Areas', Icons.account_tree_outlined, () => widget.onOpen(Section.setup, setupTab: 0)),
                _action('Boundaries & zones', Icons.pentagon_outlined, () => widget.onOpen(Section.setup, setupTab: 1)),
                _action('Send a message', Icons.campaign_outlined, () => widget.onOpen(Section.setup, setupTab: 5)),
                _action('Settings', Icons.tune, () => widget.onOpen(Section.setup, setupTab: 4)),
                _action('Audit log', Icons.history, () => widget.onOpen(Section.auditLog)),
              ]),
            ]);
          },
        ),
      );
}
