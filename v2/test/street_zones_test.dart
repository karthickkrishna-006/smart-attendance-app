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
