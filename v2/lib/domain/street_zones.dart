import 'dart:math' as math;

import 'geo.dart';

/// A cleaning zone inside a street (for example "Sri Ram Nagar Zone 3"):
/// a small circle the worker must reach while working in that street.
class CleaningZone {
  const CleaningZone({
    required this.id,
    required this.streetFenceId,
    required this.name,
    required this.center,
    this.radiusM = 25,
    this.order = 0,
  });

  final String id;
  final String streetFenceId;
  final String name;
  final GeoPoint2 center;
  final double radiusM;
  final int order;
}

/// Ticks zones off automatically while a worker is inside a street.
///
/// A zone counts once the worker is within its radius with a GPS error of at
/// most [maxAccuracyM] (a fix that is too inaccurate cannot prove presence).
/// Pure logic, unit-tested.
class ZoneTracker {
  ZoneTracker({this.maxAccuracyM = 35});

  final double maxAccuracyM;
  final Set<String> done = {};

  void reset([Iterable<String> already = const []]) {
    done
      ..clear()
      ..addAll(already);
  }

  /// Returns the zones newly reached by this fix (usually none or one).
  List<CleaningZone> update(GeoPoint2 p, double accuracyM, List<CleaningZone> zones) {
    if (!accuracyM.isFinite || accuracyM > maxAccuracyM || !p.valid) return const [];
    final reached = <CleaningZone>[];
    for (final z in zones) {
      if (done.contains(z.id)) continue;
      if (distanceM(p, z.center) <= z.radiusM) {
        done.add(z.id);
        reached.add(z);
      }
    }
    return reached;
  }
}

/// Status of one street visit for the dashboard.
enum StreetVisitStatus {
  /// Still inside the street (no check-out yet).
  inProgress,

  /// Checked out with every zone reached (or the street has no zones).
  completed,

  /// Checked out before reaching every zone.
  incomplete,
}

StreetVisitStatus streetVisitStatus({required bool checkedOut, required int zonesTotal, required int zonesDone}) {
  if (!checkedOut) return StreetVisitStatus.inProgress;
  return zonesDone >= zonesTotal ? StreetVisitStatus.completed : StreetVisitStatus.incomplete;
}

/// The colour a street gets on today's map from all its visits today:
/// completed wins, then in progress, then incomplete; null = not visited.
StreetVisitStatus? streetStatusToday(List<StreetVisitStatus> visits) {
  if (visits.isEmpty) return null;
  if (visits.contains(StreetVisitStatus.completed)) return StreetVisitStatus.completed;
  if (visits.contains(StreetVisitStatus.inProgress)) return StreetVisitStatus.inProgress;
  return StreetVisitStatus.incomplete;
}

/// A zone check-in (entered) or check-out (exited) event.
enum ZoneEventKind { entered, exited }

class ZoneEvent {
  const ZoneEvent(this.kind, this.zone, this.enteredAt, [this.exitedAt]);
  final ZoneEventKind kind;
  final CleaningZone zone;

  /// When the worker actually arrived (not when it was confirmed).
  final DateTime enteredAt;

  /// When the worker actually left (exit events only).
  final DateTime? exitedAt;

  Duration? get duration => exitedAt?.difference(enteredAt);
}

/// Automatic check-in / check-out for the cleaning zones of a street.
///
/// Check-in: inside a zone's circle for [enterAfter] (timed from arrival), so
/// walking past a zone does not count. Check-out: more than [exitMarginM]
/// outside the circle for [exitAfter] (timed from leaving), so a short GPS
/// jump does not end the visit. Fixes less accurate than [maxAccuracyM] are
/// ignored. One zone at a time. Pure logic, unit-tested.
class ZoneVisitTracker {
  ZoneVisitTracker({
    this.enterAfter = const Duration(seconds: 20),
    this.exitAfter = const Duration(seconds: 45),
    this.exitMarginM = 10,
    this.maxAccuracyM = 35,
  });

  final Duration enterAfter;
  final Duration exitAfter;
  final double exitMarginM;
  final double maxAccuracyM;

  CleaningZone? current;
  DateTime? enteredAt;
  CleaningZone? _candidate;
  DateTime? _candidateSince;
  DateTime? _outsideSince;

  void reset() {
    current = null;
    enteredAt = null;
    _candidate = null;
    _candidateSince = null;
    _outsideSince = null;
  }

  List<ZoneEvent> update(GeoPoint2 p, double accuracyM, DateTime at, List<CleaningZone> zones) {
    if (!accuracyM.isFinite || accuracyM > maxAccuracyM || !p.valid) return const [];
    final events = <ZoneEvent>[];
    final cur = current;
    if (cur != null) {
      if (distanceM(p, cur.center) <= cur.radiusM + exitMarginM) {
        _outsideSince = null;
        return events;
      }
      _outsideSince ??= at;
      if (at.difference(_outsideSince!) < exitAfter) return events;
      events.add(ZoneEvent(ZoneEventKind.exited, cur, enteredAt!, _outsideSince));
      reset();
    }
    CleaningZone? inside;
    var best = double.infinity;
    for (final z in zones) {
      final d = distanceM(p, z.center);
      if (d <= z.radiusM && d < best) {
        best = d;
        inside = z;
      }
    }
    if (inside == null) {
      _candidate = null;
      _candidateSince = null;
      return events;
    }
    if (_candidate?.id != inside.id) {
      _candidate = inside;
      _candidateSince = at;
    }
    if (at.difference(_candidateSince!) >= enterAfter) {
      current = inside;
      enteredAt = _candidateSince;
      _candidate = null;
      _candidateSince = null;
      events.add(ZoneEvent(ZoneEventKind.entered, inside, enteredAt!));
    }
    return events;
  }

  /// Ends the open zone visit (street exit or Stop duty) at [at].
  ZoneEvent? close(DateTime at) {
    final cur = current;
    if (cur == null) return null;
    final e = ZoneEvent(ZoneEventKind.exited, cur, enteredAt!, _outsideSince ?? at);
    reset();
    return e;
  }
}

/// The boundary of a street drawn by tapping along it: a strip [halfWidthM]
/// on each side of the line, extended [extendM] past both ends, following
/// bends (mitred joins, limited so sharp corners never spike out).
/// Returns the polygon ring (left side forward, right side back).
List<GeoPoint2> streetStripRing(List<GeoPoint2> line, {double halfWidthM = 25, double extendM = 10}) {
  if (line.length < 2) return const [];
  final o = line.first;
  final mLat = 111195.0, mLng = 111195.0 * math.cos(o.lat * math.pi / 180);
  final pts = [for (final p in line) ((p.lng - o.lng) * mLng, (p.lat - o.lat) * mLat)];
  // Drop repeated taps (zero-length segments).
  final xy = <(double, double)>[pts.first];
  for (final p in pts.skip(1)) {
    final q = xy.last;
    if (math.sqrt(math.pow(p.$1 - q.$1, 2) + math.pow(p.$2 - q.$2, 2)) > 0.5) xy.add(p);
  }
  if (xy.length < 2) return const [];
  (double, double) unit(double x, double y) {
    final l = math.sqrt(x * x + y * y);
    return (x / l, y / l);
  }
  final dirs = [for (var i = 0; i < xy.length - 1; i++) unit(xy[i + 1].$1 - xy[i].$1, xy[i + 1].$2 - xy[i].$2)];
  // Extend the ends along the street.
  xy[0] = (xy[0].$1 - dirs.first.$1 * extendM, xy[0].$2 - dirs.first.$2 * extendM);
  xy[xy.length - 1] = (xy.last.$1 + dirs.last.$1 * extendM, xy.last.$2 + dirs.last.$2 * extendM);
  final left = <(double, double)>[], right = <(double, double)>[];
  for (var i = 0; i < xy.length; i++) {
    (double, double) n;
    var scale = 1.0;
    if (i == 0) {
      n = (-dirs.first.$2, dirs.first.$1);
    } else if (i == xy.length - 1) {
      n = (-dirs.last.$2, dirs.last.$1);
    } else {
      final a = (-dirs[i - 1].$2, dirs[i - 1].$1), b = (-dirs[i].$2, dirs[i].$1);
      final sum = (a.$1 + b.$1, a.$2 + b.$2);
      final len = math.sqrt(sum.$1 * sum.$1 + sum.$2 * sum.$2);
      n = len < 1e-6 ? a : (sum.$1 / len, sum.$2 / len);
      final cosHalf = n.$1 * a.$1 + n.$2 * a.$2;
      scale = cosHalf < 0.4 ? 2.5 : 1 / cosHalf; // miter, limited at sharp bends
    }
    final w = halfWidthM * scale;
    left.add((xy[i].$1 + n.$1 * w, xy[i].$2 + n.$2 * w));
    right.add((xy[i].$1 - n.$1 * w, xy[i].$2 - n.$2 * w));
  }
  GeoPoint2 back((double, double) p) => GeoPoint2(o.lat + p.$2 / mLat, o.lng + p.$1 / mLng);
  return [for (final p in left) back(p), for (final p in right.reversed) back(p)];
}
