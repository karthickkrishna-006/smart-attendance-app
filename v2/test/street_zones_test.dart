import 'dart:math' as math;

import 'package:field_monitor/domain/geo.dart';
import 'package:field_monitor/domain/street_zones.dart';
import 'package:flutter_test/flutter_test.dart';

// A synthetic street with 8 cleaning zones 50 m apart (not a real street).
const start = GeoPoint2(12.6919, 79.9762);
GeoPoint2 east(double m) => GeoPoint2(start.lat, start.lng + m / (111195.0 * math.cos(start.lat * math.pi / 180)));
final zones = [
  for (var i = 0; i < 8; i++) CleaningZone(id: 'z$i', streetFenceId: 'sriRamNagar', name: 'Zone ${i + 1}', center: east(i * 50.0), order: i),
];

void main() {
  zoneVisitTests();
  stripTests();
  test('walking the whole street ticks all 8 zones, each once', () {
    final t = ZoneTracker();
    var reached = 0;
    for (var m = 0.0; m <= 350; m += 10) {
      reached += t.update(east(m), 8, zones).length;
    }
    expect(reached, 8);
    expect(t.done.length, 8);
    expect(t.update(east(0), 8, zones), <CleaningZone>[]);
  });

  test('passing 30 m beside a zone does not count; inaccurate GPS does not count', () {
    final t = ZoneTracker();
    expect(t.update(GeoPoint2(start.lat + 30 / 111195.0, start.lng), 8, zones), <CleaningZone>[]);
    expect(t.update(start, 60, zones), <CleaningZone>[]);
    expect(t.update(start, 10, zones).single.name, 'Zone 1');
  });

  test('a reset keeps zones already reached (app restarted during a visit)', () {
    final t = ZoneTracker()..reset(['z0', 'z1']);
    expect(t.update(east(0), 8, zones), <CleaningZone>[]);
    expect(t.update(east(100), 8, zones).single.id, 'z2');
  });

  test('visit status: in progress, completed, left incomplete', () {
    expect(streetVisitStatus(checkedOut: false, zonesTotal: 8, zonesDone: 3), StreetVisitStatus.inProgress);
    expect(streetVisitStatus(checkedOut: true, zonesTotal: 8, zonesDone: 8), StreetVisitStatus.completed);
    expect(streetVisitStatus(checkedOut: true, zonesTotal: 8, zonesDone: 6), StreetVisitStatus.incomplete);
    expect(streetVisitStatus(checkedOut: true, zonesTotal: 0, zonesDone: 0), StreetVisitStatus.completed);
  });

  test('street colour today: completed wins, then in progress, then incomplete', () {
    expect(streetStatusToday([]), null);
    expect(streetStatusToday([StreetVisitStatus.incomplete, StreetVisitStatus.completed]), StreetVisitStatus.completed);
    expect(streetStatusToday([StreetVisitStatus.incomplete, StreetVisitStatus.inProgress]), StreetVisitStatus.inProgress);
    expect(streetStatusToday([StreetVisitStatus.incomplete]), StreetVisitStatus.incomplete);
  });
}

void zoneVisitTests() {
  // Two zones 60 m apart; the worker cleans Zone 1 from 08:45 to 09:00,
  // walks over, and cleans Zone 2 from 09:05.
  final z1 = zones[0], z2 = CleaningZone(id: 'zB', streetFenceId: 'sriRamNagar', name: 'Zone 2', center: east(60), order: 1);
  DateTime t(int h, int m, [int s = 0]) => DateTime(2026, 11, 22, h, m, s);
  final both = [z1, z2];

  test('zone check-in at arrival time, check-out at leaving time (08:45-09:00, then 09:05)', () {
    final tr = ZoneVisitTracker();
    final ev = <ZoneEvent>[];
    for (var s = 0; s <= 15 * 60; s += 15) {
      ev.addAll(tr.update(east(2), 8, t(8, 45).add(Duration(seconds: s)), both));
    }
    expect(ev.length, 1);
    expect(ev.single.kind, ZoneEventKind.entered);
    expect(ev.single.enteredAt, t(8, 45));
    // Walk to Zone 2: away from Zone 1 from 09:00 on.
    // Walking between the zones (40 m to the side of the street) until 09:05.
    final between = GeoPoint2(east(30).lat + 40 / 111195.0, east(30).lng);
    for (var s = 0; s < 5 * 60; s += 15) {
      ev.addAll(tr.update(between, 8, t(9, 0).add(Duration(seconds: s)), both));
    }
    final exit = ev.firstWhere((e) => e.kind == ZoneEventKind.exited);
    expect(exit.zone.id, z1.id);
    expect(exit.exitedAt, t(9, 0));
    expect(exit.duration, const Duration(minutes: 15));
    for (var s = 0; s <= 60; s += 15) {
      ev.addAll(tr.update(east(60), 8, t(9, 5).add(Duration(seconds: s)), both));
    }
    final second = ev.lastWhere((e) => e.kind == ZoneEventKind.entered);
    expect(second.zone.id, 'zB');
    expect(second.enteredAt, t(9, 5));
  });

  test('walking past a zone without stopping is not a check-in', () {
    final tr = ZoneVisitTracker();
    final ev = <ZoneEvent>[];
    for (var s = 0; s <= 10; s += 5) {
      ev.addAll(tr.update(east(1), 8, t(10, 0, s), both));
    }
    ev.addAll(tr.update(east(35), 8, t(10, 0, 15), both));
    expect(ev, <ZoneEvent>[]);
  });

  test('a short GPS jump does not check out; weak GPS is ignored', () {
    final tr = ZoneVisitTracker();
    tr.update(east(0), 8, t(11, 0), both);
    tr.update(east(0), 8, t(11, 0, 30), both);
    expect(tr.current?.id, z1.id);
    expect(tr.update(east(45), 8, t(11, 1), both), <ZoneEvent>[]); // 30 s away only
    tr.update(east(0), 8, t(11, 1, 30), both);
    expect(tr.update(east(45), 8, t(11, 3), both), <ZoneEvent>[]);
    expect(tr.update(east(300), 80, t(11, 6), both), <ZoneEvent>[]); // weak GPS
    expect(tr.current?.id, z1.id);
  });

  test('Stop duty or leaving the street closes the open zone', () {
    final tr = ZoneVisitTracker();
    tr.update(east(0), 8, t(12, 0), both);
    tr.update(east(0), 8, t(12, 0, 25), both);
    final e = tr.close(t(12, 20));
    expect(e?.kind, ZoneEventKind.exited);
    expect(e?.duration, const Duration(minutes: 20));
    expect(tr.current, null);
  });
}

void stripTests() {
  GeoPoint2 north(GeoPoint2 p, double m) => GeoPoint2(p.lat + m / 111195.0, p.lng);
  test('a street drawn with 2 taps becomes a 4-corner strip, 25 m each side, 10 m past the ends', () {
    final ring = streetStripRing([start, east(200)]);
    expect(ring.length, 4);
    expect(pointInPolygon(east(100), ring), true);            // on the street
    expect(pointInPolygon(north(east(100), 20), ring), true); // 20 m to the side
    expect(pointInPolygon(north(east(100), 30), ring), false); // 30 m to the side
    expect(pointInPolygon(east(-8), ring), true);              // just before the start
    expect(pointInPolygon(east(-15), ring), false);
  });
  test('a street with a bend follows the bend', () {
    final corner = east(150);
    final ring = streetStripRing([start, corner, north(corner, 150)]);
    expect(ring.length, 6);
    expect(pointInPolygon(east(75), ring), true);
    expect(pointInPolygon(north(corner, 75), ring), true);
    expect(pointInPolygon(north(east(75), 60), ring), false);  // inside the bend, but away from both arms
  });
  test('repeated taps on the same spot are ignored; one point is not a street', () {
    expect(streetStripRing([start, start, east(100)]).length, 4);
    expect(streetStripRing([start]), <GeoPoint2>[]);
    expect(streetStripRing([start, start]), <GeoPoint2>[]);
  });
}
