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
