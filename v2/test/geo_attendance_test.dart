import 'dart:math' as math;

import 'package:field_monitor/domain/attendance.dart';
import 'package:field_monitor/domain/geo.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic test shapes near Chengalpattu's approximate location. Not real
// boundaries.
const centre = GeoPoint2(12.6919, 79.9762);
GeoPoint2 north(GeoPoint2 p, double metres) => GeoPoint2(p.lat + metres / 111195.0, p.lng);
GeoPoint2 east(GeoPoint2 p, double metres) => GeoPoint2(p.lat, p.lng + metres / (111195.0 * math.cos(p.lat * math.pi / 180)));

final square = [
  north(east(centre, -500), -500),
  north(east(centre, 500), -500),
  north(east(centre, 500), 500),
  north(east(centre, -500), 500),
];

void main() {
  group('distances', () {
    test('one degree of latitude is about 111.2 km', () {
      final d = distanceM(const GeoPoint2(12, 80), const GeoPoint2(13, 80));
      expect((d - 111195).abs() < 300, true, reason: '$d');
    });
    test('helpers move points by the requested metres', () {
      expect((distanceM(centre, north(centre, 250)) - 250).abs() < 1, true);
      expect((distanceM(centre, east(centre, 250)) - 250).abs() < 1, true);
    });
  });

  group('geofence checks allow for GPS error', () {
    final circle = Geofence.circle(id: 'c', name: 'C', areaId: 'p1', areaPath: const ['d', 'b', 'p1'], center: centre, radiusM: 100);
    final poly = Geofence.polygon(id: 'q', name: 'Q', areaId: 'p2', areaPath: const ['d', 'b', 'p2'], ring: square);

    test('circle: clearly inside, near the edge, clearly outside', () {
      expect(circle.check(north(centre, 50), 10).placement, Placement.inside);
      expect(circle.check(north(centre, 95), 10).placement, Placement.uncertain);
      expect(circle.check(north(centre, 150), 10).placement, Placement.outside);
      expect((circle.check(north(centre, 40), 5).edgeDistanceM - 60).abs() < 1, true);
    });

    test('polygon: inside, outside and edge distance', () {
      expect(pointInPolygon(centre, square), true);
      expect(pointInPolygon(east(centre, 800), square), false);
      expect(poly.check(centre, 20).placement, Placement.inside);
      expect((poly.check(centre, 20).edgeDistanceM - 500).abs() < 2, true);
      expect(poly.check(east(centre, 490), 20).placement, Placement.uncertain);
      expect(poly.check(east(centre, 600), 20).placement, Placement.outside);
      expect((poly.check(east(centre, 600), 20).edgeDistanceM + 100).abs() < 2, true);
    });

    test('poor accuracy turns a near-edge fix into "cannot tell"', () {
      expect(poly.check(east(centre, 400), 20).placement, Placement.inside);
      expect(poly.check(east(centre, 400), 150).placement, Placement.uncertain);
    });

    test('best match prefers the fence the worker is inside', () {
      final near = Geofence.circle(id: 'n', name: 'N', areaId: 'x', areaPath: const ['x'], center: east(centre, 700), radiusM: 50);
      final m = bestMatch(centre, 10, [near, poly]);
      expect(m?.fence.id, 'q');
      expect(bestMatch(centre, 10, const []), null);
      expect(bestMatch(east(centre, 2000), 10, [near, poly])?.fence.id, 'n');
    });
  });

  group('boundary simplification', () {
    test('a 1,000-point boundary shrinks but stays within the tolerance', () {
      final ring = [
        for (var i = 0; i < 1000; i++)
          GeoPoint2(centre.lat + 0.01 * math.sin(2 * math.pi * i / 1000), centre.lng + 0.01 * math.cos(2 * math.pi * i / 1000)),
      ];
      final s = simplifyRing(ring, toleranceM: 5);
      expect(s.length < 200, true, reason: '${s.length}');
      expect(s.length >= 3, true);
      var worst = 0.0;
      for (final p in ring) {
        worst = math.max(worst, distanceToRingM(p, s));
      }
      expect(worst <= 6, true, reason: 'max deviation $worst m');
    });
    test('small rings are left alone', () => expect(simplifyRing(square).length, 4));
  });

  group('GeoJSON import', () {
    const fc = '''
{"type":"FeatureCollection","features":[
 {"type":"Feature","properties":{"name":"Test A"},"geometry":{"type":"Polygon","coordinates":[[[79.97,12.69],[79.98,12.69],[79.98,12.70],[79.97,12.70],[79.97,12.69]],[[79.975,12.695],[79.976,12.695],[79.976,12.696]]]}},
 {"type":"Feature","properties":{"name":"Test B"},"geometry":{"type":"MultiPolygon","coordinates":[[[[79.9,12.6],[79.91,12.6],[79.91,12.61]]],[[[79.92,12.6],[79.93,12.6],[79.93,12.61]]]]}},
 {"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[79.9,12.6]}}
]}''';

    test('reads polygons, multipolygons and names; lon/lat order respected', () {
      final r = parseGeoJson(fc);
      expect(r.rings.map((x) => x.name).toList(), ['Test A', 'Test B (1)', 'Test B (2)']);
      expect(r.rings.first.ring.first, const GeoPoint2(12.69, 79.97));
      expect(r.warnings.length, 2, reason: '${r.warnings}');
    });
    test('bad input gives a plain error', () {
      expect(() => parseGeoJson('not json'), throwsFormatException);
      expect(() => parseGeoJson('{"type":"Point","coordinates":[1,2]}'), throwsFormatException);
    });
  });

  group('attendance verdicts (flag, never block)', () {
    final nineAm = DateTime(2026, 11, 6, 9, 5);
    Verdict v({bool area = true, Placement? at = Placement.inside, double acc = 10, bool mock = false, DateTime? time}) =>
        evaluateCheckIn(hasAssignedArea: area, placement: at, accuracyM: acc, mocked: mock, localTime: time ?? nineAm);

    test('inside, accurate, on time: Verified', () {
      final r = v();
      expect(r.status, AttendanceStatus.verified);
      expect(r.late, false);
      expect(r.reasons, <FlagReason>[]);
    });
    test('each failed check flags with its reason', () {
      expect(v(at: Placement.outside).reasons, [FlagReason.outsideArea]);
      expect(v(at: Placement.uncertain).reasons, [FlagReason.nearEdge]);
      expect(v(at: null).reasons, [FlagReason.noGeofence]);
      expect(v(area: false).reasons, [FlagReason.noAssignedArea]);
      expect(v(acc: 120).reasons, [FlagReason.lowAccuracy]);
      expect(v(mock: true).reasons, [FlagReason.mockLocation]);
      expect(v(time: DateTime(2026, 11, 6, 6, 30)).reasons, [FlagReason.outsideHours]);
      expect(v(mock: true, at: Placement.outside).status, AttendanceStatus.flagged);
    });
    test('late is recorded but does not flag', () {
      final r = v(time: DateTime(2026, 11, 6, 9, 40));
      expect(r.late, true);
      expect(r.status, AttendanceStatus.verified);
      expect(v(time: DateTime(2026, 11, 6, 9, 15)).late, false);
    });
    test('policy reads configured hours and ignores bad values', () {
      final p = AttendancePolicy.fromMap({'dutyStart': '07:30', 'dutyEnd': '15:00', 'lateToleranceMin': 10, 'maxAccuracyM': 30});
      expect(p.startMinute, 450);
      expect(p.endMinute, 900);
      expect(p.lateToleranceMin, 10);
      expect(p.maxAccuracyM, 30.0);
      final bad = AttendancePolicy.fromMap({'dutyStart': '25:99', 'lateToleranceMin': -4});
      expect(bad.startMinute, 540);
      expect(bad.lateToleranceMin, 15);
    });
    test('one session id per worker per day', () {
      expect(dayKey(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
      expect(sessionId('u1', '2026-01-05'), 'u1_2026-01-05');
    });
  });
}
