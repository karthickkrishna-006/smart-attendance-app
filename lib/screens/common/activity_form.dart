import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import '../../core/geo.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/evidence_storage.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';

/// Field activity / visit submission with GPS stamp and image evidence.
/// Images are compressed on-device (max 1280 px JPEG, < 1.5 MB) and uploaded
/// to Cloud Storage; the Firestore record stores only the object paths.
class ActivityForm extends StatefulWidget {
  final AppUser me;
  final Doc task;
  const ActivityForm({super.key, required this.me, required this.task});
  @override
  State<ActivityForm> createState() => _ActivityFormState();
}

class _ActivityFormState extends State<ActivityForm> {
  final _form = GlobalKey<FormState>();
  final _desc = TextEditingController();
  final _measure = TextEditingController();
  String _visitType = 'Inspection';
  bool _markDone = true;
  final List<Uint8List> _images = [];
  bool _storageEnabled = false;
  Position? _pos;
  GeoCheck? _geo;
  String? _locErr;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final p = await LocationService.current();
      final b = await Db.getBoundary(widget.me.boundaryId);
      final s = await Db.getSettings();
      if (!mounted) return;
      setState(() {
        _storageEnabled = s['evidenceStorageEnabled'] == true;
        _pos = p;
        _geo = checkLocation(LatLng(p.latitude, p.longitude), p.accuracy, b?.points, asDoubleSafe(s['maxGpsAccuracy']));
        _locErr = null;
      });
    } catch (e) {
      if (mounted) setState(() => _locErr = e.toString());
    }
  }

  double asDoubleSafe(dynamic v) => v is num ? v.toDouble() : 50;

  Future<void> _addImage(ImageSource src) async {
    if (_images.length >= 3) {
      showSnack(context, 'Maximum 3 evidence images per submission.');
      return;
    }
    XFile? x;
    try {
      x = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 90);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not open ${src == ImageSource.camera ? 'camera' : 'gallery'}: $e', error: true);
      return;
    }
    if (x == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(x.path).readAsBytes();
      var im = img.decodeImage(bytes);
      if (im == null) throw 'Unsupported image';
      im = img.bakeOrientation(im);
      if (im.width > 1280 || im.height > 1280) {
        im = im.width >= im.height ? img.copyResize(im, width: 1280) : img.copyResize(im, height: 1280);
      }
      var q = 80;
      var out = img.encodeJpg(im, quality: q);
      while (out.length > EvidenceStorage.maxBytes && q > 40) {
        q -= 10;
        out = img.encodeJpg(im, quality: q);
      }
      setState(() => _images.add(out));
    } catch (e) {
      if (mounted) showSnack(context, 'Image processing failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final ref = Db.col('activities').doc(); // ID generated first so Storage paths can reference it
      final paths = <String>[];
      for (int i = 0; i < _images.length; i++) {
        try {
          paths.add(await EvidenceStorage.upload(widget.me.uid, ref.id, i, _images[i]));
        } catch (e) {
          throw 'Photo upload failed: ${EvidenceStorage.errorText(e)}';
        }
      }
      // Only move the task forward along a transition the security rules allow
      // (assigned -> in_progress -> submitted). Previously a re-submission on
      // an already submitted/completed task tried to set it back to
      // 'in_progress', the rules rejected that, and the activity was left
      // saved while the task update failed.
      final current = (widget.task['status'] as String?) ?? 'assigned';
      String? next;
      if (_markDone && (current == 'assigned' || current == 'in_progress')) {
        next = 'submitted';
      } else if (current == 'assigned') {
        next = 'in_progress';
      }
      // Activity and task status are written together: both succeed or neither.
      final batch = Db.fs.batch();
      batch.set(ref, {
        'taskId': widget.task['id'],
        'taskTitle': widget.task['title'],
        'uid': widget.me.uid,
        'name': widget.me.name,
        'visitType': _visitType,
        'description': _desc.text.trim(),
        'measurement': _measure.text.trim(),
        'lat': _pos?.latitude,
        'lng': _pos?.longitude,
        'accuracy': _pos?.accuracy,
        'geoStatus': _geo?.status ?? 'unavailable',
        'images': paths, // Cloud Storage object paths only
        'reviewStatus': 'pending',
        'synthetic': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (next != null) {
        batch.update(Db.col('tasks').doc(widget.task['id']), {
          'status': next,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      await Db.audit('activity_submitted', 'tasks/${widget.task['id']}', {'images': paths.length});
      if (!mounted) return;
      showSnack(context, 'Activity submitted for supervisor review.', success: true);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, 'Submission failed: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Submit field activity')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.assignment_outlined, color: AppColors.navy),
              title: Text(widget.task['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(_locErr ??
                  (_pos == null
                      ? 'Capturing GPS location…'
                      : 'GPS ±${_pos!.accuracy.toStringAsFixed(0)} m · ${_geo?.message ?? ''}')),
              trailing: _pos == null && _locErr == null
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(onPressed: _locate, icon: const Icon(Icons.my_location)),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _visitType,
            decoration: const InputDecoration(labelText: 'Visit type'),
            items: const ['Inspection', 'Survey', 'Monitoring', 'Measurement', 'Beneficiary meeting', 'Other']
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: (v) => setState(() => _visitType = v!),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _desc,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Activity description / observations', alignLabelWithHint: true),
            validator: (v) => (v ?? '').trim().length < 10 ? 'Describe the activity (min 10 characters)' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _measure,
            decoration: const InputDecoration(labelText: 'Measurement / quantity (optional)', hintText: 'e.g. 120 m road, 15 saplings'),
          ),
          const SectionTitle('Image evidence'),
          if (!_storageEnabled)
            const Card(
              child: ListTile(
                leading: Icon(Icons.cloud_off_outlined, color: AppColors.warning),
                title: Text('Photo evidence is disabled'),
                subtitle: Text('It needs Cloud Storage for Firebase (Blaze plan). An administrator can enable it in Settings once storage is set up. Text and GPS details are still recorded.'),
              ),
            )
          else
          Wrap(spacing: 10, runSpacing: 10, children: [
            ..._images.asMap().entries.map((e) => Stack(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(e.value, width: 90, height: 90, fit: BoxFit.cover)),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: InkWell(
                      onTap: () => setState(() => _images.removeAt(e.key)),
                      child: const CircleAvatar(radius: 12, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)),
                    ),
                  ),
                ])),
            if (_images.length < 3) ...[
              _addBtn(Icons.photo_camera_outlined, 'Camera', () => _addImage(ImageSource.camera)),
              _addBtn(Icons.photo_library_outlined, 'Gallery', () => _addImage(ImageSource.gallery)),
            ],
          ]),
          const SizedBox(height: 10),
          SwitchListTile(
            value: _markDone,
            onChanged: (v) => setState(() => _markDone = v),
            contentPadding: EdgeInsets.zero,
            title: const Text('Mark task as submitted for review'),
            subtitle: const Text('Turn off for progress updates'),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send),
            label: const Text('Submit activity'),
          ),
        ]),
      ),
    );
  }

  Widget _addBtn(IconData i, String l, VoidCallback onTap) => InkWell(
        onTap: _busy ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.navy.withValues(alpha: 0.3)),
            color: Colors.white,
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(i, color: AppColors.navy),
            const SizedBox(height: 4),
            Text(l, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      );
}
