import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'audited_batch.dart';

/// Loads the official Chengalpattu areas from the Local Government Directory
/// (assets/lgd/chengalpattu_lgd.json): 8 blocks → 359 village panchayats →
/// their villages as habitations.
///
/// Ids come from the LGD codes (lgd-b-6175, lgd-gp-223892,
/// lgd-v-223892-630069), so running it again updates instead of duplicating,
/// and areas already up to date are skipped. Writes are audited, level by
/// level (a child's path is checked against its saved parent), 5 per batch.
class LgdImport {
  LgdImport(this.user, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;
  final User user;
  final FirebaseFirestore db;

  static const asset = 'assets/lgd/chengalpattu_lgd.json';

  Future<String> run({void Function(String)? progress}) async {
    final data = jsonDecode(await rootBundle.loadString(asset)) as Map<String, dynamic>;
    final district = data['district'] as Map<String, dynamic>;
    final blocks = (data['blocks'] as List).cast<Map<String, dynamic>>();

    progress?.call('Reading existing areas');
    final existing = {for (final d in (await db.collection('areas').get()).docs) d.id: d.data()};

    // The district: an existing "Chengalpattu" district, or a new one.
    final districtName = '${district['name']}';
    String? districtId;
    for (final e in existing.entries) {
      if (e.value['level'] == 'district' && '${e.value['name']}'.toLowerCase().contains(districtName.toLowerCase())) {
        districtId = e.key;
        break;
      }
    }
    final writes = <_Area>[];
    late final List<String> districtPath;
    if (districtId == null) {
      districtId = 'lgd-${district['code']}';
      districtPath = [districtId];
      writes.add(_Area(districtId, districtName, 'district', null, districtPath));
    } else {
      districtPath = ((existing[districtId]!['path'] as List?) ?? [districtId]).whereType<String>().toList();
    }

    final levels = <List<_Area>>[[], [], []];
    for (final b in blocks) {
      final bid = 'lgd-b-${b['code']}';
      final bpath = [...districtPath, bid];
      levels[0].add(_Area(bid, '${b['name']}', 'block', districtId, bpath));
      for (final g in (b['panchayats'] as List).cast<Map<String, dynamic>>()) {
        final gid = 'lgd-gp-${g['code']}';
        final gpath = [...bpath, gid];
        levels[1].add(_Area(gid, '${g['name']}', 'panchayat', bid, gpath));
        for (final v in (g['villages'] as List).cast<Map<String, dynamic>>()) {
          final vid = 'lgd-v-${g['code']}-${v['code']}';
          levels[2].add(_Area(vid, '${v['name']}', 'habitation', gid, [...gpath, vid]));
        }
      }
    }

    bool upToDate(_Area a) {
      final e = existing[a.id];
      if (e == null) return false;
      final path = ((e['path'] as List?) ?? const []).whereType<String>().toList();
      return e['name'] == a.name && e['level'] == a.level && e['parentId'] == a.parentId && path.join('/') == a.path.join('/');
    }

    var saved = 0, skipped = 0;
    Future<void> save(String step, List<_Area> list) async {
      final todo = list.where((a) => !upToDate(a)).toList();
      skipped += list.length - todo.length;
      for (var i = 0; i < todo.length; i += 5) {
        progress?.call('$step: ${i + 1}–${(i + 5).clamp(0, todo.length)} of ${todo.length}');
        final b = AuditedBatch(db, user);
        for (final a in todo.skip(i).take(5)) {
          b.batch.set(db.doc('areas/${a.id}'), {
            'name': a.name,
            'level': a.level,
            'parentId': a.parentId,
            'path': a.path,
            'provisional': false,
            ...b.stamp('lgd_area_import', 'areas/${a.id}', details: 'LGD'),
          });
        }
        try {
          await b.commit();
        } catch (e) {
          throw 'Step "$step" failed: $e';
        }
        saved += todo.skip(i).take(5).length;
      }
    }

    await save('District', writes);
    await save('Blocks', levels[0]);
    await save('Village panchayats', levels[1]);
    await save('Habitations', levels[2]);
    return 'Chengalpattu areas loaded from LGD: ${levels[0].length} blocks, ${levels[1].length} village panchayats, '
        '${levels[2].length} habitations ($saved saved, $skipped already up to date).';
  }
}

class _Area {
  const _Area(this.id, this.name, this.level, this.parentId, this.path);
  final String id;
  final String name;
  final String level;
  final String? parentId;
  final List<String> path;
}
