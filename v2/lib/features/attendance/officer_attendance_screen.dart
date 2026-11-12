import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/officer_attendance.dart';
import '../../data/scoped.dart';
import '../../data/session_controller.dart';
import '../../domain/attendance.dart';
import '../../domain/attendance_summary.dart';
import '../staff/staff_screens.dart';

String _time(Object? t) {
  if (t is! Timestamp) return '…';
  final d = t.toDate().toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// The day's figures as a row of tiles. Used on the Overview and here.
class AttendanceSummaryTiles extends StatelessWidget {
  const AttendanceSummaryTiles({super.key, required this.summary});
  final AttendanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    Widget tile(String label, int n, Color c) => Container(
          constraints: const BoxConstraints(minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('$n', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: c)),
            Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ]),
        );
    return Wrap(spacing: 10, runSpacing: 10, children: [
      tile(s.t('present'), summary.present, AppColors.ink),
      tile(s.t('verifiedCount'), summary.verified, AppColors.success),
      tile(s.t('flaggedCount'), summary.flagged, AppColors.turmeric),
      tile(s.t('lateCount'), summary.late, AppColors.turmeric),
      tile(s.t('stillWorking'), summary.stillWorking, AppColors.indigo),
      tile(s.t('finished'), summary.finished, AppColors.muted),
    ]);
  }
}

/// Attendance for the officer's own scope (area or organisation), one day
/// at a time. Read-only: corrections come with their own audited workflow.
class OfficerAttendanceScreen extends StatefulWidget {
  const OfficerAttendanceScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<OfficerAttendanceScreen> createState() => _OfficerAttendanceScreenState();
}

class _OfficerAttendanceScreenState extends State<OfficerAttendanceScreen> {
  late final data = OfficerAttendance(widget.session);
  DateTime _day = DateTime.now();
  AttendanceFilter _filter = AttendanceFilter.all;
  late Stream<List<Map<String, dynamic>>> _stream = data.watch(dayKey(_day));
  Map<String, String> _areaNames = const {};

  bool get _isToday => dayKey(_day) == dayKey(DateTime.now());

  void _shift(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    setState(() {
      _day = next;
      _stream = data.watch(dayKey(_day));
    });
  }

  Future<void> _loadAreaNames(List<Map<String, dynamic>> records) async {
    final ids = {
      for (final r in records)
        if ((r['areaPath'] as List?)?.isNotEmpty ?? false) (r['areaPath'] as List).last as String,
    }..removeAll(_areaNames.keys);
    if (ids.isEmpty) return;
    try {
      final names = await data.areaNames(ids);
      if (mounted) setState(() => _areaNames = {..._areaNames, ...names});
    } catch (_) {}
  }

  String _filterLabel(AttendanceFilter f, Strings s) => switch (f) {
        AttendanceFilter.all => s.t('filterAll'),
        AttendanceFilter.flagged => s.t('flaggedCount'),
        AttendanceFilter.late => s.t('lateCount'),
        AttendanceFilter.stillWorking => s.t('stillWorking'),
      };

  void _details(Map<String, dynamic> r) {
    final s = Strings.of(context);
    final ci = (r['checkIn'] as Map?) ?? const {};
    final co = r['checkOut'] as Map?;
    final edge = ci['edgeDistanceM'];
    final placement = ci['placement'];
    final where = switch (placement) {
      'inside' => s.t('insideBy', {'m': '${(edge as num?)?.round() ?? 0}'}),
      'outside' => s.t('outsideBy', {'m': '${(-((edge as num?) ?? 0)).round()}'}),
      'uncertain' => s.t('atEdge'),
      _ => s.t('noFence'),
    };
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text(_name(r, s), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.login),
            title: Text('${s.t('checkInLabel')}: ${_time(ci['at'])}'),
            subtitle: Text('${ci['status'] == 'verified' ? s.t('statusVerified') : s.t('statusFlagged')}'
                '${ci['late'] == true ? ' · ${s.t('late')}' : ''}'),
          ),
          for (final reason in ((ci['reasons'] as List?) ?? const []).whereType<String>())
            Padding(padding: const EdgeInsets.only(left: 40, bottom: 4), child: Text('• ${s.t('reason_$reason')}')),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: Text(where),
            subtitle: Text(s.t('gpsAccuracy', {'m': '${(ci['accuracy'] as num?)?.round() ?? '?'}'})),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout),
            title: Text('${s.t('checkOutLabel')}: ${co == null ? s.t('notYet') : _time(co['at'])}'),
          ),
          const SizedBox(height: 8),
          Text(s.t('deviceChecked'), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        ]),
      ),
    );
  }

  String _name(Map<String, dynamic> r, Strings s) {
    final n = (r['workerName'] as String?)?.trim() ?? '';
    return n.isEmpty ? s.t('unnamedWorker') : n;
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(children: [
          const TabBar(tabs: [Tab(text: 'Daily attendance'), Tab(text: 'GPS photos')]),
          Expanded(child: TabBarView(children: [_daily(context), PhotoComplianceView(session: widget.session)])),
        ]),
      );

  Widget _daily(BuildContext context) {
    final s = Strings.of(context);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final all = snap.data;
        if (all != null) _loadAreaNames(all);
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          Row(children: [
            IconButton(tooltip: s.t('previousDay'), onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text(
                _isToday ? '${s.t('today')} · ${dayKey(_day)}' : dayKey(_day),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(tooltip: s.t('nextDay'), onPressed: _isToday ? null : () => _shift(1), icon: const Icon(Icons.chevron_right)),
          ]),
          const SizedBox(height: 8),
          if (scopeProblem(widget.session) != null) NoticeCard(text: scopeProblem(widget.session)!),
          if (snap.hasError)
            MessageView(icon: Icons.cloud_off_outlined, title: s.t('errorTitle'), body: '${snap.error}')
          else if (all == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else ...[
            AttendanceSummaryTiles(summary: AttendanceSummary.of(all)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: [
              for (final f in AttendanceFilter.values)
                ChoiceChip(label: Text(_filterLabel(f, s)), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
            ]),
            const SizedBox(height: 8),
            if (all.where((r) => matchesFilter(r, _filter)).isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(s.t('noAttendance'), textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
              )
            else
              Card(
                child: Column(children: [
                  for (final r in all.where((r) => matchesFilter(r, _filter)))
                    Builder(builder: (context) {
                      final ci = (r['checkIn'] as Map?) ?? const {};
                      final co = r['checkOut'] as Map?;
                      final verified = ci['status'] == 'verified';
                      final areaId = (r['areaPath'] as List?)?.isNotEmpty ?? false ? (r['areaPath'] as List).last as String : null;
                      return ListTile(
                        onTap: () => _details(r),
                        leading: Icon(verified ? Icons.verified : Icons.flag_outlined, color: verified ? AppColors.success : AppColors.turmeric),
                        title: Text(_name(r, s)),
                        subtitle: Text(
                          '${_time(ci['at'])} – ${co == null ? s.t('stillWorking') : _time(co['at'])}'
                          '${areaId != null ? ' · ${_areaNames[areaId] ?? '…'}' : ''}'
                          '${ci['late'] == true ? ' · ${s.t('late')}' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                      );
                    }),
                ]),
              ),
            const SizedBox(height: 12),
            Text(s.t('absentNote'), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
        ]);
      },
    );
  }
}
