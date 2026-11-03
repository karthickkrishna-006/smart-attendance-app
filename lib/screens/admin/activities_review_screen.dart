import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';
import '../common/activity_tile.dart';

class ActivitiesReviewScreen extends StatefulWidget {
  final AppUser me;
  const ActivitiesReviewScreen({super.key, required this.me});
  @override
  State<ActivitiesReviewScreen> createState() => _ActivitiesReviewScreenState();
}

class _ActivitiesReviewScreenState extends State<ActivitiesReviewScreen> {
  String _filter = 'pending';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Field activity review')),
      body: LiveQueries(
        queries: [Db.col('activities')],
        builder: (context, d) {
          final all = d[0]..sort((a, b) => (toDate(b['createdAt']) ?? DateTime(0)).compareTo(toDate(a['createdAt']) ?? DateTime(0)));
          final list = all.where((a) => _filter == 'all' || (a['reviewStatus'] ?? 'pending') == _filter).toList();
          return Column(children: [
            SizedBox(
              height: 54,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), children: [
                for (final s in ['pending', 'approved', 'rejected', 'all'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('${titleCase(s)} (${s == 'all' ? all.length : all.where((a) => (a['reviewStatus'] ?? 'pending') == s).length})'),
                      selected: _filter == s,
                      onSelected: (_) => setState(() => _filter = s),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyView(icon: Icons.fact_check_outlined, title: 'Nothing to review')
                  : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: list.map((a) => ActivityTile(a: a, me: widget.me, showTask: true)).toList()),
            ),
          ]);
        },
      ),
    );
  }
}
