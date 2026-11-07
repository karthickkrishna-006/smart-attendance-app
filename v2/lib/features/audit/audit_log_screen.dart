import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';

/// The latest 200 audit entries (System administrator and Auditor only; the
/// security rules refuse everyone else). Entries can never be edited.
class AuditLogScreen extends StatelessWidget {
  const AuditLogScreen({super.key});

  static String _when(Object? t) {
    if (t is! Timestamp) return '';
    final d = t.toDate().toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('auditLog').orderBy('at', descending: true).limit(200).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return MessageView(icon: Icons.error_outline, title: 'Could not load the audit log', body: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snap.data!.docs;
          if (docs.isEmpty) return const MessageView(icon: Icons.policy_outlined, title: 'No entries yet');
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final e = docs.elementAt(i).data();
              return ListTile(
                leading: const Icon(Icons.history, color: AppColors.indigo),
                title: Text('${e['action']}'),
                subtitle: Text('${e['actorEmail'] ?? e['actorUid']} · ${e['target']}${(e['details'] ?? '') != '' ? ' · ${e['details']}' : ''}'),
                trailing: Text(_when(e['at']), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              );
            },
          );
        },
      );
}
