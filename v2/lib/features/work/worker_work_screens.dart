import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:image_picker/image_picker.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/attendance_repository.dart';
import '../../data/location.dart';
import '../../data/session_controller.dart';
import '../../data/work_repository.dart';

String shortDateTime(Object? t) {
  if (t is! Timestamp) return '…';
  final d = t.toDate().toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
}

Color statusColor(String? s) => switch (s) {
      'approved' => AppColors.success,
      'rejected' || 'cancelled' => AppColors.danger,
      'rework' => AppColors.turmeric,
      _ => AppColors.indigo,
    };

/// One stored photo, loaded on demand (only people allowed by the rules can read it).
class ActivityPhoto extends StatefulWidget {
  const ActivityPhoto({super.key, required this.repo, required this.activityId, this.index = 0, this.size = 64});
  final WorkRepository repo;
  final String activityId;
  final int index;
  final double size;
  @override
  State<ActivityPhoto> createState() => _ActivityPhotoState();
}

class _ActivityPhotoState extends State<ActivityPhoto> {
  late final Future<Uint8List?> _bytes = widget.repo.photo(widget.activityId, widget.index);

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: FutureBuilder<Uint8List?>(
            future: _bytes,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const ColoredBox(color: AppColors.surface);
              final b = snap.data;
              if (b == null) return const ColoredBox(color: AppColors.surface, child: Icon(Icons.image_not_supported_outlined, color: AppColors.muted));
              return Image.memory(b, fit: BoxFit.cover);
            },
          ),
        ),
      );
}

// ------------------------------------------------------------------ activity
class WorkerActivityScreen extends StatefulWidget {
  const WorkerActivityScreen({super.key, required this.session, this.task});
  final SessionController session;
  final Map<String, dynamic>? task;
  @override
  State<WorkerActivityScreen> createState() => _WorkerActivityScreenState();
}

class _WorkerActivityScreenState extends State<WorkerActivityScreen> {
  late final repo = WorkRepository(widget.session);
  late final stream = repo.watchMyActivities();
  late final tasks = repo.watchTasks();
  final _title = TextEditingController();
  final _details = TextEditingController();
  final _photos = <Uint8List>[];
  String? _taskId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _taskId = widget.task?['id'] as String?;
    if (widget.task != null) _title.text = (widget.task!['title'] as String?) ?? '';
  }

  @override
  void dispose() {
    _title.dispose();
    _details.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final s = Strings.of(context);
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (bytes.length > WorkRepository.maxPhotoBytes) {
        showToast(s.t('photoTooLarge'), kind: ToastKind.error);
        return;
      }
      setState(() => _photos.add(bytes));
    } catch (_) {
      showToast(s.t('cameraFailed'), kind: ToastKind.error);
    }
  }

  Future<void> _send(List<Map<String, dynamic>> openTasks) async {
    final s = Strings.of(context);
    if (_photos.isEmpty) return showToast(s.t('needPhoto'), kind: ToastKind.error);
    if (_title.text.trim().isEmpty) return showToast(s.t('needTitle'), kind: ToastKind.error);
    setState(() => _busy = true);
    try {
      Position? position;
      try {
        position = await Location.current();
      } on LocationProblem {
        position = null;
      }
      final areaIds = widget.session.current?.areaIds ?? const <String>[];
      final fences = await AttendanceRepository(widget.session.user!.uid).geofencesFor(areaIds);
      final task = openTasks.where((t) => t['id'] == _taskId).firstOrNull;
      final outcome = await repo.submitActivity(
        title: _title.text,
        description: _details.text,
        photos: List.of(_photos),
        task: task,
        position: position,
        fences: fences,
      );
      showToast(outcome == SaveOutcome.saved ? s.t('workSent') : s.t('savedOffline'),
          kind: outcome == SaveOutcome.saved ? ToastKind.success : ToastKind.info);
      if (!mounted) return;
      setState(() {
        _photos.clear();
        _title.clear();
        _details.clear();
        _taskId = null;
      });
      if (widget.task != null) Navigator.of(context).maybePop();
    } catch (e) {
      showToast('$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final body = StreamBuilder<List<Map<String, dynamic>>>(
      stream: tasks,
      builder: (context, taskSnap) {
        final open = (taskSnap.data ?? const <Map<String, dynamic>>[])
            .where((t) => ['assigned', 'in_progress', 'rework'].contains(t['status']))
            .toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 32), children: [
          Text(s.t('newActivity'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (var i = 0; i < _photos.length; i++)
              Stack(children: [
                ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_photos.elementAt(i), width: 96, height: 96, fit: BoxFit.cover)),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy ? null : () => setState(() => _photos.removeAt(i)),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
              ]),
            if (_photos.length < 3)
              InkWell(
                onTap: _busy ? null : _takePhoto,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.green, width: 1.5)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.photo_camera, color: AppColors.green, size: 30),
                    Text(s.t('takePhoto'), textAlign: TextAlign.center, style: const TextStyle(color: AppColors.green, fontSize: 12)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 6),
          Text(s.t('photosCount', {'n': '${_photos.length}'}), style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 14),
          TextField(controller: _title, enabled: !_busy, decoration: InputDecoration(labelText: s.t('workTitle'))),
          const SizedBox(height: 10),
          TextField(controller: _details, enabled: !_busy, maxLines: 3, decoration: InputDecoration(labelText: s.t('workDescription'))),
          const SizedBox(height: 10),
          DropdownButtonFormField<String?>(
            value: open.any((t) => t['id'] == _taskId) ? _taskId : null,
            isExpanded: true,
            decoration: InputDecoration(labelText: s.t('linkTask')),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(s.t('noTaskLinked'))),
              for (final t in open) DropdownMenuItem<String?>(value: t['id'] as String, child: Text('${t['title']}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _busy ? null : (v) => setState(() => _taskId = v),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _send(open),
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.send),
            label: Text(_busy ? s.t('sendingWork') : s.t('submitWork')),
          ),
          if (widget.task == null) ...[
            const SizedBox(height: 28),
            Text(s.t('myWork'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snap) {
                if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: AppColors.danger));
                final list = snap.data;
                if (list == null) return const LinearProgressIndicator();
                if (list.isEmpty) return Text(s.t('noWorkYet'), style: const TextStyle(color: AppColors.muted));
                return Card(
                  child: Column(children: [
                    for (final a in list.take(30))
                      ListTile(
                        leading: (a['photoCount'] as num? ?? 0) > 0 ? ActivityPhoto(repo: repo, activityId: a['id'] as String, size: 52) : null,
                        title: Text('${a['title']}'),
                        subtitle: Text([
                          shortDateTime(a['createdAt']),
                          s.t('st_${a['status']}'),
                          if ((a['reviewNote'] ?? '').toString().isNotEmpty) '${s.t('reviewNoteLabel')}: ${a['reviewNote']}',
                        ].join(' · ')),
                        trailing: Icon(Icons.circle, size: 12, color: statusColor(a['status'] as String?)),
                      ),
                  ]),
                );
              },
            ),
          ],
        ]);
      },
    );
    return widget.task == null ? body : Scaffold(appBar: AppBar(title: Text(s.t('submitProof'))), body: body);
  }
}

// --------------------------------------------------------------------- tasks
class WorkerTasksScreen extends StatelessWidget {
  const WorkerTasksScreen({super.key, required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final repo = WorkRepository(session);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: repo.watchTasks(),
      builder: (context, snap) {
        if (snap.hasError) return MessageView(icon: Icons.cloud_off_outlined, title: s.t('errorTitle'), body: '${snap.error}');
        final list = snap.data;
        if (list == null) return const Center(child: CircularProgressIndicator());
        final visible = list.where((t) => t['status'] != 'cancelled').toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 32), children: [
          Text(s.t('myTasks'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 12),
          if (visible.isEmpty) Text(s.t('noTasks'), style: const TextStyle(color: AppColors.muted)),
          for (final t in visible)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${t['title']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                    Chip(label: Text(s.t('ts_${t['status']}')), backgroundColor: statusColor(t['status'] as String?).withValues(alpha: 0.12)),
                  ]),
                  if ((t['description'] ?? '').toString().isNotEmpty) Text('${t['description']}'),
                  const SizedBox(height: 6),
                  Text('${s.t('dueOn', {'date': '${t['dueDate']}'})} · ${s.t('pr_${t['priority'] ?? 'normal'}')}',
                      style: const TextStyle(color: AppColors.muted)),
                  if ((t['reviewNote'] ?? '').toString().isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text('${s.t('reviewNoteLabel')}: ${t['reviewNote']}')),
                  const SizedBox(height: 10),
                  Row(children: [
                    if (t['status'] == 'assigned')
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            try {
                              await repo.setTaskStatus(t['id'] as String, 'in_progress');
                            } catch (e) {
                              showToast('$e', kind: ToastKind.error);
                            }
                          },
                          child: Text(s.t('startTask')),
                        ),
                      ),
                    if (t['status'] == 'assigned') const SizedBox(width: 10),
                    if (['assigned', 'in_progress', 'rework'].contains(t['status']))
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => WorkerActivityScreen(session: session, task: t)),
                          ),
                          icon: const Icon(Icons.photo_camera),
                          label: Text(s.t('submitProof')),
                        ),
                      ),
                  ]),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
