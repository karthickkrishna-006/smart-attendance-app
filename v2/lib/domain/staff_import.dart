import 'area.dart';
import 'designations.dart';

/// One person read from a staff sheet, ready to be pre-registered.
class ImportRow {
  const ImportRow({
    required this.line,
    required this.email,
    required this.name,
    required this.employeeId,
    required this.designation,
    required this.areaIds,
    required this.areaLabel,
  });

  /// Line number in the pasted sheet (1 = first line), for messages.
  final int line;
  final String email;
  final String name;
  final String employeeId;
  final Designation designation;
  final List<String> areaIds;

  /// The areas as people read them, e.g. "Kattankolathur › Urapakkam".
  final String areaLabel;
}

class ImportProblem {
  const ImportProblem(this.line, this.message);
  final int line;
  final String message;
}

class ImportResult {
  const ImportResult(this.rows, this.problems, this.skipped);

  /// Ready to add.
  final List<ImportRow> rows;

  /// Lines that cannot be added until they are fixed.
  final List<ImportProblem> problems;

  /// Lines left out on purpose (already added, or a repeat in the sheet).
  final List<ImportProblem> skipped;
}

/// Reads a staff sheet pasted from Excel (tab-separated) or a CSV file.
///
/// Columns, found by the heading row (any order, any case):
/// email, name, employee id, designation, block, panchayat, habitation.
/// Without a heading row they are taken in that order.
///
/// The area is the deepest of block / panchayat / habitation that is filled
/// in. Several panchayats or habitations can be given separated by ";"
/// (for example a Zonal Deputy BDO's panchayats).
class StaffSheet {
  StaffSheet(List<AreaNode> areas) {
    for (final a in areas) {
      _children.putIfAbsent(a.parentId, () => []).add(a);
    }
    _roots = _children[null] ?? const [];
  }

  static const maxAreas = 15;
  static const template = 'email\tname\temployee id\tdesignation\tblock\tpanchayat\thabitation';

  final _children = <String?, List<AreaNode>>{};
  late final List<AreaNode> _roots;

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static final _aliases = <String, Designation>{
    for (final d in Designation.values) ...{_norm(d.key): d, _norm(d.title): d},
    'thoomaikavalar': Designation.thoomaiKavalar,
    'thooimaikavalar': Designation.thoomaiKavalar,
    'thooimaipaniyalar': Designation.thoomaiKavalar,
    'thoomaipaniyalar': Designation.thoomaiKavalar,
    'tk': Designation.thoomaiKavalar,
    'oht': Designation.ohtOperator,
    'ohtoperator': Designation.ohtOperator,
    'overheadtankoperator': Designation.ohtOperator,
    'mnp': Designation.mnp,
    'makkalnalapaniyalar': Designation.mnp,
    'vpsecretary': Designation.vpSecretary,
    'secretary': Designation.vpSecretary,
    'panchayatsecretary': Designation.vpSecretary,
    'vpsec': Designation.vpSecretary,
    'zonaldybdo': Designation.zonalDyBdo,
    'zonaldeputybdo': Designation.zonalDyBdo,
    'zonalbdo': Designation.zonalDyBdo,
    'dybdopanchayats': Designation.dyBdoPanchayats,
    'deputybdopanchayats': Designation.dyBdoPanchayats,
    'dybdopanchayat': Designation.dyBdoPanchayats,
    'dybdoregular': Designation.dyBdoRegular,
    'deputybdoregular': Designation.dyBdoRegular,
    'bdovillage': Designation.bdoVillage,
    'bdovillagepanchayats': Designation.bdoVillage,
    'bdovp': Designation.bdoVillage,
    'bdoblock': Designation.bdoBlock,
    'bdoblockpanchayat': Designation.bdoBlock,
    'bdobp': Designation.bdoBlock,
    'districtmonitor': Designation.districtMonitor,
    'districtmonitoring': Designation.districtMonitor,
  };

  static Designation? designationOf(String s) => _aliases[_norm(s)];

  static List<String> _split(String line) {
    if (line.contains('\t')) return line.split('\t').map((c) => c.trim()).toList();
    // CSV with optional "quoted, cells".
    final out = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (ch == ',' && !quoted) {
        out.add(cell.toString().trim());
        cell.clear();
      } else {
        cell.write(ch);
      }
    }
    out.add(cell.toString().trim());
    return out;
  }

  static const _cols = ['email', 'name', 'employee', 'designation', 'block', 'panchayat', 'habitation'];

  static String? _columnOf(String heading) {
    final h = _norm(heading);
    if (h.contains('mail')) return 'email';
    if (h.contains('employee') || h == 'empid' || h == 'id') return 'employee';
    if (h.contains('designation') || h.contains('stafftype') || h == 'job' || h == 'post' || h == 'role') return 'designation';
    if (h.contains('habitation') || h == 'village' || h == 'hamlet') return 'habitation';
    if (h.contains('block') || h == 'union') return 'block';
    if (h.contains('panchayat') || h == 'vp') return 'panchayat';
    if (h.contains('name')) return 'name';
    return null;
  }

  AreaNode? _find(List<AreaNode> among, String name) {
    final n = _norm(name);
    for (final a in among) {
      if (_norm(a.name) == n) return a;
    }
    return null;
  }

  /// [existingEmails]: people already added (they are skipped, not changed).
  ImportResult read(String text, {Set<String> existingEmails = const {}}) {
    final rows = <ImportRow>[];
    final problems = <ImportProblem>[];
    final skipped = <ImportProblem>[];
    final seen = <String>{};
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    var map = <String, int>{for (var i = 0; i < _cols.length; i++) _cols[i]: i};
    var start = 0;
    final firstFilled = lines.indexWhere((l) => l.trim().isNotEmpty);
    if (firstFilled >= 0) {
      final head = _split(lines[firstFilled]);
      final found = <String, int>{};
      for (var i = 0; i < head.length; i++) {
        final c = _columnOf(head[i]);
        if (c != null) found.putIfAbsent(c, () => i);
      }
      if (found.containsKey('email')) {
        map = found;
        start = firstFilled + 1;
      }
    }

    for (var i = start; i < lines.length; i++) {
      final raw = lines[i];
      if (raw.trim().isEmpty) continue;
      final line = i + 1;
      final c = _split(raw);
      String cell(String col) {
        final at = map[col];
        return at == null || at >= c.length ? '' : c[at].trim();
      }

      final email = cell('email').toLowerCase();
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
        problems.add(ImportProblem(line, email.isEmpty ? 'No email.' : '"$email" is not a valid email.'));
        continue;
      }
      if (!seen.add(email)) {
        skipped.add(ImportProblem(line, '$email appears twice in the sheet; the first one is used.'));
        continue;
      }
      if (existingEmails.contains(email)) {
        skipped.add(ImportProblem(line, '$email is already added.'));
        continue;
      }
      final job = designationOf(cell('designation'));
      if (job == null) {
        problems.add(ImportProblem(line, cell('designation').isEmpty ? 'No designation.' : 'Unknown designation "${cell('designation')}".'));
        continue;
      }

      // Area: district → block → panchayat(s) → habitation(s).
      final block = cell('block');
      final panchayats = cell('panchayat').split(';').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
      final habitations = cell('habitation').split(';').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
      List<AreaNode> picked;
      String? error;
      final trail = <String>[]; // official names, for the preview
      if (block.isEmpty) {
        if (job == Designation.districtMonitor && _roots.isNotEmpty) {
          picked = [_roots.first];
        } else {
          problems.add(ImportProblem(line, 'No block.'));
          continue;
        }
      } else {
        AreaNode? b;
        for (final r in _roots) {
          b ??= _find(_children[r.id] ?? const [], block);
        }
        if (b == null) {
          problems.add(ImportProblem(line, 'Block "$block" not found.'));
          continue;
        }
        picked = [b];
        trail.add(b.name);
        if (panchayats.isNotEmpty) {
          final ps = <AreaNode>[];
          for (final p in panchayats) {
            final f = _find(_children[b.id] ?? const [], p);
            if (f == null) {
              error = 'Panchayat "$p" not found in $block.';
              break;
            }
            ps.add(f);
          }
          picked = ps;
          trail.add(ps.map((x) => x.name).join(', '));
          if (error == null && habitations.isNotEmpty) {
            if (ps.length != 1) {
              error = 'Give one panchayat when habitations are given.';
            } else {
              final hs = <AreaNode>[];
              for (final h in habitations) {
                final f = _find(_children[ps.first.id] ?? const [], h);
                if (f == null) {
                  error = 'Habitation "$h" not found in ${ps.first.name}.';
                  break;
                }
                hs.add(f);
              }
              picked = hs;
              trail.add(hs.map((x) => x.name).join(', '));
            }
          }
        } else if (habitations.isNotEmpty) {
          error = 'Give the panchayat of the habitation.';
        }
      }
      if (error != null) {
        problems.add(ImportProblem(line, error));
        continue;
      }
      if (picked.length > maxAreas) {
        problems.add(ImportProblem(line, 'At most $maxAreas areas per person.'));
        continue;
      }
      rows.add(ImportRow(
        line: line,
        email: email,
        name: cell('name'),
        employeeId: cell('employee'),
        designation: job,
        areaIds: [for (final a in picked) a.id],
        areaLabel: trail.isEmpty ? picked.first.name : trail.join(' › '),
      ));
    }
    return ImportResult(rows, problems, skipped);
  }
}
