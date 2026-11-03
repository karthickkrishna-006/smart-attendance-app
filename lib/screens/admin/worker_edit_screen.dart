import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/ui.dart';
import '../../services/db.dart';
import '../../services/models.dart';

/// Create / update worker profiles. Role changes are admin-only.
class WorkerEditScreen extends StatefulWidget {
  final AppUser me;
  final AppUser? existing;
  const WorkerEditScreen({super.key, required this.me, this.existing});
  @override
  State<WorkerEditScreen> createState() => _WorkerEditScreenState();
}

class _WorkerEditScreenState extends State<WorkerEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _emp = TextEditingController(text: widget.existing?.employeeId ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _cat = TextEditingController(text: widget.existing?.category ?? '');
  late String _role = widget.existing?.role ?? Roles.worker;
  late String _status = widget.existing?.status ?? 'active';
  late String? _boundary = widget.existing?.boundaryId;
  late String? _supervisor = widget.existing?.supervisorId;
  bool _busy = false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final emp = _emp.text.trim();
    try {
      if (emp.isNotEmpty) {
        final dup = await Db.col('users').where('employeeId', isEqualTo: emp).get();
        if (dup.docs.any((d) => d.id != widget.existing?.uid)) {
          if (mounted) showSnack(context, 'Employee ID $emp is already used by another worker.', error: true);
          setState(() => _busy = false);
          return;
        }
      }
      final data = <String, dynamic>{
        'name': _name.text.trim(),
        'employeeId': emp,
        'phone': _phone.text.trim(),
        'category': _cat.text.trim(),
        'status': _status,
        'boundaryId': _boundary,
        'supervisorId': _supervisor,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (widget.me.isAdmin) data['role'] = _role;
      if (widget.existing == null) {
        final r = await Db.col('users').add({
          ...data,
          'role': widget.me.isAdmin ? _role : Roles.worker,
          'email': '',
          'hasLogin': false,
          'synthetic': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
        await Db.audit('worker_created', 'users/${r.id}', {'employeeId': emp});
      } else {
        await Db.col('users').doc(widget.existing!.uid).update(data);
        await Db.audit('worker_updated', 'users/${widget.existing!.uid}', {
          if (widget.existing!.role != _role) 'role': '${widget.existing!.role}→$_role',
          if (widget.existing!.status != _status) 'status': '${widget.existing!.status}→$_status',
        });
      }
      if (mounted) {
        showSnack(context, 'Saved.', success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final self = widget.existing?.uid == widget.me.uid;
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add worker' : 'Edit ${widget.existing!.name}')),
      body: LiveQueries(
        queries: [Db.col('boundaries'), Db.col('users').where('role', whereIn: [Roles.supervisor, Roles.admin])],
        builder: (context, d) {
          final bIds = d[0].map((b) => b['id']).toSet();
          final sIds = d[1].map((s) => s['id']).toSet();
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emp,
                decoration: const InputDecoration(labelText: 'Employee ID (official, human-facing)', helperText: 'Use the official ID format. Leave blank if not yet issued.'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
                validator: (v) => (v ?? '').isEmpty || RegExp(r'^[0-9+ ]{10,14}$').hasMatch(v!.trim()) ? null : 'Invalid phone number',
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _cat, decoration: const InputDecoration(labelText: 'Worker category / designation')),
              const SizedBox(height: 12),
              if (widget.me.isAdmin) ...[
                DropdownButtonFormField<String>(
                  value: _role,
                  decoration: InputDecoration(labelText: 'Role', helperText: self ? 'You cannot change your own role.' : null),
                  items: Roles.all.map((r) => DropdownMenuItem(value: r, child: Text(Roles.label(r)))).toList(),
                  onChanged: self ? null : (v) => setState(() => _role = v!),
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<String>(
                value: _status,
                decoration: const InputDecoration(labelText: 'Account / employment status'),
                items: const ['pending_approval', 'active', 'inactive', 'suspended']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s == 'pending_approval' ? 'Pending approval' : s[0].toUpperCase() + s.substring(1))))
                    .toList(),
                onChanged: self ? null : (v) => setState(() => _status = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                value: bIds.contains(_boundary) ? _boundary : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assigned boundary / location'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('— None —')),
                  ...d[0].map((b) => DropdownMenuItem<String?>(
                        value: b['id'] as String,
                        child: Text('${b['name']}${b['synthetic'] != false ? ' (SYNTHETIC)' : ''}', overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: (v) => setState(() => _boundary = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                value: sIds.contains(_supervisor) ? _supervisor : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Reporting supervisor'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('— None —')),
                  ...d[1].map((s) => DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name']} (${Roles.label(s['role'])})'))),
                ],
                onChanged: (v) => setState(() => _supervisor = v),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Save')),
              if (widget.existing == null) ...[
                const SizedBox(height: 10),
                const Text(
                  'Tip: workers who should use the app themselves can register with Google or email; then assign their role, boundary and employee ID here.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ]),
          );
        },
      ),
    );
  }
}
