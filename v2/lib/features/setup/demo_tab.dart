import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/demo_data.dart';
import '../../data/live_simulation.dart';
import '../../data/location.dart';
import '../../data/session_controller.dart';

/// System administrator: the SAMPLE district (realistic, clearly marked) and
/// a time-limited live simulation for demonstrations.
class DemoTab extends StatefulWidget {
  const DemoTab({super.key, required this.session});
  final SessionController session;
  @override
  State<DemoTab> createState() => _DemoTabState();
}

class _DemoTabState extends State<DemoTab> {
  bool _busy = false;
  String? _progress;

  Future<void> _run(Future<String> Function() job) async {
    setState(() => _busy = true);
    try {
      showToast(await job(), kind: ToastKind.success);
    } catch (e) {
      showToast('Failed: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() {
            _busy = false;
            _progress = null;
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final demo = DemoData(widget.session.user!);
    void progress(String p) {
      if (mounted) setState(() => _progress = p);
    }

    return ListView(padding: const EdgeInsets.all(16), children: [
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'SAMPLE district for demonstrations and training (from Smart-Attendance-SAMPLE-Data.xlsx):\n\n'
            '• Thirukazhukundram block (sample): 2 zones, 6 village panchayats, 18 habitations, 36 streets with boundaries '
            'and 262 cleaning zones, 43 staff of every type with today\'s attendance, GPS photos, street check-ins/outs, tasks and reports.\n'
            '• Names of panchayats, streets and people are made up and marked "sample". Replace with official data for real use.\n'
            '• Collector and auditors see it at once. Give other officers "Thirukazhukundram (sample)" in Setup → Access.\n'
            '• Takes about a minute (about 360 small saves, so the security rules can check each one).',
            style: TextStyle(height: 1.4),
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (_progress != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text('Creating: $_progress…')),
          ]),
        ),
      FilledButton.icon(
        onPressed: _busy ? null : () => _run(() => demo.generate(progress: progress)),
        icon: const Icon(Icons.location_city),
        label: const Text('Create sample district (Thirukazhukundram)'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () => _run(() async {
                  final p = await Location.current();
                  return demo.generate(lat: p.latitude, lng: p.longitude, progress: progress);
                }),
        icon: const Icon(Icons.my_location),
        label: const Text('Create it around my location (to walk into a street)'),
      ),
      const SizedBox(height: 20),
      ListenableBuilder(
        listenable: LiveSimulation.instance,
        builder: (context, _) {
          final sim = LiveSimulation.instance;
          final left = sim.endsAt?.difference(DateTime.now());
          return Card(
            color: sim.running ? const Color(0xFFE3EFE9) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Live simulation (demonstration)', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Up to 12 sample Thoomai Kavalars walk along their streets for 15 minutes: they move on every officer\'s '
                    'live map, check in and out of streets automatically and tick cleaning zones. Keep this screen open while it runs.',
                    style: TextStyle(color: AppColors.muted)),
                if (sim.running) ...[
                  const SizedBox(height: 8),
                  Text('Running · ${left == null ? '' : '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')} left'} · ${sim.writes} updates sent',
                      style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.green)),
                ],
                if (sim.lastError != null) Text(sim.lastError!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                const SizedBox(height: 10),
                sim.running
                    ? OutlinedButton.icon(onPressed: sim.stop, icon: const Icon(Icons.stop), label: const Text('Stop simulation'))
                    : FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                try {
                                  final n = await sim.start();
                                  showToast('Simulation started: $n workers walking. Open Live monitoring on another phone.', kind: ToastKind.success);
                                } catch (e) {
                                  showToast('$e', kind: ToastKind.error);
                                }
                              },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start live simulation (15 min)'),
                      ),
              ]),
            ),
          );
        },
      ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: _busy ? null : () => _run(() async => 'Removed ${await demo.clear()} sample activity records.'),
        icon: const Icon(Icons.delete_sweep_outlined),
        label: const Text('Remove sample activity records'),
      ),
    ]);
  }
}
