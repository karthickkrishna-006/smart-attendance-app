import 'dart:async';
import 'package:geolocator/geolocator.dart';

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

  /// Position stream for field duty. On Android this runs as a foreground
  /// service, so tracking continues while the phone is locked or another app
  /// is open. It posts an ongoing notification, which Android shows only if
  /// notifications are allowed for the app. It stops when duty is stopped.
  static Stream<Position> dutyStream({int intervalSec = 30}) => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0, // TrackingService decides which points to keep
          intervalDuration: Duration(seconds: intervalSec),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Field duty in progress',
            notificationText: 'Smart Attendance is recording your location for field work. Open the app and tap Stop duty to end.',
            notificationChannelName: 'Field duty tracking',
            enableWakeLock: true,
            setOngoing: true,
          ),
        ),
      );

  static Future<void> openSettings() => Geolocator.openLocationSettings();
  static Future<void> openAppSettings() => Geolocator.openAppSettings();
}

