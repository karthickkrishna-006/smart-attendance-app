import 'package:geolocator/geolocator.dart';

/// A plain-language reason why no location could be taken.
class LocationProblem implements Exception {
  const LocationProblem(this.code, this.message);

  /// 'service_off' | 'denied' | 'denied_forever' | 'timeout'
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// One accurate fix while the app is open (no background location).
class Location {
  Location._();

  static Future<Position> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationProblem('service_off', 'Location is turned off. Turn it on in the phone settings.');
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) {
      throw const LocationProblem('denied', 'Location permission is needed to mark attendance.');
    }
    if (p == LocationPermission.deniedForever) {
      throw const LocationProblem('denied_forever', 'Location permission is blocked. Allow it in the app settings.');
    }
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 30)),
      );
    } on Exception {
      throw const LocationProblem('timeout', 'Could not get a GPS fix. Move to an open place and try again.');
    }
  }

  static Future<bool> openSettings(String code) =>
      code == 'service_off' ? Geolocator.openLocationSettings() : Geolocator.openAppSettings();
}
