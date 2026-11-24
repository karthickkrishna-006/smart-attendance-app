import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';

/// The latest 300 audit entries (System administrator and Auditor only; the
/// security rules refuse everyone else). Entries can never be edited.
/// Shown in plain words, grouped by day, with a filter and a search.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});
  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

enum _Kind { changes, signIns, all }

class _AuditLogScreenState extends State<AuditLogScreen> {
  late final _stream = FirebaseFirestore.instance.collection('auditLog').orderBy('at', descending: true).limit(300).snapshots();
  _Kind _kind = _Kind.changes;
  String _q = '';

  /// Plain words for the recorded action codes.
  static const _words = {
    'sign_in': 'Signed in',
    'sign_out': 'Signed out',
    'account_claimed': 'First sign-in (account set up)',
    'bootstrap_first_admin': 'First administrator set up',
    'person_added': 'Person added',
    'role_granted': 'Role given',
    'role_deleted': 'Role deleted',
    'role_scope_changed': 'Role or areas changed',
    'role_title_changed': 'Role title renamed',
    'role_demo_areas_removed': 'Demo areas removed from a role',
    'area_created': 'Area added',
    'district_created': 'District created',
    'lgd_area_import': 'Official area loaded (LGD)',
    'geofence_created': 'Boundary drawn',
    'geofence_imported': 'Boundary imported',
    'cleaning_zone_added': 'Cleaning zone marked',
    'organisation_created': 'Organisation added',
    'settings_changed': 'Settings changed',
    'open_signup': 'Open sign-up changed',
    'sample_area': 'Sample area (demo)',
    'sample_boundary': 'Sample boundary (demo)',
    'sample_cleaning_zone': 'Sample cleaning zone (demo)',
  };

  static String _word(Object? action) => _words['$action'] ?? '$action'.replaceAll('_', ' ');
  static bool _isSign(Object? action) => action == 'sign_in' || action == 'sign_out';

  static String _day(DateTime d) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today';
    final y = now.subtract(const Duration(days: 1));
    if (d.year == y.year && d.month == y.month && d.day == y.day) return 'Yesterday';
    return '${two(d.day)}-${two(d.month)}-${d.year}';
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load the audit log', body: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final q = _q.toLowerCase();
          final entries = [
            for (final d in snap.data!.docs)
              if (switch (_kind) { _Kind.changes => !_isSign(d.data()['action']), _Kind.signIns => _isSign(d.data()['action']), _Kind.all => true })
                if (q.isEmpty ||
                    '${d.data()['actorEmail']} ${_word(d.data()['action'])} ${d.data()['target']} ${d.data()['details']}'.toLowerCase().contains(q))
                  d.data(),
          ];
          String? lastDay;
          final rows = <Widget>[];
          for (final e in entries) {
            final at = e['at'] is Timestamp ? (e['at'] as Timestamp).toDate().toLocal() : null;
            final day = at == null ? '' : _day(at);
            if (day != lastDay) {
              lastDay = day;
              rows.add(Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
                child: Text(day, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.green)),
              ));
            }
            rows.add(Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                leading: Icon(_isSign(e['action']) ? Icons.login : Icons.edit_note, color: _isSign(e['action']) ? AppColors.muted : AppColors.indigo),
                title: Text(_word(e['action']), style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  '${e['actorEmail'] ?? e['actorUid']}',
                  if ((e['details'] ?? '') != '') '${e['details']}',
                ].join(' · ')),
                trailing: Text(
                  at == null ? '' : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ),
            ));
          }
          return ListView(padding: const EdgeInsets.all(12), children: [
            SegmentedButton<_Kind>(
              segments: const [
                ButtonSegment(value: _Kind.changes, label: Text('Changes')),
                ButtonSegment(value: _Kind.signIns, label: Text('Sign-ins')),
                ButtonSegment(value: _Kind.all, label: Text('All')),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by person, action or area', isDense: true),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('Nothing here.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted))),
            ...rows,
          ]);
        },
      );
}
