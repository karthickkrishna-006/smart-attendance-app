import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../domain/geo.dart';
import 'location.dart';

/// "Where am I" for map screens: the phone's own live position while a map
/// screen that shows it is open. Nothing is saved or sent anywhere.
class MyLocation extends ChangeNotifier {
  MyLocation._();
  static final instance = MyLocation._();

  StreamSubscription<Position>? _sub;
  int _users = 0;
  GeoPoint2? at;
  double? accuracyM;
  DateTime? time;
  String? problem;

  bool get active => _sub != null;

  /// Starts following the phone's position (asks for permission if needed).
  /// Call [release] when the screen closes.
  Future<void> acquire() async {
    _users++;
    if (_sub != null) return;
    try {
      final first = await Location.current();
      _set(first);
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 2),
      ).listen(_set, onError: (Object e) {
        problem = '$e';
        notifyListeners();
      });
    } on LocationProblem catch (e) {
      problem = e.message;
      notifyListeners();
      rethrow;
    }
  }

  void release() {
    if (_users > 0) _users--;
    if (_users == 0) {
      _sub?.cancel();
      _sub = null;
    }
  }

  void _set(Position p) {
    at = GeoPoint2(p.latitude, p.longitude);
    accuracyM = p.accuracy;
    time = p.timestamp;
    problem = null;
    notifyListeners();
  }
}
