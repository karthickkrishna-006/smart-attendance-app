import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/models.dart';
import '../common/alerts_screen.dart';
import '../common/profile_screen.dart';
import 'activities_review_screen.dart';
import 'attendance_admin_screen.dart';
import 'audit_screen.dart';
import 'boundaries_screen.dart';
import 'coverage_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';

class MoreScreen extends StatelessWidget {
  final AppUser me;
  const MoreScreen({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, Color, Widget)>[
      (Icons.how_to_reg_outlined, 'Attendance register', 'Daily records, review & override', AppColors.success, AttendanceAdminScreen(me: me)),
      (Icons.fact_check_outlined, 'Field activity review', 'Approve or reject submissions', AppColors.teal, ActivitiesReviewScreen(me: me)),
      (Icons.notifications_active_outlined, 'Alerts', 'Open, critical and resolved alerts', AppColors.danger, AlertsScreen(me: me)),
      (Icons.grid_view_outlined, 'Field coverage', 'Panchayat-wise duty coverage by day', AppColors.success, CoverageScreen(me: me)),
      (Icons.polyline_outlined, 'GIS boundaries', 'Draw, import & assign boundaries', AppColors.demo, BoundariesScreen(me: me)),
      (Icons.insights_outlined, 'Reports & analytics', 'Date / worker / location filters', AppColors.info, ReportsScreen(me: me)),
      (Icons.policy_outlined, 'Audit trail', 'Administrative action log', AppColors.navy, AuditScreen(me: me)),
      if (me.isAdmin) (Icons.tune, 'Settings & rules', 'Attendance rules, alert rules, demo data', AppColors.warning, SettingsScreen(me: me)),
      (Icons.person_outline, 'My profile', 'Account & sign out', AppColors.muted, ProfileScreen(me: me)),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        StatGrid(
          spacing: 12,
          children: items
            .map((it) => Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => it.$5)),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: it.$4.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                          child: Icon(it.$1, color: it.$4),
                        ),
                        const SizedBox(height: 12),
                        Text(it.$2, style: const TextStyle(fontWeight: FontWeight.w700), maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(it.$3, style: const TextStyle(fontSize: 11.5, color: AppColors.muted), maxLines: 3, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                  ),
                ))
            .toList(),
        ),
      ]
      ),
    );
  }
}
