import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../domain/attendance.dart';
import '../domain/geo.dart';
import '../domain/live_update.dart';
import '../domain/street_zones.dart';
import '../domain/visits.dart';
import 'attendance_repository.dart';
import 'location.dart';
import 'session_controller.dart';
import 'street_zones_repo.dart';

/// Field duty: while on, the phone shows a permanent notification and
///  * updates the worker's live position (presence) about once a minute,
///  * adds a point to today's route about once a minute,
///  * records street entry and exit automatically (VisitTracker),
///  * marks attendance automatically on the first street entry of the day,
///  * on Stop: closes the open visit and records the check-out.
/// Tracking runs only between Start and Stop, never hidden.
class DutyService extends ChangeNotifier {
  DutyService._();
  static final instance = DutyService._();

  // Between streets: every 30 m or 3 min. Inside a street: every 15 m or
  // 60 s, so officers see the worker move smoothly where the work happens.
  static const _policy = LiveUpdatePolicy(minMoveM: 30, maxQuiet: Duration(minutes: 3));
  static const _streetPolicy = LiveUpdatePolicy(minMoveM: 15, maxQuiet: Duration(seconds: 60), minGap: Duration(seconds: 15));
  static const _routePolicy = LiveUpdatePolicy(minMoveM: 25);

  final _db = FirebaseFirestore.instance;
  SessionController? _session;
  StreamSubscription<Position>? _sub;
  List<Geofence> _fences = const [];
  Map<String, List<CleaningZone>> _zones = const {};
  final ZoneTracker _zoneTracker = ZoneTracker();

  /// Worker view: the street they are in and its zone progress (no times).
  String? get currentStreet => _tracker.current?.name;
  int get zonesDone => _zoneTracker.done.length;
  int get zonesTotal => _zones[_tracker.current?.id]?.length ?? 0;
  VisitTracker _tracker = VisitTracker();
  String? _openVisitId;
  Position? _last;
  GeoPoint2? _sentPoint;
  DateTime? _sentAt;
  GeoPoint2? _routePoint;
  DateTime? _routeAt;
  bool _handling = false;
  String? lastError;
  DateTime? startedAt;

  bool get onDuty => _sub != null;

  String get _uid => _session!.user!.uid;
  String get _name => (_session!.account?['displayName'] as String?) ?? '';
  String? get _orgId => _session!.current?.orgId;
  List<String> get _homePath {
    final ids = _session!.current?.areaIds ?? const <String>[];
    if (ids.isEmpty) return const [];
    return _session!.areaPaths[ids.first] ?? [ids.first];
  }

  Future<void> start(SessionController session) async {
    if (_sub != null) return;
    _session = session;
    lastError = null;
    await Location.current(); // permission and location-service checks, with plain messages
    _fences = await AttendanceRepository(_uid).geofencesFor(session.current?.areaIds ?? const []);
    try {
      _zones = await StreetZonesRepo().forStreets(_fences.map((f) => f.id));
    } catch (_) {
      _zones = const {}; // streets without zones still get check-in/check-out
    }
    _tracker = VisitTracker();
    _openVisitId = null;
    _sentPoint = null;
    _sentAt = null;
    _routePoint = null;
    _routeAt = null;
    final settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 20),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Field duty in progress',
              notificationText: 'Your location is recorded for field work until you tap Stop duty.',
              notificationChannelName: 'Field duty tracking',
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10);
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onFix, onError: (Object e) {
      lastError = '$e';
      notifyListeners();
    });
    startedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final now = DateTime.now();
    final closed = _tracker.close(now);
    if (closed != null) await _closeVisit(closed);
    final p = _last;
    if (_session != null && p != null) {
      await _guard(() => _writePresence(p, onDuty: false));
      // Automatic check-out when duty ends (only if checked in and not out).
      await _guard(() async {
        final repo = AttendanceRepository(_uid);
        final today = (await repo.today().get()).data();
        if (today?['checkIn'] != null && today?['checkOut'] == null) await repo.checkOut(p);
      });
    }
    startedAt = null;
    notifyListeners();
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // Saved on the phone; Firestore sends it when online.
    } catch (e) {
      lastError = '$e';
      notifyListeners();
    }
  }

  Future<void> _writePresence(Position p, {required bool onDuty}) => _db.doc('presence/$_uid').set({
        'uid': _uid,
        'workerName': _name,
        'orgId': _orgId,
        'areaPath': _homePath,
        'lat': p.latitude,
        'lng': p.longitude,
        'accuracy': p.accuracy,
        'onDuty': onDuty,
        'designation': _session!.current?.designation,
        'geofenceId': _tracker.current?.id,
        'at': FieldValue.serverTimestamp(),
        'synthetic': false,
      });

  Future<void> _onFix(Position p) async {
    if (_handling || _session == null) return;
    _handling = true;
    try {
      _last = p;
      final now = DateTime.now();
      final events = _tracker.update(GeoPoint2(p.latitude, p.longitude), p.accuracy, now, _fences);
      for (final e in events) {
        if (e.kind == VisitEventKind.entered) {
          await _openVisit(e);
          await _autoAttendance(p);
        } else {
          await _closeVisit(e);
        }
      }
      final here = GeoPoint2(p.latitude, p.longitude);
      // Cleaning zones inside the current street are ticked automatically.
      final street = _tracker.current;
      final id = _openVisitId;
      if (street != null && id != null) {
        final reached = _zoneTracker.update(here, p.accuracy, _zones[street.id] ?? const []);
        if (reached.isNotEmpty) {
          notifyListeners();
          await _guard(() => _db.doc('visits/$id').update({
                'zonesDone': FieldValue.arrayUnion([for (final z in reached) z.id]),
                'updatedAt': FieldValue.serverTimestamp(),
              }));
        }
      }
      // Smart updates: only after moving, every 5 minutes when still, or at
      // once on a street entry/exit.
      if ((_tracker.current != null ? _streetPolicy : _policy).shouldSend(lastSent: _sentPoint, lastSentAt: _sentAt, now: here, accuracyM: p.accuracy, at: now, force: events.isNotEmpty)) {
        _sentPoint = here;
        _sentAt = now;
        await _guard(() => _writePresence(p, onDuty: true));
      }
      if (p.accuracy <= 50 &&
          _routePolicy.shouldSend(lastSent: _routePoint, lastSentAt: _routeAt, now: here, accuracyM: p.accuracy, at: now)) {
        _routePoint = here;
        _routeAt = now;
        final day = dayKey(now);
        await _guard(() => _db.doc('routes/${_uid}_$day').set({
              'uid': _uid,
              'workerName': _name,
              'date': day,
              'orgId': _orgId,
              'areaPath': _homePath,
              'points': FieldValue.arrayUnion([
                {'lat': p.latitude, 'lng': p.longitude, 't': Timestamp.fromDate(now)},
              ]),
              'updatedAt': FieldValue.serverTimestamp(),
              'synthetic': false,
            }, SetOptions(merge: true)));
      }
    } finally {
      _handling = false;
    }
  }

  Future<void> _openVisit(VisitEvent e) async {
    final ref = _db.collection('visits').doc();
    _openVisitId = ref.id;
    _zoneTracker.reset();
    notifyListeners();
    await _guard(() => ref.set({
          'uid': _uid,
          'workerName': _name,
          'date': dayKey(e.enteredAt),
          'orgId': _orgId,
          'areaPath': e.fence.areaPath,
          'geofenceId': e.fence.id,
          'geofenceName': e.fence.name,
          'enteredAt': Timestamp.fromDate(e.enteredAt),
          'exitedAt': null,
          'durationMin': null,
          'createdAt': FieldValue.serverTimestamp(),
          'closedAt': null,
          'synthetic': false,
          'zonesTotal': (_zones[e.fence.id] ?? const []).length,
          'zonesDone': const <String>[],
        }));
  }

  Future<void> _closeVisit(VisitEvent e) async {
    final id = _openVisitId;
    _openVisitId = null;
    if (id == null || e.exitedAt == null) return;
    await _guard(() => _db.doc('visits/$id').update({
          'exitedAt': Timestamp.fromDate(e.exitedAt!),
          'durationMin': e.duration!.inMinutes,
          'closedAt': FieldValue.serverTimestamp(),
          'zonesDone': _zoneTracker.done.toList(),
        }));
    _zoneTracker.reset();
    notifyListeners();
  }

  /// First street entry of the day marks attendance (same checks as the button).
  Future<void> _autoAttendance(Position p) async {
    await _guard(() async {
      final repo = AttendanceRepository(_uid);
      final today = await repo.today().get();
      if (today.exists) return;
      final preview = repo.preview(p, _fences, hasAssignedArea: (_session!.current?.areaIds ?? const []).isNotEmpty);
      await repo.checkIn(preview,
          orgId: _orgId, workerName: _name, designation: _session!.current?.designation, homePath: _session!.homePath);
    });
  }
}
