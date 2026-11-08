/// Today's figures for an officer, from the attendance records they may see.
class AttendanceSummary {
  const AttendanceSummary({
    this.present = 0,
    this.verified = 0,
    this.flagged = 0,
    this.late = 0,
    this.stillWorking = 0,
    this.finished = 0,
  });

  /// Workers who marked attendance (verified or flagged).
  final int present;
  final int verified;
  final int flagged;
  final int late;

  /// Checked in, not yet checked out.
  final int stillWorking;
  final int finished;

  static AttendanceSummary of(Iterable<Map<String, dynamic>> sessions) {
    var present = 0, verified = 0, flagged = 0, late = 0, open = 0, done = 0;
    for (final s in sessions) {
      final ci = s['checkIn'];
      if (ci is! Map) continue;
      present++;
      if (ci['status'] == 'verified') {
        verified++;
      } else {
        flagged++;
      }
      if (ci['late'] == true) late++;
      if (s['checkOut'] is Map) {
        done++;
      } else {
        open++;
      }
    }
    return AttendanceSummary(present: present, verified: verified, flagged: flagged, late: late, stillWorking: open, finished: done);
  }
}

/// Filters on the officer attendance list.
enum AttendanceFilter { all, flagged, late, stillWorking }

bool matchesFilter(Map<String, dynamic> s, AttendanceFilter f) {
  final ci = s['checkIn'];
  if (ci is! Map) return false;
  return switch (f) {
    AttendanceFilter.all => true,
    AttendanceFilter.flagged => ci['status'] != 'verified',
    AttendanceFilter.late => ci['late'] == true,
    AttendanceFilter.stillWorking => s['checkOut'] is! Map,
  };
}
