import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/demo_seed.dart';
import '../../services/face_service.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';

/// Configurable attendance & alert business rules (admin only) + demo data.
class SettingsScreen extends StatefulWidget {
  final AppUser me;
  const SettingsScreen({super.key, required this.me});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _s;
  bool _busy = false;
  String? _modelInfo;

  @override
  void initState() {
    super.initState();
    Db.getSettings().then((s) {
      if (mounted) setState(() => _s = s);
    });
    FaceService.ensureLoaded().then((ok) {
      if (mounted) setState(() => _modelInfo = ok ? 'Loaded · ${FaceService.modelInfo}' : (FaceService.loadError ?? 'Unavailable'));
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await Db.col('settings').doc('config').set(_s!);
      await Db.audit('settings_updated', 'settings/config');
      if (mounted) showSnack(context, 'Rules saved.', success: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime(String key) async {
    final m = hm(_s![key] as String);
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (t != null) setState(() => _s![key] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
  }

  Future<void> _seed() async {
    if (!await confirm(context, 'Load synthetic demo data',
        'Creates demo boundaries around your current location, demo workers, tasks, 7 days of attendance and alerts. Everything is labelled SYNTHETIC DEMO and can be removed later.',
        ok: 'Create')) return;
    setState(() => _busy = true);
    try {
      LatLng c;
      try {
        final p = await LocationService.current();
        c = LatLng(p.latitude, p.longitude);
      } catch (_) {
        c = const LatLng(12.6919, 79.9762); // generic Chengalpattu town reference point
      }
      final msg = await DemoSeed.seed(c);
      if (mounted) showSnack(context, msg, success: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (!await confirm(context, 'Remove demo data', 'Deletes every record marked synthetic. Real records are not touched.', ok: 'Delete', danger: true)) return;
    setState(() => _busy = true);
    try {
      final n = await DemoSeed.clear();
      if (mounted) showSnack(context, 'Removed $n synthetic records.', success: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & rules')),
      body: s == null
          ? const LoadingView()
          : ListView(padding: const EdgeInsets.all(16), children: [
              const SectionTitle('Attendance rules'),
              Card(
                child: Column(children: [
                  ListTile(leading: const Icon(Icons.schedule), title: const Text('Late after'), trailing: Text(s['lateAfter']), onTap: () => _pickTime('lateAfter')),
                  ListTile(leading: const Icon(Icons.event_busy), title: const Text('Missing-attendance alert after'), trailing: Text(s['missingAfter']), onTap: () => _pickTime('missingAfter')),
                  SwitchListTile(
                    secondary: const Icon(Icons.face),
                    title: const Text('Require face verification at check-in'),
                    value: s['requireFace'] == true,
                    onChanged: (v) => setState(() => s['requireFace'] = v),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.layers_outlined),
                    title: const Text('Require location inside boundary'),
                    value: s['requireBoundary'] == true,
                    onChanged: (v) => setState(() => s['requireBoundary'] = v),
                  ),
                  ListTile(
                    leading: const Icon(Icons.percent),
                    title: Text('Face match threshold: ${(asDouble(s['faceThreshold']) * 100).toStringAsFixed(0)}%'),
                    subtitle: Slider(
                      value: asDouble(s['faceThreshold']).clamp(0.3, 0.95),
                      min: 0.3,
                      max: 0.95,
                      divisions: 13,
                      onChanged: (v) => setState(() => s['faceThreshold'] = double.parse(v.toStringAsFixed(2))),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.gps_fixed),
                    title: Text('Max GPS accuracy: ±${asDouble(s['maxGpsAccuracy']).toStringAsFixed(0)} m'),
                    subtitle: Slider(
                      value: asDouble(s['maxGpsAccuracy']).clamp(10, 200),
                      min: 10,
                      max: 200,
                      divisions: 19,
                      onChanged: (v) => setState(() => s['maxGpsAccuracy'] = v.round()),
                    ),
                  ),
                ]),
              ),
              const SectionTitle('Field-duty tracking'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.straighten),
                    title: Text('Save a route point every ${asDouble(s['trackMinDistanceM'], 50).toStringAsFixed(0)} m moved'),
                    subtitle: Slider(
                      value: asDouble(s['trackMinDistanceM'], 50).clamp(20, 200),
                      min: 20,
                      max: 200,
                      divisions: 18,
                      onChanged: (v) => setState(() => s['trackMinDistanceM'] = v.round()),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: Text('…or at least every ${(asDouble(s['trackHeartbeatSec'], 300) / 60).toStringAsFixed(0)} min'),
                    subtitle: Slider(
                      value: asDouble(s['trackHeartbeatSec'], 300).clamp(120, 1800),
                      min: 120,
                      max: 1800,
                      divisions: 14,
                      onChanged: (v) => setState(() => s['trackHeartbeatSec'] = (v / 60).round() * 60),
                    ),
                  ),
                  const ListTile(
                    dense: true,
                    leading: Icon(Icons.info_outline),
                    title: Text('Fewer points use less battery and fewer database writes. Changes apply when a worker next starts duty.'),
                  ),
                ]),
              ),
              const SectionTitle('Evidence storage'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('Enable photo evidence uploads'),
                  subtitle: const Text('Requires Cloud Storage for Firebase (Blaze plan) and published storage.rules. See docs/STORAGE.md.'),
                  value: s['evidenceStorageEnabled'] == true,
                  onChanged: (v) => setState(() => s['evidenceStorageEnabled'] = v),
                ),
              ),
              const SectionTitle('Alert rules'),
              Card(
                child: Column(
                  children: (s['rules'] as Map).keys.map((k) {
                    return SwitchListTile(
                      title: Text(titleCase(k.toString())),
                      value: (s['rules'] as Map)[k] == true,
                      onChanged: (v) => setState(() => (s['rules'] as Map)[k] = v),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Save rules')),
              const SectionTitle('AI face verification service'),
              Card(
                child: ListTile(
                  leading: Icon(Icons.memory, color: _modelInfo?.startsWith('Loaded') == true ? AppColors.success : AppColors.warning),
                  title: Text(FaceService.modelName),
                  subtitle: Text(_modelInfo ?? 'Checking…'),
                ),
              ),
              const SectionTitle('Demo data'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Row(children: [DemoBadge(small: false)]),
                    const SizedBox(height: 8),
                    const Text('Use only for demonstrations until official worker master data and GIS boundaries are provided. All demo records are visibly labelled.'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(onPressed: _busy ? null : _seed, icon: const Icon(Icons.auto_awesome), label: const Text('Load synthetic demo data')),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                      onPressed: _busy ? null : _clear,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Remove all demo data'),
                    ),
                  ]),
                ),
              ),
              if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
              const SizedBox(height: 30),
            ]),
    );
  }
}
