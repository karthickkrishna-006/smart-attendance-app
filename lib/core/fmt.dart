import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

DateTime? toDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
String fmtTime(dynamic v) {
  final d = toDate(v);
  return d == null ? '--' : DateFormat('hh:mm a').format(d);
}

String fmtDate(dynamic v) {
  final d = toDate(v);
  return d == null ? '--' : DateFormat('dd MMM yyyy').format(d);
}

String fmtDateTime(dynamic v) {
  final d = toDate(v);
  return d == null ? '--' : DateFormat('dd MMM, hh:mm a').format(d);
}

String ago(dynamic v) {
  final d = toDate(v);
  if (d == null) return '--';
  final s = DateTime.now().difference(d);
  if (s.inSeconds < 60) return 'just now';
  if (s.inMinutes < 60) return '${s.inMinutes} min ago';
  if (s.inHours < 24) return '${s.inHours} h ago';
  return '${s.inDays} d ago';
}

String titleCase(String s) => s
    .replaceAll('_', ' ')
    .split(' ')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

double asDouble(dynamic v, [double def = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? def;
  return def;
}

/// Parses "HH:mm" to minutes since midnight.
int hm(String s) {
  final p = s.split(':');
  if (p.length != 2) return 9 * 60 + 30;
  return (int.tryParse(p[0]) ?? 9) * 60 + (int.tryParse(p[1]) ?? 30);
}
