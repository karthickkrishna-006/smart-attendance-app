import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/fmt.dart';
import '../../core/geo.dart';
import '../../core/osm_map.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';
import '../../services/tracking_service.dart';
import 'check_flow_screen.dart';
import 'duty_card.dart';
import 'face_enroll_screen.dart';

class WorkerHome extends StatefulWidget {
  final AppUser me;
  const WorkerHome({super.key, required this.me});
  @override
  State<WorkerHome> createState() => _WorkerHomeState();
}

class _WorkerHomeState extends State<WorkerHome> {
  String get _today => dayKey(DateTime.now());

  @override
  void initState() {
    super.initState();
    // Continue today's duty if the app was closed while on duty.
    TrackingService.resume(widget.me);
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me;
    TrackingService.refreshProfile(me);
    final hour = DateTime.now().hour;
    final greet = hour < 12 ? 'Good morning' : (hour < 17 ? 'Good afternoon' : 'Good evening');
    return Scaffold(
      body: StreamBuilder(
        stream: Db.col('attendance').doc('${me.uid}_$_today').snapshots(),
        builder: (context, snap) {
          final att = snap.data?.data();
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Container(
                padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 18, 20, 26),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [AppColors.navyDark, AppColors.navy, Color(0xFF1B5E7A)]),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    AvatarCircle(name: me.name, radius: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('$greet,', style: const TextStyle(color: Colors.white70)),
                        Text(me.name, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                    ValueListenableBuilder<DutyState?>(
                      valueListenable: TrackingService.state,
                      builder: (context, duty, _) => duty == null
                          ? const SizedBox.shrink()
                          : Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: AppColors.success, borderRadius: BorderRadius.circular(20)),
                              child: const Row(children: [
                                Icon(Icons.gps_fixed, color: Colors.white, size: 14),
                                SizedBox(width: 4),
                                Text('On duty', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                              ]),
                            ),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Text(fmtDate(DateTime.now()), style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 4),
                  Text(
                    me.employeeId.isEmpty ? Roles.label(me.role) : '${Roles.label(me.role)} · ${me.employeeId}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!me.faceEnrolled) _enrollBanner(context),
                  if (me.boundaryId == null || me.boundaryId!.isEmpty) _noAreaBanner(),
                  _attendanceCard(context, att),
                  DutyCard(me: me),
                  const SectionTitle('My assigned area'),
                  _AreaCard(me: me),
                  const SectionTitle('Today at a glance'),
                  _TodayTasks(me: me),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _noAreaBanner() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          color: AppColors.warning.withValues(alpha: 0.08),
          child: const ListTile(
            leading: Icon(Icons.location_off_outlined, color: AppColors.warning, size: 32),
            title: Text('Work area not assigned yet', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('You can mark attendance now. It will be checked by your supervisor until your panchayat is assigned.'),
          ),
        ),
      );

  Widget _enrollBanner(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          color: AppColors.warning.withValues(alpha: 0.08),
          child: ListTile(
            leading: const Icon(Icons.face_retouching_natural, color: AppColors.warning, size: 32),
            title: const Text('Face not enrolled', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Enrol your face once so attendance can be verified.'),
            trailing: FilledButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FaceEnrollScreen(target: widget.me))),
              child: const Text('Enrol'),
            ),
          ),
        ),
      );

  Widget _attendanceCard(BuildContext context, Doc? att) {
    final ci = att?['checkIn'] as Map?;
    final co = att?['checkOut'] as Map?;
    final status = att?['status'] as String?;
    String hours = '--';
    if (ci != null) {
      final a = toDate(ci['time']);
      final b = toDate(co?['time']) ?? DateTime.now();
      if (a != null) {
        final m = b.difference(a).inMinutes;
        hours = '${m ~/ 60}h ${m % 60}m';
      }
    }
    final canIn = ci == null;
    final canOut = ci != null && co == null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text("Today's attendance", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const Spacer(),
            StatusChip(status ?? 'not_marked', label: status == null ? 'Not marked' : null),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            _timeBox('Check-in', fmtTime(ci?['time']), Icons.login, AppColors.success),
            const SizedBox(width: 10),
            _timeBox('Check-out', fmtTime(co?['time']), Icons.logout, AppColors.danger),
            const SizedBox(width: 10),
            _timeBox('Duration', hours, Icons.timer_outlined, AppColors.info),
          ]),
          if (ci != null) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              StatusChip(ci['faceStatus'] ?? 'unavailable', label: 'Face: ${titleCase(ci['faceStatus'] ?? 'n/a')}'),
              StatusChip(ci['geoStatus'] ?? 'no_boundary', label: 'Location: ${titleCase(ci['geoStatus'] ?? 'n/a')}'),
              if (ci['accuracy'] != null) StatusChip('info', label: 'GPS ±${asDouble(ci['accuracy']).toStringAsFixed(0)} m'),
            ]),
          ],
          const SizedBox(height: 16),
          if (canIn || canOut)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: canIn ? AppColors.success : AppColors.danger),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => CheckFlowScreen(me: widget.me, checkOut: canOut)),
                ),
                icon: Icon(canIn ? Icons.fingerprint : Icons.logout),
                label: Text(canIn ? 'Check in now' : 'Check out'),
              ),
            )
          else
            const Row(children: [
              Icon(Icons.check_circle, color: AppColors.success),
              SizedBox(width: 8),
              Text('Attendance completed for today'),
            ]),
        ]),
      ),
    );
  }

  Widget _timeBox(String label, String value, IconData icon, Color c) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Icon(icon, color: c, size: 20),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
          ]),
        ),
      );
}

class _AreaCard extends StatefulWidget {
  final AppUser me;
  const _AreaCard({required this.me});
  @override
  State<_AreaCard> createState() => _AreaCardState();
}

class _AreaCardState extends State<_AreaCard> {
  LatLng? _pos;
  double? _acc;
  String? _err;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final p = await LocationService.current();
      if (mounted) setState(() {
        _pos = LatLng(p.latitude, p.longitude);
        _acc = p.accuracy;
        _err = null;
      });
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: widget.me.boundaryId == null ? null : Db.col('boundaries').doc(widget.me.boundaryId).snapshots(),
      builder: (context, snap) {
        Boundary? b;
        if (snap.data?.exists == true) b = Boundary(snap.data!.id, {...snap.data!.data()!, 'id': snap.data!.id});
        final center = _pos ?? (b != null ? centroid(b.points) : const LatLng(12.6919, 79.9762));
        GeoCheck? g;
        if (_pos != null) g = checkLocation(_pos!, _acc ?? 0, b?.points, 1e9);
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            SizedBox(
              height: 190,
              child: OsmMap(
                key: ValueKey('${center.latitude}${b?.id}'),
                center: center,
                zoom: 15,
                layers: [
                  if (b != null) PolygonLayer(polygons: [boundaryPolygon(b, highlight: true)]),
                  if (_pos != null)
                    CircleLayer(circles: [
                      CircleMarker(point: _pos!, radius: _acc ?? 10, useRadiusInMeter: true, color: AppColors.info.withValues(alpha: 0.15), borderColor: AppColors.info, borderStrokeWidth: 1),
                    ]),
                  if (_pos != null) MarkerLayer(markers: [Marker(point: _pos!, width: 20, height: 20, child: const MyLocationDot())]),
                ],
              ),
            ),
            ListTile(
              leading: Icon(b == null ? Icons.layers_clear : Icons.layers, color: b?.synthetic == true ? AppColors.demo : AppColors.teal),
              title: Row(children: [
                Flexible(child: Text(b?.name ?? 'No boundary assigned', style: const TextStyle(fontWeight: FontWeight.w700))),
                if (b?.synthetic == true) ...[const SizedBox(width: 6), const DemoBadge()],
              ]),
              subtitle: Text(_err ??
                  (g == null
                      ? 'Getting your location…'
                      : '${g.message}${_acc != null ? '  (GPS ±${_acc!.toStringAsFixed(0)} m)' : ''}')),
              trailing: IconButton(onPressed: _locate, icon: const Icon(Icons.my_location)),
            ),
          ]),
        );
      },
    );
  }
}

class _TodayTasks extends StatelessWidget {
  final AppUser me;
  const _TodayTasks({required this.me});
  @override
  Widget build(BuildContext context) {
    return LiveQueries(
      queries: [Db.col('tasks').where('assignedTo', isEqualTo: me.uid)],
      builder: (context, d) {
        final t = d[0];
        int c(String s) => t.where((e) => e['status'] == s).length;
        final overdue = t.where((e) {
          final due = toDate(e['dueDate']);
          return due != null && due.isBefore(DateTime.now()) && e['status'] != 'completed';
        }).length;
        return GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.45,
          children: [
            StatCard(label: 'Assigned', value: '${c('assigned')}', icon: Icons.assignment_ind_outlined, color: AppColors.info),
            StatCard(label: 'In progress', value: '${c('in_progress')}', icon: Icons.autorenew, color: AppColors.warning),
            StatCard(label: 'Completed', value: '${c('completed')}', icon: Icons.task_alt, color: AppColors.success),
            StatCard(label: 'Overdue', value: '$overdue', icon: Icons.schedule, color: AppColors.danger),
          ],
        );
      },
    );
  }
}
