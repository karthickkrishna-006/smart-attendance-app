import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/demo_data.dart';
import '../../data/location.dart';
import '../../data/session_controller.dart';

/// System administrator: create or remove synthetic demo records.
class DemoTab extends StatefulWidget {
  const DemoTab({super.key, required this.session});
  final SessionController session;
  @override
  State<DemoTab> createState() => _DemoTabState();
}

class _DemoTabState extends State<DemoTab> {
  bool _busy = false;

  Future<void> _run(Future<String> Function() job) async {
    setState(() => _busy = true);
    try {
      showToast(await job(), kind: ToastKind.success);
    } catch (e) {
      showToast('Failed: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final demo = DemoData(widget.session.user!);
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Demo data lets every role see realistic screens before real workers use the app.\n\n'
            '• Creates "Demo Block", "Demo Panchayat", "Demo Street 1 and 2" with boundaries, today\'s attendance for 6 demo workers, '
            '4 tasks and 5 field reports.\n'
            '• Everything is marked synthetic and shows "demo" in the officer screens.\n'
            '• The Collector and auditors see it at once. To let an AD, Zonal Secretary or Supervisor see it, '
            'give them "Demo Block (synthetic)" in Setup → Access.\n'
            '• Boundaries are placed around your current location when available, so you can test attendance there.',
            style: TextStyle(height: 1.4),
          ),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy
            ? null
            : () => _run(() async {
                  double? lat, lng;
                  try {
                    final p = await Location.current();
                    lat = p.latitude;
                    lng = p.longitude;
                  } catch (_) {}
                  return lat == null ? demo.generate() : demo.generate(lat: lat, lng: lng!);
                }),
        icon: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Icon(Icons.auto_awesome),
        label: const Text('Create demo data for today'),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: _busy ? null : () => _run(() async => 'Removed ${await demo.clear()} demo records.'),
        icon: const Icon(Icons.delete_sweep_outlined),
        label: const Text('Remove demo records'),
      ),
    ]);
  }
}
