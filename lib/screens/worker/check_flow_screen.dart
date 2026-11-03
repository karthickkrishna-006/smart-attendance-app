import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import '../../core/fmt.dart';
import '../../core/geo.dart';
import '../../core/osm_map.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/face_service.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';
import 'face_enroll_screen.dart';

/// Check-in / check-out workflow: GPS fix → GIS boundary validation →
/// AI face verification → attendance record with linked verification outcomes.
class CheckFlowScreen extends StatefulWidget {
  final AppUser me;
  final bool checkOut;
  const CheckFlowScreen({super.key, required this.me, this.checkOut = false});
  @override
  State<CheckFlowScreen> createState() => _CheckFlowScreenState();
}

class _CheckFlowScreenState extends State<CheckFlowScreen> {
  Map<String, dynamic>? _settings;
  Boundary? _boundary;
  Position? _pos;
  GeoCheck? _geo;
  String? _locError;
  LocationException? _locEx;
  bool _locating = false;

  FaceVerification? _face;
  bool _faceBusy = false;
  bool _saving = false;

  bool get _needFace => !widget.checkOut && (_settings?['requireFace'] ?? true) == true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _settings = await Db.getSettings();
    _boundary = await Db.getBoundary(widget.me.boundaryId);
    if (mounted) setState(() {});
    await _locate();
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _locError = null;
      _locEx = null;
    });
    try {
      final p = await LocationService.current();
      final g = checkLocation(LatLng(p.latitude, p.longitude), p.accuracy, _boundary?.points, asDouble(_settings?['maxGpsAccuracy'], 50));
      setState(() {
        _pos = p;
        _geo = g;
      });
    } on LocationException catch (e) {
      setState(() {
        _locError = e.message;
        _locEx = e;
      });
    } catch (e) {
      setState(() => _locError = 'Location error: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _captureFace() async {
    if (!widget.me.faceEnrolled) {
      final go = await confirm(context, 'Face not enrolled', 'You need to enrol your reference face before verification. Enrol now?', ok: 'Enrol');
      if (go && mounted) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => FaceEnrollScreen(target: widget.me)));
        if (mounted) Navigator.pop(context); // reopen flow with fresh profile
      }
      return;
    }
    XFile? x;
    try {
      x = await ImagePicker().pickImage(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxWidth: 1080, imageQuality: 92);
    } catch (e) {
      if (mounted) showSnack(context, 'Camera unavailable or permission denied: $e', error: true);
      return;
    }
    if (x == null) return;
    setState(() => _faceBusy = true);
    final threshold = asDouble(_settings?['faceThreshold'], 0.6);
    List<double>? ref;
    try {
      ref = await FaceTemplates.readOwn(widget.me.uid); // owner-only read
    } catch (_) {
      ref = null;
    }
    final r = ref == null
        ? FaceVerification('unavailable', false, null, threshold, 'Could not read your enrolled face template (offline or not enrolled).')
        : await FaceService.verify(x.path, ref, threshold);
    try {
      await File(x.path).delete(); // selfie is never kept
    } catch (_) {}
    // Log every verification attempt (auditable)
    try {
      await Db.col('verifications').add({
        ...r.toMap(widget.me.uid),
        'uid': widget.me.uid,
        'name': widget.me.name,
        'type': 'face',
        'context': widget.checkOut ? 'check_out' : 'check_in',
        'createdAt': FieldValue.serverTimestamp(),
        'date': dayKey(DateTime.now()),
      });
    } catch (_) {}
    if (r.status == 'failed' && Db.ruleOn(_settings!, 'face_failed')) {
      await Db.raiseAlert(
        type: 'face_failed',
        description: 'Face verification failed for ${widget.me.name} (${((r.similarity ?? 0) * 100).toStringAsFixed(1)}% similarity).',
        severity: 'high',
        uid: widget.me.uid,
        workerName: widget.me.name,
      );
    }
    if (mounted) setState(() {
      _face = r;
      _faceBusy = false;
    });
  }

  String _computeStatus() {
    final s = _settings!;
    final geoOk = _geo?.status == 'inside';
    final geoUnknown = _geo == null || _geo!.status == 'no_boundary' || _geo!.status == 'low_accuracy';
    final faceOk = _face?.verified == true;
    final faceUnknown = _face == null || _face!.status == 'unavailable';
    final reqBoundary = s['requireBoundary'] == true;
    if (_face?.status == 'failed') return 'rejected';
    if (reqBoundary && _geo?.status == 'outside') return 'rejected';
    if ((_needFace && (faceUnknown || !faceOk)) || (reqBoundary && geoUnknown)) return 'pending_verification';
    final now = DateTime.now();
    if (now.hour * 60 + now.minute > hm(s['lateAfter'] as String)) return 'late';
    return 'present';
  }

  Future<void> _submit() async {
    if (_pos == null) return;
    setState(() => _saving = true);
    final me = widget.me;
    final today = dayKey(DateTime.now());
    final ref = Db.col('attendance').doc('${me.uid}_$today');
    final s = _settings!;
    final point = {
      'time': FieldValue.serverTimestamp(),
      'lat': _pos!.latitude,
      'lng': _pos!.longitude,
      'accuracy': _pos!.accuracy,
      'gpsTime': Timestamp.fromDate(_pos!.timestamp),
      'mocked': _pos!.isMocked,
      'geoStatus': _geo?.status,
      'geoMessage': _geo?.message,
      'distanceToEdge': (_geo?.distanceToEdge.isFinite ?? false) ? _geo!.distanceToEdge : null,
      'boundaryId': _boundary?.id,
      'boundaryLayer': _boundary?.layer,
      'attributeColumn': _boundary?.attributeColumn,
      'attributeValue': _boundary?.attributeValue,
      'boundarySynthetic': _boundary?.synthetic,
      if (_face != null) ...{
        'faceStatus': _face!.status,
        'similarity': _face!.similarity,
        'faceThreshold': _face!.threshold,
        'faceMessage': _face!.message,
      } else
        'faceStatus': _needFace ? 'not_performed' : 'not_required',
    };
    try {
      // location verification log
      await Db.col('verifications').add({
        'type': 'location',
        'uid': me.uid,
        'name': me.name,
        'status': _geo?.status,
        'message': _geo?.message,
        'lat': _pos!.latitude,
        'lng': _pos!.longitude,
        'accuracy': _pos!.accuracy,
        'boundaryId': _boundary?.id,
        'context': widget.checkOut ? 'check_out' : 'check_in',
        'createdAt': FieldValue.serverTimestamp(),
        'date': today,
      });
      if (widget.checkOut) {
        await ref.set({'checkOut': point, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
        await LiveTracker.stop(markOffDuty: true);
      } else {
        var status = _computeStatus();
        Map<String, dynamic> record(String st) => {
              'uid': me.uid,
              'name': me.name,
              'employeeId': me.employeeId,
              'date': today,
              'status': st,
              'boundaryId': me.boundaryId,
              'checkIn': point,
              'synthetic': false,
              'createdAt': FieldValue.serverTimestamp(),
            };
        try {
          await ref.set(record(status));
        } on FirebaseException catch (e) {
          // The server re-checks lateness against its own clock (IST). If the
          // phone clock was slightly behind the cut-off, resubmit as late.
          if (e.code == 'permission-denied' && status == 'present') {
            status = 'late';
            await ref.set(record(status));
          } else {
            rethrow;
          }
        }
        if (status == 'late' && Db.ruleOn(s, 'late_checkin')) {
          await Db.raiseAlert(type: 'late_checkin', description: '${me.name} checked in late at ${fmtTime(DateTime.now())}.', severity: 'medium', uid: me.uid, workerName: me.name, dedupId: 'late_${me.uid}_$today');
        }
        LiveTracker.start(me);
      }
      // location-based alerts
      if (_geo?.status == 'outside' && Db.ruleOn(s, 'outside_boundary')) {
        await Db.raiseAlert(type: 'outside_boundary', description: '${me.name} ${widget.checkOut ? 'checked out' : 'checked in'} outside the assigned boundary (${_geo!.distanceToEdge.toStringAsFixed(0)} m away).', severity: 'high', uid: me.uid, workerName: me.name);
      }
      if (_geo?.status == 'low_accuracy' && Db.ruleOn(s, 'low_accuracy')) {
        await Db.raiseAlert(type: 'low_accuracy', description: 'Low GPS accuracy (±${_pos!.accuracy.toStringAsFixed(0)} m) during ${me.name}\'s attendance.', severity: 'low', uid: me.uid, workerName: me.name);
      }
      if (_pos!.isMocked && Db.ruleOn(s, 'mock_location')) {
        await Db.raiseAlert(type: 'mock_location', description: 'Mock (fake) GPS location detected during ${me.name}\'s attendance.', severity: 'critical', uid: me.uid, workerName: me.name, dedupId: 'mock_${me.uid}_$today');
      }
      if (!mounted) return;
      showSnack(context, widget.checkOut ? 'Checked out successfully.' : 'Check-in recorded.', success: true);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not save attendance: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _pos != null && (!_needFace || _face != null);
    return Scaffold(
      appBar: AppBar(title: Text(widget.checkOut ? 'Check out' : 'Check in')),
      body: _settings == null
          ? const LoadingView(label: 'Loading rules…')
          : ListView(padding: const EdgeInsets.all(16), children: [
              _stepHeader(1, 'Location verification', _geo != null),
              _locationCard(),
              if (_needFace) ...[
                _stepHeader(2, 'AI face verification', _face != null),
                _faceCard(),
              ],
              _stepHeader(_needFace ? 3 : 2, 'Submit', false),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (!widget.checkOut && ready)
                      Row(children: [
                        const Text('Resulting status: '),
                        StatusChip(_computeStatus()),
                      ]),
                    if (!widget.checkOut && ready) const SizedBox(height: 6),
                    const Text(
                      'GPS can be inaccurate or spoofed; coordinates alone are not conclusive proof of presence. Your supervisor may review this record.',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: ready && !_saving ? _submit : null,
                      icon: _saving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check),
                      label: Text(widget.checkOut ? 'Confirm check-out' : 'Submit attendance'),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }

  Widget _stepHeader(int n, String t, bool done) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
        child: Row(children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: done ? AppColors.success : AppColors.navy,
            child: done ? const Icon(Icons.check, size: 15, color: Colors.white) : Text('$n', style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
        ]),
      );

  Widget _locationCard() {
    final b = _boundary;
    final pos = _pos == null ? null : LatLng(_pos!.latitude, _pos!.longitude);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 220,
          child: (pos == null && b == null)
              ? Center(child: _locating ? const LoadingView(label: 'Acquiring GPS fix…') : const Icon(Icons.location_off, size: 40, color: AppColors.muted))
              : OsmMap(
                  key: ValueKey('${pos?.latitude}_${b?.id}'),
                  center: pos ?? centroid(b!.points),
                  zoom: 16,
                  layers: [
                    if (b != null) PolygonLayer(polygons: [boundaryPolygon(b, highlight: true)]),
                    if (pos != null)
                      CircleLayer(circles: [
                        CircleMarker(point: pos, radius: _pos!.accuracy, useRadiusInMeter: true, color: AppColors.info.withOpacity(0.15), borderColor: AppColors.info, borderStrokeWidth: 1),
                      ]),
                    if (pos != null) MarkerLayer(markers: [Marker(point: pos, width: 22, height: 22, child: const MyLocationDot())]),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_locError != null) ...[
              Text(_locError!, style: const TextStyle(color: AppColors.danger)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                OutlinedButton(onPressed: _locate, child: const Text('Retry')),
                if (_locEx?.openSettings == true) OutlinedButton(onPressed: LocationService.openSettings, child: const Text('Open GPS settings')),
                if (_locEx?.openAppSettings == true) OutlinedButton(onPressed: LocationService.openAppSettings, child: const Text('App settings')),
              ]),
            ] else if (_pos != null) ...[
              Row(children: [
                StatusChip(_geo!.status),
                const SizedBox(width: 8),
                if (b?.synthetic == true) const DemoBadge(),
                const Spacer(),
                TextButton.icon(onPressed: _locating ? null : _locate, icon: const Icon(Icons.refresh, size: 18), label: const Text('Refresh')),
              ]),
              const SizedBox(height: 6),
              Text(_geo!.message),
              const Divider(height: 20),
              InfoRow(Icons.place_outlined, 'Coordinates', '${_pos!.latitude.toStringAsFixed(6)}, ${_pos!.longitude.toStringAsFixed(6)}'),
              InfoRow(Icons.gps_fixed, 'GPS accuracy', '±${_pos!.accuracy.toStringAsFixed(1)} m',
                  color: _pos!.accuracy > asDouble(_settings?['maxGpsAccuracy'], 50) ? AppColors.danger : null),
              InfoRow(Icons.schedule, 'Fix time', fmtDateTime(_pos!.timestamp)),
              InfoRow(Icons.layers_outlined, 'Boundary', b == null ? 'Not assigned' : '${b.name} (${b.layer.isEmpty ? 'layer n/a' : b.layer})'),
              if (_pos!.isMocked) const InfoRow(Icons.warning_amber, 'Warning', 'Mock location app detected', color: AppColors.danger),
            ] else
              const Text('Acquiring GPS fix…'),
          ]),
        ),
      ]),
    );
  }

  Widget _faceCard() {
    final f = _face;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_faceBusy)
            const LoadingView(label: 'Running AI face verification…')
          else if (f == null) ...[
            const Row(children: [
              Icon(Icons.face, size: 40, color: AppColors.navy),
              SizedBox(width: 12),
              Expanded(child: Text('Take a selfie. It will be compared on-device with your enrolled reference face.')),
            ]),
            const SizedBox(height: 14),
            FilledButton.icon(onPressed: _captureFace, icon: const Icon(Icons.camera_alt_outlined), label: const Text('Capture selfie')),
          ] else ...[
            Row(children: [
              if (f.thumbnail != null) AvatarCircle(name: '', photo: f.thumbnail, radius: 30) else const Icon(Icons.face, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  StatusChip(f.status),
                  const SizedBox(height: 6),
                  if (f.similarity != null)
                    Text('Similarity ${(f.similarity! * 100).toStringAsFixed(1)}%  (threshold ${(f.threshold * 100).toStringAsFixed(0)}%)',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
            ]),
            if (f.similarity != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: f.similarity!.clamp(0.0, 1.0),
                  minHeight: 8,
                  color: f.verified ? AppColors.success : AppColors.danger,
                  backgroundColor: AppColors.surface,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(f.message),
            const SizedBox(height: 4),
            Text('Model: ${FaceService.modelName}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: _captureFace, icon: const Icon(Icons.refresh), label: const Text('Retake')),
          ],
        ]),
      ),
    );
  }
}
