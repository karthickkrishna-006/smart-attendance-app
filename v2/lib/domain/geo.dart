import 'dart:convert';
import 'dart:math' as math;

/// A latitude/longitude pair in degrees (WGS84, as GPS and GeoJSON use).
class GeoPoint2 {
  const GeoPoint2(this.lat, this.lng);
  final double lat;
  final double lng;

  bool get valid => lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 && lat.isFinite && lng.isFinite;

  @override
  bool operator ==(Object other) => other is GeoPoint2 && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => '($lat, $lng)';
}

const _earthRadiusM = 6371008.8;

double _rad(double d) => d * math.pi / 180;

/// Great-circle distance in metres (haversine).
double distanceM(GeoPoint2 a, GeoPoint2 b) {
  final dLat = _rad(b.lat - a.lat);
  final dLng = _rad(b.lng - a.lng);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Local flat projection (metres) around [origin]; accurate to well under 1 %
/// over a panchayat-sized area, which is all the edge-distance check needs.
({double x, double y}) _project(GeoPoint2 p, GeoPoint2 origin) => (
      x: _rad(p.lng - origin.lng) * _earthRadiusM * math.cos(_rad(origin.lat)),
      y: _rad(p.lat - origin.lat) * _earthRadiusM,
    );

double _segmentDistance(({double x, double y}) p, ({double x, double y}) a, ({double x, double y}) b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final cx = a.x + t * dx, cy = a.y + t * dy;
  return math.sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy));
}

/// Ray casting. The ring may be open or closed (first point repeated).
bool pointInPolygon(GeoPoint2 p, List<GeoPoint2> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring.elementAt(i), b = ring.elementAt(j);
    if ((a.lat > p.lat) != (b.lat > p.lat) && p.lng < (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng) {
      inside = !inside;
    }
  }
  return inside;
}

/// Shortest distance in metres from [p] to the polygon's boundary line.
double distanceToRingM(GeoPoint2 p, List<GeoPoint2> ring) {
  final o = p;
  final pp = _project(p, o);
  var best = double.infinity;
  for (var i = 0; i < ring.length; i++) {
    final a = _project(ring.elementAt(i), o);
    final b = _project(ring.elementAt((i + 1) % ring.length), o);
    best = math.min(best, _segmentDistance(pp, a, b));
  }
  return best;
}

enum GeofenceKind { circle, polygon }

/// Where a GPS fix lies relative to a geofence, allowing for GPS error.
enum Placement {
  /// Inside, by more than the GPS error.
  inside,

  /// Outside, by more than the GPS error.
  outside,

  /// Within the GPS error of the edge: cannot tell. Treated as "not proven
  /// inside", so the record is flagged for a person to check, never rejected.
  uncertain,
}

class GeoCheck {
  const GeoCheck(this.placement, this.edgeDistanceM);
  final Placement placement;

  /// Distance to the boundary line in metres (positive inside, negative outside).
  final double edgeDistanceM;
}

/// A work-area boundary: a circle or one polygon ring (holes are not used).
class Geofence {
  const Geofence.circle({
    required this.id,
    required this.name,
    required this.areaId,
    required this.areaPath,
    required GeoPoint2 this.center,
    required double this.radiusM,
  })  : kind = GeofenceKind.circle,
        ring = const [];

  const Geofence.polygon({
    required this.id,
    required this.name,
    required this.areaId,
    required this.areaPath,
    required this.ring,
  })  : kind = GeofenceKind.polygon,
        center = null,
        radiusM = null;

  final String id;
  final String name;
  final String areaId;

  /// The area path of [areaId] (district down to that area), copied so that
  /// records made inside this geofence carry the same scope.
  final List<String> areaPath;
  final GeofenceKind kind;
  final GeoPoint2? center;
  final double? radiusM;
  final List<GeoPoint2> ring;

  /// [accuracyM] is the phone's reported GPS error radius.
  GeoCheck check(GeoPoint2 p, double accuracyM) {
    final double edge;
    if (kind == GeofenceKind.circle) {
      edge = radiusM! - distanceM(p, center!);
    } else {
      final d = distanceToRingM(p, ring);
      edge = pointInPolygon(p, ring) ? d : -d;
    }
    final margin = accuracyM.isFinite && accuracyM > 0 ? accuracyM : 0.0;
    if (edge > margin) return GeoCheck(Placement.inside, edge);
    if (edge < -margin) return GeoCheck(Placement.outside, edge);
    return GeoCheck(Placement.uncertain, edge);
  }
}

/// The geofence that best explains a fix: one it is inside (the deepest),
/// otherwise the nearest one. Null when there are none.
({Geofence fence, GeoCheck result})? bestMatch(GeoPoint2 p, double accuracyM, List<Geofence> fences) {
  ({Geofence fence, GeoCheck result})? best;
  for (final f in fences) {
    final r = f.check(p, accuracyM);
    if (best == null || r.edgeDistanceM > best.result.edgeDistanceM) best = (fence: f, result: r);
  }
  return best;
}

/// Douglas–Peucker simplification with a tolerance in metres. Official
/// boundaries can have thousands of points; a few hundred keep a document
/// small while staying within a few metres of the original line.
List<GeoPoint2> simplifyRing(List<GeoPoint2> ring, {double toleranceM = 5}) {
  if (ring.length <= 4) return List.of(ring);
  final open = ring.first == ring.last ? ring.sublist(0, ring.length - 1) : List.of(ring);
  if (open.length < 3) return open;
  final origin = open.first;
  final pts = open.map((p) => _project(p, origin)).toList();
  final keep = List<bool>.filled(open.length, false);
  keep[0] = true;
  keep[open.length - 1] = true;
  void dp(int a, int b) {
    if (b <= a + 1) return;
    var maxD = -1.0;
    var idx = a;
    for (var i = a + 1; i < b; i++) {
      final d = _segmentDistance(pts.elementAt(i), pts.elementAt(a), pts.elementAt(b));
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD > toleranceM) {
      keep[idx] = true;
      dp(a, idx);
      dp(idx, b);
    }
  }

  // Split at the point farthest from the start so a closed ring keeps its shape.
  var far = 1;
  var farD = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final d = math.sqrt(pts.elementAt(i).x * pts.elementAt(i).x + pts.elementAt(i).y * pts.elementAt(i).y);
    if (d > farD) {
      farD = d;
      far = i;
    }
  }
  keep[far] = true;
  dp(0, far);
  dp(far, open.length - 1);
  return [for (var i = 0; i < open.length; i++) if (keep.elementAt(i)) open.elementAt(i)];
}

class GeoJsonImport {
  const GeoJsonImport(this.rings, this.warnings);

  /// Outer rings, one per polygon, each with its feature name if any.
  final List<({String name, List<GeoPoint2> ring})> rings;
  final List<String> warnings;
}

/// Reads outer polygon rings from GeoJSON (Feature, FeatureCollection,
/// Polygon or MultiPolygon). Coordinates are [longitude, latitude].
/// Throws [FormatException] with a plain message when nothing usable is found.
GeoJsonImport parseGeoJson(String text, {String nameProperty = 'name'}) {
  final Object? root;
  try {
    root = jsonDecode(text);
  } on FormatException {
    throw const FormatException('This is not valid GeoJSON text.');
  }
  final rings = <({String name, List<GeoPoint2> ring})>[];
  final warnings = <String>[];

  List<GeoPoint2>? ringFrom(Object? coords) {
    if (coords is! List) return null;
    final out = <GeoPoint2>[];
    for (final c in coords) {
      if (c is List && c.length >= 2 && c.elementAt(0) is num && c.elementAt(1) is num) {
        final p = GeoPoint2((c.elementAt(1) as num).toDouble(), (c.elementAt(0) as num).toDouble());
        if (p.valid) out.add(p);
      }
    }
    return out.length >= 3 ? out : null;
  }

  void geometry(Object? g, String name) {
    if (g is! Map) return;
    final type = g['type'];
    final coords = g['coordinates'];
    if (type == 'Polygon' && coords is List && coords.isNotEmpty) {
      final r = ringFrom(coords.first);
      if (r != null) rings.add((name: name, ring: r));
      if (coords.length > 1) warnings.add('$name: inner holes were ignored.');
    } else if (type == 'MultiPolygon' && coords is List) {
      var n = 0;
      for (final poly in coords) {
        if (poly is List && poly.isNotEmpty) {
          final r = ringFrom(poly.first);
          if (r != null) rings.add((name: coords.length > 1 ? '$name (${++n})' : name, ring: r));
        }
      }
    } else {
      warnings.add('$name: geometry type "$type" is not a polygon and was skipped.');
    }
  }

  void feature(Object? f, int index) {
    if (f is! Map) return;
    final props = f['properties'];
    final name = props is Map && props[nameProperty] is String && (props[nameProperty] as String).trim().isNotEmpty
        ? (props[nameProperty] as String).trim()
        : 'Boundary ${index + 1}';
    geometry(f['geometry'], name);
  }

  if (root is Map && root['type'] == 'FeatureCollection' && root['features'] is List) {
    var i = 0;
    for (final f in root['features'] as List) {
      feature(f, i++);
    }
  } else if (root is Map && root['type'] == 'Feature') {
    feature(root, 0);
  } else if (root is Map) {
    geometry(root, 'Boundary 1');
  }
  if (rings.isEmpty) throw const FormatException('No polygon boundaries were found in this GeoJSON.');
  return GeoJsonImport(rings, warnings);
}
