import 'package:field_monitor/domain/area.dart';
import 'package:field_monitor/domain/designations.dart';
import 'package:field_monitor/domain/roles.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime t(int h, int m) => DateTime(2026, 11, 10, h, m);

void main() {
  test('every staff type from the requirement exists with its schedule', () {
    expect(Designation.thoomaiKavalar.schedule.slotMinutes, [540, 780]);
    expect(Designation.ohtOperator.schedule.minPhotos, 1);
    expect(Designation.mnp.schedule.minPhotos, 3);
    expect(Designation.vpSecretary.schedule.slotMinutes, [600, 780, 900, 1080]);
    expect(Designation.zonalDyBdo.schedule.minPhotos, 4);
    expect(Designation.dyBdoPanchayats.schedule.slotMinutes, [600, 1080]);
    expect(Designation.dyBdoRegular.schedule.slotMinutes, [600, 1080]);
    expect(Designation.bdoVillage.schedule.minPhotos, 1);
    expect(Designation.bdoBlock.schedule.minPhotos, 1);
    expect(Designation.districtMonitor.schedule.required, false);
    expect(Designation.values.map((d) => d.key).toSet().length, Designation.values.length);
    for (final d in Designation.values) {
      expect(Designation.fromKey(d.key), d);
    }
  });

  test('monitors get monitoring roles; field staff get the worker app', () {
    expect(Designation.thoomaiKavalar.role, Role.worker);
    expect(Designation.mnp.role, Role.supervisor);
    expect(Designation.vpSecretary.role, Role.supervisor);
    expect(Designation.zonalDyBdo.role, Role.zonalSecretary);
    expect(Designation.bdoVillage.role, Role.officer);
    expect(Designation.districtMonitor.role, Role.collector);
  });

  test('Thoomai Kavalar: 9 am and 1 pm photos complete the day', () {
    final c = complianceFor(Designation.thoomaiKavalar.schedule, [t(9, 10), t(13, 25)], t(17, 0));
    expect(c.complete, true);
    expect(c.required, 2);
    expect(c.slots.map((s) => s.state).toList(), [SlotState.done, SlotState.done]);
  });

  test('a missed 1 pm photo shows as missed after 2 pm, pending before', () {
    final s = Designation.thoomaiKavalar.schedule;
    expect(complianceFor(s, [t(9, 0)], t(13, 30)).slots.last.state, SlotState.pending);
    final late = complianceFor(s, [t(9, 0)], t(14, 5));
    expect(late.slots.last.state, SlotState.missed);
    expect(late.complete, false);
    expect(late.missedSlots, 1);
  });

  test('one photo counts for one time only; photos far from a time do not count for it', () {
    final s = Designation.vpSecretary.schedule;
    final c = complianceFor(s, [t(10, 5), t(12, 50), t(16, 30)], t(19, 30));
    expect(c.slots.map((x) => x.state).toList(), [SlotState.done, SlotState.done, SlotState.missed, SlotState.missed]);
    expect(c.taken, 3);
    expect(c.required, 4);
    expect(c.complete, false);
  });

  test('MNP and Zonal Dy.BDO: any times, minimum count', () {
    expect(complianceFor(Designation.mnp.schedule, [t(8, 0), t(11, 0), t(16, 0)], t(18, 0)).complete, true);
    expect(complianceFor(Designation.mnp.schedule, [t(8, 0), t(11, 0)], t(18, 0)).complete, false);
    expect(complianceFor(Designation.zonalDyBdo.schedule, [t(9, 0), t(11, 0), t(14, 0), t(17, 0)], t(18, 0)).complete, true);
    expect(complianceFor(Designation.ohtOperator.schedule, [t(6, 15)], t(7, 0)).complete, true);
  });

  test('habitation sits between village panchayat and location', () {
    expect(AreaLevel.panchayat.childLevel, AreaLevel.habitation);
    expect(AreaLevel.habitation.childLevel, AreaLevel.location);
    expect(AreaLevel.fromKey('habitation'), AreaLevel.habitation);
  });
}
