import 'geo.dart';

/// Duty-hour rules (Phase 1, Q14 and Q15 defaults; configurable later per
/// worker category).
class AttendancePolicy {
  const AttendancePolicy({
    this.startMinute = 9 * 60,
    this.endMinute = 17 * 60,
    this.lateToleranceMin = 15,
    this.earlyWindowMin = 60,
    this.maxAccuracyM = 50,
  });

  /// Shift start and end, minutes after midnight (local time).
  final int startMinute;
  final int endMinute;

  /// Check-in up to this many minutes after the start is on time.
  final int lateToleranceMin;

  /// Check-in is accepted from this many minutes before the start.
  final int earlyWindowMin;

  /// GPS fixes with a larger error radius than this are not trusted.
  final double maxAccuracyM;

  factory AttendancePolicy.fromMap(Map<String, dynamic>? m) {
    int minutes(Object? v, int fallback) {
      if (v is! String) return fallback;
      final p = v.split(':');
      final h = p.isNotEmpty ? int.tryParse(p.first) : null;
      final mm = p.length > 1 ? int.tryParse(p.elementAt(1)) : null;
      if (h == null || mm == null || h < 0 || h > 23 || mm < 0 || mm > 59) return fallback;
      return h * 60 + mm;
    }

    num n(Object? v, num fallback) => v is num && v >= 0 ? v : fallback;
    return AttendancePolicy(
      startMinute: minutes(m?['dutyStart'], 9 * 60),
      endMinute: minutes(m?['dutyEnd'], 17 * 60),
      lateToleranceMin: n(m?['lateToleranceMin'], 15).toInt(),
      maxAccuracyM: n(m?['maxAccuracyM'], 50).toDouble(),
    );
  }
}

/// Why a record needs a person's check. Stored as codes; the app shows them
/// in the worker's language.
enum FlagReason {
  noAssignedArea('no_assigned_area'),
  noGeofence('no_geofence'),
  outsideArea('outside_area'),
  nearEdge('near_edge'),
  lowAccuracy('low_accuracy'),
  mockLocation('mock_location'),
  outsideHours('outside_hours');

  const FlagReason(this.code);
  final String code;
}

enum AttendanceStatus { verified, flagged }

class Verdict {
  const Verdict(this.status, this.late, this.reasons);
  final AttendanceStatus status;
  final bool late;
  final List<FlagReason> reasons;
}

/// Decides Verified or Flagged for a check-in (Phase 1, section 4: failed
/// checks flag the record, they never block it).
///
/// [placement] is null when the worker has no geofence to compare with.
Verdict evaluateCheckIn({
  required bool hasAssignedArea,
  required Placement? placement,
  required double accuracyM,
  required bool mocked,
  required DateTime localTime,
  AttendancePolicy policy = const AttendancePolicy(),
}) {
  final reasons = <FlagReason>[];
  if (!hasAssignedArea) {
    reasons.add(FlagReason.noAssignedArea);
  } else if (placement == null) {
    reasons.add(FlagReason.noGeofence);
  } else if (placement == Placement.outside) {
    reasons.add(FlagReason.outsideArea);
  } else if (placement == Placement.uncertain) {
    reasons.add(FlagReason.nearEdge);
  }
  if (!accuracyM.isFinite || accuracyM > policy.maxAccuracyM) reasons.add(FlagReason.lowAccuracy);
  if (mocked) reasons.add(FlagReason.mockLocation);
  final minute = localTime.hour * 60 + localTime.minute;
  final inHours = minute >= policy.startMinute - policy.earlyWindowMin && minute <= policy.endMinute;
  if (!inHours) reasons.add(FlagReason.outsideHours);
  final late = inHours && minute > policy.startMinute + policy.lateToleranceMin;
  return Verdict(reasons.isEmpty ? AttendanceStatus.verified : AttendanceStatus.flagged, late, reasons);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// yyyy-MM-dd of a local date.
String dayKey(DateTime local) => '${local.year}-${_two(local.month)}-${_two(local.day)}';

/// One attendance session per worker per day: `attendanceSessions/{uid}_{day}`.
/// The fixed id is what prevents duplicate check-ins, even offline.
String sessionId(String uid, String day) => '${uid}_$day';
