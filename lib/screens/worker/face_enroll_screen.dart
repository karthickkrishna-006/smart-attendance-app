import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/face_service.dart';
import '../../services/models.dart';

/// Reference face enrolment. Two captures are taken; they must match each
/// other (consistency check), then the averaged embedding is stored as the
/// worker's biometric template in `face_templates/{uid}` (owner-readable only).
/// No photo or thumbnail is ever stored – previews exist only in memory.
class FaceEnrollScreen extends StatefulWidget {
  final AppUser target;
  const FaceEnrollScreen({super.key, required this.target});
  @override
  State<FaceEnrollScreen> createState() => _FaceEnrollScreenState();
}

class _FaceEnrollScreenState extends State<FaceEnrollScreen> {
  final List<FaceCapture> _caps = [];
  bool _busy = false;
  bool _consent = false;
  String? _modelStatus;

  @override
  void initState() {
    super.initState();
    FaceService.ensureLoaded().then((ok) {
      if (mounted) setState(() => _modelStatus = ok ? 'AI model ready · ${FaceService.modelInfo}' : (FaceService.loadError ?? 'Model unavailable'));
    });
  }

  Future<void> _capture() async {
    XFile? x;
    try {
      x = await ImagePicker().pickImage(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxWidth: 1080, imageQuality: 92);
    } catch (e) {
      if (mounted) showSnack(context, 'Camera unavailable or permission denied: $e', error: true);
      return;
    }
    if (x == null) return;
    setState(() => _busy = true);
    final c = await FaceService.process(x.path);
    try {
      await File(x.path).delete(); // the selfie itself is never kept
    } catch (_) {}
    setState(() => _busy = false);
    if (!c.ok) {
      if (mounted) showSnack(context, c.message, error: true);
      return;
    }
    if (_caps.isNotEmpty) {
      final sim = FaceService.cosine(_caps.first.embedding!, c.embedding!);
      if (sim < 0.5) {
        if (mounted) showSnack(context, 'The two captures do not look like the same person (${(sim * 100).toStringAsFixed(0)}%). Please retake.', error: true);
        return;
      }
    }
    setState(() => _caps.add(c));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final n = _caps.first.embedding!.length;
    final avg = List<double>.filled(n, 0);
    for (final c in _caps) {
      for (int i = 0; i < n; i++) {
        avg[i] += c.embedding![i] / _caps.length;
      }
    }
    final norm = math.sqrt(avg.fold<double>(0, (s, e) => s + e * e));
    final emb = avg.map((e) => norm == 0 ? e : e / norm).toList();
    try {
      await FaceTemplates.enrol(uid: widget.target.uid, embedding: emb, enrolledBy: Db.uid ?? '');
      await Db.audit('face_enrolled', 'users/${widget.target.uid}', {'samples': _caps.length});
      if (!mounted) return;
      showSnack(context, 'Face enrolled successfully.', success: true);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not save enrolment: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Face enrolment')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Enrolling: ${widget.target.name}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 8),
              const Text('Capture 2 clear, front-facing selfies in good light. Remove sunglasses/caps. Only one face should be visible.'),
              const SizedBox(height: 10),
              Row(children: [
                Icon(_modelStatus?.startsWith('AI model ready') == true ? Icons.memory : Icons.error_outline,
                    size: 18, color: _modelStatus?.startsWith('AI model ready') == true ? AppColors.success : AppColors.warning),
                const SizedBox(width: 6),
                Expanded(child: Text(_modelStatus ?? 'Loading AI model…', style: const TextStyle(fontSize: 12, color: AppColors.muted))),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: List.generate(2, (i) {
            final has = i < _caps.length;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 0 ? 8 : 0, left: i == 1 ? 8 : 0),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: has ? AppColors.success : const Color(0xFFD5DCE6), width: has ? 2 : 1),
                    ),
                    child: has
                        ? Center(child: AvatarCircle(name: '', photo: _caps[i].thumbnail, radius: 52))
                        : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(Icons.face_outlined, size: 44, color: AppColors.muted),
                            Text('Sample ${i + 1}', style: const TextStyle(color: AppColors.muted)),
                          ]),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 14),
        CheckboxListTile(
          value: _consent,
          onChanged: (v) => setState(() => _consent = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'I consent to my face being processed to create a biometric reference used only for attendance verification. The reference can be deleted by an administrator on request.',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
        const SizedBox(height: 10),
        if (_busy)
          const LoadingView(label: 'Processing…')
        else if (_caps.length < 2)
          FilledButton.icon(
            onPressed: _consent ? _capture : null,
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text('Capture sample ${_caps.length + 1} of 2'),
          )
        else
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.verified_user_outlined), label: const Text('Save reference face')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => setState(_caps.clear), child: const Text('Start over')),
          ]),
      ]),
    );
  }
}
