/// Levels of the area tree: district, block, zone (a group of village
/// panchayats under a Zonal Deputy BDO), village panchayat, habitation (the
/// unit staff are assigned to) and location (a street or site).
enum AreaLevel {
  district('district'),
  block('block'),
  zone('zone'),
  panchayat('panchayat'),
  habitation('habitation'),
  location('location');

  const AreaLevel(this.key);
  final String key;

  static AreaLevel? fromKey(String? k) {
    for (final l in AreaLevel.values) {
      if (l.key == k) return l;
    }
    return null;
  }

  /// The level a child of this level must have (null: no children allowed).
  AreaLevel? get childLevel => index + 1 < AreaLevel.values.length ? AreaLevel.values.elementAt(index + 1) : null;
}

/// One node of the area tree.
///
/// [path] lists the ids from the district down to this node itself. Every
/// operational record stores the same kind of path, so "is this record inside
/// my area?" is one list check, both here and in the database rules.
class AreaNode {
  const AreaNode({
    required this.id,
    required this.name,
    required this.level,
    required this.path,
    this.parentId,
    this.provisional = true,
  });

  final String id;
  final String name;
  final AreaLevel level;
  final String? parentId;
  final List<String> path;

  /// True until boundaries come from official GIS data (Phase 1, Q13).
  final bool provisional;

  static AreaNode? fromMap(String id, Map<String, dynamic> m) {
    final level = AreaLevel.fromKey(m['level'] as String?);
    final path = (m['path'] as List?)?.whereType<String>().toList();
    if (level == null || path == null || path.isEmpty || path.last != id) return null;
    return AreaNode(
      id: id,
      name: (m['name'] as String?)?.trim().isNotEmpty == true ? (m['name'] as String).trim() : id,
      level: level,
      parentId: m['parentId'] as String?,
      path: List.unmodifiable(path),
      provisional: m['provisional'] != false,
    );
  }

  /// The path a new child of this node must have.
  List<String> childPath(String childId) => [...path, childId];
}

/// True when a record with [recordPath] lies inside any of [scopeAreaIds].
/// An empty scope covers nothing (an officer with no area assigned sees no
/// area-based records).
bool areaCovers(List<String> scopeAreaIds, List<String> recordPath) =>
    scopeAreaIds.any(recordPath.contains);

/// "District › Block › Panchayat" for display, from names known for the ids.
String areaLabel(List<String> path, Map<String, String> namesById, {String separator = ' › '}) =>
    path.map((id) => namesById[id] ?? '…').join(separator);
