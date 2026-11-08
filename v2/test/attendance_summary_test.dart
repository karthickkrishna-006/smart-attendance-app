import 'package:field_monitor/domain/attendance_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final records = <Map<String, dynamic>>[
    {'checkIn': {'status': 'verified', 'late': false}, 'checkOut': {'at': 1}},
    {'checkIn': {'status': 'verified', 'late': true}},
    {'checkIn': {'status': 'flagged', 'late': false, 'reasons': ['outside_area']}},
    {'checkIn': {'status': 'flagged', 'late': true}, 'checkOut': {'at': 2}},
    {'date': '2026-11-08'}, // no check-in: not counted
  ];

  test('today\'s figures count only real check-ins', () {
    final s = AttendanceSummary.of(records);
    expect(s.present, 4);
    expect(s.verified, 2);
    expect(s.flagged, 2);
    expect(s.late, 2);
    expect(s.stillWorking, 2);
    expect(s.finished, 2);
  });

  test('filters pick the right records', () {
    int n(AttendanceFilter f) => records.where((r) => matchesFilter(r, f)).length;
    expect(n(AttendanceFilter.all), 4);
    expect(n(AttendanceFilter.flagged), 2);
    expect(n(AttendanceFilter.late), 2);
    expect(n(AttendanceFilter.stillWorking), 2);
  });

  test('no records gives zeros', () => expect(AttendanceSummary.of(const []).present, 0));
}
