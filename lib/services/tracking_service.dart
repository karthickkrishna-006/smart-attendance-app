import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../core/fmt.dart';
import '../core/geo.dart';
import 'db.dart';
import 'location_service.dart';
import 'models.dart';

/// What the worker's phone currently knows about its own field-duty session.
@immutable
class DutyState {
  final String sessionId;
  final DateTime startedAt;
  final int points;
  final double distanceM;
  final int insidePoints;
  final String? geoStatus;
  final DateTime? lastFix;

  /// Route points the server rejected or that failed to save. Shown to the
  /// worker; never hidden.
  final int failedPoints;
  const DutyState({
    required this.sessionId,
    required this.startedAt,
    this.points = 0,
    this.distanceM = 0,
    this.insidePoints = 0,
    this.geoStatus,
    this.lastFix,
    this.failedPoints = 0,
  });

  DutyState copyWith({
    int? points,
    double? distanceM,
    int? insidePoints,
    String? geoStatus,
    DateTime? lastFix,
    int? failedPoints,
  }) =>
      DutyState(
        sessionId: sessionId,
        startedAt: startedAt,
        points: points ?? this.points,
        distanceM: distanceM ?? this.distanceM,
        insidePoints: insidePoints ?? this.insidePoints,
        geoStatus: geoStatus ?? this.geoStatus,
        lastFix: lastFix ?? this.lastFix,
        failedPoints: failedPoints ?? this.failedPoints,
      );
}

/// What happened to one database write.
enum WriteOutcome {
  /// Confirmed by the server.
  saved,

  /// Not confirmed yet (usually no internet). Firestore keeps it on the phone
  /// and uploads it when the connection returns.
  queued,

  /// Rejected or failed. It will not be uploaded.
  failed,

  /// Nothing was written (for example, no GPS fix for the final point).
  skipped,
}

/// Result of stopping field duty, so the screen can tell the worker exactly
/// what was saved instead of assuming success.
@immutable
class StopResult {
  final WriteOutcome finalPoint;
  final WriteOutcome sessionClosed;
  final int failedPoints;
  final String? error;
  const StopResult({required this.finalPoint, required this.sessionClosed, this.failedPoints = 0, this.error});

  bool get fullySaved => finalPoint == WriteOutcome.saved && sessionClosed == WriteOutcome.saved && failedPoints == 0;
  bool get waitingForInternet => finalPoint == WriteOutcome.queued || sessionClosed == WriteOutcome.queued;
}

/// Field-duty tracking.
///
/// Firestore (see firestore.rules for who can read what):
///  * `tracking_sessions/{sessionId}`: one record per Start duty → Stop duty.
///  * `worker_location_updates/{pointId}`: the movement history (route).
///  * `locations/{uid}`: the latest position only, for the live map.
///
/// Tracking runs ONLY between "Start field duty" and "Stop duty" (or check-out
/// / sign-out). It runs as an Android foreground service with an ongoing
/// "Field duty in progress" notification. Android only shows that notification
/// if notifications are allowed for the app, so the duty card asks first and
/// tells the worker plainly if they are off. To limit battery and database use, a history point is saved only
/// when the worker moved at least `trackMinDistanceM` metres, after
/// `trackHeartbeatSec` seconds without a saved point, or when the
/// inside/outside-boundary result changes.
class TrackingService {
  TrackingService._();

  static final ValueNotifier<DutyState?> state = ValueNotifier<DutyState?>(null);
  static bool get onDuty => state.value != null;

  static const _channel = MethodChannel('in.cit.smartattendance/permissions');
  static const _statsEvery = 10; // write session totals every N points

  static StreamSubscription<Position>? _sub;
  static AppUser? _me;
  static Map<String, dynamic>? _session; // uid, supervisorId, boundaryId of the running session
  static Boundary? _boundary;
  static Map<String, dynamic> _settings = Db.defaultSettings;
  static LatLng? _lastSaved;
  static DateTime? _lastSavedAt;
  static String? _lastGeo;
  static int _sinceStats = 0;
  static bool _starting = false;
  static bool _stopping = false;

  /// A session whose closing write failed in this app run. resume() closes it
  /// again instead of restarting tracking the worker already stopped.
  static ({String id, String reason})? _closeRetry;

  /// How long to wait for the server before treating a write as queued offline.
  static const _serverWait = Duration(seconds: 15);

  /// Keeps the cached profile current (supervisor / boundary reassignment).
  static void refreshProfile(AppUser me) {
    if (_me?.uid == me.uid) _me = me;
  }

  /// Called when the worker home opens: continues today's active session after
  /// the app was closed, and closes sessions left open on earlier days.
  static Future<void> resume(AppUser me) async {
    if (onDuty || _starting) return;
    _starting = true;
    try {
      final snap = await Db.col('tracking_sessions')
          .where('uid', isEqualTo: me.uid)
          .where('status', isEqualTo: 'active')
          .get();
      final today = dayKey(DateTime.now());
      final retry = _closeRetry;
      QueryDocumentSnapshot<Map<String, dynamic>>? current;
      for (final d in snap.docs) {
        if (retry != null && d.id == retry.id) {
          // The worker already stopped this session; finish closing it.
          if (await _endSessionDoc(d.id, d.data(), retry.reason) != WriteOutcome.failed) _closeRetry = null;
        } else if (d.data()['date'] == today && current == null) {
          current = d;
        } else {
          await _endSessionDoc(d.id, d.data(), 'auto_closed');
        }
      }
      if (current == null) return;
      final s = current.data();
      _me = me;
      _session = {'id': current.id, 'supervisorId': s['supervisorId'], 'boundaryId': s['boundaryId'], 'date': s['date']};
      state.value = DutyState(
        sessionId: current.id,
        startedAt: toDate(s['startedAt']) ?? DateTime.now(),
        points: (s['pointCount'] as num?)?.toInt() ?? 0,
        distanceM: asDouble(s['distanceM']),
        insidePoints: (s['insideCount'] as num?)?.toInt() ?? 0,
      );
      await _startStream();
    } catch (e) {
      debugPrint('[tracking] resume failed: $e');
    } finally {
      _starting = false;
    }
  }

  /// Starts field duty: asks for permissions, creates the session, records the
  /// starting point and begins background tracking with a notification.
  static Future<void> startDuty(AppUser me) async {
    if (onDuty || _starting) return;
    _starting = true;
    try {
      await LocationService.ensurePermission();
      final first = await LocationService.current();
      _me = me;
      _settings = await Db.getSettings();
      _boundary = await Db.getBoundary(me.boundaryId);

      final ref = Db.col('tracking_sessions').doc();
      final today = dayKey(DateTime.now());
      await ref.set({
        'uid': me.uid,
        'name': me.name,
        'date': today,
        'boundaryId': me.boundaryId,
        'supervisorId': me.supervisorId,
        'status': 'active',
        'consent': true,
        'pointCount': 0,
        'insideCount': 0,
        'distanceM': 0,
        'synthetic': false,
        'startedAt': FieldValue.serverTimestamp(),
      });
      _session = {'id': ref.id, 'supervisorId': me.supervisorId, 'boundaryId': me.boundaryId, 'date': today};
      state.value = DutyState(sessionId: ref.id, startedAt: DateTime.now());
      _lastSaved = null;
      _lastSavedAt = null;
      _lastGeo = null;
      _sinceStats = 0;
      _trackFailures(_savePoint(first, 'start'));
      await _startStream();
      unawaited(Db.audit('duty_started', 'tracking_sessions/${ref.id}'));
    } finally {
      _starting = false;
    }
  }

  /// Ends field duty: saves the final point, THEN closes the session, then
  /// stops the background service (which removes the notification).
  ///
  /// Firestore sends one phone's writes in the order they were made, so the
  /// session can never be closed on the server before the final point arrives.
  /// The returned [StopResult] says what was really saved.
  static Future<StopResult> stopDuty({String reason = 'stopped_by_worker'}) async {
    final st = state.value;
    final session = _session;
    final me = _me;
    if (st == null || session == null || me == null || _stopping) {
      return const StopResult(finalPoint: WriteOutcome.skipped, sessionClosed: WriteOutcome.skipped);
    }
    _stopping = true;
    try {
      await _sub?.cancel();
      _sub = null;

      // 1. Final point (awaited).
      var finalPoint = WriteOutcome.skipped;
      String? error;
      Position? last;
      try {
        last = await LocationService.current().timeout(const Duration(seconds: 20));
      } catch (_) {
        // No final fix (indoors / GPS off): the route ends at the last saved point.
      }
      if (last != null) {
        final (outcome, e) = await _settle(_savePoint(last, 'stop'));
        finalPoint = outcome;
        error = e;
      }

      // 2. Close the session, only after the final point is saved or queued.
      final now = state.value ?? st;
      final points = finalPoint == WriteOutcome.failed ? now.points - 1 : now.points;
      final (closed, closeError) = await _settle(Db.col('tracking_sessions').doc(st.sessionId).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': reason,
        'pointCount': points < 0 ? 0 : points,
        'insideCount': now.insidePoints > points ? (points < 0 ? 0 : points) : now.insidePoints,
        'distanceM': double.parse(now.distanceM.toStringAsFixed(1)),
        'lastPointAt': FieldValue.serverTimestamp(),
      }));
      _closeRetry = closed == WriteOutcome.failed ? (id: st.sessionId, reason: reason) : null;

      // 3. Mark the live position as off duty (best effort; the map also
      //    greys out positions that stop updating).
      unawaited(_settle(Db.col('locations').doc(me.uid).set(
        {'onDuty': false, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      )));
      unawaited(Db.audit('duty_stopped', 'tracking_sessions/${st.sessionId}', {'reason': reason}).catchError((_) {}));

      return StopResult(
        finalPoint: finalPoint,
        sessionClosed: closed,
        failedPoints: (state.value ?? st).failedPoints,
        error: error ?? closeError,
      );
    } finally {
      _clear();
      _stopping = false;
    }
  }

  /// Waits for a write: saved (server confirmed), queued (no reply in time,
  /// kept on the phone for later upload) or failed (with the reason).
  static Future<(WriteOutcome, String?)> _settle(Future<void> write) async {
    try {
      await write.timeout(_serverWait);
      return (WriteOutcome.saved, null);
    } on TimeoutException {
      // Still pending. If it fails later, record that too.
      write.catchError((Object e) => debugPrint('[tracking] queued write failed later: $e'));
      return (WriteOutcome.queued, null);
    } catch (e) {
      debugPrint('[tracking] write failed: $e');
      return (WriteOutcome.failed, e.toString());
    }
  }

  /// Background route points are not awaited (the stream must keep running),
  /// but every failure is counted and shown to the worker.
  static void _trackFailures(Future<void> write) {
    write.catchError((Object e) {
      debugPrint('[tracking] point not saved: $e');
      final st = state.value;
      if (st != null) state.value = st.copyWith(failedPoints: st.failedPoints + 1);
    });
  }

  /// Stops the GPS stream without writing anything (used after sign-out,
  /// when the database can no longer be written).
  static Future<void> cancelLocal() async {
    await _sub?.cancel();
    _clear();
    _closeRetry = null;
  }

  static void _clear() {
    _sub = null;
    _session = null;
    _me = null;
    _boundary = null;
    _lastSaved = null;
    _lastSavedAt = null;
    _lastGeo = null;
    state.value = null;
  }

  static Future<WriteOutcome> _endSessionDoc(String id, Map<String, dynamic> s, String reason) async {
    final (outcome, _) = await _settle(Db.col('tracking_sessions').doc(id).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': reason,
        'pointCount': (s['pointCount'] as num?)?.toInt() ?? 0,
        'insideCount': (s['insideCount'] as num?)?.toInt() ?? 0,
        'distanceM': asDouble(s['distanceM']),
        'lastPointAt': s['lastPointAt'] ?? FieldValue.serverTimestamp(),
      }));
    return outcome;
  }

  /// Asks Android for permission to show notifications and returns the
  /// worker's actual answer: true only if notifications for this app are
  /// allowed (Android 13+ permission granted and not switched off in settings).
  /// Field duty can still run without it, but Android may then hide the
  /// "Field duty in progress" notification, so the screen must say so.
  static Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotifications') ?? false;
    } on MissingPluginException {
      return true; // not running on Android (for example, unit tests)
    } catch (e) {
      debugPrint('[tracking] notification permission check failed: $e');
      return false;
    }
  }

  static Future<void> _startStream() async {
    _settings = await Db.getSettings();
    _boundary ??= await Db.getBoundary(_session?['boundaryId'] as String?);
    await _sub?.cancel();
    _sub = LocationService.dutyStream(
      intervalSec: (_settings['trackingIntervalSec'] as num?)?.toInt() ?? 30,
    ).listen(_onPosition, onError: (e) => debugPrint('[tracking] stream error: $e'));
  }

  static void _onPosition(Position p) {
    if (state.value == null) return;
    final ll = LatLng(p.latitude, p.longitude);
    final minDist = asDouble(_settings['trackMinDistanceM'], 50);
    final heartbeat = (_settings['trackHeartbeatSec'] as num?)?.toInt() ?? 300;
    final maxAcc = asDouble(_settings['maxGpsAccuracy'], 50);
    final g = checkLocation(ll, p.accuracy, _boundary?.points, maxAcc);
    final moved = _lastSaved == null ? double.infinity : distanceMeters(_lastSaved!, ll);
    final waited = _lastSavedAt == null ? 1 << 30 : DateTime.now().difference(_lastSavedAt!).inSeconds;
    state.value = state.value!.copyWith(geoStatus: g.status, lastFix: DateTime.now());
    if (moved >= minDist || waited >= heartbeat || g.status != _lastGeo) {
      _trackFailures(_savePoint(p, 'track', geo: g));
    }
  }

  /// Saves one history point and the live position in one batch. The write is
  /// not awaited: with no network, Firestore keeps it on the phone and uploads
  /// it later, so a route recorded offline is not lost.
  static Future<void> _savePoint(Position p, String kind, {GeoCheck? geo}) {
    final me = _me;
    final session = _session;
    final st = state.value;
    if (me == null || session == null || st == null) return Future<void>.value();
    final ll = LatLng(p.latitude, p.longitude);
    final maxAcc = asDouble(_settings['maxGpsAccuracy'], 50);
    final g = geo ?? checkLocation(ll, p.accuracy, _boundary?.points, maxAcc);
    final edge = g.distanceToEdge.isFinite ? double.parse(g.distanceToEdge.toStringAsFixed(1)) : null;

    // Distance only counts between reasonably accurate fixes.
    var dist = st.distanceM;
    if (_lastSaved != null && p.accuracy <= maxAcc) dist += distanceMeters(_lastSaved!, ll);
    final points = st.points + 1;
    final inside = st.insidePoints + (g.status == 'inside' ? 1 : 0);

    final batch = Db.fs.batch();
    batch.set(Db.col('worker_location_updates').doc(), {
      'uid': me.uid,
      'sessionId': session['id'],
      'supervisorId': session['supervisorId'],
      'boundaryId': session['boundaryId'],
      'date': session['date'],
      'kind': kind,
      'lat': p.latitude,
      'lng': p.longitude,
      'accuracy': p.accuracy,
      'speed': p.speed >= 0 ? p.speed : null,
      'mocked': p.isMocked,
      'geoStatus': g.status,
      'distanceToEdge': edge,
      'gpsTime': Timestamp.fromDate(p.timestamp),
      'synthetic': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(
      Db.col('locations').doc(me.uid),
      {
        'uid': me.uid,
        'name': me.name,
        'lat': p.latitude,
        'lng': p.longitude,
        'accuracy': p.accuracy,
        'mocked': p.isMocked,
        'geoStatus': g.status,
        'distanceToEdge': edge,
        'boundaryId': me.boundaryId,
        'supervisorId': me.supervisorId,
        'sessionId': session['id'],
        'onDuty': kind != 'stop',
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    _sinceStats++;
    if (_sinceStats >= _statsEvery && kind != 'stop') {
      _sinceStats = 0;
      batch.update(Db.col('tracking_sessions').doc(session['id'] as String), {
        'pointCount': points,
        'insideCount': inside,
        'distanceM': double.parse(dist.toStringAsFixed(1)),
        'lastPointAt': FieldValue.serverTimestamp(),
      });
    }
    final write = batch.commit();

    _raiseAlerts(me, g, p);
    _lastSaved = ll;
    _lastSavedAt = DateTime.now();
    _lastGeo = g.status;
    state.value = st.copyWith(points: points, distanceM: dist, insidePoints: inside, geoStatus: g.status, lastFix: DateTime.now());
    return write;
  }

  static void _raiseAlerts(AppUser me, GeoCheck g, Position p) {
    final today = dayKey(DateTime.now());
    if (g.status == 'outside' && _lastGeo != 'outside' && Db.ruleOn(_settings, 'outside_boundary')) {
      unawaited(Db.raiseAlert(
        type: 'outside_boundary',
        description: '${me.name} moved outside the assigned boundary (${g.distanceToEdge.toStringAsFixed(0)} m from edge) while on duty.',
        severity: 'high',
        uid: me.uid,
        workerName: me.name,
        dedupId: 'outside_${me.uid}_${today}_${DateTime.now().hour}',
      ));
    }
    if (p.isMocked && Db.ruleOn(_settings, 'mock_location')) {
      unawaited(Db.raiseAlert(
        type: 'mock_location',
        description: 'Possible GPS spoofing: mock location detected on ${me.name}\'s device.',
        severity: 'critical',
        uid: me.uid,
        workerName: me.name,
        dedupId: 'mock_${me.uid}_$today',
      ));
    }
  }
}
