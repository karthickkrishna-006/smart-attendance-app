import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../data/location.dart';
import '../../data/session_controller.dart';
import '../../domain/area.dart';
import '../../domain/designations.dart';
import '../../domain/geo.dart';
import '../../domain/roles.dart';
import '../monitor/live_map_view.dart';
import '../work/worker_work_screens.dart' show shortDateTime;

/// Pick a staff type (designation); null = none. Returns false when cancelled.
Future<({bool ok, Designation? value})> pickDesignation(BuildContext context, {Designation? current, Role? forRole}) async {
  var value = current;
  final options = forRole == null ? Designation.values : [...Designation.forRole(forRole), ...Designation.values.where((d) => d.role != forRole)];
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Staff type'),
        content: DropdownButtonFormField<Designation?>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Designation'),
          items: [
            const DropdownMenuItem<Designation?>(value: null, child: Text('None (no photo attendance)')),
            for (final d in options) DropdownMenuItem<Designation?>(value: d, child: Text(d.title, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => set(() => value = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  return (ok: ok == true, value: value);
}

// ------------------------------------------------------------------ messages
class MessagesAdminTab extends StatelessWidget {
  const MessagesAdminTab({super.key, required this.session});
  final SessionController session;

  Future<void> _compose(BuildContext context) async {
    final title = TextEditingController();
    final body = TextEditingController();
    var urgent = false;
    final chosen = <Designation>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Send a message'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: title, maxLength: 120, decoration: const InputDecoration(labelText: 'Title')),
              TextField(controller: body, maxLines: 5, maxLength: 2000, decoration: const InputDecoration(labelText: 'Message')),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Urgent'), value: urgent, onChanged: (v) => set(() => urgent = v)),
              const Text('Send to (none selected = all staff)', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final d in Designation.values.where((d) => d != Designation.districtMonitor))
                  FilterChip(
                    label: Text(d.title),
                    selected: chosen.contains(d),
                    onSelected: (v) => set(() => v ? chosen.add(d) : chosen.remove(d)),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (title.text.trim().isEmpty || body.text.trim().isEmpty) {
      showToast('Write a title and a message.', kind: ToastKind.error);
      return;
    }
    try {
      await Directory(session.user!).sendMessage(
        title: title.text,
        body: body.text,
        urgent: urgent,
        designations: [for (final d in chosen) d.key],
        roles: const [],
        senderName: (session.account?['displayName'] as String?) ?? 'District administration',
      );
      showToast(chosen.isEmpty ? 'Sent to all staff.' : 'Sent to ${chosen.length} staff type(s).', kind: ToastKind.success);
    } catch (e) {
      showToast('Not sent: $e', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _compose(context), icon: const Icon(Icons.campaign_outlined), label: const Text('New message')),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('messages').orderBy('createdAt', descending: true).limit(100).snapshots(),
          builder: (context, snap) {
            if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load messages', body: '${snap.error}');
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final docs = snap.data!.docs;
            if (docs.isEmpty) return const MessageView(icon: Icons.campaign_outlined, title: 'No messages sent yet', body: 'Messages appear in every addressed staff member\'s app.');
            return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
              for (final d in docs)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(d.data()['priority'] == 'urgent' ? Icons.priority_high : Icons.mail_outline,
                        color: d.data()['priority'] == 'urgent' ? AppColors.danger : AppColors.indigo),
                    title: Text('${d.data()['title']}'),
                    subtitle: Text('${d.data()['body']}\n${shortDateTime(d.data()['createdAt'])} · '
                        '${((d.data()['designations'] as List?) ?? const []).isEmpty ? 'all staff' : ((d.data()['designations'] as List).map((k) => Designation.fromKey(k as String?)?.title ?? k).join(', '))}'),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => Directory(session.user!).deleteMessage(d.id).catchError((Object e) => showToast('$e', kind: ToastKind.error)),
                    ),
                  ),
                ),
            ]);
          },
        ),
      );
}

// ------------------------------------------------------- boundary drawing
/// Draw a polygon boundary for an area by tapping its corners on the map.
class BoundaryDrawPage extends StatefulWidget {
  const BoundaryDrawPage({super.key, required this.dir, required this.area});
  final Directory dir;
  final AreaNode area;
  @override
  State<BoundaryDrawPage> createState() => _BoundaryDrawPageState();
}

class _BoundaryDrawPageState extends State<BoundaryDrawPage> {
  final _map = LiveMapController();
  final _points = <GeoPoint2>[];
  bool _saving = false;

  Future<void> _centreOnMe() async {
    try {
      final p = await Location.current();
      _map.moveTo(GeoPoint2(p.latitude, p.longitude), zoom: 17);
    } catch (e) {
      showToast('$e', kind: ToastKind.error);
    }
  }

  Future<void> _save() async {
    if (_points.length < 3) {
      showToast('Tap at least 3 corners of the boundary.', kind: ToastKind.error);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.dir.addPolygonGeofences(
        area: widget.area,
        rings: [(name: '${widget.area.name} boundary', ring: List.of(_points))],
        official: false,
      );
      showToast('Boundary saved for ${widget.area.name}.', kind: ToastKind.success);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      showToast('Not saved: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Boundary: ${widget.area.name}')),
        body: Column(children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Tap the corners of the area in order. Use the satellite-free street map and zoom in for accuracy.',
                style: TextStyle(color: AppColors.muted)),
          ),
          Expanded(
            child: LiveMapView(
              center: const GeoPoint2(12.6919, 79.9762),
              zoom: 14,
              controller: _map,
              onMapTap: (p) => setState(() => _points.add(p)),
              route: _points.length == 2 ? List.of(_points) : const [],
              areas: [
                if (_points.length >= 3)
                  MapArea(id: 'draft', ring: List.of(_points), stroke: AppColors.green, fill: AppColors.green.withValues(alpha: 0.18)),
              ],
              dots: [
                for (var k = 0; k < _points.length; k++)
                  MapDot(id: 'c$k', at: _points[k], radiusM: 8, fill: AppColors.indigo, stroke: Colors.white),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                IconButton.filledTonal(tooltip: 'Centre on me', onPressed: _centreOnMe, icon: const Icon(Icons.my_location)),
                const SizedBox(width: 8),
                IconButton.filledTonal(tooltip: 'Undo', onPressed: _points.isEmpty ? null : () => setState(_points.removeLast), icon: const Icon(Icons.undo)),
                const SizedBox(width: 8),
                IconButton.filledTonal(tooltip: 'Clear', onPressed: _points.isEmpty ? null : () => setState(_points.clear), icon: const Icon(Icons.delete_sweep_outlined)),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text('Save (${_points.length} corners)'),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      );
}
