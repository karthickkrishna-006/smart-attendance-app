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
