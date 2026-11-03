import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';

class AuditScreen extends StatelessWidget {
  final AppUser me;
  const AuditScreen({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audit trail')),
      body: LiveQueries(
        queries: [Db.col('audit_logs').orderBy('createdAt', descending: true).limit(200)],
        builder: (context, d) {
          final list = d[0];
          if (list.isEmpty) return const EmptyView(icon: Icons.policy_outlined, title: 'No audit entries yet');
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final a = list[i];
              final details = (a['details'] as Map?)?.entries.map((e) => '${e.key}: ${e.value}').join(', ') ?? '';
              return Card(
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, color: AppColors.navy),
                  title: Text(titleCase(a['action'] ?? ''), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${a['actorEmail'] ?? a['actorUid']}\n${a['target'] ?? ''}${details.isEmpty ? '' : ' · $details'}'),
                  isThreeLine: true,
                  trailing: Text(fmtDateTime(a['createdAt']), style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
