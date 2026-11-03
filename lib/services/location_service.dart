import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../core/fmt.dart';
import '../core/geo.dart';
import 'db.dart';
import 'models.dart';

class LocationException implements Exception {
  final String message;
  final bool openSettings;
  final bool openAppSettings;
  LocationException(this.message, {this.openSettings = false, this.openAppSettings = false});
  @override
  String toString() => message;
}

class LocationService {
  static Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationException('Location (GPS) is turned off. Please enable it to continue.', openSettings: true);
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied) {
      throw LocationException('Location permission was denied. Attendance needs your location to verify presence.');
    }
    if (p == LocationPermission.deniedForever) {
      throw LocationException('Location permission is permanently denied. Enable it in App Settings.', openAppSettings: true);
    }
  }

  static Future<Position> current() async {
    await ensurePermission();
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 25)),
      );
    } on TimeoutException {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      throw LocationException('Could not get a GPS fix in time. Move to an open area and retry.');
    }
  }

  static Stream<Position> stream({int distanceFilter = 15, int intervalSec = 30}) => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilter,
          intervalDuration: Duration(seconds: intervalSec),
        ),
      );

  static Future<void> openSettings() => Geolocator.openLocationSettings();
  static Future<void> openAppSettings() => Geolocator.openAppSettings();
}

/// Streams the on-duty worker's position to `locations/{uid}` while the app is
/// open (foreground tracking), evaluates the GIS boundary and raises alerts.
class LiveTracker {
  static StreamSubscription<Position>? _sub;
  static String? _uid;
  static String? _lastStatus;

  static bool get running => _sub != null;

  static Future<void> start(AppUser user) async {
    if (_sub != null && _uid == user.uid) return;
    await stop();
    _uid = user.uid;
    final settings = await Db.getSettings();
    final boundary = await Db.getBoundary(user.boundaryId);
    final maxAcc = asDouble(settings['maxGpsAccuracy'], 50);
    try {
      await LocationService.ensurePermission();
    } catch (_) {
      return;
    }
    _sub = LocationService.stream(intervalSec: (settings['trackingIntervalSec'] as num?)?.toInt() ?? 30).listen((p) async {
      final ll = LatLng(p.latitude, p.longitude);
      final g = checkLocation(ll, p.accuracy, boundary?.points, maxAcc);
      try {
        await Db.col('locations').doc(user.uid).set({
          'uid': user.uid,
          'name': user.name,
          'lat': p.latitude,
          'lng': p.longitude,
          'accuracy': p.accuracy,
          'mocked': p.isMocked,
          'geoStatus': g.status,
          'distanceToEdge': g.distanceToEdge.isFinite ? g.distanceToEdge : null,
          'boundaryId': user.boundaryId,
          'onDuty': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}
      final today = dayKey(DateTime.now());
      if (g.status == 'outside' && _lastStatus != 'outside' && Db.ruleOn(settings, 'outside_boundary')) {
        await Db.raiseAlert(
          type: 'outside_boundary',
          description: '${user.name} moved outside the assigned boundary (${g.distanceToEdge.toStringAsFixed(0)} m from edge) while on duty.',
          severity: 'high',
          uid: user.uid,
          workerName: user.name,
          dedupId: 'outside_${user.uid}_${today}_${DateTime.now().hour}',
        );
      }
      if (p.isMocked && Db.ruleOn(settings, 'mock_location')) {
        await Db.raiseAlert(
          type: 'mock_location',
          description: 'Possible GPS spoofing: mock location detected on ${user.name}\'s device.',
          severity: 'critical',
          uid: user.uid,
          workerName: user.name,
          dedupId: 'mock_${user.uid}_$today',
        );
      }
      _lastStatus = g.status;
    });
  }

  static Future<void> stop({bool markOffDuty = false}) async {
    await _sub?.cancel();
    _sub = null;
    if (markOffDuty && _uid != null) {
      try {
        await Db.col('locations').doc(_uid).set({'onDuty': false, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      } catch (_) {}
    }
    _uid = null;
    _lastStatus = null;
  }
}
