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
import '../../data/photo_attendance.dart';
import '../../data/scoped.dart';
import '../../data/session_controller.dart';
import '../../domain/attendance.dart';
import '../../domain/designations.dart';
import '../../domain/geo.dart';
import '../work/worker_work_screens.dart' show shortDateTime;

DateTime _local(Object? t) => t is Timestamp ? t.toDate().toLocal() : DateTime.now();

String designationTitle(Strings s, String? key) {
  final d = Designation.fromKey(key);
  return d == null ? '' : s.t('d_${d.key}');
}

class _Thumb extends StatefulWidget {
  const _Thumb({required this.repo, required this.id, this.size = 56});
  final PhotoAttendanceRepository repo;
  final String id;
  final double size;
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _f = widget.repo.photo(widget.id);
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: FutureBuilder<Uint8List?>(
            future: _f,
            builder: (context, snap) => snap.data == null
                ? const ColoredBox(color: AppColors.surface, child: Icon(Icons.photo_outlined, color: AppColors.muted))
                : Image.memory(snap.data!, fit: BoxFit.cover),
          ),
        ),
      );
}

Widget _slotChip(Strings s, SlotResult r) {
  final (Color c, String text) = switch (r.state) {
    SlotState.done => (AppColors.success, s.t('slotDone', {'time': '${r.at!.hour.toString().padLeft(2, '0')}:${r.at!.minute.toString().padLeft(2, '0')}'})),
    SlotState.pending => (AppColors.indigo, s.t('slotPending')),
    SlotState.missed => (AppColors.danger, s.t('slotMissed')),
  };
  return Chip(
    avatar: Icon(r.state == SlotState.done ? Icons.check_circle : (r.state == SlotState.missed ? Icons.cancel : Icons.schedule), color: c, size: 18),
    label: Text('${r.label} · $text'),
    backgroundColor: c.withValues(alpha: 0.08),
  );
}

// ------------------------------------------------------------ own attendance
/// Every staff member with a designation: today's required photos and the
/// "Take GPS photo" button. The first photo also marks the day's attendance.
class PhotoAttendanceScreen extends StatefulWidget {
  const PhotoAttendanceScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<PhotoAttendanceScreen> createState() => _PhotoAttendanceScreenState();
}

class _PhotoAttendanceScreenState extends State<PhotoAttendanceScreen> {
  late final repo = PhotoAttendanceRepository(widget.session);
  late final _stream = repo.watchMine(dayKey(DateTime.now()));
  bool _busy = false;

  Future<void> _take() async {
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final Position pos = await Location.current();
      final fences = await AttendanceRepository(widget.session.user!.uid).geofencesFor(widget.session.current?.areaIds ?? const []);
      final m = bestMatch(GeoPoint2(pos.latitude, pos.longitude), pos.accuracy, fences);
      if (!mounted) return;
      final note = TextEditingController();
      final where = m == null
          ? s.t('noFence')
          : switch (m.result.placement) {
              Placement.inside => s.t('inArea', {'name': m.fence.name}),
              Placement.outside => s.t('outsideArea', {'name': m.fence.name, 'm': (-m.result.edgeDistanceM).round().toString()}),
              Placement.uncertain => s.t('nearEdge', {'name': m.fence.name}),
            };
      final ok = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(c).bottom),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(bytes, height: 220, fit: BoxFit.cover)),
                const SizedBox(height: 10),
                Text(where, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Text(s.t('gpsAccuracy', {'m': pos.accuracy.round().toString()}), style: const TextStyle(color: AppColors.muted)),
                const SizedBox(height: 10),
                TextField(controller: note, decoration: InputDecoration(labelText: s.t('photoNote'))),
                const SizedBox(height: 14),
                FilledButton.icon(onPressed: () => Navigator.pop(c, true), icon: const Icon(Icons.check), label: Text(s.t('savePhoto'))),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
              ]),
            ),
          ),
        ),
      );
      if (ok != true) return;
      final outcome = await repo.submit(jpeg: bytes, position: pos, fences: fences, note: note.text);
      showToast(outcome == SaveOutcome.saved ? s.t('photoSaved') : s.t('savedOffline'),
          kind: outcome == SaveOutcome.saved ? ToastKind.success : ToastKind.info);
    } on LocationProblem catch (e) {
      showToast(e.message, kind: ToastKind.error);
    } catch (e) {
      showToast('$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final d = widget.session.designation;
    if (d == null || !d.schedule.required) {
      return MessageView(icon: Icons.badge_outlined, title: s.t('photoAttendance'), body: s.t('noDesignation'));
    }
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final list = snap.data ?? const <Map<String, dynamic>>[];
        final c = complianceFor(d.schedule, [for (final p in list) _local(p['createdAt'] ?? p['capturedAt'])], DateTime.now());
        return ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 32), children: [
          Text(s.t('photoAttendance'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.ink)),
          Text(s.t('d_${d.key}'), style: const TextStyle(color: AppColors.muted, fontSize: 15)),
          const SizedBox(height: 14),
          Card(
            color: c.complete ? const Color(0xFFE3EFE9) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.t('photosToday', {'n': '${c.taken}', 'm': '${c.required}'}), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (c.complete) Text(s.t('dayComplete'), style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600)),
                if (d.schedule.slotMinutes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(s.t('photoTimes'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 6, children: [for (final r in c.slots) _slotChip(s, r)]),
                ] else if (d.schedule.eventLabel != null)
                  Text(s.t('eventPhoto', {'event': s.t('ev_water_opened')}))
                else
                  Text(s.t('anyTime', {'n': '${d.schedule.minPhotos}'})),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : _take,
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.add_a_photo),
            label: Text(_busy ? s.t('checkingLocation') : s.t('takeGpsPhoto')),
          ),
          const SizedBox(height: 24),
          Text(s.t('todayPhotos'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (snap.hasError) Text('${snap.error}', style: const TextStyle(color: AppColors.danger)),
          if (list.isEmpty && !snap.hasError) Text('—', style: const TextStyle(color: AppColors.muted)),
          for (final p in list)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: _Thumb(repo: repo, id: p['id'] as String),
                title: Text('${shortDateTime(p['createdAt'] ?? p['capturedAt'])}${p['slot'] != null ? ' · ${p['slot']}' : ''}'),
                subtitle: Text([
                  p['status'] == 'verified' ? s.t('statusVerified') : s.t('statusFlagged'),
                  for (final r in ((p['reasons'] as List?) ?? const []).whereType<String>()) s.t('reason_$r'),
                ].join(' · ')),
                trailing: Icon(p['status'] == 'verified' ? Icons.verified : Icons.flag_outlined,
                    color: p['status'] == 'verified' ? AppColors.success : AppColors.turmeric),
              ),
            ),
        ]);
      },
    );
  }
}

// --------------------------------------------------------------- compliance
/// Monitors: photo attendance of every staff member in scope for a day.
class PhotoComplianceView extends StatefulWidget {
  const PhotoComplianceView({super.key, required this.session});
  final SessionController session;
  @override
  State<PhotoComplianceView> createState() => _PhotoComplianceViewState();
}

class _PhotoComplianceViewState extends State<PhotoComplianceView> {
  late final repo = PhotoAttendanceRepository(widget.session);
  DateTime _day = DateTime.now();
  late Stream<List<Map<String, dynamic>>> _stream = repo.watchScope(dayKey(_day));
  String _filter = 'all';

  void _shift(int d) {
    final next = _day.add(Duration(days: d));
    if (next.isAfter(DateTime.now())) return;
    setState(() {
      _day = next;
      _stream = repo.watchScope(dayKey(_day));
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final isToday = dayKey(_day) == dayKey(DateTime.now());
    final endOfDay = isToday ? DateTime.now() : DateTime(_day.year, _day.month, _day.day, 23, 59);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final all = snap.data ?? const <Map<String, dynamic>>[];
        final byPerson = <String, List<Map<String, dynamic>>>{};
        for (final p in all) {
          byPerson.putIfAbsent(p['uid'] as String? ?? '?', () => []).add(p);
        }
        final rows = [
          for (final e in byPerson.entries)
            if (Designation.fromKey(e.value.first['designation'] as String?) case final Designation d)
              (
                uid: e.key,
                name: (e.value.first['workerName'] as String?)?.trim().isNotEmpty == true ? e.value.first['workerName'] as String : s.t('unnamedWorker'),
                d: d,
                photos: e.value,
                c: complianceFor(d.schedule, [for (final p in e.value) _local(p['createdAt'] ?? p['capturedAt'])], endOfDay),
                flagged: e.value.where((p) => p['status'] != 'verified').length,
                demo: e.value.first['synthetic'] == true,
              ),
        ]..sort((a, b) => a.c.complete == b.c.complete ? a.name.compareTo(b.name) : (a.c.complete ? 1 : -1));
        final shown = rows.where((r) => switch (_filter) {
              'incomplete' => !r.c.complete,
              'village' => r.d.tier == StaffTier.village,
              'block' => r.d.tier == StaffTier.block,
              _ => true,
            });
        return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (scopeProblem(widget.session) != null) NoticeCard(text: scopeProblem(widget.session)!),
          Row(children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(child: Text(isToday ? '${s.t('today')} · ${dayKey(_day)}' : dayKey(_day), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600))),
            IconButton(onPressed: isToday ? null : () => _shift(1), icon: const Icon(Icons.chevron_right)),
          ]),
          Text('${rows.where((r) => r.c.complete).length} of ${rows.length} staff have all required photos'
              '${rows.isEmpty ? '' : ' · ${rows.fold<int>(0, (n, r) => n + r.c.missedSlots)} missed photo times'}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final f in const [('all', 'All'), ('incomplete', 'Incomplete'), ('village', 'Village panchayat staff'), ('block', 'Block staff')])
              ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
          ]),
          const SizedBox(height: 8),
          if (snap.hasError) Text('${snap.error}', style: const TextStyle(color: AppColors.danger)),
          if (!snap.hasData && !snap.hasError) const LinearProgressIndicator(),
          if (snap.hasData && rows.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('No GPS photos in your area for this day yet. Staff who took none are not listed.', textAlign: TextAlign.center)),
          for (final r in shown)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                leading: Icon(r.c.complete ? Icons.check_circle : Icons.error_outline, color: r.c.complete ? AppColors.success : AppColors.turmeric),
                title: Text('${r.name}${r.demo ? ' (demo)' : ''}'),
                subtitle: Text('${s.t('d_${r.d.key}')} · ${r.c.taken}/${r.c.required} photos'
                    '${r.c.missedSlots > 0 ? ' · ${r.c.missedSlots} missed' : ''}${r.flagged > 0 ? ' · ${r.flagged} to check' : ''}'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  if (r.c.slots.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: [for (final x in r.c.slots) _slotChip(s, x)]),
                  for (final p in r.photos)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: p['synthetic'] == true ? const Icon(Icons.photo_outlined) : _Thumb(repo: repo, id: p['id'] as String, size: 64),
                      title: Text('${shortDateTime(p['createdAt'] ?? p['capturedAt'])}${p['slot'] != null ? ' · ${p['slot']}' : ''}'),
                      subtitle: Text([
                        p['status'] == 'verified' ? 'Verified' : 'To check',
                        for (final x in ((p['reasons'] as List?) ?? const []).whereType<String>()) s.t('reason_$x'),
                        if ((p['note'] ?? '').toString().isNotEmpty) '"${p['note']}"',
                      ].join(' · ')),
                    ),
                ],
              ),
            ),
        ]);
      },
    );
  }
}

// ------------------------------------------------------------------ messages
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key, required this.session, this.standalone = false});
  final SessionController session;
  final bool standalone;
  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late final _stream = FirebaseFirestore.instance.collection('messages').orderBy('createdAt', descending: true).limit(100).snapshots();

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final body = StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) return MessageView(icon: Icons.cloud_off_outlined, title: s.t('messages'), body: '${snap.error}');
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final list = snap.data!.docs.map((d) => d.data()).where((m) => PhotoAttendanceRepository.messageIsFor(m, widget.session)).toList();
        if (list.isEmpty) return MessageView(icon: Icons.mail_outline, title: s.t('messages'), body: s.t('noMessages'));
        return ListView(padding: const EdgeInsets.all(16), children: [
          for (final m in list)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (m['priority'] == 'urgent')
                      Padding(padding: const EdgeInsets.only(right: 8), child: Chip(label: Text(s.t('urgent')), backgroundColor: AppColors.danger.withValues(alpha: 0.12))),
                    Expanded(child: Text('${m['title']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 6),
                  Text('${m['body']}', style: const TextStyle(height: 1.4)),
                  const SizedBox(height: 6),
                  Text('${m['createdByName'] ?? ''} · ${shortDateTime(m['createdAt'])}', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                ]),
              ),
            ),
        ]);
      },
    );
    return widget.standalone ? Scaffold(appBar: AppBar(title: Text(s.t('messages'))), body: body) : body;
  }
}
