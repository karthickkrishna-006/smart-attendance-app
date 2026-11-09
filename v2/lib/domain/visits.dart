import 'geo.dart';

enum VisitEventKind { entered, exited }

/// A worker entering or leaving a street (geofence).
class VisitEvent {
  const VisitEvent(this.kind, this.fence, this.enteredAt, [this.exitedAt]);
  final VisitEventKind kind;
  final Geofence fence;
  final DateTime enteredAt;
  final DateTime? exitedAt;

  Duration? get duration => exitedAt?.difference(enteredAt);
}

/// Turns a stream of GPS fixes into street entries and exits.
///
/// * Entry: inside the same boundary (beyond GPS error) for [enterAfter];
///   the entry time is when they were first seen inside.
/// * Exit: away from the current boundary for [exitAfter]; the exit time is
///   when they were first seen outside, so a short GPS jump changes nothing.
/// * Fixes with an error radius above [maxAccuracyM] are ignored.
/// Pure logic (no clock, no GPS), so it is unit-tested.
class VisitTracker {
  VisitTracker({
    this.enterAfter = const Duration(minutes: 1),
    this.exitAfter = const Duration(minutes: 2),
    this.maxAccuracyM = 50,
  });

  final Duration enterAfter;
  final Duration exitAfter;
  final double maxAccuracyM;

  Geofence? current;
  DateTime? enteredAt;
  String? _candidateId;
  DateTime? _candidateSince;
  DateTime? _outsideSince;

  List<VisitEvent> update(GeoPoint2 p, double accuracyM, DateTime t, List<Geofence> fences) {
    if (!accuracyM.isFinite || accuracyM > maxAccuracyM || !p.valid) return const [];
    final events = <VisitEvent>[];
    final match = bestMatch(p, accuracyM, fences);
    final inside = match != null && match.result.placement == Placement.inside ? match.fence : null;

    final cur = current;
    if (cur != null) {
      final stillHere = cur.check(p, accuracyM).placement != Placement.outside;
      if (stillHere) {
        _outsideSince = null;
        return events;
      }
      _outsideSince ??= t;
      if (t.difference(_outsideSince!) < exitAfter) return events;
      events.add(VisitEvent(VisitEventKind.exited, cur, enteredAt!, _outsideSince));
      current = null;
      enteredAt = null;
      _outsideSince = null;
    }

    if (inside == null) {
      _candidateId = null;
      _candidateSince = null;
      return events;
    }
    if (_candidateId != inside.id) {
      _candidateId = inside.id;
      _candidateSince = t;
    }
    if (t.difference(_candidateSince!) >= enterAfter) {
      current = inside;
      enteredAt = _candidateSince;
      _candidateId = null;
      _candidateSince = null;
      events.add(VisitEvent(VisitEventKind.entered, inside, enteredAt!));
    }
    return events;
  }

  /// Ends an open visit (for example when duty stops) at time [t].
  VisitEvent? close(DateTime t) {
    final cur = current;
    if (cur == null) return null;
    final e = VisitEvent(VisitEventKind.exited, cur, enteredAt!, _outsideSince ?? t);
    current = null;
    enteredAt = null;
    _outsideSince = null;
    return e;
  }
}
