import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:smartattendance/core/fmt.dart';
import 'package:smartattendance/core/geo.dart';
import 'package:smartattendance/services/db.dart';

void main() {
  // ~1.1 km square near Chengalpattu (synthetic test geometry)
  final square = [
    const LatLng(12.690, 79.970),
    const LatLng(12.690, 79.980),
    const LatLng(12.700, 79.980),
    const LatLng(12.700, 79.970),
  ];

  group('GIS point-in-polygon', () {
    test('centre is inside', () {
      expect(pointInPolygon(const LatLng(12.695, 79.975), square), isTrue);
    });
    test('outside point is outside', () {
      expect(pointInPolygon(const LatLng(12.710, 79.975), square), isFalse);
    });
    test('degenerate polygon is never inside', () {
      expect(pointInPolygon(const LatLng(12.695, 79.975), square.take(2).toList()), isFalse);
    });
  });

  group('distance to edge', () {
    test('point ~1.1 km north of the north edge', () {
      final d = distanceToEdge(const LatLng(12.710, 79.975), square);
      expect(d, closeTo(1112, 25));
    });
    test('area of square is ~1.2 km²', () {
      expect(areaSqM(square) / 1e6, closeTo(1.18, 0.05));
    });
  });

  group('checkLocation', () {
    test('inside with good accuracy', () {
      final r = checkLocation(const LatLng(12.695, 79.975), 8, square, 50);
      expect(r.status, 'inside');
      expect(r.inside, isTrue);
    });
    test('outside', () {
      final r = checkLocation(const LatLng(12.720, 79.975), 8, square, 50);
      expect(r.status, 'outside');
    });
    test('poor accuracy is not treated as verified', () {
      final r = checkLocation(const LatLng(12.695, 79.975), 120, square, 50);
      expect(r.status, 'low_accuracy');
    });
    test('no boundary is not treated as verified', () {
      final r = checkLocation(const LatLng(12.695, 79.975), 5, null, 50);
      expect(r.status, 'no_boundary');
    });
  });

  group('settings & formatting', () {
    test('settings merge keeps defaults and is mutable', () {
      final s = Db.mergeSettings({'lateAfter': '10:00', 'rules': {'late_checkin': false}});
      expect(s['lateAfter'], '10:00');
      expect((s['rules'] as Map)['late_checkin'], false);
      expect((s['rules'] as Map)['face_failed'], true);
      (s['rules'] as Map)['face_failed'] = false; // must not throw
    });
    test('hm parses HH:mm', () {
      expect(hm('09:30'), 570);
      expect(hm('bad'), 570);
    });
    test('titleCase', () {
      expect(titleCase('pending_verification'), 'Pending Verification');
    });
  });
}
