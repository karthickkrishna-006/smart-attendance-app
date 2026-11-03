import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// GIS helpers: point-in-polygon (ray casting), distance to boundary edge,
/// centroid and area. All computations are done on WGS84 lat/lng with a local
/// equirectangular projection, which is accurate for village-sized polygons.

bool pointInPolygon(LatLng p, List<LatLng> poly) {
  if (poly.length < 3) return false;
  bool inside = false;
  for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final xi = poly[i].longitude, yi = poly[i].latitude;
    final xj = poly[j].longitude, yj = poly[j].latitude;
    final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

double distanceMeters(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b);

/// Local projection to metres around a reference latitude.
math.Point<double> _proj(LatLng p, double refLat) {
  const r = 6371000.0;
  final x = p.longitude * math.pi / 180 * r * math.cos(refLat * math.pi / 180);
  final y = p.latitude * math.pi / 180 * r;
  return math.Point(x, y);
}

/// Shortest distance (metres) from point to the polygon outline.
double distanceToEdge(LatLng p, List<LatLng> poly) {
  if (poly.length < 2) return double.infinity;
  final ref = p.latitude;
  final pp = _proj(p, ref);
  double best = double.infinity;
  for (int i = 0; i < poly.length; i++) {
    final a = _proj(poly[i], ref);
    final b = _proj(poly[(i + 1) % poly.length], ref);
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    double t = len2 == 0 ? 0 : ((pp.x - a.x) * dx + (pp.y - a.y) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + t * dx, cy = a.y + t * dy;
    final d = math.sqrt((pp.x - cx) * (pp.x - cx) + (pp.y - cy) * (pp.y - cy));
    if (d < best) best = d;
  }
  return best;
}

LatLng centroid(List<LatLng> poly) {
  if (poly.isEmpty) return const LatLng(12.6919, 79.9762);
  double lat = 0, lng = 0;
  for (final p in poly) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / poly.length, lng / poly.length);
}

/// Polygon area in square metres (shoelace on local projection).
double areaSqM(List<LatLng> poly) {
  if (poly.length < 3) return 0;
  final ref = centroid(poly).latitude;
  final pts = poly.map((e) => _proj(e, ref)).toList();
  double s = 0;
  for (int i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    s += a.x * b.y - b.x * a.y;
  }
  return s.abs() / 2;
}

/// Result of validating a GPS fix against an assigned boundary.
class GeoCheck {
  final String status; // inside | outside | no_boundary | low_accuracy
  final bool inside;
  final double distanceToEdge;
  final String message;
  const GeoCheck(this.status, this.inside, this.distanceToEdge, this.message);
}

GeoCheck checkLocation(LatLng p, double accuracy, List<LatLng>? boundary, double maxAccuracy) {
  if (boundary == null || boundary.length < 3) {
    return const GeoCheck('no_boundary', false, double.nan,
        'No boundary assigned – location recorded but not verified.');
  }
  final inside = pointInPolygon(p, boundary);
  final d = distanceToEdge(p, boundary);
  if (accuracy > maxAccuracy) {
    return GeoCheck('low_accuracy', inside, d,
        'GPS accuracy ±${accuracy.toStringAsFixed(0)} m is worse than the allowed ±${maxAccuracy.toStringAsFixed(0)} m. Move to open sky and retry.');
  }
  // If the accuracy circle overlaps the edge, the result is uncertain – reported in message.
  final uncertain = d < accuracy;
  if (inside) {
    return GeoCheck('inside', true, d,
        uncertain ? 'Inside boundary (near edge – within GPS error margin).' : 'Inside assigned boundary.');
  }
  return GeoCheck('outside', false, d,
      'Outside assigned boundary by ${d.toStringAsFixed(0)} m${uncertain ? ' (within GPS error margin)' : ''}.');
}
