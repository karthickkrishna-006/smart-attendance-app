import 'package:latlong2/latlong.dart';
import '../core/fmt.dart';

class Roles {
  static const admin = 'admin';
  static const supervisor = 'supervisor';
  static const worker = 'worker';
  static const auditor = 'auditor';
  static const all = [admin, supervisor, worker, auditor];
  static String label(String r) => const {
        admin: 'Administrator',
        supervisor: 'Supervisor',
        worker: 'Field Worker',
        auditor: 'Auditor / Analyst',
      }[r] ??
      r;
}

class AppUser {
  final String uid; // database-generated ID (Firebase UID or Firestore doc id)
  final Map<String, dynamic> raw;
  AppUser(this.uid, this.raw);

  String get name => (raw['name'] ?? '') as String;
  String get email => (raw['email'] ?? '') as String;
  String get role => (raw['role'] ?? Roles.worker) as String;
  String get status => (raw['status'] ?? 'active') as String;
  String get employeeId => (raw['employeeId'] ?? '') as String; // human-facing ID
  String get phone => (raw['phone'] ?? '') as String;
  String get category => (raw['category'] ?? '') as String;
  String? get supervisorId => raw['supervisorId'] as String?;
  String? get boundaryId => raw['boundaryId'] as String?;
  String? get photo => raw['photo'] as String?;
  bool get synthetic => raw['synthetic'] == true;
  bool get hasLogin => raw['hasLogin'] != false;
  List<double>? get faceEmbedding {
    final f = raw['faceEmbedding'];
    if (f is List && f.isNotEmpty) return f.map((e) => asDouble(e)).toList();
    return null;
  }

  bool get isAdmin => role == Roles.admin;
  bool get isStaff => role == Roles.admin || role == Roles.supervisor;
  bool get canViewAll => isStaff || role == Roles.auditor;
}

class Boundary {
  final String id;
  final Map<String, dynamic> raw;
  Boundary(this.id, this.raw);

  factory Boundary.fromDoc(Map<String, dynamic> d) => Boundary(d['id'] as String, d);

  String get name => (raw['name'] ?? 'Boundary') as String;
  String get district => (raw['district'] ?? 'Chengalpattu') as String;
  String get block => (raw['block'] ?? '') as String;
  String get panchayat => (raw['panchayat'] ?? '') as String;
  String get layer => (raw['layer'] ?? '') as String;
  String get attributeColumn => (raw['attributeColumn'] ?? '') as String;
  String get attributeValue => (raw['attributeValue'] ?? '') as String;
  String get source => (raw['source'] ?? '') as String;
  bool get synthetic => raw['synthetic'] != false;
  List<LatLng> get points {
    final p = raw['points'];
    if (p is! List) return [];
    return p
        .whereType<Map>()
        .map((m) => LatLng(asDouble(m['lat']), asDouble(m['lng'])))
        .toList();
  }

  static List<Map<String, double>> encode(List<LatLng> pts) =>
      pts.map((e) => {'lat': e.latitude, 'lng': e.longitude}).toList();
}
