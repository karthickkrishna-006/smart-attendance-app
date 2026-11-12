import 'dart:math' as math;

import 'package:field_monitor/domain/geo.dart';
import 'package:field_monitor/domain/live_update.dart';
import 'package:flutter_test/flutter_test.dart';

const p0 = GeoPoint2(12.6919, 79.9762);
GeoPoint2 east(double m) => GeoPoint2(p0.lat, p0.lng + m / (111195.0 * math.cos(p0.lat * math.pi / 180)));
final t0 = DateTime(2026, 11, 12, 9, 0);
DateTime at(int s) => t0.add(Duration(seconds: s));

void main() {
  const policy = LiveUpdatePolicy();
  bool send(GeoPoint2 p, int sec, {double acc = 10, bool force = false}) =>
      policy.shouldSend(lastSent: p0, lastSentAt: t0, now: p, accuracyM: acc, at: at(sec), force: force);

  test('the first position is always sent', () {
    expect(policy.shouldSend(lastSent: null, lastSentAt: null, now: p0, accuracyM: 500, at: t0), true);
  });
  test('moving 40 m or more sends; small movement does not', () {
    expect(send(east(50), 60), true);
    expect(send(east(20), 60), false);
  });
  test('standing still still sends every 5 minutes', () {
    expect(send(p0, 299), false);
    expect(send(p0, 300), true);
  });
  test('never more often than every 30 seconds, and inaccurate fixes wait', () {
    expect(send(east(200), 20), false);
    expect(send(east(200), 60, acc: 120), false);
    expect(send(east(200), 301, acc: 120), true);
  });
  test('street entry or exit sends at once (after 5 s)', () {
    expect(send(p0, 10, force: true), true);
    expect(send(p0, 3, force: true), false);
  });
  test('map colours: moving, no update for 10 minutes, off duty', () {
    final now = t0.add(const Duration(minutes: 30));
    expect(liveStateOf(onDuty: true, at: now.subtract(const Duration(minutes: 3)), now: now), LiveState.moving);
    expect(liveStateOf(onDuty: true, at: now.subtract(const Duration(minutes: 11)), now: now), LiveState.stale);
    expect(liveStateOf(onDuty: false, at: now, now: now), LiveState.offDuty);
    expect(liveStateOf(onDuty: true, at: null, now: now), LiveState.offDuty);
  });
}
