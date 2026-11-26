import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/directory.dart';
import '../../domain/area.dart';
import '../../domain/staff_import.dart';

/// Adds many staff at once from a sheet: copy the rows in Excel (or open a
/// CSV file and copy its text), paste here, check, then add. Each person gets
/// their role, designation and area the first time they sign in.
class BulkImportScreen extends StatefulWidget {
  const BulkImportScreen({super.key, required this.dir, required this.existingEmails});
  final Directory dir;
  final Set<String> existingEmails;

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> {
  final _text = TextEditingController();
  ImportResult? _result;
  bool _busy = false;
  int _done = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_text.text.trim().isEmpty) {
      showToast('Paste the staff rows first.', kind: ToastKind.error);
      return;
    }
    setState(() => _busy = true);
    try {
      final List<AreaNode> areas = await widget.dir.areas().first;
      if (areas.isEmpty) {
        showToast('No areas yet. Load the official areas in Setup → Areas first.', kind: ToastKind.error);
        return;
      }
      setState(() => _result = StaffSheet(areas).read(_text.text, existingEmails: widget.existingEmails));
    } catch (e) {
      showToast('Could not check: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final rows = _result?.rows ?? const <ImportRow>[];
    if (rows.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Add ${rows.length} people?'),
        content: const Text('Each person gets this role and area the first time they sign in. '
            'Lines with problems are left out; fix them and import those lines again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _done = 0;
    });
    try {
      final n = await widget.dir.bulkPreregister(rows, onProgress: (d, _) {
        if (mounted) setState(() => _done = d);
      });
      showToast('$n people added.', kind: ToastKind.success);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      showToast('$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Import staff from a sheet')),
      bottomNavigationBar: r == null || r.rows.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.group_add_outlined),
                  label: Text(_busy ? 'Adding… $_done of ${r.rows.length}' : 'Add ${r.rows.length} people'),
                ),
              ),
            ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
        const Text('1. Prepare the sheet in Excel with these columns:', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(8)),
          child: const SelectableText('email | name | employee id | designation | block | panchayat | habitation',
              style: TextStyle(fontFamily: 'monospace', fontSize: 13)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: StaffSheet.template));
              showToast('Heading row copied. Paste it into the first row in Excel.', kind: ToastKind.success);
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy the heading row'),
          ),
        ),
        const Text(
          '• Designation: for example Thoomai Kavalar, OHT Operator, MNP, VP Secretary, Zonal Dy.BDO, '
          'Dy.BDO (Panchayats), Dy.BDO (Regular), BDO (Village Panchayats), BDO (Block Panchayat).\n'
          '• Area: names as in Setup → Areas. Fill only as deep as needed: block only for BDOs; '
          'block + panchayat for VP Secretary / MNP; block + panchayat + habitation for Thoomai Kavalar / OHT.\n'
          '• Several panchayats or habitations: separate with ";" (for example a Zonal Dy.BDO).',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        const Text('2. Select the rows in Excel (with the heading), copy, and paste here:', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          controller: _text,
          minLines: 6,
          maxLines: 12,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(hintText: 'Paste here (a CSV file\'s text also works)', alignLabelWithHint: true),
          onChanged: (_) {
            if (_result != null) setState(() => _result = null);
          },
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _check,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('3. Check the rows'),
        ),
        if (r != null) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(avatar: const Icon(Icons.check_circle, color: AppColors.success, size: 18), label: Text('${r.rows.length} ready')),
            Chip(avatar: const Icon(Icons.error_outline, color: AppColors.danger, size: 18), label: Text('${r.problems.length} to fix')),
            Chip(avatar: const Icon(Icons.skip_next, color: AppColors.muted, size: 18), label: Text('${r.skipped.length} left out')),
          ]),
          if (r.problems.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('To fix (these lines are not added):', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
            for (final p in r.problems.take(200))
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('Line ${p.line}: ${p.message}')),
            if (r.problems.length > 200) Text('… and ${r.problems.length - 200} more.'),
          ],
          if (r.skipped.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Left out:', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final p in r.skipped.take(50))
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('Line ${p.line}: ${p.message}', style: const TextStyle(color: AppColors.muted))),
            if (r.skipped.length > 50) Text('… and ${r.skipped.length - 50} more.'),
          ],
          if (r.rows.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Ready to add:', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final x in r.rows.take(100))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(x.name.isEmpty ? x.email : '${x.name} · ${x.email}'),
                subtitle: Text('${x.designation.title} · ${x.areaLabel}'),
              ),
            if (r.rows.length > 100) Text('… and ${r.rows.length - 100} more.'),
          ],
        ],
      ]),
    );
  }
}
