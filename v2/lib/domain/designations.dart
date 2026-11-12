import 'roles.dart';

/// Which tier a designation belongs to (Chengalpattu rural development).
enum StaffTier { village, block, district }

/// How many GPS photos a designation must take each day, and at which times.
class PhotoSchedule {
  const PhotoSchedule({required this.minPhotos, this.slotMinutes = const [], this.eventLabel});

  /// At least this many photos per day.
  final int minPhotos;

  /// Fixed times (minutes after midnight) a photo is expected around, if any.
  final List<int> slotMinutes;

  /// For event-based photos (OHT operator: "water opened").
  final String? eventLabel;

  bool get required => minPhotos > 0;
}

/// Job titles of village panchayat, block and district staff. The [role]
/// decides what they may see and do (permissions); the [schedule] decides
/// their daily GPS photo attendance.
enum Designation {
  thoomaiKavalar('thoomai_kavalar', 'Thoomai Kavalar (Thooimai Paniyalar)', StaffTier.village, Role.worker,
      PhotoSchedule(minPhotos: 2, slotMinutes: [9 * 60, 13 * 60])),
  ohtOperator('oht_operator', 'OHT Operator', StaffTier.village, Role.worker,
      PhotoSchedule(minPhotos: 1, eventLabel: 'Water opened')),
  mnp('mnp', 'Makkal Nala Paniyalar (MNP)', StaffTier.village, Role.supervisor, PhotoSchedule(minPhotos: 3)),
  vpSecretary('vp_secretary', 'Village Panchayat Secretary', StaffTier.village, Role.supervisor,
      PhotoSchedule(minPhotos: 4, slotMinutes: [10 * 60, 13 * 60, 15 * 60, 18 * 60])),
  zonalDyBdo('zonal_dy_bdo', 'Zonal Deputy BDO', StaffTier.block, Role.zonalSecretary, PhotoSchedule(minPhotos: 4)),
  dyBdoPanchayats('dy_bdo_panchayats', 'Deputy BDO (Panchayats)', StaffTier.block, Role.worker,
      PhotoSchedule(minPhotos: 2, slotMinutes: [10 * 60, 18 * 60])),
  bdoVillage('bdo_village', 'BDO (Village Panchayats)', StaffTier.block, Role.officer, PhotoSchedule(minPhotos: 1)),
  dyBdoRegular('dy_bdo_regular', 'Deputy BDO (Regular)', StaffTier.block, Role.worker,
      PhotoSchedule(minPhotos: 2, slotMinutes: [10 * 60, 18 * 60])),
  bdoBlock('bdo_block', 'BDO (Block Panchayat)', StaffTier.block, Role.officer, PhotoSchedule(minPhotos: 1)),
  districtMonitor('district_monitor', 'District monitoring', StaffTier.district, Role.collector, PhotoSchedule(minPhotos: 0));

  const Designation(this.key, this.title, this.tier, this.role, this.schedule);

  final String key;
  final String title;
  final StaffTier tier;

  /// The permission role this designation is normally given.
  final Role role;
  final PhotoSchedule schedule;

  static Designation? fromKey(String? key) {
    for (final d in Designation.values) {
      if (d.key == key) return d;
    }
    return null;
  }

  /// Designations that can sensibly hold [role] (for the admin's role picker).
  static List<Designation> forRole(Role role) => Designation.values.where((d) => d.role == role).toList();
}

/// Minutes allowed before or after a scheduled time for a photo to count.
const slotToleranceMin = 60;

enum SlotState { done, pending, missed }

class SlotResult {
  const SlotResult(this.slotMinute, this.state, [this.at]);
  final int slotMinute;
  final SlotState state;
  final DateTime? at;

  String get label => '${(slotMinute ~/ 60).toString().padLeft(2, '0')}:${(slotMinute % 60).toString().padLeft(2, '0')}';
}

class Compliance {
  const Compliance({required this.required, required this.taken, required this.slots});

  /// Photos required today (at least the minimum, and one per fixed time).
  final int required;
  final int taken;
  final List<SlotResult> slots;

  bool get complete => taken >= required && slots.every((s) => s.state == SlotState.done);
  int get missedSlots => slots.where((s) => s.state == SlotState.missed).length;
}

/// Which of today's required photos are done, still pending or missed.
///
/// Each photo can satisfy at most one fixed time: the nearest one within
/// [slotToleranceMin] minutes. [photoTimes] and [now] are local times on the
/// same day. Pure function, unit-tested.
Compliance complianceFor(PhotoSchedule s, List<DateTime> photoTimes, DateTime now) {
  final times = [...photoTimes]..sort();
  final used = <int>{};
  final slots = <SlotResult>[];
  for (final slot in s.slotMinutes) {
    int? best;
    var bestDiff = slotToleranceMin + 1;
    for (var i = 0; i < times.length; i++) {
      if (used.contains(i)) continue;
      final t = times.elementAt(i);
      final diff = (t.hour * 60 + t.minute - slot).abs();
      if (diff <= slotToleranceMin && diff < bestDiff) {
        best = i;
        bestDiff = diff;
      }
    }
    if (best != null) {
      used.add(best);
      slots.add(SlotResult(slot, SlotState.done, times.elementAt(best)));
    } else {
      final nowMin = now.hour * 60 + now.minute;
      slots.add(SlotResult(slot, nowMin > slot + slotToleranceMin ? SlotState.missed : SlotState.pending));
    }
  }
  final required = s.minPhotos > s.slotMinutes.length ? s.minPhotos : s.slotMinutes.length;
  return Compliance(required: required, taken: times.length, slots: slots);
}
