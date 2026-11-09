import 'dart:math' as math;

import 'package:field_monitor/domain/geo.dart';
import 'package:field_monitor/domain/visits.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic test streets, not real boundaries.
const c1 = GeoPoint2(12.6919, 79.9762);
GeoPoint2 east(GeoPoint2 p, double m) => GeoPoint2(p.lat, p.lng + m / (111195.0 * math.cos(p.lat * math.pi / 180)));
final s1 = Geofence.circle(id: 's1', name: 'Street 1', areaId: 'a1', areaPath: const ['d', 'a1'], center: c1, radiusM: 100);
final s2 = Geofence.circle(id: 's2', name: 'Street 2', areaId: 'a2', areaPath: const ['d', 'a2'], center: east(c1, 400), radiusM: 100);
final fences = [s1, s2];
final t0 = DateTime(2026, 11, 9, 9, 0);
DateTime at(int sec) => t0.add(Duration(seconds: sec));

void main() {
  test('entry is recorded after a minute inside, with the first-seen time', () {
    final v = VisitTracker();
    expect(v.update(c1, 10, at(0), fences), <VisitEvent>[]);
    expect(v.update(c1, 10, at(30), fences), <VisitEvent>[]);
    final e = v.update(c1, 10, at(60), fences);
    expect(e.length, 1);
    expect(e.first.kind, VisitEventKind.entered);
    expect(e.first.fence.id, 's1');
    expect(e.first.enteredAt, at(0));
  });

  test('walking past (less than a minute) records nothing', () {
    final v = VisitTracker();
    v.update(c1, 10, at(0), fences);
    v.update(east(c1, 250), 10, at(40), fences);
    expect(v.update(east(c1, 250), 10, at(120), fences), <VisitEvent>[]);
    expect(v.current, null);
  });

  test('a short GPS jump outside does not end the visit', () {
    final v = VisitTracker();
    v.update(c1, 10, at(0), fences);
    v.update(c1, 10, at(60), fences);
    expect(v.update(east(c1, 250), 10, at(90), fences), <VisitEvent>[]);
    expect(v.update(c1, 10, at(150), fences), <VisitEvent>[]);
    expect(v.current?.id, 's1');
  });

  test('exit after two minutes away, timed from first seen outside', () {
    final v = VisitTracker();
    v.update(c1, 10, at(0), fences);
    v.update(c1, 10, at(60), fences);
    v.update(east(c1, 250), 10, at(600), fences);
    expect(v.update(east(c1, 250), 10, at(700), fences), <VisitEvent>[]);
    final e = v.update(east(c1, 250), 10, at(720), fences);
    expect(e.length, 1);
    expect(e.first.kind, VisitEventKind.exited);
    expect(e.first.exitedAt, at(600));
    expect(e.first.duration, const Duration(seconds: 600));
  });

  test('moving to the next street: exit the first, then enter the second', () {
    final v = VisitTracker();
    v.update(c1, 10, at(0), fences);
    v.update(c1, 10, at(60), fences);
    final s2c = east(c1, 400);
    v.update(s2c, 10, at(300), fences);
    final out = v.update(s2c, 10, at(420), fences);
    expect(out.map((e) => e.kind).toList(), [VisitEventKind.exited]);
    final inn = v.update(s2c, 10, at(480), fences);
    expect(inn.single.kind, VisitEventKind.entered);
    expect(inn.single.fence.id, 's2');
  });

  test('inaccurate fixes are ignored; duty stop closes an open visit', () {
    final v = VisitTracker();
    expect(v.update(c1, 120, at(0), fences), <VisitEvent>[]);
    expect(v.update(c1, 120, at(90), fences), <VisitEvent>[]);
    expect(v.current, null);
    v.update(c1, 10, at(100), fences);
    v.update(c1, 10, at(160), fences);
    final closed = v.close(at(900));
    expect(closed?.exitedAt, at(900));
    expect(v.close(at(901)), null);
  });
}
