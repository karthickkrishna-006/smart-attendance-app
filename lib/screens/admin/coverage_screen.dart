import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';

/// Panchayat-wise field coverage for one day, worked out from field-duty
/// sessions (`tracking_sessions`). Administrators can save the day as a
/// permanent report in `panchayat_coverage` (one document per panchayat per
/// day) for auditors and later review. No personal positions are shown here.
class CoverageScreen extends StatefulWidget {
  final AppUser me;
  const CoverageScreen({super.key, required this.me});
  @override
  State<CoverageScreen> createState() => _CoverageScreenState();
}

class _Row {
  final Boundary b;
  int sessions = 0;
  final Set<String> workers = {};
  int points = 0;
  int inside = 0;
  double distanceM = 0;
  bool synthetic = false;
  _Row(this.b);
  bool get covered => sessions > 0;
  int? get insidePct => points == 0 ? null : (inside * 100 / points).round();
}

class _CoverageScreenState extends State<CoverageScreen> {
  DateTime _day = DateTime.now();
  String _block = 'all';
  String _show = 'all'; // all | covered | not_covered
  bool _saving = false;

  Future<void> _pickDay() async {
    final d = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
    if (d != null) setState(() => _day = d);
  }

  List<_Row> _compute(List<Doc> sessions, List<Boundary> boundaries) {
    final rows = {for (final b in boundaries) b.id: _Row(b)};
    for (final s in sessions) {
      final r = rows[s['boundaryId']];
      if (r == null) continue;
      r.sessions++;
      r.workers.add((s['uid'] ?? '') as String);
      r.points += (s['pointCount'] as num?)?.toInt() ?? 0;
      r.inside += (s['insideCount'] as num?)?.toInt() ?? 0;
      r.distanceM += asDouble(s['distanceM']);
      if (s['synthetic'] == true) r.synthetic = true;
    }
    return rows.values.toList();
  }

  Future<void> _save(List<_Row> rows, String day) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save daily coverage report?'),
        content: Text('Saves coverage for ${rows.length} panchayats on ${fmtDate(_day)}. '
            'Saving again for the same day replaces the earlier report.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save report')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      // Firestore batches hold up to 500 writes.
      for (var i = 0; i < rows.length; i += 400) {
        final batch = Db.fs.batch();
        for (final r in rows.skip(i).take(400)) {
          batch.set(Db.col('panchayat_coverage').doc('${r.b.id}_$day'), {
            'boundaryId': r.b.id,
            'date': day,
            'name': r.b.name,
            'block': r.b.block,
            'panchayat': r.b.panchayat,
            'sessions': r.sessions,
            'workers': r.workers.length,
            'points': r.points,
            'insidePoints': r.inside,
            'distanceM': double.parse(r.distanceM.toStringAsFixed(1)),
            'covered': r.covered,
            'synthetic': r.synthetic || r.b.synthetic,
            'generatedBy': widget.me.uid,
            'generatedAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      }
      await Db.audit('coverage_report_saved', 'panchayat_coverage/$day', {'panchayats': rows.length});
      if (mounted) showSnack(context, 'Coverage report saved.', success: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = dayKey(_day);
    final sessQ = Db.trackingQuery('tracking_sessions', widget.me)?.where('date', isEqualTo: day);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Field coverage'),
        actions: [
          TextButton.icon(
            onPressed: _pickDay,
            icon: const Icon(Icons.calendar_today, size: 16, color: Colors.white),
            label: Text(fmtDate(_day), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: LiveQueries(
        queryKey: day,
        queries: [
          sessQ,
          Db.col('boundaries'),
          // Saved reports: administrators and auditors only.
          (widget.me.isAdmin || widget.me.role == Roles.auditor)
              ? Db.col('panchayat_coverage').where('date', isEqualTo: day)
              : null,
        ],
        builder: (context, d) {
          final boundaries = d[1].map(Boundary.fromDoc).toList();
          if (boundaries.isEmpty) {
            return const EmptyView(
              icon: Icons.polyline_outlined,
              title: 'No panchayat boundaries yet',
              subtitle: 'Add or import boundaries under More → GIS boundaries.',
            );
          }
          final all = _compute(d[0], boundaries);
          final saved = d[2].length;
          final blocks = boundaries.map((b) => b.block).where((e) => e.isNotEmpty).toSet().toList()..sort();
          final rows = all.where((r) {
            if (_block != 'all' && r.b.block != _block) return false;
            if (_show == 'covered' && !r.covered) return false;
            if (_show == 'not_covered' && r.covered) return false;
            return true;
          }).toList()
            ..sort((a, b) {
              final c = b.sessions.compareTo(a.sessions);
              return c != 0 ? c : a.b.name.compareTo(b.b.name);
            });
          final scope = all.where((r) => _block == 'all' || r.b.block == _block).toList();
          final covered = scope.where((r) => r.covered).length;
          final workers = scope.expand((r) => r.workers).toSet().length;
          final km = scope.fold<double>(0, (t, r) => t + r.distanceM) / 1000;
          final pts = scope.fold<int>(0, (t, r) => t + r.points);
          final ins = scope.fold<int>(0, (t, r) => t + r.inside);

          return ListView(padding: const EdgeInsets.all(16), children: [
            if (widget.me.role == Roles.supervisor)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text('Showing duty by your assigned workers only.', style: TextStyle(color: AppColors.muted)),
              ),
            StatGrid(children: [
                StatCard(
                  label: 'Panchayats covered',
                  value: '$covered / ${scope.length}',
                  icon: Icons.grid_view,
                  color: AppColors.success,
                  sub: scope.isEmpty ? null : '${(covered * 100 / scope.length).round()}% of area',
                ),
                StatCard(label: 'Workers on duty', value: '$workers', icon: Icons.groups_outlined, color: AppColors.info),
                StatCard(label: 'Distance covered', value: '${km.toStringAsFixed(1)} km', icon: Icons.route_outlined, color: AppColors.teal),
                StatCard(
                  label: 'Time in assigned area',
                  value: pts == 0 ? '–' : '${(ins * 100 / pts).round()}%',
                  icon: Icons.verified_outlined,
                  color: AppColors.warning,
                  sub: 'share of location points',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(children: [
              if (blocks.isNotEmpty)
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: blocks.contains(_block) ? _block : 'all',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Block', isDense: true),
                    items: [
                      const DropdownMenuItem(value: 'all', child: Text('All blocks')),
                      ...blocks.map((b) => DropdownMenuItem(value: b, child: Text(b))),
                    ],
                    onChanged: (v) => setState(() => _block = v ?? 'all'),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final f in const ['all', 'covered', 'not_covered'])
                ChoiceChip(
                  label: Text(const {'all': 'All', 'covered': 'Covered', 'not_covered': 'Not covered'}[f]!),
                  selected: _show == f,
                  onSelected: (_) => setState(() => _show = f),
                ),
            ]),
            if (widget.me.isAdmin) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(
                    saved > 0 ? 'Saved report exists for this day ($saved panchayats).' : 'No saved report for this day yet.',
                    style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _saving ? null : () => _save(all, day),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(saved > 0 ? 'Update report' : 'Save report'),
                ),
              ]),
            ],
            const SectionTitle('Panchayats'),
            if (rows.isEmpty) const EmptyView(icon: Icons.search_off, title: 'No panchayats match the filters'),
            ...rows.map(_tile),
          ]);
        },
      ),
    );
  }

  Widget _tile(_Row r) {
    final pct = r.insidePct;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: (r.covered ? AppColors.success : AppColors.muted).withValues(alpha: 0.12),
          child: Icon(r.covered ? Icons.check_circle_outline : Icons.radio_button_unchecked, color: r.covered ? AppColors.success : AppColors.muted),
        ),
        title: Text(r.b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          r.covered
              ? '${r.workers.length} worker${r.workers.length == 1 ? '' : 's'} · ${(r.distanceM / 1000).toStringAsFixed(1)} km'
                  '${pct == null ? '' : ' · $pct% in area'}${r.b.block.isEmpty ? '' : '\n${r.b.block}'}'
              : 'No field duty recorded${r.b.block.isEmpty ? '' : ' · ${r.b.block}'}',
        ),
        isThreeLine: r.covered && r.b.block.isNotEmpty,
        trailing: (r.synthetic || r.b.synthetic) ? const DemoBadge() : null,
      ),
    );
  }
}
