import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../data/lgd_import.dart';

/// Setup → Areas: load the official Chengalpattu areas (LGD) in one step.
class LgdImportCard extends StatefulWidget {
  const LgdImportCard({super.key, required this.dir});
  final Directory dir;
  @override
  State<LgdImportCard> createState() => _LgdImportCardState();
}

class _LgdImportCardState extends State<LgdImportCard> {
  bool _busy = false;
  String? _progress;

  Future<void> _run() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Load Chengalpattu areas (LGD)?'),
        content: const Text('Creates the official area tree from the Local Government Directory: 8 blocks, 359 village '
            'panchayats and their 681 villages as habitations. Areas already loaded are skipped, so it is safe to run again. '
            'Takes a few minutes; keep this screen open.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Load')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final msg = await LgdImport(widget.dir.user).run(progress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      showToast(msg, kind: ToastKind.success);
    } catch (e) {
      showToast('Not finished: $e. Press Load again to continue (finished areas are skipped).', kind: ToastKind.error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
        color: const Color(0xFFE8F1EC),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Official Chengalpattu areas (LGD)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('8 blocks · 359 village panchayats · 681 villages (as habitations), from lgdirectory.gov.in. '
                'Then add streets under the habitations, draw their boundaries and mark the cleaning zones.',
                style: TextStyle(color: AppColors.muted, height: 1.35)),
            if (_progress != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(child: Text(_progress!)),
              ]),
            ],
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: const Icon(Icons.download_for_offline_outlined),
              label: const Text('Load Chengalpattu areas (LGD)'),
            ),
          ]),
        ),
      );
}
