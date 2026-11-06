import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'theme.dart';
import 'fmt.dart';

typedef Doc = Map<String, dynamic>;

List<Doc> docsOf(QuerySnapshot<Map<String, dynamic>> s) =>
    s.docs.map((d) => <String, dynamic>{...d.data(), 'id': d.id}).toList();

/// Subscribes to several Firestore queries at once and rebuilds when any of
/// them changes. Every dashboard number comes from these live snapshots.
///
/// A `null` query is treated as an always-empty result. This is used for data
/// a role is not allowed to read (for example, live positions for auditors),
/// so one forbidden query cannot break a whole screen.
class LiveQueries extends StatefulWidget {
  final List<Query<Map<String, dynamic>>?> queries;
  final Widget Function(BuildContext, List<List<Doc>>) builder;
  final Object? queryKey;
  const LiveQueries({super.key, required this.queries, required this.builder, this.queryKey});

  @override
  State<LiveQueries> createState() => _LiveQueriesState();
}

class _LiveQueriesState extends State<LiveQueries> {
  final List<StreamSubscription> _subs = [];
  late List<List<Doc>?> _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _data = List.filled(widget.queries.length, null);
    _error = null;
    for (int i = 0; i < widget.queries.length; i++) {
      final q = widget.queries[i];
      if (q == null) {
        _data[i] = const <Doc>[];
        continue;
      }
      _subs.add(q.snapshots().listen((snap) {
        if (!mounted) return;
        setState(() => _data[i] = docsOf(snap));
      }, onError: (e) {
        if (!mounted) return;
        setState(() => _error = e);
      }));
    }
  }

  @override
  void didUpdateWidget(covariant LiveQueries old) {
    super.didUpdateWidget(old);
    if (old.queryKey != widget.queryKey) _subscribe();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return ErrorView(message: friendlyError(_error!), onRetry: () => setState(_subscribe));
    if (_data.any((d) => d == null)) return const LoadingView();
    return widget.builder(context, _data.map((e) => e!).toList());
  }
}

String friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('permission-denied')) {
    return 'Permission denied by Firestore security rules. Make sure the rules from firestore.rules are published and your role allows this.';
  }
  if (s.contains('unavailable') || s.contains('network')) {
    return 'Network unavailable. Check your internet connection and try again.';
  }
  return s.replaceAll(RegExp(r'^\[.*?\]\s*'), '');
}

class LoadingView extends StatelessWidget {
  final String? label;
  const LoadingView({super.key, this.label});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            if (label != null) ...[const SizedBox(height: 14), Text(label!, style: const TextStyle(color: AppColors.muted))],
          ]),
        ),
      );
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorView({super.key, required this.message, this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 52, color: AppColors.danger),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ],
          ]),
        ),
      );
}

class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  const EmptyView({super.key, required this.icon, required this.title, this.subtitle});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.navy.withValues(alpha: 0.06), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: AppColors.navy.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
            ],
          ]),
        ),
      );
}

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? sub;
  final VoidCallback? onTap;
  const StatCard({super.key, required this.label, required this.value, required this.icon, required this.color, this.sub, this.onTap});
  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: color, size: 20),
                ),
                const Spacer(),
                if (onTap != null) const Icon(Icons.chevron_right, size: 18, color: AppColors.muted),
              ]),
              const SizedBox(height: 10),
              Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
              if (sub != null) Text(sub!, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionTitle(this.title, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: AppColors.navyDark))),
          if (trailing != null) trailing!,
        ]),
      );
}

Color statusColor(String? s) {
  switch (s) {
    case 'present':
    case 'verified':
    case 'inside':
    case 'completed':
    case 'approved':
    case 'resolved':
    case 'active':
      return AppColors.success;
    case 'late':
    case 'pending':
    case 'pending_verification':
    case 'submitted':
    case 'in_progress':
    case 'medium':
    case 'low_accuracy':
    case 'unavailable':
    case 'not_enrolled':
    case 'not_performed':
    case 'no_face':
    case 'no_boundary':
      return AppColors.warning;
    case 'rejected':
    case 'failed':
    case 'outside':
    case 'absent':
    case 'critical':
    case 'high':
    case 'open':
    case 'overdue':
    case 'inactive':
    case 'suspended':
      return AppColors.danger;
    case 'pending_approval':
    case 'assigned':
    case 'low':
      return AppColors.info;
    default:
      return AppColors.muted;
  }
}

class StatusChip extends StatelessWidget {
  final String status;
  final String? label;
  const StatusChip(this.status, {super.key, this.label});
  @override
  Widget build(BuildContext context) {
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(label ?? titleCase(status), style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

/// Visible label for all synthetic / demo records (Product Report §5.4, §9).
class DemoBadge extends StatelessWidget {
  final bool small;
  const DemoBadge({super.key, this.small = true});
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 6 : 10, vertical: small ? 2 : 5),
        decoration: BoxDecoration(
          color: AppColors.demo.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.demo.withValues(alpha: 0.5)),
        ),
        child: Text('SYNTHETIC DEMO',
            style: TextStyle(color: AppColors.demo, fontSize: small ? 9.5 : 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
      );
}

class AvatarCircle extends StatelessWidget {
  final String name;
  final String? photo; // base64 jpeg
  final double radius;
  const AvatarCircle({super.key, required this.name, this.photo, this.radius = 20});
  @override
  Widget build(BuildContext context) {
    if (photo != null && photo!.isNotEmpty) {
      try {
        return CircleAvatar(radius: radius, backgroundImage: MemoryImage(base64Decode(photo!)));
      } catch (_) {}
    }
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.teal.withValues(alpha: 0.18),
      child: Text(initials, style: TextStyle(color: AppColors.navy, fontWeight: FontWeight.w700, fontSize: radius * 0.7)),
    );
  }
}

void showSnack(BuildContext context, String msg, {bool error = false, bool success = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? AppColors.danger : (success ? AppColors.success : null),
    ));
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'Confirm', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: AppColors.danger) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

class InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  const InfoRow(this.icon, this.label, this.value, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color ?? AppColors.muted),
          const SizedBox(width: 10),
          SizedBox(width: 110, child: Text(label, style: const TextStyle(color: AppColors.muted))),
          Expanded(child: Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color))),
        ]),
      );
}

class Legend extends StatelessWidget {
  final Color color;
  final String text;
  const Legend(this.color, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ]);
}
