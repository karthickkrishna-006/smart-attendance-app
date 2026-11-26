import 'package:field_monitor/domain/area.dart';
import 'package:field_monitor/domain/designations.dart';
import 'package:field_monitor/domain/staff_import.dart';
import 'package:flutter_test/flutter_test.dart';

AreaNode _a(String id, String name, AreaLevel l, List<String> path) =>
    AreaNode(id: id, name: name, level: l, path: path, parentId: path.length > 1 ? path[path.length - 2] : null);

final _areas = [
  _a('d', 'Chengalpattu', AreaLevel.district, ['d']),
  _a('b', 'Kattankolathur', AreaLevel.block, ['d', 'b']),
  _a('p', 'Urapakkam', AreaLevel.panchayat, ['d', 'b', 'p']),
  _a('p2', 'Vallam', AreaLevel.panchayat, ['d', 'b', 'p2']),
  _a('h', 'Ayancheri', AreaLevel.habitation, ['d', 'b', 'p', 'h']),
  _a('h2', 'Urapakkam (Ct)', AreaLevel.habitation, ['d', 'b', 'p', 'h2']),
];

void main() {
  test('reads a sheet pasted from Excel, with headings in any case', () {
    final r = StaffSheet(_areas).read(
      'Email\tName\tEmployee ID\tDesignation\tBlock\tPanchayat\tHabitation\n'
      'KK@Gmail.com\tKarthick\tE1\tOHT Operator\tKattankolathur\tUrapakkam\tAyancheri\n'
      'tk@x.in\tRavi\t\tThoomai Kavalar\tkattankolathur\turapakkam\tUrapakkam Ct; Ayancheri\n'
      'z@x.in\tZonal\t\tZonal Dy.BDO\tKattankolathur\tUrapakkam; Vallam\t\n'
      'bdo@x.in\tBDO\t\tBDO (Village Panchayats)\tKattankolathur\t\t\n'
      'col@x.in\tCollector\t\tDistrict monitoring\t\t\t\n',
    );
    expect(r.problems, isEmpty);
    expect(r.rows.map((x) => x.email), ['kk@gmail.com', 'tk@x.in', 'z@x.in', 'bdo@x.in', 'col@x.in']);
    expect(r.rows[0].designation, Designation.ohtOperator);
    expect(r.rows[0].areaIds, ['h']);
    expect(r.rows[0].areaLabel, 'Kattankolathur › Urapakkam › Ayancheri');
    expect(r.rows[1].areaIds, ['h2', 'h']);
    expect(r.rows[2].areaIds, ['p', 'p2']);
    expect(r.rows[3].areaIds, ['b']);
    expect(r.rows[4].areaIds, ['d']);
  });

  test('reports problems by line and skips people already added', () {
    final r = StaffSheet(_areas).read(
      'email,name,employee id,designation,block,panchayat,habitation\n'
      'a@x.in,A,,MNP,Kattankolathur,Vallam,\n'
      'a@x.in,A again,,MNP,Kattankolathur,Vallam,\n'
      'old@x.in,Old,,MNP,Kattankolathur,Vallam,\n'
      'bad,No,,MNP,Kattankolathur,,\n'
      'x@x.in,X,,President,Kattankolathur,,\n'
      'y@x.in,Y,,MNP,Nowhere,,\n'
      'q@x.in,Q,,MNP,Kattankolathur,Vallam,Ayancheri\n'
      'n@x.in,"Rao, N",,TK,,,\n',
      existingEmails: {'old@x.in'},
    );
    expect(r.rows.map((x) => x.email), ['a@x.in']);
    expect(r.skipped.map((p) => p.line), [3, 4]);
    expect(r.problems.map((p) => p.line), [5, 6, 7, 8, 9]);
    expect(r.problems.last.message, 'No block.');
  });

  test('designations are recognised by their common short names', () {
    expect(StaffSheet.designationOf('OHT'), Designation.ohtOperator);
    expect(StaffSheet.designationOf('V.P. Secretary'), Designation.vpSecretary);
    expect(StaffSheet.designationOf('Dy BDO (Regular)'), Designation.dyBdoRegular);
    expect(StaffSheet.designationOf('bdo_block'), Designation.bdoBlock);
    expect(StaffSheet.designationOf('Clerk'), isNull);
  });
}
