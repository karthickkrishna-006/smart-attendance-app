import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/fmt.dart';
import '../../core/osm_map.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';

/// Detailed view of an attendance record, including linked face and location
/// verification outcomes. Staff can review and override the status.
class AttendanceDetail extends StatefulWidget {
  final Doc a;
  final AppUser? reviewer;
  const AttendanceDetail({super.key, required this.a, this.reviewer});
  @override
  State<AttendanceDetail> createState() => _AttendanceDetailState();
}

class _AttendanceDetailState extends State<AttendanceDetail> {
  Boundary? _b;

  @override
  void initState() {
    super.initState();
    final bid = (widget.a['checkIn'] as Map?)?['boundaryId'] ?? widget.a['boundaryId'];
    Db.getBoundary(bid as String?).then((b) {
      if (mounted) setState(() => _b = b);
    });
  }

  Future<void> _review() async {
    String status = widget.a['status'] ?? 'pending_verification';
    final note = TextEditingController(text: widget.a['reviewNote'] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Review attendance'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const ['present', 'late', 'pending_verification', 'rejected', 'absent']
                  .map((s) => DropdownMenuItem(value: s, child: Text(titleCase(s))))
                  .toList(),
              onChanged: (v) => set(() => status = v!),
            ),
            const SizedBox(height: 12),
            TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Review note (required)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (note.text.trim().isEmpty) {
      if (mounted) showSnack(context, 'A review note is required for status overrides.', error: true);
      return;
    }
    try {
      await Db.col('attendance').doc(widget.a['id']).update({
        'status': status,
        'reviewNote': note.text.trim(),
        'reviewedBy': widget.reviewer?.name,
        'reviewedAt': FieldValue.serverTimestamp(),
      });
      await Db.audit('attendance_review', 'attendance/${widget.a['id']}', {'from': widget.a['status'], 'to': status});
      if (mounted) {
        showSnack(context, 'Attendance updated.', success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Widget _point(String title, Map? p) {
    if (p == null) {
      return Card(child: ListTile(title: Text(title), subtitle: const Text('Not recorded')));
    }
    final ll = LatLng(asDouble(p['lat']), asDouble(p['lng']));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 170,
          child: OsmMap(center: ll, zoom: 16, layers: [
            if (_b != null) PolygonLayer(polygons: [boundaryPolygon(_b!)]),
            CircleLayer(circles: [CircleMarker(point: ll, radius: asDouble(p['accuracy'], 10), useRadiusInMeter: true, color: AppColors.info.withValues(alpha: 0.15))]),
            MarkerLayer(markers: [Marker(point: ll, width: 20, height: 20, child: const MyLocationDot())]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            InfoRow(Icons.schedule, 'Time', fmtDateTime(p['time'])),
            InfoRow(Icons.place_outlined, 'Coordinates', '${ll.latitude.toStringAsFixed(6)}, ${ll.longitude.toStringAsFixed(6)}'),
            InfoRow(Icons.gps_fixed, 'Accuracy', '±${asDouble(p['accuracy']).toStringAsFixed(1)} m'),
            InfoRow(Icons.layers_outlined, 'Location', titleCase(p['geoStatus'] ?? 'n/a'), color: statusColor(p['geoStatus'])),
            if (p['geoMessage'] != null) Padding(padding: const EdgeInsets.only(left: 28), child: Text(p['geoMessage'], style: const TextStyle(fontSize: 12, color: AppColors.muted))),
            if (p['faceStatus'] != null) InfoRow(Icons.face, 'Face', titleCase(p['faceStatus']), color: statusColor(p['faceStatus'])),
            if (p['similarity'] != null) InfoRow(Icons.percent, 'Similarity', '${(asDouble(p['similarity']) * 100).toStringAsFixed(1)}% (threshold ${(asDouble(p['faceThreshold'], 0.6) * 100).toStringAsFixed(0)}%)'),
            if (p['mocked'] == true) const InfoRow(Icons.warning_amber, 'Warning', 'Mock location detected', color: AppColors.danger),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    final canReview = widget.reviewer?.isStaff == true;
    return Scaffold(
      appBar: AppBar(title: Text('${a['name'] ?? 'Attendance'} · ${fmtDate(a['date'])}')),
      floatingActionButton: canReview
          ? FloatingActionButton.extended(onPressed: _review, icon: const Icon(Icons.rate_review_outlined), label: const Text('Review'))
          : null,
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          StatusChip(a['status'] ?? 'pending'),
          const SizedBox(width: 8),
          if (a['synthetic'] == true) const DemoBadge(),
          if (_b?.synthetic == true && a['synthetic'] != true) const DemoBadge(),
        ]),
        if (a['reviewNote'] != null) ...[
          const SizedBox(height: 8),
          Text('Reviewed by ${a['reviewedBy'] ?? 'staff'}: ${a['reviewNote']}', style: const TextStyle(fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 12),
        _point('Check-in', a['checkIn'] as Map?),
        const SizedBox(height: 12),
        _point('Check-out', a['checkOut'] as Map?),
        const SizedBox(height: 70),
      ]),
    );
  }
}
