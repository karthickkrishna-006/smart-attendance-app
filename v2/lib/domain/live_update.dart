import 'geo.dart';

/// When a phone on duty should send its position (and add a route point).
///
/// Sending only when the worker has really moved, or after a quiet period,
/// keeps the live map current while using about a fifth of the database
/// writes and battery of sending every minute. Pure logic, unit-tested.
class LiveUpdatePolicy {
  const LiveUpdatePolicy({
    this.minMoveM = 40,
    this.maxQuiet = const Duration(minutes: 5),
    this.minGap = const Duration(seconds: 30),
    this.maxAccuracyM = 60,
  });

  /// Send after moving at least this far from the last sent position.
  final double minMoveM;

  /// Send at least this often even when standing still (shows "still here").
  final Duration maxQuiet;

  /// Never send more often than this.
  final Duration minGap;

  /// Ignore fixes less accurate than this (unless nothing was sent yet).
  final double maxAccuracyM;

  bool shouldSend({
    required GeoPoint2? lastSent,
    required DateTime? lastSentAt,
    required GeoPoint2 now,
    required double accuracyM,
    required DateTime at,
    bool force = false,
  }) {
    if (lastSent == null || lastSentAt == null) return true;
    final gap = at.difference(lastSentAt);
    if (force) return gap >= const Duration(seconds: 5);
    if (gap < minGap) return false;
    if (gap >= maxQuiet) return true;
    if (!accuracyM.isFinite || accuracyM > maxAccuracyM) return false;
    return distanceM(lastSent, now) >= minMoveM;
  }
}

/// How fresh a live position is, for the map colours.
enum LiveState { moving, stale, offDuty }

LiveState liveStateOf({required bool onDuty, required DateTime? at, required DateTime now}) {
  if (!onDuty || at == null) return LiveState.offDuty;
  return now.difference(at) <= const Duration(minutes: 10) ? LiveState.moving : LiveState.stale;
}
