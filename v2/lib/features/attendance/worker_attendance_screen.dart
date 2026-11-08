import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/attendance_repository.dart';
import '../../data/location.dart';
import '../../data/session_controller.dart';
import '../../domain/attendance.dart';
import '../../domain/geo.dart';

/// Assisted attendance (Phase 1, section 4): the worker taps once, sees what
/// will be recorded and why, and confirms. Failed checks flag the record for
/// the supervisor; they never block it. Success is shown only after the server
/// confirms, otherwise "saved on this phone".
class WorkerAttendanceScreen extends StatefulWidget {
  const WorkerAttendanceScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<WorkerAttendanceScreen> createState() => _WorkerAttendanceScreenState();
}

class _WorkerAttendanceScreenState extends State<WorkerAttendanceScreen> {
  late final repo = AttendanceRepository(widget.session.user!.uid);
  bool _busy = false;

  static String _time(Object? t) {
    final d = t is Timestamp ? t.toDate().toLocal() : null;
    if (d == null) return '…';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _locationProblem(LocationProblem p) async {
    final s = Strings.of(context);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(p.message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
          if (p.code != 'timeout')
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
              onPressed: () {
                Navigator.pop(c);
                Location.openSettings(p.code);
              },
              child: Text(s.t('openSettings')),
            ),
        ],
      ),
    );
  }

  Future<void> _markAttendance() async {
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      final position = await Location.current();
      final areaIds = widget.session.current?.areaIds ?? const <String>[];
      final fences = await repo.geofencesFor(areaIds);
      final preview = repo.preview(position, fences, hasAssignedArea: areaIds.isNotEmpty);
      if (!mounted) return;
      final ok = await _confirm(preview);
      if (ok != true) return;
      final outcome = await repo.checkIn(
        preview,
        orgId: widget.session.current?.orgId,
        workerName: (widget.session.account?['displayName'] as String?) ?? '',
      );
      showToast(outcome == SaveOutcome.saved ? s.t('savedOk') : s.t('savedOffline'),
          kind: outcome == SaveOutcome.saved ? ToastKind.success : ToastKind.info);
    } on LocationProblem catch (p) {
      if (mounted) await _locationProblem(p);
    } catch (e) {
      showToast('$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(CheckInPreview p) {
    final s = Strings.of(context);
    final m = p.match;
    final String where;
    if (m == null) {
      where = s.t('noFence');
    } else {
      switch (m.result.placement) {
        case Placement.inside:
          where = s.t('inArea', {'name': m.fence.name});
        case Placement.outside:
          where = s.t('outsideArea', {'name': m.fence.name, 'm': (-m.result.edgeDistanceM).round().toString()});
        case Placement.uncertain:
          where = s.t('nearEdge', {'name': m.fence.name});
      }
    }
    final verified = p.verdict.status == AttendanceStatus.verified;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(verified ? Icons.verified : Icons.flag_outlined, color: verified ? AppColors.success : AppColors.turmeric, size: 30),
              const SizedBox(width: 10),
              Expanded(child: Text(where, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 8),
            Text(s.t('gpsAccuracy', {'m': p.position.accuracy.round().toString()}), style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 14),
            Text(verified ? s.t('willBeVerified') : s.t('willBeFlagged'), style: const TextStyle(fontSize: 15.5)),
            for (final r in p.verdict.reasons)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 8),
                child: Text('• ${s.t('reason_${r.code}')}', style: const TextStyle(fontSize: 15)),
              ),
            if (p.verdict.late) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${s.t('late')}.', style: const TextStyle(color: AppColors.turmeric))),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('confirmAttendance'))),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
          ]),
        ),
      ),
    );
  }

  Future<void> _finish() async {
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      // A final fix is recorded when available; check-out works without one.
      Position? fix;
      try {
        fix = await Location.current();
      } on LocationProblem {
        fix = null;
      }
      final outcome = await repo.checkOut(fix);
      showToast(outcome == SaveOutcome.saved ? s.t('savedOk') : s.t('savedOffline'),
          kind: outcome == SaveOutcome.saved ? ToastKind.success : ToastKind.info);
    } catch (e) {
      showToast('$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return StreamBuilder<Map<String, dynamic>?>(
      stream: repo.watchToday(),
      builder: (context, snap) {
        if (snap.hasError) return MessageView(icon: Icons.cloud_off_outlined, title: s.t('errorTitle'), body: '${snap.error}');
        if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        final day = snap.data;
        final ci = day?['checkIn'] as Map<String, dynamic>?;
        final co = day?['checkOut'] as Map<String, dynamic>?;
        final verified = ci?['status'] == 'verified';
        final reasons = ((ci?['reasons'] as List?) ?? const []).whereType<String>().toList();
        return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
          Text(s.t('attendanceTitle'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 6),
          Text(dayKey(DateTime.now()), style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (ci == null) ...[
                  Text(s.t('notMarked'), style: const TextStyle(fontSize: 17)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _markAttendance,
                    icon: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Icon(Icons.how_to_reg),
                    label: Text(_busy ? s.t('checkingLocation') : s.t('markAttendance')),
                  ),
                ] else ...[
                  Row(children: [
                    Icon(verified ? Icons.verified : Icons.flag_outlined, color: verified ? AppColors.success : AppColors.turmeric),
                    const SizedBox(width: 8),
                    Text(verified ? s.t('statusVerified') : s.t('statusFlagged'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    if (ci['late'] == true) ...[const SizedBox(width: 10), Text('· ${s.t('late')}', style: const TextStyle(color: AppColors.turmeric))],
                  ]),
                  const SizedBox(height: 10),
                  Text(s.t('startedAt', {'time': _time(ci['at'] ?? ci['deviceAt'])}), style: const TextStyle(fontSize: 16)),
                  for (final r in reasons)
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text('• ${s.t('reason_$r')}', style: const TextStyle(color: AppColors.muted))),
                  const SizedBox(height: 16),
                  if (co == null)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _finish,
                      icon: const Icon(Icons.logout),
                      label: Text(s.t('finishWork')),
                    )
                  else ...[
                    Text(s.t('finishedAt', {'time': _time(co['at'] ?? co['deviceAt'])}), style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(s.t('doneForToday'), style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600)),
                  ],
                ],
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text(s.t('privacyNote'), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        ]);
      },
    );
  }
}
